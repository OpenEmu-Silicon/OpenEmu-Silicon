#ifndef __SOUND_H__
#define __SOUND_H__

#include "supervision.h"

#if defined __cplusplus
extern "C" {
#endif

void sound_init();
void sound_reset();
void sound_done();
void sound_write(uint32 Addr, uint8 data);
void sound_noise_write(uint32 Addr, uint8 data);
void sound_audio_dma(uint32 Addr, uint8 data);
void sound_exec(uint32 cycles);
void audio_turnSound(BOOL bOn);
// Tick the per-channel note-duration counters. Call once per frame.
void sound_decrement(void);
// Render `len` bytes of unsigned 8-bit stereo (interleaved L,R; 2 bytes per frame).
void sound_stream_update(uint8 *stream, uint32 len);

#if defined __cplusplus
}
#endif

#endif
