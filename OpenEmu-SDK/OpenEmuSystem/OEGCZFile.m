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

#import "OEGCZFile.h"

#include <zlib.h>

// Dolphin's GCZ (Source/Core/DiscIO/CompressedBlob.h): a 32-byte header, then a 64-bit offset and a
// 32-bit Adler-32 for each block, then the blocks. A block is zlib-compressed, or stored as it is when
// its offset has the top bit set. Every number is little-endian.
enum {
    OEGCZMagic = 0xB10BC001, // GCZ_MAGIC; the comment on Dolphin's header struct gives an older value
    OEGCZHeaderSize = 32,
    OEGCZMaxBlockSize = 16 * 1024 * 1024,
};
static const uint64_t OEGCZStoredFlag = 1ULL << 63;

static uint32_t OEGCZRead32(const uint8_t *bytes)
{
    return (uint32_t)bytes[0] | (uint32_t)bytes[1] << 8 | (uint32_t)bytes[2] << 16 | (uint32_t)bytes[3] << 24;
}

static uint64_t OEGCZRead64(const uint8_t *bytes)
{
    return (uint64_t)OEGCZRead32(bytes) | (uint64_t)OEGCZRead32(bytes + 4) << 32;
}

@implementation OEGCZFile {
    NSFileHandle *_handle;
    BOOL _triedToOpen;
    uint64_t _compressedDataSize;
    uint64_t _dataSize;
    uint64_t _dataOffset; // where the blocks start in the file
    uint32_t _blockSize;
    uint32_t _blockCount;
    NSData *_blockOffsets;
    uint64_t _cachedBlock; // UINT64_MAX when the cache holds nothing
    NSMutableData *_cache;
}

- (BOOL)_open
{
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:self.fileURL error:nil];
    unsigned long long fileSize = 0;
    if(handle == nil || ![handle seekToEndReturningOffset:&fileSize error:nil] || ![handle seekToOffset:0 error:nil])
        return NO;

    NSData *header = [handle readDataUpToLength:OEGCZHeaderSize error:nil];
    if(header.length != OEGCZHeaderSize)
        return NO;
    const uint8_t *bytes = header.bytes;
    if(OEGCZRead32(bytes) != OEGCZMagic)
        return NO;
    _compressedDataSize = OEGCZRead64(bytes + 8);
    _dataSize = OEGCZRead64(bytes + 16);
    _blockSize = OEGCZRead32(bytes + 24);
    _blockCount = OEGCZRead32(bytes + 28);

    // The block list and the blocks must fit in the file: a cut-off copy is refused here, not when a
    // game reaches its missing part.
    if(_blockSize == 0 || _blockSize > OEGCZMaxBlockSize || _dataSize == 0
       || _blockCount != (_dataSize + _blockSize - 1) / _blockSize
       || OEGCZHeaderSize + (uint64_t)_blockCount * 12 + _compressedDataSize > fileSize)
        return NO;

    _blockOffsets = [handle readDataUpToLength:(NSUInteger)_blockCount * 8 error:nil];
    if(_blockOffsets.length != (NSUInteger)_blockCount * 8)
        return NO;

    _dataOffset = OEGCZHeaderSize + (uint64_t)_blockCount * 12;
    _cache = [NSMutableData dataWithLength:_blockSize];
    _cachedBlock = UINT64_MAX;
    _handle = handle;
    return YES;
}

// The decompressed block, or NULL when it cannot be read.
- (const uint8_t *)_block:(uint64_t)index
{
    if(index == _cachedBlock)
        return _cache.bytes;
    _cachedBlock = UINT64_MAX;

    const uint8_t *offsets = _blockOffsets.bytes;
    const uint64_t offset = OEGCZRead64(offsets + index * 8);
    const BOOL stored = (offset & OEGCZStoredFlag) != 0;
    const uint64_t start = offset & ~OEGCZStoredFlag;
    const uint64_t end = index + 1 < _blockCount ? OEGCZRead64(offsets + (index + 1) * 8) & ~OEGCZStoredFlag : _compressedDataSize;
    // A block never takes more room than it holds; a bigger one is stored as it is.
    if(end <= start || end - start > _blockSize || (stored && end - start != _blockSize))
        return NULL;

    NSError *error = nil;
    if(![_handle seekToOffset:_dataOffset + start error:&error])
        return NULL;
    NSData *block = [_handle readDataUpToLength:(NSUInteger)(end - start) error:&error];
    if(block.length != end - start)
        return NULL;

    if(stored) {
        memcpy(_cache.mutableBytes, block.bytes, _blockSize);
    } else {
        z_stream stream = { 0 };
        stream.next_in = (Bytef *)block.bytes;
        stream.avail_in = (uInt)block.length;
        stream.next_out = _cache.mutableBytes;
        stream.avail_out = _blockSize;
        if(inflateInit(&stream) != Z_OK)
            return NULL;
        inflate(&stream, Z_FINISH);
        const uLong decompressed = stream.total_out;
        inflateEnd(&stream);
        // Dolphin pads the last block before compressing it, so every block decompresses to a full one.
        if(decompressed != _blockSize)
            return NULL;
    }

    _cachedBlock = index;
    return _cache.bytes;
}

- (NSData *)readDataInRange:(NSRange)dataRange
{
    @synchronized(self) {
        // Opened on first read, like OECHDFile.
        if(!_triedToOpen) {
            _triedToOpen = YES;
            if(![self _open])
                _handle = nil;
        }

        if(_handle == nil || dataRange.length == 0 || dataRange.location >= _dataSize)
            return [NSData data];

        const uint64_t length = MIN((uint64_t)dataRange.length, _dataSize - dataRange.location);
        NSMutableData *data = [NSMutableData dataWithCapacity:(NSUInteger)length];
        uint64_t position = dataRange.location;
        while(position < dataRange.location + length) {
            const uint8_t *block = [self _block:position / _blockSize];
            if(block == NULL)
                break;
            const uint64_t offsetInBlock = position % _blockSize;
            const uint64_t count = MIN(_blockSize - offsetInBlock, dataRange.location + length - position);
            [data appendBytes:block + offsetInBlock length:(NSUInteger)count];
            position += count;
        }
        return data;
    }
}

@end
