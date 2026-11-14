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

// Checks OECHDReader against small CHDs made from made-up images (no game data): a PSP DVD image,
// a two-track CD (a data track and an audio track with a pregap), and a three-track GD-ROM.
// Run by Scripts/test-chd-reader.sh. The fixtures come from Fixtures/CHD/make-fixtures.sh, which
// runs this program with --write-iso, --write-cd and --write-gd to get the images and converts them
// with chdman.

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

// The two-track CD: track 1 is MODE2/2352 data, track 2 is audio whose first 150 sectors are its pregap.
enum { CDDataSectors = 10, CDAudioSectors = 157, CDAudioPregap = 150, RawSectorSize = 2352 };

static void makeCDDataTrack(uint8_t *track)
{
    for(size_t sector = 0; sector < CDDataSectors; sector++) {
        uint8_t *bytes = track + sector * RawSectorSize;
        memcpy(bytes, "\x00\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x00", 12); // sync
        bytes[12] = 0; bytes[13] = 2; bytes[14] = (uint8_t)sector; bytes[15] = 2; // header, mode 2
        for(size_t i = 16; i < RawSectorSize; i++)
            bytes[i] = (uint8_t)(sector * 7 + (i - 16));
    }
}

static void makeCDAudioTrack(uint8_t *track)
{
    for(size_t i = 0; i < (size_t)CDAudioSectors * RawSectorSize; i++)
        track[i] = (uint8_t)((i / RawSectorSize) * 3 + i % RawSectorSize);
}

static const char *const CDCueSheet =
    "FILE \"Game (Track 01).bin\" BINARY\n"
    "  TRACK 01 MODE2/2352\n"
    "    INDEX 01 00:00:00\n"
    "FILE \"Game (Track 02).bin\" BINARY\n"
    "  TRACK 02 AUDIO\n"
    "    INDEX 00 00:00:00\n"
    "    INDEX 01 00:02:00\n";

// The GD-ROM, as a GDI: data, audio, data. Each track ends before the next one starts, as on a real
// disc (where the third track starts the high-density area at sector 45000), and no track is a
// multiple of the 4 sectors CHD pads tracks to.
enum { GDTrackCount = 3 };
static const struct { uint32_t lba; uint32_t sectors; OECHDTrackType type; } GDTracks[GDTrackCount] = {
    { 0, 150, OECHDTrackTypeMode1Raw },
    { 301, 77, OECHDTrackTypeAudio },
    { 1003, 41, OECHDTrackTypeMode1Raw },
};

static const char *const GDISheet =
    "3\n"
    "1 0 4 2352 \"Game (Track 01).bin\" 0\n"
    "2 301 0 2352 \"Game (Track 02).bin\" 0\n"
    "3 1003 4 2352 \"Game (Track 03).bin\" 0\n";

static uint8_t *makeGDTrack(unsigned index)
{
    const size_t size = (size_t)GDTracks[index].sectors * RawSectorSize;
    uint8_t *track = malloc(size);
    assert(track != NULL);
    for(size_t i = 0; i < size; i++)
        track[i] = (uint8_t)((index + 1) * 11 + (i / RawSectorSize) * 5 + i % RawSectorSize);
    return track;
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

typedef OECHDReaderStatus (*Opener)(const char *, OECHDReader **);

static void checkRejected(Opener open, const char *path, OECHDReaderStatus expected)
{
    OECHDReader *reader = (OECHDReader *)1;
    assert(open(path, &reader) == expected);
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
static void checkVersion(Opener open, const char *temporaryDirectory, uint8_t version, OECHDReaderStatus expected)
{
    uint8_t *bytes = NULL;
    const size_t length = readFile(fixture("dvd.chd"), &bytes);
    bytes[15] = version;
    char path[2048];
    snprintf(path, sizeof(path), "%s/version-%u.chd", temporaryDirectory, version);
    writeFile(path, bytes, length);
    free(bytes);
    checkRejected(open, path, expected);
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

static void checkTrack(OECHDReader *reader, unsigned index, const uint8_t *expected, size_t size)
{
    assert(OECHDReaderTrackSize(reader, index) == size);
    uint8_t *actual = calloc(1, size + 16);
    assert(actual != NULL);
    assert(OECHDReaderReadTrack(reader, index, 0, actual, size + 16) == size);
    assert(memcmp(actual, expected, size) == 0);

    // A read that starts at an odd byte inside one sector and ends in another.
    assert(OECHDReaderReadTrack(reader, index, 2001, actual, 3001) == 3001);
    assert(memcmp(actual, expected + 2001, 3001) == 0);
    assert(OECHDReaderReadTrack(reader, index, size, actual, 1) == 0);
    free(actual);
}

static void checkCD(void)
{
    static uint8_t dataTrack[CDDataSectors * RawSectorSize], audioTrack[CDAudioSectors * RawSectorSize];
    makeCDDataTrack(dataTrack);
    makeCDAudioTrack(audioTrack);

    OECHDReader *reader = NULL;
    assert(OECHDReaderOpenCD(fixture("cd-mixed.chd"), &reader) == OECHDReaderStatusOK);
    assert(OECHDReaderTrackCount(reader) == 2);

    const OECHDTrack *data = OECHDReaderTrackAtIndex(reader, 0);
    assert(data->number == 1 && data->type == OECHDTrackTypeMode2Raw && data->sectorSize == RawSectorSize);
    assert(data->sectors == CDDataSectors && data->pregap == 0 && !data->pregapStored && data->postgap == 0);
    const OECHDTrack *audio = OECHDReaderTrackAtIndex(reader, 1);
    assert(audio->number == 2 && audio->type == OECHDTrackTypeAudio && audio->sectorSize == RawSectorSize);
    assert(audio->sectors == CDAudioSectors && audio->pregap == CDAudioPregap && audio->pregapStored);
    assert(OECHDReaderTrackAtIndex(reader, 2) == NULL);

    // Track 2 starts after track 1's 10 sectors and 2 sectors of CHD padding; its audio is byte-swapped in the CHD.
    checkTrack(reader, 0, dataTrack, sizeof(dataTrack));
    checkTrack(reader, 1, audioTrack, sizeof(audioTrack));

    char cue[512], name[64];
    assert(OECHDReaderWriteCueSheet(reader, "Game", cue, sizeof(cue)) == strlen(CDCueSheet));
    assert(strcmp(cue, CDCueSheet) == 0);
    char small[20];
    assert(OECHDReaderWriteCueSheet(reader, "Game", small, sizeof(small)) == strlen(CDCueSheet));
    assert(strlen(small) == sizeof(small) - 1 && strncmp(small, CDCueSheet, sizeof(small) - 1) == 0);
    assert(OECHDReaderTrackFileName("Game", 2, name, sizeof(name)) == strlen("Game (Track 02).bin"));
    assert(strcmp(name, "Game (Track 02).bin") == 0);
    OECHDReaderClose(reader);
}

// A CD made from a 2048-byte ISO: one MODE1/2048 track whose .bin is the ISO.
static void checkCDFromISO(const uint8_t *image)
{
    OECHDReader *reader = NULL;
    assert(OECHDReaderOpenCD(fixture("cd.chd"), &reader) == OECHDReaderStatusOK);
    assert(OECHDReaderTrackCount(reader) == 1);
    const OECHDTrack *track = OECHDReaderTrackAtIndex(reader, 0);
    assert(track->type == OECHDTrackTypeMode1 && track->sectorSize == SectorSize && track->sectors == SectorCount);
    checkTrack(reader, 0, image, ImageSize);
    OECHDReaderClose(reader);
}

static void checkGDROM(void)
{
    OECHDReader *reader = NULL;
    assert(OECHDReaderOpenGDROM(fixture("gd.chd"), &reader) == OECHDReaderStatusOK);
    assert(OECHDReaderTrackCount(reader) == GDTrackCount);
    for(unsigned index = 0; index < GDTrackCount; index++) {
        const OECHDTrack *track = OECHDReaderTrackAtIndex(reader, index);
        assert(track->number == index + 1 && track->type == GDTracks[index].type && track->sectorSize == RawSectorSize);
        assert(track->sectors == GDTracks[index].sectors && track->lba == GDTracks[index].lba);
        assert(track->pregap == 0 && !track->pregapStored && track->postgap == 0);

        // The gap after a track is in the CHD but not in its .bin, and audio is byte-swapped in the CHD.
        uint8_t *expected = makeGDTrack(index);
        checkTrack(reader, index, expected, (size_t)GDTracks[index].sectors * RawSectorSize);
        free(expected);
    }
    assert(OECHDReaderTrackAtIndex(reader, GDTrackCount) == NULL);
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
    if(argc == 3 && strcmp(argv[1], "--write-cd") == 0) {
        // The two tracks and their CUE sheet, in the given folder.
        static uint8_t dataTrack[CDDataSectors * RawSectorSize], audioTrack[CDAudioSectors * RawSectorSize];
        makeCDDataTrack(dataTrack);
        makeCDAudioTrack(audioTrack);
        char path[2048];
        snprintf(path, sizeof(path), "%s/Game (Track 01).bin", argv[2]);
        writeFile(path, dataTrack, sizeof(dataTrack));
        snprintf(path, sizeof(path), "%s/Game (Track 02).bin", argv[2]);
        writeFile(path, audioTrack, sizeof(audioTrack));
        snprintf(path, sizeof(path), "%s/Game.cue", argv[2]);
        writeFile(path, CDCueSheet, strlen(CDCueSheet));
        return 0;
    }
    if(argc == 3 && strcmp(argv[1], "--write-gd") == 0) {
        // The three tracks and their GDI, in the given folder.
        char path[2048];
        for(unsigned index = 0; index < GDTrackCount; index++) {
            uint8_t *track = makeGDTrack(index);
            snprintf(path, sizeof(path), "%s/Game (Track %02u).bin", argv[2], index + 1);
            writeFile(path, track, (size_t)GDTracks[index].sectors * RawSectorSize);
            free(track);
        }
        snprintf(path, sizeof(path), "%s/Game.gdi", argv[2]);
        writeFile(path, GDISheet, strlen(GDISheet));
        return 0;
    }
    if(argc != 3) {
        fprintf(stderr, "usage: %s <fixture folder> <temporary folder>\n       %s --write-iso <path>\n       %s --write-cd <folder>\n       %s --write-gd <folder>\n", argv[0], argv[0], argv[0], argv[0]);
        return 2;
    }
    snprintf(fixtureDirectory, sizeof(fixtureDirectory), "%s", argv[1]);
    const char *temporaryDirectory = argv[2];

    checkWholeImage("dvd.chd", image);       // chdman's default DVD compression (LZMA, zlib, Huffman, FLAC)
    checkWholeImage("dvd-zstd.chd", image);  // zstd only

    checkRejected(OECHDReaderOpenDVD, fixture("cd.chd"), OECHDReaderStatusNotDVD);         // chdman createcd
    checkRejected(OECHDReaderOpenDVD, fixture("cd-mixed.chd"), OECHDReaderStatusNotDVD);
    checkRejected(OECHDReaderOpenDVD, fixture("gd.chd"), OECHDReaderStatusNotDVD);         // chdman createcd of a GDI
    checkRejected(OECHDReaderOpenDVD, fixture("hd.chd"), OECHDReaderStatusNotDVD);         // chdman createhd
    checkRejected(OECHDReaderOpenDVD, fixture("child.chd"), OECHDReaderStatusNeedsParent); // createdvd with a parent
    checkRejected(OECHDReaderOpenDVD, fixture("make-fixtures.sh"), OECHDReaderStatusCouldNotOpen);
    checkRejected(OECHDReaderOpenDVD, fixture("missing.chd"), OECHDReaderStatusCouldNotOpen);
    checkVersion(OECHDReaderOpenDVD, temporaryDirectory, 4, OECHDReaderStatusNotDVD);
    checkVersion(OECHDReaderOpenDVD, temporaryDirectory, 6, OECHDReaderStatusUnsupported);
    checkDamaged(temporaryDirectory, image);

    checkCD();
    checkCDFromISO(image);
    checkRejected(OECHDReaderOpenCD, fixture("dvd.chd"), OECHDReaderStatusNotCD);
    checkRejected(OECHDReaderOpenCD, fixture("hd.chd"), OECHDReaderStatusNotCD);
    checkRejected(OECHDReaderOpenCD, fixture("gd.chd"), OECHDReaderStatusNotCD);
    checkRejected(OECHDReaderOpenCD, fixture("child.chd"), OECHDReaderStatusNeedsParent);
    checkRejected(OECHDReaderOpenCD, fixture("missing.chd"), OECHDReaderStatusCouldNotOpen);
    checkVersion(OECHDReaderOpenCD, temporaryDirectory, 4, OECHDReaderStatusUnsupported);

    checkGDROM();
    checkRejected(OECHDReaderOpenGDROM, fixture("dvd.chd"), OECHDReaderStatusNotGDROM);
    checkRejected(OECHDReaderOpenGDROM, fixture("cd-mixed.chd"), OECHDReaderStatusNotGDROM);
    checkRejected(OECHDReaderOpenGDROM, fixture("hd.chd"), OECHDReaderStatusNotGDROM);
    checkRejected(OECHDReaderOpenGDROM, fixture("child.chd"), OECHDReaderStatusNeedsParent);
    checkRejected(OECHDReaderOpenGDROM, fixture("missing.chd"), OECHDReaderStatusCouldNotOpen);

    puts("OECHDReader tests passed");
    return 0;
}
