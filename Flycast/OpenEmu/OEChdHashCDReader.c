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


#include "OEChdHashCDReader.h"

#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "../../OpenEmu-SDK/OpenEmuSystem/OECHDReader.h"

enum { OEChdHashDataSize = 2048 }; // rcheevos reads the 2048 data bytes of each sector

typedef struct {
    void *defaultTrack;  // a track rcheevos's own cdreader opened,
    OECHDReader *reader; // or a track of a GD-ROM CHD:
    unsigned index;
    uint32_t firstSector;
    uint32_t sectorSize;
    uint32_t headerSize; // bytes in each sector before its data
} OEChdHashTrack;

static rc_hash_cdreader_t OEChdHashDefaultCDReader(void)
{
    rc_hash_cdreader_t reader;
    rc_hash_get_default_cdreader(&reader);
    return reader;
}

static int OEChdHashIsCHD(const char *path)
{
    const size_t length = strlen(path);
    return length > 4 && strcasecmp(path + length - 4, ".chd") == 0;
}

// The track rcheevos asks for, as its GDI reader picks it.
static int OEChdHashTrackIndex(const OECHDReader *reader, uint32_t track, unsigned *index)
{
    const unsigned count = OECHDReaderTrackCount(reader);
    if(track == RC_HASH_CDTRACK_FIRST_DATA) {
        for(unsigned i = 0; i < count; i++) {
            if(OECHDReaderTrackAtIndex(reader, i)->type != OECHDTrackTypeAudio) {
                *index = i;
                return 1;
            }
        }
        return 0;
    }
    if(track == RC_HASH_CDTRACK_LAST) {
        *index = count - 1;
        return 1;
    }
    if(track == 0 || track == RC_HASH_CDTRACK_LARGEST) {
        uint64_t largest = 0;
        for(unsigned i = 0; i < count; i++) {
            const uint64_t size = OECHDReaderTrackSize(reader, i);
            if(OECHDReaderTrackAtIndex(reader, i)->type != OECHDTrackTypeAudio && size > largest) {
                largest = size;
                *index = i;
            }
        }
        return largest > 0;
    }
    if(track >= 1 && track <= count) {
        *index = track - 1;
        return 1;
    }
    return 0;
}

static size_t OEChdHashReadBin(OEChdHashTrack *track, uint64_t offset, void *buffer, size_t length)
{
    return OECHDReaderReadTrack(track->reader, track->index, offset, buffer, length);
}

// rcheevos's cdreader_determine_sector_size, on the track's .bin: the sector layout comes from the
// sync pattern or the "CD001" volume descriptor at sector 16, tried as 2352-, 2336- and 2048-byte
// sectors, and from the GDI's sector size when none is found.
static void OEChdHashFindSectorLayout(OEChdHashTrack *track)
{
    static const uint8_t sync[] = { 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
    static const uint32_t sizes[] = { 2352, 2336, 2048 };
    uint8_t header[32];

    // Like rcheevos, give up on finding it when the track is too short to hold sector 16.
    for(size_t i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
        if(OEChdHashReadBin(track, (uint64_t)16 * sizes[i], header, sizeof(header)) < sizeof(header))
            break;
        if(sizes[i] != 2048 && memcmp(header, sync, sizeof(sync)) == 0) {
            track->sectorSize = sizes[i];
            track->headerSize = memcmp(&header[25], "CD001", 5) == 0 ? 24 : 16;
            return;
        }
        if(sizes[i] == 2048 && memcmp(&header[1], "CD001", 5) == 0) {
            track->sectorSize = 2048;
            track->headerSize = 0;
            return;
        }
    }

    // A GDI names every track MODE1/<sector size>.
    track->sectorSize = OECHDReaderTrackAtIndex(track->reader, track->index)->sectorSize;
    track->headerSize = track->sectorSize == 2352 ? 16 : track->sectorSize == 2336 ? 8 : 0;
}

static void *OEChdHashOpenCHDTrack(const char *path, uint32_t track)
{
    OECHDReader *reader = NULL;
    if(OECHDReaderOpenGDROM(path, &reader) != OECHDReaderStatusOK)
        return NULL;

    OEChdHashTrack *handle = calloc(1, sizeof(OEChdHashTrack));
    if(handle == NULL || !OEChdHashTrackIndex(reader, track, &handle->index)) {
        free(handle);
        OECHDReaderClose(reader);
        return NULL;
    }
    handle->reader = reader;
    handle->firstSector = OECHDReaderTrackAtIndex(reader, handle->index)->lba;
    OEChdHashFindSectorLayout(handle);
    return handle;
}

static void *OEChdHashOpenTrackIterator(const char *path, uint32_t track, const rc_hash_iterator_t *iterator)
{
    if(OEChdHashIsCHD(path))
        return OEChdHashOpenCHDTrack(path, track);

    void *defaultTrack = OEChdHashDefaultCDReader().open_track_iterator(path, track, iterator);
    if(defaultTrack == NULL)
        return NULL;
    OEChdHashTrack *handle = calloc(1, sizeof(OEChdHashTrack));
    if(handle == NULL) {
        OEChdHashDefaultCDReader().close_track(defaultTrack);
        return NULL;
    }
    handle->defaultTrack = defaultTrack;
    return handle;
}

// rcheevos ignores a cdreader without open_track, though it calls open_track_iterator when there is
// one. Without an iterator rcheevos's own cdreader cannot be asked, so this one only opens CHDs.
static void *OEChdHashOpenTrack(const char *path, uint32_t track)
{
    return OEChdHashIsCHD(path) ? OEChdHashOpenCHDTrack(path, track) : NULL;
}

// rcheevos's cdreader_read_sector: whole sectors' data while more than one sector's worth is asked
// for, then the rest straight from where the last sector's data starts.
static size_t OEChdHashReadSector(void *opaque, uint32_t sector, void *buffer, size_t requested)
{
    OEChdHashTrack *track = opaque;
    if(track->defaultTrack != NULL)
        return OEChdHashDefaultCDReader().read_sector(track->defaultTrack, sector, buffer, requested);
    if(sector < track->firstSector)
        return 0;

    uint8_t *output = buffer;
    uint64_t start = (uint64_t)(sector - track->firstSector) * track->sectorSize + track->headerSize;
    size_t total = 0;
    while(requested > OEChdHashDataSize) {
        const size_t got = OEChdHashReadBin(track, start, output, OEChdHashDataSize);
        total += got;
        if(got < OEChdHashDataSize)
            return total;
        output += OEChdHashDataSize;
        start += track->sectorSize;
        requested -= OEChdHashDataSize;
    }
    return total + OEChdHashReadBin(track, start, output, requested);
}

static void OEChdHashCloseTrack(void *opaque)
{
    OEChdHashTrack *track = opaque;
    if(track == NULL)
        return;
    if(track->defaultTrack != NULL)
        OEChdHashDefaultCDReader().close_track(track->defaultTrack);
    OECHDReaderClose(track->reader);
    free(track);
}

static uint32_t OEChdHashFirstTrackSector(void *opaque)
{
    OEChdHashTrack *track = opaque;
    if(track->defaultTrack != NULL)
        return OEChdHashDefaultCDReader().first_track_sector(track->defaultTrack);
    return track->firstSector;
}

const rc_hash_cdreader_t OEChdHashCDReader = {
    OEChdHashOpenTrack,
    OEChdHashReadSector,
    OEChdHashCloseTrack,
    OEChdHashFirstTrackSector,
    OEChdHashOpenTrackIterator,
};
