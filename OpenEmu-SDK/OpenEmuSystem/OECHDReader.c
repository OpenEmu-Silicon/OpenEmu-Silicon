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


#include "OECHDReader.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libchdr/chd.h>

enum {
    OECHDSectorSize = 2048,
    OECHDCacheSlots = 4, // a few decompressed hunks, so reads that alternate between two places stay cheap

    // CD images (libchdr's cdrom.h; not included, its inline functions do not build warning-free here)
    OECHDMaxTracks = 99,
    OECHDCDFrameSize = 2448,   // a 2352-byte sector, then 96 bytes of subchannel data
    OECHDCDTrackPadding = 4,   // every track's frames are padded to a multiple of this
};

struct OECHDReader {
    chd_file *chd;
    uint64_t size;
    uint32_t hunkBytes;
    uint32_t hunkCount;
    uint8_t *cache;                        // OECHDCacheSlots hunks, one after another
    uint32_t cachedHunk[OECHDCacheSlots];  // UINT32_MAX marks an empty slot
    unsigned nextSlot;

    // CD and GD-ROM
    unsigned trackCount;
    OECHDTrack tracks[OECHDMaxTracks];
    uint32_t trackFirstFrame[OECHDMaxTracks]; // where each track starts among the CHD's frames
    uint8_t frame[OECHDCDFrameSize];
};

static OECHDReaderStatus OECHDReaderStatusForError(chd_error error)
{
    switch(error) {
        case CHDERR_REQUIRES_PARENT:
        case CHDERR_INVALID_PARENT:
            return OECHDReaderStatusNeedsParent;
        case CHDERR_UNSUPPORTED_VERSION:
        case CHDERR_UNSUPPORTED_FORMAT:
        case CHDERR_NOT_SUPPORTED:
            return OECHDReaderStatusUnsupported;
        default:
            return OECHDReaderStatusCouldNotOpen;
    }
}

static int OECHDHeaderHasParent(const chd_header *header)
{
    for(size_t i = 0; i < CHD_SHA1_BYTES; i++)
        if(header->parentsha1[i] != 0)
            return 1;
    return 0;
}

// Reads the version from the start of the file: "MComprHD", header length, version (big endian).
// Returns 0 when the file is not a CHD.
static uint32_t OECHDFileVersion(const char *path)
{
    FILE *file = fopen(path, "rb");
    if(file == NULL)
        return 0;
    uint8_t start[16];
    const size_t got = fread(start, 1, sizeof(start), file);
    fclose(file);
    if(got != sizeof(start) || memcmp(start, "MComprHD", 8) != 0)
        return 0;
    return ((uint32_t)start[12] << 24) | ((uint32_t)start[13] << 16) | ((uint32_t)start[14] << 8) | start[15];
}

// Checks shared by every kind of image, from the header alone. chdman has written version 5 since
// 2012, and libchdr's header-only read of older versions guesses their unit size from a structure it
// never filled in, so they are turned away before it is called (as `olderStatus`).
static OECHDReaderStatus OECHDReadHeader(const char *path, OECHDReaderStatus olderStatus, chd_header *header)
{
    const uint32_t version = OECHDFileVersion(path);
    if(version == 0)
        return OECHDReaderStatusCouldNotOpen;
    if(version < 5)
        return olderStatus;
    if(version > 5)
        return OECHDReaderStatusUnsupported;

    const chd_error error = chd_read_header(path, header);
    if(error != CHDERR_NONE)
        return OECHDReaderStatusForError(error);
    if(OECHDHeaderHasParent(header))
        return OECHDReaderStatusNeedsParent;
    return OECHDReaderStatusOK;
}

static int OECHDHasMetadata(chd_file *chd, uint32_t tag)
{
    uint8_t scratch[4];
    return chd_get_metadata(chd, tag, 0, scratch, sizeof(scratch), NULL, NULL, NULL) == CHDERR_NONE;
}

// Opens the CHD and sets up the hunk cache; the caller fills in what the kind of image needs.
static OECHDReaderStatus OECHDReaderCreate(const char *path, OECHDReader **reader)
{
    chd_file *chd = NULL;
    const chd_error error = chd_open(path, CHD_OPEN_READ, NULL, &chd);
    if(error != CHDERR_NONE)
        return OECHDReaderStatusForError(error);

    const chd_header *header = chd_get_header(chd);
    OECHDReader *result = calloc(1, sizeof(OECHDReader));
    uint8_t *cache = result ? malloc((size_t)header->hunkbytes * OECHDCacheSlots) : NULL;
    if(result == NULL || cache == NULL) {
        free(result);
        chd_close(chd);
        return OECHDReaderStatusCouldNotOpen;
    }

    result->chd = chd;
    result->size = header->logicalbytes;
    result->hunkBytes = header->hunkbytes;
    result->hunkCount = header->totalhunks;
    result->cache = cache;
    for(unsigned slot = 0; slot < OECHDCacheSlots; slot++)
        result->cachedHunk[slot] = UINT32_MAX;

    *reader = result;
    return OECHDReaderStatusOK;
}

#pragma mark - DVD

// The header alone tells a DVD image from most others without decoding the hunk map, which is slow
// for large hard-disk CHDs. createdvd writes 2048-byte units.
static int OECHDHeaderLooksLikeDVD(const chd_header *header)
{
    if(header->unitbytes != OECHDSectorSize)
        return 0;
    if(header->hunkbytes == 0 || header->hunkbytes % OECHDSectorSize != 0)
        return 0;
    return header->logicalbytes != 0 && header->logicalbytes % OECHDSectorSize == 0;
}

OECHDReaderStatus OECHDReaderOpenDVD(const char *path, OECHDReader **reader)
{
    *reader = NULL;

    chd_header header;
    OECHDReaderStatus status = OECHDReadHeader(path, OECHDReaderStatusNotDVD, &header);
    if(status != OECHDReaderStatusOK)
        return status;
    if(!OECHDHeaderLooksLikeDVD(&header))
        return OECHDReaderStatusNotDVD;

    OECHDReader *result = NULL;
    status = OECHDReaderCreate(path, &result);
    if(status != OECHDReaderStatusOK)
        return status;

    // A CD or GD-ROM CHD made from 2048-byte tracks could pass the header check; its track list gives it away.
    static const uint32_t otherMediaTags[] = {
        CDROM_OLD_METADATA_TAG, CDROM_TRACK_METADATA_TAG, CDROM_TRACK_METADATA2_TAG,
        GDROM_OLD_METADATA_TAG, GDROM_TRACK_METADATA_TAG,
        HARD_DISK_METADATA_TAG, AV_METADATA_TAG,
    };
    for(size_t i = 0; i < sizeof(otherMediaTags) / sizeof(otherMediaTags[0]); i++) {
        if(OECHDHasMetadata(result->chd, otherMediaTags[i])) {
            OECHDReaderClose(result);
            return OECHDReaderStatusNotDVD;
        }
    }

    *reader = result;
    return OECHDReaderStatusOK;
}

uint64_t OECHDReaderSize(const OECHDReader *reader)
{
    return reader->size;
}

static const uint8_t *OECHDReaderHunk(OECHDReader *reader, uint32_t hunk)
{
    for(unsigned slot = 0; slot < OECHDCacheSlots; slot++)
        if(reader->cachedHunk[slot] == hunk)
            return reader->cache + (size_t)slot * reader->hunkBytes;

    unsigned slot = reader->nextSlot;
    reader->nextSlot = (slot + 1) % OECHDCacheSlots;
    uint8_t *buffer = reader->cache + (size_t)slot * reader->hunkBytes;
    reader->cachedHunk[slot] = UINT32_MAX;
    if(chd_read(reader->chd, hunk, buffer) != CHDERR_NONE)
        return NULL;
    reader->cachedHunk[slot] = hunk;
    return buffer;
}

size_t OECHDReaderRead(OECHDReader *reader, uint64_t offset, void *buffer, size_t length)
{
    if(offset >= reader->size)
        return 0;
    if(length > reader->size - offset)
        length = (size_t)(reader->size - offset);

    uint8_t *output = buffer;
    size_t copied = 0;
    while(copied < length) {
        const uint64_t position = offset + copied;
        const uint32_t hunk = (uint32_t)(position / reader->hunkBytes);
        const size_t offsetInHunk = (size_t)(position % reader->hunkBytes);
        if(hunk >= reader->hunkCount)
            break;

        const uint8_t *data = OECHDReaderHunk(reader, hunk);
        if(data == NULL)
            break;

        size_t count = reader->hunkBytes - offsetInHunk;
        if(count > length - copied)
            count = length - copied;
        memcpy(output + copied, data + offsetInHunk, count);
        copied += count;
    }
    return copied;
}

#pragma mark - CD and GD-ROM

static int OECHDTrackTypeFromName(const char *name, OECHDTrackType *type, uint32_t *sectorSize)
{
    static const struct { const char *name; OECHDTrackType type; uint32_t sectorSize; } types[] = {
        { "MODE1",     OECHDTrackTypeMode1,    2048 },
        { "MODE1_RAW", OECHDTrackTypeMode1Raw, 2352 },
        { "MODE2",     OECHDTrackTypeMode2,    2336 },
        { "MODE2_RAW", OECHDTrackTypeMode2Raw, 2352 },
        { "AUDIO",     OECHDTrackTypeAudio,    2352 },
    };
    for(size_t i = 0; i < sizeof(types) / sizeof(types[0]); i++) {
        if(strcmp(name, types[i].name) == 0) {
            *type = types[i].type;
            *sectorSize = types[i].sectorSize;
            return 1;
        }
    }
    return 0;
}

// Reads the track list from the CHD's text metadata: for a CD, CHT2 (with gaps) or the older CHTR
// (without); for a GD-ROM, CHGD.
static OECHDReaderStatus OECHDReaderReadTracks(OECHDReader *reader, int gdrom)
{
    const int hasGaps = !gdrom && OECHDHasMetadata(reader->chd, CDROM_TRACK_METADATA2_TAG);
    const uint32_t tag = gdrom ? GDROM_TRACK_METADATA_TAG : hasGaps ? CDROM_TRACK_METADATA2_TAG : CDROM_TRACK_METADATA_TAG;
    const int fields = gdrom ? 9 : hasGaps ? 8 : 4;
    // 64-bit, so a damaged track list cannot wrap them: 99 tracks of up to INT_MAX frames each.
    uint64_t frame = 0, lba = 0;

    for(unsigned index = 0; index < OECHDMaxTracks; index++) {
        char metadata[256] = { 0 };
        uint32_t length = 0;
        if(chd_get_metadata(reader->chd, tag, index, metadata, (uint32_t)sizeof(metadata) - 1, &length, NULL, NULL) != CHDERR_NONE)
            break;
        metadata[length < sizeof(metadata) ? length : sizeof(metadata) - 1] = 0;

        int number = 0, frames = 0, padding = 0, pregap = 0, postgap = 0;
        char type[32] = { 0 }, subtype[32] = { 0 }, pregapType[32] = { 0 }, pregapSubtype[32] = { 0 };
        const int parsed = gdrom
            ? sscanf(metadata, "TRACK:%d TYPE:%31s SUBTYPE:%31s FRAMES:%d PAD:%d PREGAP:%d PGTYPE:%31s PGSUB:%31s POSTGAP:%d",
                     &number, type, subtype, &frames, &padding, &pregap, pregapType, pregapSubtype, &postgap)
            : hasGaps
            ? sscanf(metadata, "TRACK:%d TYPE:%31s SUBTYPE:%31s FRAMES:%d PREGAP:%d PGTYPE:%31s PGSUB:%31s POSTGAP:%d",
                     &number, type, subtype, &frames, &pregap, pregapType, pregapSubtype, &postgap)
            : sscanf(metadata, "TRACK:%d TYPE:%31s SUBTYPE:%31s FRAMES:%d", &number, type, subtype, &frames);
        if(parsed != fields || number != (int)index + 1 || frames <= 0 || padding < 0 || padding >= frames || pregap < 0 || postgap < 0)
            return OECHDReaderStatusCouldNotOpen;
        // chdman moves a GD-ROM's gaps into the tracks before them; one with gaps left is not a layout
        // a GDI can describe (Flycast refuses it too).
        if(gdrom && (pregap != 0 || postgap != 0))
            return OECHDReaderStatusUnsupported;

        OECHDTrack *track = &reader->tracks[index];
        if(!OECHDTrackTypeFromName(type, &track->type, &track->sectorSize))
            return OECHDReaderStatusUnsupported;
        track->number = (unsigned)number;
        track->sectors = (uint32_t)(frames - padding);
        track->pregap = (uint32_t)pregap;
        track->pregapStored = pregap > 0 && pregapType[0] == 'V'; // "V…": the pregap's sectors are in the data
        track->postgap = (uint32_t)postgap;
        // GD-ROM: PAD is the empty sectors up to the next track's start (45000 for the high-density
        // area); they are part of FRAMES but not of the track's .bin.
        track->lba = gdrom ? (uint32_t)lba : 0;
        lba += (uint64_t)frames;

        // Each track's frames are padded to a multiple of OECHDCDTrackPadding in the CHD.
        reader->trackFirstFrame[index] = (uint32_t)frame;
        frame += (uint64_t)frames + (OECHDCDTrackPadding - (uint64_t)frames % OECHDCDTrackPadding) % OECHDCDTrackPadding;
        // The tracks so far must fit in the CHD, and their starts in the 32-bit fields above (a CD or
        // GD-ROM has well under a million frames).
        if(frame > UINT32_MAX || lba > UINT32_MAX || frame * OECHDCDFrameSize > reader->size)
            return OECHDReaderStatusCouldNotOpen;
        reader->trackCount = index + 1;
    }

    if(reader->trackCount == 0)
        return OECHDReaderStatusCouldNotOpen;
    return OECHDReaderStatusOK;
}

// CD and GD-ROM images both use CD frames; the kind of track list tells them apart.
static OECHDReaderStatus OECHDReaderOpenDisc(const char *path, int gdrom, OECHDReader **reader)
{
    *reader = NULL;
    const OECHDReaderStatus wrongKind = gdrom ? OECHDReaderStatusNotGDROM : OECHDReaderStatusNotCD;

    chd_header header;
    OECHDReaderStatus status = OECHDReadHeader(path, OECHDReaderStatusUnsupported, &header);
    if(status != OECHDReaderStatusOK)
        return status;
    if(header.unitbytes != OECHDCDFrameSize || header.hunkbytes == 0 || header.hunkbytes % OECHDCDFrameSize != 0)
        return wrongKind;

    OECHDReader *result = NULL;
    status = OECHDReaderCreate(path, &result);
    if(status != OECHDReaderStatusOK)
        return status;

    const int hasTrackList = gdrom
        ? OECHDHasMetadata(result->chd, GDROM_TRACK_METADATA_TAG)
        : OECHDHasMetadata(result->chd, CDROM_TRACK_METADATA2_TAG) || OECHDHasMetadata(result->chd, CDROM_TRACK_METADATA_TAG);
    status = hasTrackList ? OECHDReaderReadTracks(result, gdrom) : wrongKind;

    if(status != OECHDReaderStatusOK) {
        OECHDReaderClose(result);
        return status;
    }
    *reader = result;
    return OECHDReaderStatusOK;
}

OECHDReaderStatus OECHDReaderOpenCD(const char *path, OECHDReader **reader)
{
    return OECHDReaderOpenDisc(path, 0, reader);
}

OECHDReaderStatus OECHDReaderOpenGDROM(const char *path, OECHDReader **reader)
{
    return OECHDReaderOpenDisc(path, 1, reader);
}

unsigned OECHDReaderTrackCount(const OECHDReader *reader)
{
    return reader->trackCount;
}

const OECHDTrack *OECHDReaderTrackAtIndex(const OECHDReader *reader, unsigned index)
{
    return index < reader->trackCount ? &reader->tracks[index] : NULL;
}

uint64_t OECHDReaderTrackSize(const OECHDReader *reader, unsigned index)
{
    if(index >= reader->trackCount)
        return 0;
    return (uint64_t)reader->tracks[index].sectors * reader->tracks[index].sectorSize;
}

size_t OECHDReaderReadTrack(OECHDReader *reader, unsigned index, uint64_t offset, void *buffer, size_t length)
{
    const uint64_t size = OECHDReaderTrackSize(reader, index);
    if(offset >= size)
        return 0;
    if(length > size - offset)
        length = (size_t)(size - offset);

    const OECHDTrack *track = &reader->tracks[index];
    uint8_t *output = buffer;
    size_t copied = 0;
    while(copied < length) {
        // A frame is the track's sector (sectorSize bytes, at the start) followed by padding and subchannel data.
        const uint64_t position = offset + copied;
        const uint32_t sector = (uint32_t)(position / track->sectorSize);
        const size_t offsetInSector = (size_t)(position % track->sectorSize);
        const uint64_t frameOffset = ((uint64_t)reader->trackFirstFrame[index] + sector) * OECHDCDFrameSize;
        if(OECHDReaderRead(reader, frameOffset, reader->frame, track->sectorSize) != track->sectorSize)
            break;

        // CHD keeps CD audio big-endian; the .bin it came from was little-endian.
        if(track->type == OECHDTrackTypeAudio) {
            for(size_t i = 0; i + 1 < track->sectorSize; i += 2) {
                const uint8_t byte = reader->frame[i];
                reader->frame[i] = reader->frame[i + 1];
                reader->frame[i + 1] = byte;
            }
        }

        size_t count = track->sectorSize - offsetInSector;
        if(count > length - copied)
            count = length - copied;
        memcpy(output + copied, reader->frame + offsetInSector, count);
        copied += count;
    }
    return copied;
}

size_t OECHDReaderTrackFileName(const char *baseName, unsigned number, char *buffer, size_t capacity)
{
    const int length = snprintf(buffer, capacity, "%s (Track %02u).bin", baseName, number);
    return length < 0 ? 0 : (size_t)length;
}

static void OECHDWriteMSF(char *buffer, size_t capacity, uint32_t sectors)
{
    snprintf(buffer, capacity, "%02u:%02u:%02u", sectors / (75 * 60), sectors / 75 % 60, sectors % 75);
}

// Appends like snprintf: counts every character, writes only what fits.
__attribute__((format(printf, 4, 5)))
static void OECHDAppend(char *buffer, size_t capacity, size_t *total, const char *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    const int length = vsnprintf(*total < capacity ? buffer + *total : NULL, *total < capacity ? capacity - *total : 0, format, arguments);
    va_end(arguments);
    if(length > 0)
        *total += (size_t)length;
}

size_t OECHDReaderWriteCueSheet(const OECHDReader *reader, const char *baseName, char *buffer, size_t capacity)
{
    static const char *const modes[] = {
        [OECHDTrackTypeMode1] = "MODE1/2048",
        [OECHDTrackTypeMode1Raw] = "MODE1/2352",
        [OECHDTrackTypeMode2] = "MODE2/2336",
        [OECHDTrackTypeMode2Raw] = "MODE2/2352",
        [OECHDTrackTypeAudio] = "AUDIO",
    };

    size_t total = 0;
    if(capacity > 0)
        buffer[0] = 0;
    for(unsigned index = 0; index < reader->trackCount; index++) {
        const OECHDTrack *track = &reader->tracks[index];
        char fileName[1024], time[16];
        OECHDReaderTrackFileName(baseName, track->number, fileName, sizeof(fileName));
        OECHDAppend(buffer, capacity, &total, "FILE \"%s\" BINARY\n  TRACK %02u %s\n", fileName, track->number, modes[track->type]);
        if(track->pregap > 0 && !track->pregapStored) {
            OECHDWriteMSF(time, sizeof(time), track->pregap);
            OECHDAppend(buffer, capacity, &total, "    PREGAP %s\n", time);
        }
        if(track->pregapStored)
            OECHDAppend(buffer, capacity, &total, "    INDEX 00 00:00:00\n");
        OECHDWriteMSF(time, sizeof(time), track->pregapStored ? track->pregap : 0);
        OECHDAppend(buffer, capacity, &total, "    INDEX 01 %s\n", time);
        if(track->postgap > 0) {
            OECHDWriteMSF(time, sizeof(time), track->postgap);
            OECHDAppend(buffer, capacity, &total, "    POSTGAP %s\n", time);
        }
    }
    return total;
}

void OECHDReaderClose(OECHDReader *reader)
{
    if(reader == NULL)
        return;
    chd_close(reader->chd);
    free(reader->cache);
    free(reader);
}
