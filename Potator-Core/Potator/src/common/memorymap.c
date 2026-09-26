////////////////////////////////////////////////////////////////////////////////
//
////////////////////////////////////////////////////////////////////////////////
//
//
//
//
//
////////////////////////////////////////////////////////////////////////////////
#include "memorymap.h"
#include "sound.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

uint8	*memorymap_programRom;
uint8	*memorymap_lowerRam;
uint8	*memorymap_upperRam;
uint8	*memorymap_lowerRomBank;
uint8	*memorymap_upperRomBank;
uint8	*memorymap_regs;

static uint32   memorymap_programRomSize;

////////////////////////////////////////////////////////////////////////////////
//
////////////////////////////////////////////////////////////////////////////////
//
//
//
//
//
////////////////////////////////////////////////////////////////////////////////
uint8 *memorymap_getRomPointer(void)
{
	return(memorymap_programRom);
}

uint32 memorymap_getRomSize(void)
{
	return(memorymap_programRomSize);
}

////////////////////////////////////////////////////////////////////////////////
//
////////////////////////////////////////////////////////////////////////////////
//
//
//
//
//
////////////////////////////////////////////////////////////////////////////////
void memorymap_init()
{
	fprintf(log_get(), "memorymap: init\n");
	memory_malloc_secure((void**)&memorymap_lowerRam, 0x2000, "Lower ram");
	memory_malloc_secure((void**)&memorymap_upperRam, 0x2000, "Upper ram");
	memory_malloc_secure((void**)&memorymap_regs,     0x2000, "Internal registers");

}
////////////////////////////////////////////////////////////////////////////////
//
////////////////////////////////////////////////////////////////////////////////
//
//
//
//
//
////////////////////////////////////////////////////////////////////////////////
void memorymap_done()
{
	//fprintf(log_get(), "memorymap: done\n");
}
////////////////////////////////////////////////////////////////////////////////
//
////////////////////////////////////////////////////////////////////////////////
//
//
//
//
//
////////////////////////////////////////////////////////////////////////////////
void memorymap_reset()
{
	//fprintf(log_get(), "memorymap: reset\n");
	memorymap_lowerRomBank = memorymap_programRom + 0x0000;
	memorymap_upperRomBank = memorymap_programRom + (memorymap_programRomSize==0x10000?0xc000:0x4000);

	memset(memorymap_lowerRam, 0x00, 0x2000);
	memset(memorymap_upperRam, 0x00, 0x2000);
}
////////////////////////////////////////////////////////////////////////////////
//
////////////////////////////////////////////////////////////////////////////////
//
//
//
//
//
////////////////////////////////////////////////////////////////////////////////
uint8  memorymap_registers_read(uint32 Addr)
{
	switch (Addr&0x1fff)
	{
	case 0x00:
	case 0x01:
	case 0x02:
	case 0x03: return(gpu_read(Addr));
	case 0x20: return(controls_read(Addr));
	case 0x21: return(io_read(Addr));
	case 0x23:
	case 0x24: return(timer_read(Addr));
	}
	uint8 data = memorymap_regs[Addr&0x1fff]; 
//	iprintf("regs: reading 0x%.2x from 0x%.4x\n", data, Addr);
	return(data);
}
////////////////////////////////////////////////////////////////////////////////
//
////////////////////////////////////////////////////////////////////////////////
//
//
//
//
//
////////////////////////////////////////////////////////////////////////////////
void memorymap_registers_write(uint32 Addr, uint8 Value)
{
	memorymap_regs[Addr&0x1fff] = Value;

	switch (Addr&0x1fff)
	{
	case 0x00:
	case 0x01:
	case 0x02:
	case 0x03:  gpu_write(Addr, Value);
				break;
	case 0x22:	io_write(Addr, Value);
				break;
	case 0x23:
	case 0x24:  timer_write(Addr, Value);
				break;
	case 0x26:
			//fprintf(log_get(), "memorymap: writing 0x%.2x to rom bank register\n", Value);
			memorymap_lowerRomBank = memorymap_programRom + ((((uint32)Value) & 0x60) << 9);
			memorymap_upperRomBank = memorymap_programRom + (memorymap_programRomSize==0x10000?0xc000:0x4000); 
			return;
	case 0x27: 	//fprintf(log_get(), "regs: writing 0x%.2x from 0x%.4x\n", Value, Addr);		
				break;
	case 0x10:
	case 0x11:
	case 0x12:	
	case 0x14:
	case 0x15:
	case 0x16:	
#ifdef GP2X
		if(currentConfig.enable_sound) sound_write(Addr&7, Value); break;
#else
		sound_write(Addr&7, Value); break;
#endif
	case 0x28:
	case 0x29:
	case 0x2a: 
#ifdef GP2X
		if(currentConfig.enable_sound) sound_noise_write(Addr&0x07, Value); break;
#else
		sound_noise_write(Addr&0x07, Value); break;
#endif
	case 0x18:
	case 0x19:
	case 0x1a:
	case 0x1b:
	case 0x1c:
#ifdef GP2X
		if(currentConfig.enable_sound) sound_audio_dma(Addr&0x07, Value); break;
#else
		sound_audio_dma(Addr&0x07, Value); break;
#endif
	}
}
////////////////////////////////////////////////////////////////////////////////
//
////////////////////////////////////////////////////////////////////////////////
//
//
//
//
//
////////////////////////////////////////////////////////////////////////////////
void Wr6502(register word Addr,register byte Value)
{
	Addr&=0xffff;
	switch (Addr>>12)
	{
	case 0x0:
	case 0x1:	memorymap_lowerRam[Addr] = Value;			return;
	case 0x2:
	case 0x3:	memorymap_registers_write(Addr, Value);	return;
	case 0x4:
	case 0x5:	memorymap_upperRam[Addr&0x1fff] = Value;	return;
	}
}
////////////////////////////////////////////////////////////////////////////////
//
////////////////////////////////////////////////////////////////////////////////
//
//
//
//
//
////////////////////////////////////////////////////////////////////////////////
byte Rd6502(register word Addr)
{	
	Addr&=0xffff;

	switch (Addr>>12)
	{
	case 0x0:
	case 0x1:	return(memorymap_lowerRam[Addr]);
	case 0x2:
	case 0x3:	return(memorymap_registers_read(Addr));
	case 0x4:
	case 0x5:	return(memorymap_upperRam[Addr&0x1fff]);
	case 0x6:
	case 0x7:	return(memorymap_programRom[Addr&0x1fff]);
	case 0x8:
	case 0x9:
	case 0xa:
	case 0xb: 	return(memorymap_lowerRomBank[Addr&0x3fff]);
	case 0xc:
	case 0xd:
	case 0xe:
	case 0xf: 	return(memorymap_upperRomBank[Addr&0x3fff]);
	}
	return(0xff);
}
//////////////////////////////////////////////////////////////////////////////
//
//////////////////////////////////////////////////////////////////////////////
//
//
//
//
//
//
//////////////////////////////////////////////////////////////////////////////
void memorymap_load(uint8 *rom, uint32 size)
{
	memorymap_programRomSize = size;
	memorymap_programRom = rom;

	if (memorymap_programRomSize == 32768)
	{
		uint8 *tmp = (uint8*)malloc(0x10000);
		memcpy(tmp+0x0000, memorymap_programRom, 0x8000);
		memcpy(tmp+0x8000, memorymap_programRom, 0x8000);
		free(memorymap_programRom);
		memorymap_programRom = tmp;
		memorymap_programRomSize = 0x10000;
	}
}
////////////////////////////////////////////////////////////////////////////////
//
////////////////////////////////////////////////////////////////////////////////
//
//
//
//
//
////////////////////////////////////////////////////////////////////////////////
uint8 *memorymap_getUpperRamPointer(void)
{
	return(memorymap_upperRam);
}
uint8 *memorymap_getLowerRamPointer(void)
{
	return(memorymap_lowerRam);
}
uint8 *memorymap_getUpperRomBank(void)
{
	return(memorymap_upperRomBank);
}
uint8 *memorymap_getLowerRomBank(void)
{
	return(memorymap_lowerRomBank);
}
uint8 *memorymap_getRegisters(void)
{
	return(memorymap_regs);
}
