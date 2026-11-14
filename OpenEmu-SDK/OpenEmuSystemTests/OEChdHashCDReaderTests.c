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


// Checks OEChdHashCDReader, the rcheevos cdreader the cores hash CHD discs with, on the CHD fixtures:
// which track each request opens, the sector each track starts at, and the data a sector read returns.
// Damaged, missing and unsupported CHDs must open nothing, and other files must go to rcheevos's own
// cdreader. Run by Scripts/test-chd-reader.sh, next to OECHDReaderTests.c.

#include "../../OpenEmuKit/Source/OEChdHashCDReader.h"
#include "../OpenEmuSystem/OECHDReader.h"
#ifdef NDEBUG
#error "These tests require assertions; compile with -UNDEBUG."
#endif
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char fixtureDirectory[1024];
static rc_hash_iterator_t iterator;

static const char *fixture(const char *name)
{
    static char path[2048];
    snprintf(path, sizeof(path), "%s/%s", fixtureDirectory, name);
    return path;
}

static void *openTrack(const char *path, uint32_t track)
{
    return OEChdHashCDReader.open_track_iterator(path, track, &iterator);
}

// A track opens, starts at `firstSector`, and its sector `sector` reads as `length` bytes of the track's
// .bin from `binOffset` (OECHDReader's view), crossing into the next sector's data when it is longer
// than one sector's 2048 bytes.
static void checkTrack(const char *name, uint32_t track, uint32_t firstSector, unsigned index, uint32_t sector,
                       uint32_t sectorSize, uint32_t headerSize, int gdrom)
{
    void *handle = openTrack(fixture(name), track);
    assert(handle != NULL);
    assert(OEChdHashCDReader.first_track_sector(handle) == firstSector);

    OECHDReader *reader = NULL;
    assert((gdrom ? OECHDReaderOpenGDROM : OECHDReaderOpenCD)(fixture(name), &reader) == OECHDReaderStatusOK);
    uint8_t expected[4096], actual[4096];
    const uint64_t start = (uint64_t)(sector - firstSector) * sectorSize + headerSize;
    assert(OECHDReaderReadTrack(reader, index, start, expected, 2048) == 2048);
    assert(OECHDReaderReadTrack(reader, index, start + sectorSize, expected + 2048, 952) == 952);
    OECHDReaderClose(reader);

    memset(actual, 0, sizeof(actual));
    assert(OEChdHashCDReader.read_sector(handle, sector, actual, 3000) == 3000);
    assert(memcmp(actual, expected, 3000) == 0);
    if(firstSector > 0)
        assert(OEChdHashCDReader.read_sector(handle, firstSector - 1, actual, 16) == 0);
    OEChdHashCDReader.close_track(handle);
}

static void checkNotOpened(const char *path, uint32_t track)
{
    assert(openTrack(path, track) == NULL);
}

// The GD-ROM fixture's GDI: tracks at sectors 0, 301 and 1003; data, audio, data. Its made-up sectors
// have no sync pattern, so the layout comes from the GDI (MODE1/2352: 16 header bytes).
static void checkGDROM(void)
{
    checkTrack("gd.chd", 1, 0, 0, 5, 2352, 16, 1);
    checkTrack("gd.chd", 2, 301, 1, 310, 2352, 16, 1);
    checkTrack("gd.chd", 3, 1003, 2, 1010, 2352, 16, 1);
    checkTrack("gd.chd", RC_HASH_CDTRACK_LAST, 1003, 2, 1003, 2352, 16, 1);
    checkTrack("gd.chd", RC_HASH_CDTRACK_FIRST_DATA, 0, 0, 0, 2352, 16, 1);
    checkTrack("gd.chd", RC_HASH_CDTRACK_LARGEST, 0, 0, 1, 2352, 16, 1); // 150 sectors against 41
    checkNotOpened(fixture("gd.chd"), 4);
    checkNotOpened(fixture("gd.chd"), RC_HASH_CDTRACK_FIRST_OF_SECOND_SESSION);
}

// The CD fixture as its CUE sheet: track 1 is 10 sectors of MODE2/2352 (too short for the sector 16
// rcheevos looks at, so the mode gives the layout: 24 header bytes), track 2 is audio whose 150-sector
// pregap is stored at the start of its .bin.
static void checkCD(void)
{
    checkTrack("cd-mixed.chd", 1, 0, 0, 2, 2352, 24, 0);
    checkTrack("cd-mixed.chd", RC_HASH_CDTRACK_FIRST_DATA, 0, 0, 0, 2352, 24, 0);
    checkTrack("cd-mixed.chd", RC_HASH_CDTRACK_LARGEST, 0, 0, 0, 2352, 24, 0);

    void *audio = openTrack(fixture("cd-mixed.chd"), RC_HASH_CDTRACK_LAST);
    assert(audio != NULL);
    assert(OEChdHashCDReader.first_track_sector(audio) == 10 + 150); // after track 1, past the pregap
    OEChdHashCDReader.close_track(audio);
    checkNotOpened(fixture("cd-mixed.chd"), 3);
}

// A DVD reads as the ISO it was made from: one track, 2048-byte sectors from sector 0, and no other
// track (rcheevos's own reader names none either).
static void checkDVD(const char *temporaryDirectory)
{
    void *handle = openTrack(fixture("dvd.chd"), 1);
    assert(handle != NULL);
    assert(OEChdHashCDReader.first_track_sector(handle) == 0);
    uint8_t sector[2048];
    assert(OEChdHashCDReader.read_sector(handle, 16, sector, sizeof(sector)) == sizeof(sector));
    assert(memcmp(sector, "\x01" "CD001", 6) == 0 && memcmp(sector + 8, "PSP GAME", 8) == 0);
    OEChdHashCDReader.close_track(handle);

    checkNotOpened(fixture("dvd.chd"), 2);
    checkNotOpened(fixture("dvd.chd"), RC_HASH_CDTRACK_FIRST_DATA);
    checkNotOpened(fixture("dvd.chd"), RC_HASH_CDTRACK_LARGEST);

    // The same disc as a plain ISO goes to rcheevos's own reader, and reads the same.
    OECHDReader *reader = NULL;
    assert(OECHDReaderOpenDVD(fixture("dvd.chd"), &reader) == OECHDReaderStatusOK);
    const size_t size = (size_t)OECHDReaderSize(reader);
    uint8_t *image = malloc(size);
    assert(image != NULL && OECHDReaderRead(reader, 0, image, size) == size);
    OECHDReaderClose(reader);
    char path[2048];
    snprintf(path, sizeof(path), "%s/image.iso", temporaryDirectory);
    FILE *file = fopen(path, "wb");
    assert(file != NULL && fwrite(image, 1, size, file) == size);
    fclose(file);
    free(image);

    void *plain = openTrack(path, 1);
    assert(plain != NULL);
    uint8_t plainSector[2048];
    assert(OEChdHashCDReader.read_sector(plain, 16, plainSector, sizeof(plainSector)) == sizeof(plainSector));
    assert(memcmp(plainSector, sector, sizeof(sector)) == 0);
    OEChdHashCDReader.close_track(plain);
}

static void checkRefused(const char *temporaryDirectory)
{
    checkNotOpened(fixture("missing.chd"), 1);
    checkNotOpened(fixture("hd.chd"), 1);    // a hard disk
    checkNotOpened(fixture("child.chd"), 1); // needs its parent

    char path[2048];
    snprintf(path, sizeof(path), "%s/text.chd", temporaryDirectory);
    FILE *file = fopen(path, "wb");
    assert(file != NULL && fputs("not a disc", file) >= 0);
    fclose(file);
    checkNotOpened(path, 1);
    assert(OEChdHashCDReader.open_track(path, 1) == NULL);
}

int main(int argc, char **argv)
{
    if(argc != 3) {
        fprintf(stderr, "usage: %s <fixture folder> <temporary folder>\n", argv[0]);
        return 2;
    }
    snprintf(fixtureDirectory, sizeof(fixtureDirectory), "%s", argv[1]);
    rc_hash_initialize_iterator(&iterator, fixture("gd.chd"), NULL, 0);

    checkGDROM();
    checkCD();
    checkDVD(argv[2]);
    checkRefused(argv[2]);

    rc_hash_destroy_iterator(&iterator);
    puts("OEChdHashCDReader tests passed");
    return 0;
}
