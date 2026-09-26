////////////////////////////////////////////////////////////////////////////////
//
// Watara Supervision sound emulation.
//
// Synthesis ported from the modern libretro Potator core (common/sound.c):
// two square-wave channels, an LFSR noise channel, and a 4-bit sample DMA
// channel, mixed into an unsigned 8-bit stereo stream. The register-write
// entry points keep the signatures this tree's memorymap.c already calls, so
// the memory map needs no changes.
//
////////////////////////////////////////////////////////////////////////////////
#include "sound.h"
#include "memorymap.h"
#include <string.h>

#define UNSCALED_CLOCK 4000000
#define SV_SAMPLE_RATE 44100

typedef struct {
	uint8  reg[4];
	int    on;
	uint8  waveform, volume;
	uint16 pos, size;
	uint16 count;
} SVISION_CHANNEL;
static SVISION_CHANNEL m_channel[2];
// Synced copy used for glitch-free playback (updated on waveform boundaries).
static SVISION_CHANNEL ch[2];

typedef struct {
	uint8  reg[3];
	int    on, right, left, play;
	uint8  type; // 6 = 7-bit LFSR, 14 = 15-bit LFSR
	uint16 state;
	uint8  value, volume;
	uint16 count;
	double pos, step;
} SVISION_NOISE;
static SVISION_NOISE m_noise;

typedef struct {
	uint8  reg[5];
	int    on, right, left;
	uint32 ca14to16;
	uint16 start;
	uint16 size;
	double pos, step;
} SVISION_DMA;
static SVISION_DMA m_dma;

static BOOL sound_muted = FALSE;

void sound_reset()
{
	memset(m_channel, 0, sizeof(m_channel));
	memset(&m_noise,  0, sizeof(m_noise));
	memset(&m_dma,    0, sizeof(m_dma));
	memset(ch,        0, sizeof(ch));
}

void sound_init()
{
	sound_reset();
}

void sound_done()
{
}

void audio_turnSound(BOOL bOn)
{
	sound_muted = !bOn;
}

void sound_exec(uint32 cycles)
{
	(void)cycles;
}

// Note-duration counters tick once per frame (matching the upstream cadence, where
// supervision_exec calls this at frame end). Doing it per-scanline expires count-gated
// notes ~160x too fast and silences them.
void sound_decrement(void)
{
	if (m_channel[0].count > 0) m_channel[0].count--;
	if (m_channel[1].count > 0) m_channel[1].count--;
	if (m_noise.count    > 0) m_noise.count--;
}

void sound_stream_update(uint8 *stream, uint32 len)
{
	uint32 i;
	int j;
	SVISION_CHANNEL *channel;
	uint8 s = 0;
	uint8 *left  = stream + 0;
	uint8 *right = stream + 1;

	if (sound_muted) {
		memset(stream, 0, len);
		return;
	}

	for (i = 0; i < len >> 1; i++, left += 2, right += 2) {
		*left = *right = 0;

		for (channel = m_channel, j = 0; j < 2; j++, channel++) {
			if (ch[j].size != 0) {
				if (ch[j].on || channel->count != 0) {
					BOOL on = FALSE;
					switch (ch[j].waveform) {
					case 0: on = ch[j].pos < ((28 * ch[j].size) >> 5); break; // 12.5%
					case 1: on = ch[j].pos < ((24 * ch[j].size) >> 5); break; // 25%
					case 2: on = ch[j].pos < (ch[j].size / 2);         break; // 50%
					case 3: on = ch[j].pos < (ch[j].size / 4);         break; // 75%
					}
					s = on ? ch[j].volume : 0;
					if (j == 0)
						*right += s;
					else
						*left += s;
				}
				ch[j].pos++;
				if (ch[j].pos >= ch[j].size) {
					ch[j].pos = 0;
					if (channel->on) {
						memcpy(&ch[j], channel, sizeof(ch[j]));
						channel->on = FALSE;
					}
				}
			}
		}

		if (m_noise.on && (m_noise.play || m_noise.count != 0)) {
			s = m_noise.value * m_noise.volume;
			if (m_noise.left)  *left  += s;
			if (m_noise.right) *right += s;
			m_noise.pos += m_noise.step;
			while (m_noise.pos >= 1.0) {
				uint16 feedback;
				m_noise.value = m_noise.state & 1;
				feedback = ((m_noise.state >> 1) ^ m_noise.state) & 0x0001;
				feedback <<= m_noise.type;
				m_noise.state = (m_noise.state >> 1) | feedback;
				m_noise.pos -= 1.0;
			}
		}

		if (m_dma.on) {
			uint8 sample;
			uint16 addr = m_dma.start + (uint16)m_dma.pos / 2;
			if (addr >= 0x8000 && addr < 0xc000) {
				uint32 romSize = memorymap_getRomSize();
				uint32 index = (addr & 0x3fff) | m_dma.ca14to16;
				sample = romSize ? memorymap_getRomPointer()[index % romSize] : 0;
			}
			else {
				sample = Rd6502(addr);
			}
			if (((uint16)m_dma.pos) & 1)
				s = (sample & 0x0f);
			else
				s = (sample & 0xf0) >> 4;
			if (m_dma.left)  *left  += s;
			if (m_dma.right) *right += s;
			m_dma.pos += m_dma.step;
			if (m_dma.pos >= m_dma.size) {
				m_dma.on = FALSE;
				// DMA-finished interrupt (equivalent of memorymap_set_dma_finished).
				if (Rd6502(0x2026) & 0x04) {
					Wr6502(0x2027, Rd6502(0x2027) | 0x02);
					interrupts_irq();
				}
			}
		}
	}
}

void sound_write(uint32 Addr, uint8 data)
{
	int which  = (Addr & 0x04) >> 2;
	int offset =  Addr & 0x03;
	SVISION_CHANNEL *channel = &m_channel[which];

	channel->reg[offset] = data;
	switch (offset) {
	case 0:
	case 1: {
		uint16 size = channel->reg[0] | ((channel->reg[1] & 7) << 8);
		channel->size = (uint16)((double)SV_SAMPLE_RATE * ((size + 1) << 5) / UNSCALED_CLOCK);
		channel->pos = 0;
		if (channel->count != 0 || ch[which].size == 0 || channel->size == 0) {
			ch[which].size = channel->size;
			if (channel->count == 0)
				ch[which].pos = 0;
		}
		break;
	}
	case 2:
		channel->on       =  data & 0x40;
		channel->waveform = (data & 0x30) >> 4;
		channel->volume   =  data & 0x0f;
		if (!channel->on || ch[which].size == 0 || channel->size == 0) {
			uint16 pos = ch[which].pos;
			memcpy(&ch[which], channel, sizeof(ch[which]));
			if (channel->count != 0)
				ch[which].pos = pos;
		}
		break;
	case 3:
		channel->count = data + 1;
		ch[which].size = channel->size;
		break;
	}
}

void sound_noise_write(uint32 Addr, uint8 data)
{
	int offset = Addr & 0x03;

	m_noise.reg[offset] = data;
	switch (offset) {
	case 0: {
		uint32 divisor = 8 << (data >> 4);
		m_noise.step   = (double)UNSCALED_CLOCK / ((double)SV_SAMPLE_RATE * divisor);
		m_noise.volume = data & 0x0f;
		break;
	}
	case 1:
		m_noise.count = data + 1;
		break;
	case 2:
		m_noise.type  = (data & 1) ? 14 : 6;
		m_noise.play  =  data & 2;
		m_noise.right =  data & 4;
		m_noise.left  =  data & 8;
		m_noise.on    =  data & 0x10;
		m_noise.state = 1;
		break;
	}
	m_noise.pos = 0.0;
}

void sound_audio_dma(uint32 Addr, uint8 data)
{
	int offset = Addr & 0x07;

	m_dma.reg[offset] = data;
	switch (offset) {
	case 0:
	case 1:
		m_dma.start = (m_dma.reg[0] | (m_dma.reg[1] << 8));
		break;
	case 2:
		m_dma.size = (data ? data : 0x100) * 32; // number of 4-bit samples
		break;
	case 3:
		m_dma.step     = (double)UNSCALED_CLOCK / ((double)SV_SAMPLE_RATE * (256 << (data & 3)));
		m_dma.right    =  data & 4;
		m_dma.left     =  data & 8;
		m_dma.ca14to16 = ((data & 0x70) >> 4) << 14;
		break;
	case 4:
		m_dma.on = data & 0x80;
		if (m_dma.on)
			m_dma.pos = 0.0;
		break;
	}
}
