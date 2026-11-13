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

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libchdr/chd.h>

enum {
    OECHDSectorSize = 2048,
    OECHDCacheSlots = 4, // a few decompressed hunks, so reads that alternate between two places stay cheap
};

struct OECHDReader {
    chd_file *chd;
    uint64_t size;
    uint32_t hunkBytes;
    uint32_t hunkCount;
    uint8_t *cache;                        // OECHDCacheSlots hunks, one after another
    uint32_t cachedHunk[OECHDCacheSlots];  // UINT32_MAX marks an empty slot
    unsigned nextSlot;
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

static int OECHDHasMetadata(chd_file *chd, uint32_t tag)
{
    uint8_t scratch[4];
    return chd_get_metadata(chd, tag, 0, scratch, sizeof(scratch), NULL, NULL, NULL) == CHDERR_NONE;
}

OECHDReaderStatus OECHDReaderOpenDVD(const char *path, OECHDReader **reader)
{
    *reader = NULL;

    // createdvd only writes version 5. Older versions are never DVD images, and libchdr's
    // header-only read guesses their sector size from a structure it never filled in, so stop here.
    const uint32_t version = OECHDFileVersion(path);
    if(version == 0)
        return OECHDReaderStatusCouldNotOpen;
    if(version < 5)
        return OECHDReaderStatusNotDVD;
    if(version > 5)
        return OECHDReaderStatusUnsupported;

    chd_header header;
    chd_error error = chd_read_header(path, &header);
    if(error != CHDERR_NONE)
        return OECHDReaderStatusForError(error);
    if(OECHDHeaderHasParent(&header))
        return OECHDReaderStatusNeedsParent;
    if(!OECHDHeaderLooksLikeDVD(&header))
        return OECHDReaderStatusNotDVD;

    chd_file *chd = NULL;
    error = chd_open(path, CHD_OPEN_READ, NULL, &chd);
    if(error != CHDERR_NONE)
        return OECHDReaderStatusForError(error);

    // A CD or GD-ROM CHD made from 2048-byte tracks could pass the header check; its track list gives it away.
    static const uint32_t otherMediaTags[] = {
        CDROM_OLD_METADATA_TAG, CDROM_TRACK_METADATA_TAG, CDROM_TRACK_METADATA2_TAG,
        GDROM_OLD_METADATA_TAG, GDROM_TRACK_METADATA_TAG,
        HARD_DISK_METADATA_TAG, AV_METADATA_TAG,
    };
    for(size_t i = 0; i < sizeof(otherMediaTags) / sizeof(otherMediaTags[0]); i++) {
        if(OECHDHasMetadata(chd, otherMediaTags[i])) {
            chd_close(chd);
            return OECHDReaderStatusNotDVD;
        }
    }

    const chd_header *openHeader = chd_get_header(chd);
    OECHDReader *result = calloc(1, sizeof(OECHDReader));
    uint8_t *cache = result ? malloc((size_t)openHeader->hunkbytes * OECHDCacheSlots) : NULL;
    if(result == NULL || cache == NULL) {
        free(result);
        chd_close(chd);
        return OECHDReaderStatusCouldNotOpen;
    }

    result->chd = chd;
    result->size = openHeader->logicalbytes;
    result->hunkBytes = openHeader->hunkbytes;
    result->hunkCount = openHeader->totalhunks;
    result->cache = cache;
    for(unsigned slot = 0; slot < OECHDCacheSlots; slot++)
        result->cachedHunk[slot] = UINT32_MAX;

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

void OECHDReaderClose(OECHDReader *reader)
{
    if(reader == NULL)
        return;
    chd_close(reader->chd);
    free(reader->cache);
    free(reader);
}
