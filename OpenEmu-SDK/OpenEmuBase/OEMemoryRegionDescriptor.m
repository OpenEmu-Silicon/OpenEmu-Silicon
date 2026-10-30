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

#import "OEMemoryRegionDescriptor.h"

@implementation OEMemoryRegionDescriptor

- (instancetype)initWithName:(NSString *)name address:(uint32_t)address addressBytes:(uint8_t)addressBytes minDataBytes:(uint8_t)minDataBytes addressShift:(int8_t)addressShift data:(NSData *)data
{
    if ((self = [super init])) {
        _name = [name copy];
        _address = address;
        _addressBytes = addressBytes;
        _minDataBytes = minDataBytes;
        _addressShift = addressShift;
        _data = [data copy];
    }
    return self;
}

+ (instancetype)descriptorWithName:(NSString *)name address:(uint32_t)address addressBytes:(uint8_t)addressBytes minDataBytes:(uint8_t)minDataBytes addressShift:(int8_t)addressShift data:(NSData *)data
{
    return [[self alloc] initWithName:name address:address addressBytes:addressBytes minDataBytes:minDataBytes addressShift:addressShift data:data];
}

- (instancetype)initWithName:(NSString *)name address:(uint32_t)address addressBytes:(uint8_t)addressBytes minDataBytes:(uint8_t)minDataBytes data:(NSData *)data
{
    return [self initWithName:name address:address addressBytes:addressBytes minDataBytes:minDataBytes addressShift:0 data:data];
}

+ (instancetype)descriptorWithName:(NSString *)name address:(uint32_t)address addressBytes:(uint8_t)addressBytes minDataBytes:(uint8_t)minDataBytes data:(NSData *)data
{
    return [[self alloc] initWithName:name address:address addressBytes:addressBytes minDataBytes:minDataBytes data:data];
}

- (instancetype)initWithName:(NSString *)name address:(uint32_t)address addressBytes:(uint8_t)addressBytes data:(NSData *)data
{
    return [self initWithName:name address:address addressBytes:addressBytes minDataBytes:1 data:data];
}

+ (instancetype)descriptorWithName:(NSString *)name address:(uint32_t)address addressBytes:(uint8_t)addressBytes data:(NSData *)data
{
    return [[self alloc] initWithName:name address:address addressBytes:addressBytes data:data];
}

- (uint32_t)addressForOffset:(NSInteger)offset
{
    uint64_t units = _addressShift >= 0 ? ((uint64_t)offset << _addressShift) : ((uint64_t)offset >> -_addressShift);
    return _address + (uint32_t)units;
}

- (NSInteger)offsetForAddress:(uint32_t)address
{
    if (address < _address) return NSNotFound;
    uint64_t delta = address - _address;
    uint64_t offset;
    if (_addressShift >= 0) {
        if (delta & ((1ULL << _addressShift) - 1)) return NSNotFound;
        offset = delta >> _addressShift;
    } else {
        offset = delta << -_addressShift;
    }
    return offset < _data.length ? (NSInteger)offset : NSNotFound;
}

@end
