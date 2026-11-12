/*
 Copyright (c) 2026, OpenEmu Team
 Author: Leonardo Kasperavičius

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Describes a contiguous region of readable memory exposed by a game core.
@interface OEMemoryRegionDescriptor : NSObject

/// A short human-readable label for this region (e.g. "EWRAM", "IWRAM").
@property (nonatomic, readonly, copy) NSString *name;

/// The base address of this region in the console's address space.
@property (nonatomic, readonly) uint32_t address;

/// The number of bytes used to represent addresses in this system's address space.
/// For example: 1 for Atari 2600 (8-bit), 2 for NES (16-bit), 3 for SNES (24-bit), 4 for GBA (32-bit).
@property (nonatomic, readonly) uint8_t addressBytes;

/// The raw bytes of this memory region. The length of this data is the region's size in bytes.
@property (nonatomic, readonly, copy) NSData *data;

/// The minimum number of bytes per data unit for this system's cheat format.
/// For byte-addressable systems (NES, SNES, GB, GBA, SMS, etc.) this is 1 (default).
/// For word-addressed systems (Genesis/Mega Drive) this is 2.
@property (nonatomic, readonly) uint8_t minDataBytes;

/// How the system's addresses relate to bytes in `data`, as a power of two.
/// 0 (default): one address per byte. Positive: each byte spans 2^shift addresses (3 for a CPU
/// that addresses bits, such as the TMS34010). Negative: 2^-shift bytes share one address.
@property (nonatomic, readonly) int8_t addressShift;

/// The system address of the byte at `offset` in `data`.
- (uint32_t)addressForOffset:(NSInteger)offset;

/// The offset in `data` of the byte at system `address`, or NSNotFound when the address is outside
/// this region or does not start a byte.
- (NSInteger)offsetForAddress:(uint32_t)address;

- (instancetype)initWithName:(NSString *)name address:(uint32_t)address addressBytes:(uint8_t)addressBytes minDataBytes:(uint8_t)minDataBytes addressShift:(int8_t)addressShift data:(NSData *)data;
+ (instancetype)descriptorWithName:(NSString *)name address:(uint32_t)address addressBytes:(uint8_t)addressBytes minDataBytes:(uint8_t)minDataBytes addressShift:(int8_t)addressShift data:(NSData *)data;

- (instancetype)initWithName:(NSString *)name address:(uint32_t)address addressBytes:(uint8_t)addressBytes minDataBytes:(uint8_t)minDataBytes data:(NSData *)data;
+ (instancetype)descriptorWithName:(NSString *)name address:(uint32_t)address addressBytes:(uint8_t)addressBytes minDataBytes:(uint8_t)minDataBytes data:(NSData *)data;

- (instancetype)initWithName:(NSString *)name address:(uint32_t)address addressBytes:(uint8_t)addressBytes data:(NSData *)data;
+ (instancetype)descriptorWithName:(NSString *)name address:(uint32_t)address addressBytes:(uint8_t)addressBytes data:(NSData *)data;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
