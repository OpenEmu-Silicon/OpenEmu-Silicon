// Copyright (c) 2026, OpenEmu Team
// Author: Leonardo Kasperavičius
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#import <XCTest/XCTest.h>
#import "OEMemoryRegionDescriptor.h"

@interface OEMemoryRegionDescriptorTests : XCTestCase
@end

@implementation OEMemoryRegionDescriptorTests

- (OEMemoryRegionDescriptor *)regionAt:(uint32_t)address size:(NSUInteger)size shift:(int8_t)shift
{
    return [OEMemoryRegionDescriptor descriptorWithName:@"RAM"
                                                address:address
                                           addressBytes:3
                                           minDataBytes:1
                                           addressShift:shift
                                                   data:[NSMutableData dataWithLength:size]];
}

// The address arithmetic CheatSearchViewController used before addressShift existed.
static NSInteger oldOffsetForAddress(uint32_t start, NSUInteger size, uint32_t address)
{
    if (address < start) return NSNotFound;
    uint64_t delta = (uint64_t)address - start;
    return delta < size ? (NSInteger)delta : NSNotFound;
}

#pragma mark - Shift 0 (every core except bit-addressed MAME CPUs)

- (void)testOldInitializerDefaultsToShiftZero
{
    OEMemoryRegionDescriptor *region = [OEMemoryRegionDescriptor descriptorWithName:@"RAM"
                                                                            address:0x7E0000
                                                                       addressBytes:3
                                                                       minDataBytes:1
                                                                               data:[NSMutableData dataWithLength:16]];
    XCTAssertEqual(region.addressShift, 0);
}

- (void)testShiftZeroMatchesOldArithmetic
{
    // Genesis-shaped work RAM: 64 KB at 0xFF0000.
    uint32_t start = 0xFF0000;
    NSUInteger size = 0x10000;
    OEMemoryRegionDescriptor *region = [self regionAt:start size:size shift:0];

    uint32_t probes[] = { 0, start - 1, start, start + 1, 0xFFFE20, start + (uint32_t)size - 1, start + (uint32_t)size, UINT32_MAX };
    for (size_t i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
        XCTAssertEqual([region offsetForAddress:probes[i]], oldOffsetForAddress(start, size, probes[i]), @"address %08X", probes[i]);
    }

    NSInteger offsets[] = { 0, 1, 0xFE20, (NSInteger)size - 1 };
    for (size_t i = 0; i < sizeof(offsets) / sizeof(offsets[0]); i++) {
        XCTAssertEqual([region addressForOffset:offsets[i]], start + (uint32_t)offsets[i], @"offset %ld", (long)offsets[i]);
    }
}

- (void)testShiftZeroRegionEndingAtTopOfAddressSpace
{
    // The old `start + count` end check overflowed here; the helper must not.
    uint32_t start = 0xFFFFFF00;
    OEMemoryRegionDescriptor *region = [self regionAt:start size:0x100 shift:0];

    XCTAssertEqual([region offsetForAddress:0xFFFFFF00], 0);
    XCTAssertEqual([region offsetForAddress:0xFFFFFFFF], 0xFF);
    XCTAssertEqual([region offsetForAddress:0xFFFFFEFF], NSNotFound);
    XCTAssertEqual([region addressForOffset:0xFF], 0xFFFFFFFF);
}

#pragma mark - Positive shift (TMS34010: one address per bit)

- (void)testBitAddressedRegionMapsEightAddressesPerByte
{
    // Mortal Kombat work RAM on the TMS34010, from the cheat search fix.
    uint32_t start = 0x01000000;
    OEMemoryRegionDescriptor *region = [self regionAt:start size:0x80000 shift:3];

    XCTAssertEqual([region addressForOffset:0], start);
    XCTAssertEqual([region addressForOffset:1], start + 8);
    XCTAssertEqual([region addressForOffset:0xA260], 0x01051300); // P1 health, matches Pugsy's code

    XCTAssertEqual([region offsetForAddress:0x01051300], 0xA260);
    XCTAssertEqual([region offsetForAddress:0x01051301], NSNotFound); // not on a byte boundary
    XCTAssertEqual([region offsetForAddress:0x01051307], NSNotFound);
    XCTAssertEqual([region offsetForAddress:start + (0x80000 << 3)], NSNotFound); // one past the end
}

#pragma mark - Negative shift (several bytes per address)

- (void)testWordAddressedRegionMapsTwoBytesPerAddress
{
    uint32_t start = 0x1000;
    OEMemoryRegionDescriptor *region = [self regionAt:start size:0x100 shift:-1];

    XCTAssertEqual([region addressForOffset:0], start);
    XCTAssertEqual([region addressForOffset:1], start); // second byte of the same word
    XCTAssertEqual([region addressForOffset:2], start + 1);
    XCTAssertEqual([region offsetForAddress:start + 1], 2);
    XCTAssertEqual([region offsetForAddress:start + 0x80], NSNotFound); // one past the end
}

@end
