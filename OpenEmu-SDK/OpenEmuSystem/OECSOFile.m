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

#import "OECSOFile.h"

#include <compression.h>
#include <zlib.h>

// CSO (https://github.com/unknownbrackets/maxcso/blob/master/README_CSO.md), read the way the cores
// that play it do (PPSSPP's CISOFileBlockDevice, PCSX2's CsoFileReader): a 24-byte header, then one
// 32-bit index entry per frame plus one, then the frames. An entry shifted left by the header's
// alignment is where the frame starts; the next entry is where it ends. A frame is raw deflate, or
// stored as it is: in version 1 when its entry has the top bit set, in version 2 when it did not
// shrink. In version 2 the top bit marks an LZ4 frame instead, which no core here decodes (PPSSPP
// reads version 2 without LZ4, PCSX2 only version 1), so a file with one is refused. A ZSO ("ZISO",
// version 1 only) is the same with LZ4 frames instead of deflate. Every number is little-endian.
enum {
    OECSOHeaderSize = 24,
    OECSOMinFrameSize = 2048,
    OECSOMaxFrameSize = 1024 * 1024,
    OECSOMaxAlignment = 11,
};
static const uint32_t OECSOStoredFlag = 0x80000000;
static const uint64_t OECSOMaxImageSize = 16ULL << 30; // a dual-layer PS2 DVD is 8.5 GB

static uint32_t OECSORead32(const uint8_t *bytes)
{
    return (uint32_t)bytes[0] | (uint32_t)bytes[1] << 8 | (uint32_t)bytes[2] << 16 | (uint32_t)bytes[3] << 24;
}

@implementation OECSOFile {
    NSFileHandle *_handle;
    BOOL _triedToOpen;
    uint64_t _imageSize;
    uint32_t _frameSize;
    uint32_t _frameCount;
    uint8_t _alignment;
    uint8_t _version;
    BOOL _lz4; // a ZSO
    NSData *_index; // _frameCount + 1 entries
    uint64_t _cachedFrame; // UINT64_MAX when the cache holds nothing
    NSMutableData *_cache;
}

- (BOOL)_open
{
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:self.fileURL error:nil];
    unsigned long long fileSize = 0;
    if(handle == nil || ![handle seekToEndReturningOffset:&fileSize error:nil] || ![handle seekToOffset:0 error:nil])
        return NO;

    NSData *header = [handle readDataUpToLength:OECSOHeaderSize error:nil];
    if(header.length != OECSOHeaderSize)
        return NO;
    const uint8_t *bytes = header.bytes;
    if(memcmp(bytes, "CISO", 4) != 0 && memcmp(bytes, "ZISO", 4) != 0)
        return NO;
    _lz4 = bytes[0] == 'Z';
    const uint32_t headerSize = OECSORead32(bytes + 4);
    _imageSize = (uint64_t)OECSORead32(bytes + 8) | (uint64_t)OECSORead32(bytes + 12) << 32;
    _frameSize = OECSORead32(bytes + 16);
    _version = bytes[20];
    _alignment = bytes[21];

    if(_version > (_lz4 ? 1 : 2) || _frameSize < OECSOMinFrameSize || _frameSize > OECSOMaxFrameSize
       || (_frameSize & (_frameSize - 1)) != 0 || _alignment > OECSOMaxAlignment
       || _imageSize == 0 || _imageSize > OECSOMaxImageSize)
        return NO;
    _frameCount = (uint32_t)((_imageSize + _frameSize - 1) / _frameSize);

    // Most tools leave header_size unset, so only version 2 (which requires it) reads the index there.
    const uint64_t indexOffset = _version >= 2 ? headerSize : OECSOHeaderSize;
    const uint64_t indexSize = ((uint64_t)_frameCount + 1) * 4;
    if(indexOffset < OECSOHeaderSize || indexOffset + indexSize > fileSize || ![handle seekToOffset:indexOffset error:nil])
        return NO;
    _index = [handle readDataUpToLength:(NSUInteger)indexSize error:nil];
    if(_index.length != indexSize)
        return NO;

    // The last entry is where the last frame ends: a cut-off copy is refused here, not when a game
    // reaches its missing part.
    const uint8_t *index = _index.bytes;
    const uint64_t end = (uint64_t)(OECSORead32(index + _frameCount * 4) & ~OECSOStoredFlag) << _alignment;
    if(end > fileSize)
        return NO;

    if(_version >= 2) {
        for(uint32_t frame = 0; frame < _frameCount; frame++) {
            const uint32_t entry = OECSORead32(index + frame * 4);
            const uint64_t size = ((uint64_t)(OECSORead32(index + (frame + 1) * 4) & ~OECSOStoredFlag) - (entry & ~OECSOStoredFlag)) << _alignment;
            if((entry & OECSOStoredFlag) != 0 && size < _frameSize)
                return NO;
        }
    }

    _cache = [NSMutableData dataWithLength:_frameSize];
    _cachedFrame = UINT64_MAX;
    _handle = handle;
    return YES;
}

// The decompressed frame, or NULL when it cannot be read.
- (const uint8_t *)_frame:(uint64_t)frame
{
    if(frame == _cachedFrame)
        return _cache.bytes;
    _cachedFrame = UINT64_MAX;

    const uint8_t *index = _index.bytes;
    const uint32_t entry = OECSORead32(index + frame * 4);
    const uint64_t start = (uint64_t)(entry & ~OECSOStoredFlag) << _alignment;
    const uint64_t end = (uint64_t)(OECSORead32(index + (frame + 1) * 4) & ~OECSOStoredFlag) << _alignment;
    if(end < start)
        return NULL;
    const uint64_t size = end - start;
    const BOOL stored = _version >= 2 ? size >= _frameSize : (entry & OECSOStoredFlag) != 0;

    NSError *error = nil;
    if(![_handle seekToOffset:start error:&error])
        return NULL;

    uint8_t *output = _cache.mutableBytes;
    if(stored) {
        // The last frame of the file may be short; the rest of it is past the end of the image.
        NSData *data = [_handle readDataUpToLength:_frameSize error:&error];
        if(data == nil || data.length == 0)
            return NULL;
        memcpy(output, data.bytes, data.length);
        memset(output + data.length, 0, _frameSize - data.length);
    } else {
        // Alignment may pad a frame's end, so it can take up to one alignment unit more than a frame.
        if(size == 0 || size > (uint64_t)_frameSize + (1u << _alignment))
            return NULL;
        NSData *data = [_handle readDataUpToLength:(NSUInteger)size error:&error];
        if(data.length != size)
            return NULL;
        if(_lz4) {
            // An LZ4 block with no frame around it. Alignment can leave up to one alignment unit of
            // padding after it, which the engine's lenient LZ4_decompress_safe_partial skips but this
            // stricter decoder refuses, so the padding is trimmed until the block decodes.
            size_t produced = 0;
            for(size_t padding = 0; produced == 0 && padding < (1u << _alignment) && padding < data.length; padding++)
                produced = compression_decode_buffer(output, _frameSize, data.bytes, data.length - padding, NULL, COMPRESSION_LZ4_RAW);
            if(produced == 0)
                return NULL;
            memset(output + produced, 0, _frameSize - produced);
            _cachedFrame = frame;
            return output;
        }
        z_stream stream = { 0 };
        if(inflateInit2(&stream, -15) != Z_OK)
            return NULL;
        stream.next_in = (Bytef *)data.bytes;
        stream.avail_in = (uInt)data.length;
        stream.next_out = output;
        stream.avail_out = _frameSize;
        const int status = inflate(&stream, Z_FINISH);
        const uLong produced = stream.total_out;
        inflateEnd(&stream);
        if(status != Z_STREAM_END)
            return NULL;
        memset(output + produced, 0, _frameSize - produced);
    }

    _cachedFrame = frame;
    return output;
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

        if(_handle == nil || dataRange.length == 0 || dataRange.location >= _imageSize)
            return [NSData data];

        const uint64_t length = MIN((uint64_t)dataRange.length, _imageSize - dataRange.location);
        NSMutableData *data = [NSMutableData dataWithCapacity:(NSUInteger)length];
        uint64_t position = dataRange.location;
        while(position < dataRange.location + length) {
            const uint8_t *frame = [self _frame:position / _frameSize];
            if(frame == NULL)
                break;
            const uint64_t offsetInFrame = position % _frameSize;
            const uint64_t count = MIN(_frameSize - offsetInFrame, dataRange.location + length - position);
            [data appendBytes:frame + offsetInFrame length:(NSUInteger)count];
            position += count;
        }
        return data;
    }
}

@end
