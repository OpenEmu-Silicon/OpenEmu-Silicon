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

// Checks OECHDReader against small CHDs made from a made-up PSP image (no game data).
// Run by Scripts/test-chd-reader.sh. The fixtures come from Fixtures/CHD/make-fixtures.sh, which
// runs this program with --write-iso to get the image and converts it with chdman.

#include "../OpenEmuSystem/OECHDReader.h"
#ifdef NDEBUG
#error "These tests require assertions; compile with -UNDEBUG."
#endif
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { SectorSize = 2048, SectorCount = 40, ImageSize = SectorSize * SectorCount };

// Sector 16 is an ISO 9660 volume descriptor naming a PSP disc ("PSP GAME" at 0x8008, the bytes
// OEPSPSystemController checks); every other sector is a pattern that shows which sector it is.
static void makeImage(uint8_t *image)
{
    for(size_t i = 0; i < ImageSize; i++)
        image[i] = (uint8_t)((i / SectorSize) * 7 + (i % SectorSize) / 16);

    uint8_t *descriptor = image + 16 * SectorSize;
    memset(descriptor, 0, SectorSize);
    memcpy(descriptor, "\x01" "CD001" "\x01\x00" "PSP GAME", 16);
}

static char fixtureDirectory[1024];

static const char *fixture(const char *name)
{
    static char path[2048];
    snprintf(path, sizeof(path), "%s/%s", fixtureDirectory, name);
    return path;
}

static void checkWholeImage(const char *name, const uint8_t *expected)
{
    OECHDReader *reader = NULL;
    assert(OECHDReaderOpenDVD(fixture(name), &reader) == OECHDReaderStatusOK);
    assert(reader != NULL);
    assert(OECHDReaderSize(reader) == ImageSize);

    static uint8_t actual[ImageSize];
    memset(actual, 0, sizeof(actual));
    assert(OECHDReaderRead(reader, 0, actual, ImageSize) == ImageSize);
    assert(memcmp(actual, expected, ImageSize) == 0);

    // Reads that start inside one hunk and end in another.
    uint8_t piece[5000];
    assert(OECHDReaderRead(reader, 4000, piece, sizeof(piece)) == sizeof(piece));
    assert(memcmp(piece, expected + 4000, sizeof(piece)) == 0);
    assert(OECHDReaderRead(reader, 0x8008, piece, 8) == 8);
    assert(memcmp(piece, "PSP GAME", 8) == 0);

    // At and past the end.
    assert(OECHDReaderRead(reader, ImageSize - 100, piece, sizeof(piece)) == 100);
    assert(memcmp(piece, expected + ImageSize - 100, 100) == 0);
    assert(OECHDReaderRead(reader, ImageSize, piece, 1) == 0);
    assert(OECHDReaderRead(reader, (uint64_t)ImageSize * 10, piece, 1) == 0);

    OECHDReaderClose(reader);
}

static void checkRejected(const char *path, OECHDReaderStatus expected)
{
    OECHDReader *reader = (OECHDReader *)1;
    assert(OECHDReaderOpenDVD(path, &reader) == expected);
    assert(reader == NULL);
}

static void writeFile(const char *path, const void *bytes, size_t length)
{
    FILE *file = fopen(path, "wb");
    assert(file != NULL);
    assert(fwrite(bytes, 1, length, file) == length);
    fclose(file);
}

static size_t readFile(const char *path, uint8_t **bytes)
{
    FILE *file = fopen(path, "rb");
    assert(file != NULL);
    assert(fseek(file, 0, SEEK_END) == 0);
    const long length = ftell(file);
    assert(length > 0);
    rewind(file);
    *bytes = malloc((size_t)length);
    assert(*bytes != NULL);
    assert(fread(*bytes, 1, (size_t)length, file) == (size_t)length);
    fclose(file);
    return (size_t)length;
}

// A CHD with its version field changed: libchdr must not be asked to read it.
static void checkVersion(const char *temporaryDirectory, uint8_t version, OECHDReaderStatus expected)
{
    uint8_t *bytes = NULL;
    const size_t length = readFile(fixture("dvd.chd"), &bytes);
    bytes[15] = version;
    char path[2048];
    snprintf(path, sizeof(path), "%s/version-%u.chd", temporaryDirectory, version);
    writeFile(path, bytes, length);
    free(bytes);
    checkRejected(path, expected);
}

// Damaged compressed data must give a short read, never wrong bytes reported as good.
static void checkDamaged(const char *temporaryDirectory, const uint8_t *expected)
{
    uint8_t *bytes = NULL;
    const size_t length = readFile(fixture("dvd.chd"), &bytes);
    for(size_t i = length / 2; i < length / 2 + 64; i++)
        bytes[i] ^= 0x5A;
    char path[2048];
    snprintf(path, sizeof(path), "%s/damaged.chd", temporaryDirectory);
    writeFile(path, bytes, length);
    free(bytes);

    OECHDReader *reader = NULL;
    const OECHDReaderStatus status = OECHDReaderOpenDVD(path, &reader);
    if(status != OECHDReaderStatusOK)
        return;
    static uint8_t actual[ImageSize];
    const size_t got = OECHDReaderRead(reader, 0, actual, ImageSize);
    assert(got < ImageSize);
    assert(memcmp(actual, expected, got) == 0);
    OECHDReaderClose(reader);
}

int main(int argc, char **argv)
{
    static uint8_t image[ImageSize];
    makeImage(image);

    if(argc == 3 && strcmp(argv[1], "--write-iso") == 0) {
        writeFile(argv[2], image, ImageSize);
        return 0;
    }
    if(argc != 3) {
        fprintf(stderr, "usage: %s <fixture folder> <temporary folder>\n       %s --write-iso <path>\n", argv[0], argv[0]);
        return 2;
    }
    snprintf(fixtureDirectory, sizeof(fixtureDirectory), "%s", argv[1]);
    const char *temporaryDirectory = argv[2];

    checkWholeImage("dvd.chd", image);       // chdman's default DVD compression (LZMA, zlib, Huffman, FLAC)
    checkWholeImage("dvd-zstd.chd", image);  // zstd only

    checkRejected(fixture("cd.chd"), OECHDReaderStatusNotDVD);         // chdman createcd
    checkRejected(fixture("hd.chd"), OECHDReaderStatusNotDVD);         // chdman createhd
    checkRejected(fixture("child.chd"), OECHDReaderStatusNeedsParent); // createdvd with a parent
    checkRejected(fixture("make-fixtures.sh"), OECHDReaderStatusCouldNotOpen);
    checkRejected(fixture("missing.chd"), OECHDReaderStatusCouldNotOpen);
    checkVersion(temporaryDirectory, 4, OECHDReaderStatusNotDVD);
    checkVersion(temporaryDirectory, 6, OECHDReaderStatusUnsupported);
    checkDamaged(temporaryDirectory, image);

    puts("OECHDReader tests passed");
    return 0;
}
