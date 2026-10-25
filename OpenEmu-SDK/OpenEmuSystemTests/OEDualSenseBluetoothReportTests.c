// Copyright (c) 2026, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

#include "../OpenEmuSystem/OEDualSenseBluetoothReport.h"
#ifdef NDEBUG
#error "These tests require assertions; compile with -UNDEBUG."
#endif
#include <assert.h>
#include <stdio.h>
#include <zlib.h>

// Independent CRC oracle for test fixtures; production adds no dependency.
static void seal(uint8_t payload[77])
{
    const uint8_t prefix[] = {0xA1, 0x31};
    uint32_t crc = (uint32_t)crc32(crc32(0, prefix, 2), payload, 73);
    for(unsigned i = 0; i < 4; i++)
        payload[73 + i] = (uint8_t)(crc >> (i * 8));
}

int main(void)
{
    uint8_t payload[77] = {0};
    const uint8_t axes[] = {0, 127, 128, 255, 32, 240};
    const uint32_t usages[] = {0x30, 0x31, 0x32, 0x35, 0x33, 0x34};
    memcpy(payload + 1, axes, sizeof(axes));
    OEDualSenseBluetoothState state;
    int value;

    // Each of the 14 buttons, simultaneous presses, and release. The mute
    // button is not in report 0x01's descriptor and must not alias a control.
    for(unsigned iteration = 0; iteration < 16; iteration++) {
        uint16_t buttons = iteration < 14 ? (uint16_t)(1u << iteration)
                                         : iteration == 14 ? 0x3FFF : 0;
        payload[8] = (uint8_t)((buttons & 0x0F) << 4) | 8;
        payload[9] = (uint8_t)(buttons >> 4);
        payload[10] = (uint8_t)(buttons >> 12) | 0x04;
        seal(payload);
        assert(OEDecodeDualSenseBluetoothReport(0x31, payload, sizeof(payload), &state));
        assert(state.buttons == buttons && state.hatSwitch == 8);
        for(unsigned button = 1; button <= 14; button++) {
            assert(OEDualSenseBluetoothValueForUsage(&state, 9, button, &value));
            assert(value == ((buttons >> (button - 1)) & 1));
        }
    }
    for(unsigned axis = 0; axis < 6; axis++) {
        assert(OEDualSenseBluetoothValueForUsage(&state, 1, usages[axis], &value));
        assert(value == axes[axis]);
    }
    for(unsigned hat = 0; hat <= 15; hat++) {
        payload[8] = (uint8_t)hat;
        seal(payload);
        assert(OEDecodeDualSenseBluetoothReport(0x31, payload, sizeof(payload), &state));
        assert(OEDualSenseBluetoothValueForUsage(&state, 1, 0x39, &value) && value == (int)(hat < 8 ? hat : 8));
    }
    // First packet emits neutral values; duplicates emit nothing. Press and
    // release must both be emitted, and changes to one field leave others quiet.
    OEDualSenseBluetoothState previous = state;
    assert(OEDualSenseBluetoothChangedValueForUsage(&state, NULL, 9, 1, &value));
    assert(!OEDualSenseBluetoothChangedValueForUsage(&state, &previous, 9, 1, &value));
    state.buttons = 1;
    assert(OEDualSenseBluetoothChangedValueForUsage(&state, &previous, 9, 1, &value) && value == 1);
    assert(!OEDualSenseBluetoothChangedValueForUsage(&state, &previous, 9, 2, &value));
    previous = state;
    state.buttons = 0;
    assert(OEDualSenseBluetoothChangedValueForUsage(&state, &previous, 9, 1, &value) && value == 0);
    previous = state;
    for(unsigned axis = 0; axis < 6; axis++) {
        state.axes[axis] ^= 1;
        for(unsigned other = 0; other < 6; other++)
            assert(OEDualSenseBluetoothChangedValueForUsage(&state, &previous, 1, usages[other], &value)
                   == (axis == other));
        previous = state;
    }
    state.hatSwitch = 2;
    assert(OEDualSenseBluetoothChangedValueForUsage(&state, &previous, 1, 0x39, &value) && value == 2);
    previous = state;
    state.hatSwitch = 8;
    assert(OEDualSenseBluetoothChangedValueForUsage(&state, &previous, 1, 0x39, &value) && value == 8);
    assert(!OEDualSenseBluetoothChangedValueForUsage(&state, NULL, 9, 15, &value));
    assert(!OEDualSenseBluetoothValueForUsage(&state, 9, 0, &value));
    assert(!OEDualSenseBluetoothValueForUsage(&state, 9, 15, &value));
    assert(!OEDualSenseBluetoothValueForUsage(&state, 0xFF00, 0x3B, &value));
    assert(!OEDualSenseBluetoothValueForUsage(&state, 1, 0x40, &value));
    for(size_t length = 0; length < sizeof(payload); length++)
        assert(!OEDecodeDualSenseBluetoothReport(0x31, payload, length, &state));
    assert(!OEDecodeDualSenseBluetoothReport(0x31, payload, 78, &state));
    assert(!OEDecodeDualSenseBluetoothReport(0x01, payload, sizeof(payload), &state));
    assert(!OEDecodeDualSenseBluetoothReport(0x31, NULL, sizeof(payload), &state));
    assert(!OEDecodeDualSenseBluetoothReport(0x31, payload, sizeof(payload), NULL));
    for(size_t i = 0; i < sizeof(payload); i++) {
        payload[i] ^= 1;
        assert(!OEDecodeDualSenseBluetoothReport(0x31, payload, sizeof(payload), &state));
        payload[i] ^= 1;
    }
    puts("DualSense Bluetooth report tests passed");
    return 0;
}
