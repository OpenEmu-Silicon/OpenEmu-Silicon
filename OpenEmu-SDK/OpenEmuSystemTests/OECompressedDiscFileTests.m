// Copyright (c) 2026, OpenEmu Team
// Author: Leonardo Kasperavičius
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


// Checks OEGCZFile and OECSOFile (CSO and ZSO) against images built here from a made-up disc: valid
// ones must read back byte for byte, and damaged or malformed ones (a header whose sizes wrap, a cut-off
// file, a frame that never decodes, versions and sizes no core reads) must read as empty, never crash.
// Run by Scripts/test-compressed-disc-files.sh.

#import <Foundation/Foundation.h>
#import "../OpenEmuSystem/OEGCZFile.h"
#import "../OpenEmuSystem/OECSOFile.h"

#ifdef NDEBUG
#error "These tests require assertions; compile with -UNDEBUG."
#endif
#include <assert.h>
#include <compression.h>
#include <zlib.h>

enum { SectorSize = 2048, SectorCount = 40, ImageSize = SectorSize * SectorCount };

static NSString *temporaryDirectory;

// A disc whose sectors show which sector they are, with a run of empty sectors (which compress well).
static NSData *makeImage(void)
{
    NSMutableData *image = [NSMutableData dataWithLength:ImageSize];
    uint8_t *bytes = image.mutableBytes;
    for(size_t i = 0; i < ImageSize; i++) {
        const size_t sector = i / SectorSize;
        bytes[i] = sector >= 20 && sector < 28 ? 0 : (uint8_t)(sector * 7 + (i % SectorSize) / 16);
    }
    return image;
}

static void append32(NSMutableData *data, uint32_t value)
{
    const uint8_t bytes[4] = { (uint8_t)value, (uint8_t)(value >> 8), (uint8_t)(value >> 16), (uint8_t)(value >> 24) };
    [data appendBytes:bytes length:4];
}

static void append64(NSMutableData *data, uint64_t value)
{
    append32(data, (uint32_t)value);
    append32(data, (uint32_t)(value >> 32));
}

static void put32(NSMutableData *data, size_t offset, uint32_t value)
{
    const uint8_t bytes[4] = { (uint8_t)value, (uint8_t)(value >> 8), (uint8_t)(value >> 16), (uint8_t)(value >> 24) };
    [data replaceBytesInRange:NSMakeRange(offset, 4) withBytes:bytes];
}

static void put64(NSMutableData *data, size_t offset, uint64_t value)
{
    put32(data, offset, (uint32_t)value);
    put32(data, offset + 4, (uint32_t)(value >> 32));
}

static NSURL *writeFile(NSString *name, NSData *data)
{
    NSURL *url = [NSURL fileURLWithPath:[temporaryDirectory stringByAppendingPathComponent:name]];
    assert([data writeToURL:url atomically:NO]);
    return url;
}

static NSData *readThrough(Class fileClass, NSURL *url, NSRange range)
{
    OEFile *file = [[fileClass alloc] initWithFileURL:url error:nil];
    assert(file != nil);
    return [file readDataInRange:range];
}

// Valid images: the whole disc, a read that crosses blocks, and reads at and past the end.
static void checkReadsBack(Class fileClass, NSString *name, NSData *data, NSData *image)
{
    NSURL *url = writeFile(name, data);
    OEFile *file = [[fileClass alloc] initWithFileURL:url error:nil];
    assert([[file readDataInRange:NSMakeRange(0, image.length)] isEqualToData:image]);
    assert([[file readDataInRange:NSMakeRange(SectorSize * 3 + 100, SectorSize * 9)] isEqualToData:[image subdataWithRange:NSMakeRange(SectorSize * 3 + 100, SectorSize * 9)]]);
    assert([[file readDataInRange:NSMakeRange(image.length - 10, 100)] isEqualToData:[image subdataWithRange:NSMakeRange(image.length - 10, 10)]]);
    assert([file readDataInRange:NSMakeRange(image.length, 1)].length == 0);
}

static void checkUnreadable(Class fileClass, NSString *name, NSData *data)
{
    assert(readThrough(fileClass, writeFile(name, data), NSMakeRange(0, ImageSize)).length == 0);
    assert(readThrough(fileClass, writeFile(name, data), NSMakeRange(0x1C, 4)).length == 0);
}

#pragma mark - GCZ

enum { GCZBlockSize = 16384, GCZHeaderSize = 32 };

// Dolphin's GCZ: header, a 64-bit offset per block (top bit: stored), an Adler-32 per block, then the
// blocks, zlib-compressed unless stored.
static NSMutableData *makeGCZ(NSData *image, unsigned storedBlock)
{
    const unsigned blockCount = (unsigned)((image.length + GCZBlockSize - 1) / GCZBlockSize);
    NSMutableArray<NSData *> *blocks = [NSMutableArray array];
    NSMutableData *offsets = [NSMutableData data], *hashes = [NSMutableData data];
    uint64_t position = 0;
    for(unsigned block = 0; block < blockCount; block++) {
        NSData *raw = [image subdataWithRange:NSMakeRange(block * GCZBlockSize, GCZBlockSize)];
        NSData *stored = raw;
        uint64_t flag = 1ULL << 63;
        if(block != storedBlock) {
            uLongf length = compressBound(GCZBlockSize);
            NSMutableData *compressed = [NSMutableData dataWithLength:length];
            assert(compress2(compressed.mutableBytes, &length, raw.bytes, GCZBlockSize, 9) == Z_OK);
            compressed.length = length;
            stored = compressed;
            flag = 0;
        }
        append64(offsets, position | flag);
        append32(hashes, (uint32_t)adler32(1, stored.bytes, (uInt)stored.length));
        [blocks addObject:stored];
        position += stored.length;
    }
    NSMutableData *gcz = [NSMutableData data];
    append32(gcz, 0xB10BC001);
    append32(gcz, 0);
    append64(gcz, position);
    append64(gcz, image.length);
    append32(gcz, GCZBlockSize);
    append32(gcz, blockCount);
    [gcz appendData:offsets];
    [gcz appendData:hashes];
    for(NSData *block in blocks)
        [gcz appendData:block];
    return gcz;
}

static void checkGCZ(NSData *image)
{
    Class gcz = [OEGCZFile class];
    checkReadsBack(gcz, @"valid.gcz", makeGCZ(image, 2), image);

    NSMutableData *data = makeGCZ(image, 2);
    put32(data, 0, 0xB10BB10B); // the older value in a comment of Dolphin's header struct
    checkUnreadable(gcz, @"magic.gcz", data);

    data = makeGCZ(image, 2);
    put32(data, 24, 0);
    checkUnreadable(gcz, @"block-size-0.gcz", data);

    data = makeGCZ(image, 2);
    put32(data, 24, 32 * 1024 * 1024);
    checkUnreadable(gcz, @"block-size-big.gcz", data);

    // A data size whose block count wraps to 0 (a crash before the count was computed safely).
    NSMutableData *wrap = [NSMutableData data];
    append32(wrap, 0xB10BC001);
    append32(wrap, 0);
    append64(wrap, 0);
    append64(wrap, UINT64_MAX);
    append32(wrap, 0x4000);
    append32(wrap, 0);
    checkUnreadable(gcz, @"wrap.gcz", wrap);

    // A compressed size near 2^64, which wrapped the file-size check.
    data = makeGCZ(image, 2);
    put64(data, 8, UINT64_MAX - 15);
    checkUnreadable(gcz, @"compressed-size.gcz", data);

    data = makeGCZ(image, 2);
    put32(data, 28, 3);
    checkUnreadable(gcz, @"block-count.gcz", data);

    data = makeGCZ(image, 2);
    data.length = data.length / 2;
    checkUnreadable(gcz, @"cut.gcz", data);

    checkUnreadable(gcz, @"text.gcz", [@"not a disc" dataUsingEncoding:NSUTF8StringEncoding]);
}

#pragma mark - CSO and ZSO

enum { CSOFrameSize = 2048, CSOHeaderSize = 24 };
typedef enum { CSOFrameCompressed, CSOFrameStored, CSOFrameLZ4InVersion2, CSOFrameUndecodable } CSOFrameKind;

static NSData *deflateRaw(NSData *raw)
{
    z_stream stream = { 0 };
    assert(deflateInit2(&stream, 9, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) == Z_OK);
    NSMutableData *output = [NSMutableData dataWithLength:deflateBound(&stream, raw.length)];
    stream.next_in = (Bytef *)raw.bytes;
    stream.avail_in = (uInt)raw.length;
    stream.next_out = output.mutableBytes;
    stream.avail_out = (uInt)output.length;
    assert(deflate(&stream, Z_FINISH) == Z_STREAM_END);
    output.length = stream.total_out;
    deflateEnd(&stream);
    return output;
}

static NSData *lz4Raw(NSData *raw)
{
    NSMutableData *output = [NSMutableData dataWithLength:raw.length * 2];
    const size_t length = compression_encode_buffer(output.mutableBytes, output.length, raw.bytes, raw.length, NULL, COMPRESSION_LZ4_RAW);
    assert(length > 0);
    output.length = length;
    return output;
}

// A CSO ("CISO", deflate) or ZSO ("ZISO", LZ4): header, (frames + 1) index entries holding each frame's
// position shifted right by `alignment` (top bit: stored in version 1), then the frames, each padded
// with zeros to the alignment. `kinds` says how frame i is written (compressed when NULL).
static NSMutableData *makeCSO(NSData *image, const char magic[4], uint8_t version, uint8_t alignment, const CSOFrameKind *kinds)
{
    const unsigned frameCount = (unsigned)(image.length / CSOFrameSize);
    const uint64_t unit = 1ULL << alignment;
    uint64_t position = CSOHeaderSize + (frameCount + 1) * 4;
    position = (position + unit - 1) / unit * unit;

    NSMutableData *frames = [NSMutableData dataWithLength:(NSUInteger)position];
    NSMutableData *index = [NSMutableData data];
    for(unsigned frame = 0; frame < frameCount; frame++) {
        NSData *raw = [image subdataWithRange:NSMakeRange(frame * CSOFrameSize, CSOFrameSize)];
        const CSOFrameKind kind = kinds ? kinds[frame] : CSOFrameCompressed;
        NSData *written = raw;
        uint32_t flag = 0;
        if(kind == CSOFrameStored) {
            flag = version < 2 ? 0x80000000 : 0; // version 2 marks a stored frame by its full size
        } else if(kind == CSOFrameLZ4InVersion2) {
            written = lz4Raw(raw);
            flag = 0x80000000;
        } else if(kind == CSOFrameUndecodable) {
            NSMutableData *garbage = [NSMutableData dataWithLength:64];
            memset(garbage.mutableBytes, 0xFF, 64); // an LZ4 literal run that never ends; not deflate either
            written = garbage;
        } else {
            written = magic[0] == 'Z' ? lz4Raw(raw) : deflateRaw(raw);
        }
        append32(index, (uint32_t)(position >> alignment) | flag);
        [frames appendData:written];
        position += written.length;
        const uint64_t padding = (unit - position % unit) % unit;
        [frames increaseLengthBy:(NSUInteger)padding];
        position += padding;
    }
    append32(index, (uint32_t)(position >> alignment));

    NSMutableData *cso = [NSMutableData data];
    [cso appendBytes:magic length:4];
    append32(cso, CSOHeaderSize);
    append64(cso, image.length);
    append32(cso, CSOFrameSize);
    const uint8_t versionAndAlignment[4] = { version, alignment, 0, 0 };
    [cso appendBytes:versionAndAlignment length:4];
    [cso appendData:index];
    [frames replaceBytesInRange:NSMakeRange(0, cso.length) withBytes:cso.bytes];
    return frames;
}

static void checkCSO(NSData *image)
{
    Class cso = [OECSOFile class];
    CSOFrameKind kinds[SectorCount];
    for(unsigned i = 0; i < SectorCount; i++)
        kinds[i] = i == 5 ? CSOFrameStored : CSOFrameCompressed;

    checkReadsBack(cso, @"v1.cso", makeCSO(image, "CISO", 1, 0, kinds), image);
    checkReadsBack(cso, @"v1-aligned.cso", makeCSO(image, "CISO", 1, 2, kinds), image);
    checkReadsBack(cso, @"v2.cso", makeCSO(image, "CISO", 2, 0, kinds), image);
    // Alignment pads each LZ4 frame, which the decoder has to trim off.
    checkReadsBack(cso, @"aligned.zso", makeCSO(image, "ZISO", 1, 2, kinds), image);
    checkReadsBack(cso, @"v0.zso", makeCSO(image, "ZISO", 0, 0, NULL), image);

    // No core here decodes the LZ4 frames CSO version 2 can hold, so such a file is refused.
    CSOFrameKind lz4Kinds[SectorCount];
    for(unsigned i = 0; i < SectorCount; i++)
        lz4Kinds[i] = i == 7 ? CSOFrameLZ4InVersion2 : CSOFrameCompressed;
    checkUnreadable(cso, @"v2-lz4.cso", makeCSO(image, "CISO", 2, 0, lz4Kinds));

    checkUnreadable(cso, @"v2.zso", makeCSO(image, "ZISO", 2, 0, NULL));
    checkUnreadable(cso, @"v3.cso", makeCSO(image, "CISO", 3, 0, NULL));
    checkUnreadable(cso, @"alignment.cso", makeCSO(image, "CISO", 1, 12, NULL));

    NSMutableData *data = makeCSO(image, "CISO", 1, 0, NULL);
    put32(data, 0, 0x4F534944); // "DISO"
    checkUnreadable(cso, @"magic.cso", data);

    const uint32_t frameSizes[] = { 1000, 1024, 2 * 1024 * 1024 }; // not a power of two, too small, too big
    for(size_t i = 0; i < sizeof(frameSizes) / sizeof(frameSizes[0]); i++) {
        data = makeCSO(image, "CISO", 1, 0, NULL);
        put32(data, 16, frameSizes[i]);
        checkUnreadable(cso, [NSString stringWithFormat:@"frame-size-%u.cso", frameSizes[i]], data);
    }

    data = makeCSO(image, "CISO", 1, 0, NULL);
    put64(data, 8, 0);
    checkUnreadable(cso, @"empty.cso", data);

    data = makeCSO(image, "CISO", 1, 0, NULL);
    put64(data, 8, 17ULL << 30);
    checkUnreadable(cso, @"huge.cso", data);

    data = makeCSO(image, "CISO", 1, 0, NULL);
    data.length = data.length / 2;
    checkUnreadable(cso, @"cut.cso", data);

    checkUnreadable(cso, @"text.zso", [@"not a disc" dataUsingEncoding:NSUTF8StringEncoding]);

    // A frame that never decodes: reads stop there, now and on every later read, and the frames
    // around it still read.
    CSOFrameKind badKinds[SectorCount];
    for(unsigned i = 0; i < SectorCount; i++)
        badKinds[i] = i == 3 ? CSOFrameUndecodable : CSOFrameCompressed;
    OEFile *file = [[OECSOFile alloc] initWithFileURL:writeFile(@"bad-frame.zso", makeCSO(image, "ZISO", 1, 11, badKinds)) error:nil];
    for(int attempt = 0; attempt < 2; attempt++) {
        assert([[file readDataInRange:NSMakeRange(0, ImageSize)] isEqualToData:[image subdataWithRange:NSMakeRange(0, 3 * SectorSize)]]);
        assert([file readDataInRange:NSMakeRange(3 * SectorSize, 1)].length == 0);
        assert([[file readDataInRange:NSMakeRange(4 * SectorSize, SectorSize)] isEqualToData:[image subdataWithRange:NSMakeRange(4 * SectorSize, SectorSize)]]);
    }
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if(argc != 2) {
            fprintf(stderr, "usage: %s <temporary folder>\n", argv[0]);
            return 2;
        }
        temporaryDirectory = @(argv[1]);
        NSData *image = makeImage();
        checkGCZ(image);
        checkCSO(image);
        puts("OEGCZFile and OECSOFile tests passed");
    }
    return 0;
}
