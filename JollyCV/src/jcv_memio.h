/*
Copyright (c) 2020-2022 Rupert Carmichael
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#ifndef JCV_MEMIO_H
#define JCV_MEMIO_H

#define SIZE_1K 0x400
#define SIZE_8K 0x2000
#define SIZE_16K 0x4000
#define SIZE_32K 0x8000

#define SIZE_CVBIOS SIZE_8K
#define SIZE_CVRAM SIZE_1K

// Segment 0: Numpad, FireR
#define CV_INPUT_FR 0x40 // Right Fire Button
#define CV_INPUT_1 0x02 // Numpad 1
#define CV_INPUT_2 0x08 // Numpad 2
#define CV_INPUT_3 0x03 // Numpad 3
#define CV_INPUT_4 0x0d // Numpad 4
#define CV_INPUT_5 0x0c // Numpad 5
#define CV_INPUT_6 0x01 // Numpad 6
#define CV_INPUT_7 0x0a // Numpad 7
#define CV_INPUT_8 0x0e // Numpad 8
#define CV_INPUT_9 0x04 // Numpad 9
#define CV_INPUT_0 0x05 // Numpad 0
#define CV_INPUT_STR 0x06 // Numpad Star (*)
#define CV_INPUT_PND 0x09 // Numpad Pound (#)
// Segment 1: Joystick, FireL - Shifted 8 left for easier input state management
#define CV_INPUT_FL 0x40 << 8 // Left Fire Button
#define CV_INPUT_SP 0x30 << 8 // Spinner Plus
#define CV_INPUT_SM 0x10 << 8 // Spinner Minus
#define CV_INPUT_U 0x01 << 8 // Joystick Up
#define CV_INPUT_D 0x04 << 8 // Joystick Down
#define CV_INPUT_L 0x08 << 8 // Joystick Left
#define CV_INPUT_R 0x02 << 8 // Joystick Right
// Super Action Controller Buttons
#define CV_INPUT_Y CV_INPUT_FL // Yellow
#define CV_INPUT_O CV_INPUT_FR // Orange
#define CV_INPUT_P 0x07 // Purple
#define CV_INPUT_B 0x0b // Blue

typedef struct _cv_sys_t {
    uint8_t ram[SIZE_CVRAM]; // System RAM
    uint8_t sgmram[SIZE_32K]; // Super Game Module RAM
    uint8_t cseg; // Controller Strobe Segment
    uint16_t ctrl[2]; // Controller Input state
} cv_sys_t;

void jcv_input_set_callback(uint16_t (*)(int));

uint8_t jcv_io_rd(uint8_t);
void jcv_io_wr(uint8_t, uint8_t);

uint8_t jcv_mem_rd(uint16_t);
void jcv_mem_wr(uint16_t, uint8_t);

uint8_t* jcv_get_ram(void);

void jcv_memio_init(void);
void jcv_memio_deinit(void);

int jcv_bios_load_file(const char*);
int jcv_bios_load(void*, size_t);
int jcv_rom_load(void*, size_t);

size_t jcv_state_size(void);

void jcv_state_load_raw(const void*);
int jcv_state_load(const char*);

const void* jcv_state_save_raw(void);
int jcv_state_save(const char*);

#endif
