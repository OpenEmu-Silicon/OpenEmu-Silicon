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

typedef struct {
    void *defaultTrack;     // a track rcheevos's own cdreader opened,
    OECHDReader *reader;    // or a track of a CHD:
    unsigned index;
    int64_t firstSector;    // the sector the track's .bin starts at on the disc
    uint32_t pregapSectors; // stored pregap sectors at the start of the .bin
    uint32_t sectorSize;
    uint32_t headerSize;    // bytes in each sector before its data
    uint32_t dataSize;      // data bytes in each sector
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

static int OEChdHashIsData(const OECHDReader *reader, unsigned index)
{
    return OECHDReaderTrackAtIndex(reader, index)->type != OECHDTrackTypeAudio;
}

// The track rcheevos asks for, as its GDI reader (`gdrom`) or CUE reader picks it.
static int OEChdHashTrackIndex(const OECHDReader *reader, int gdrom, uint32_t track, unsigned *index)
{
    const unsigned count = OECHDReaderTrackCount(reader);
    if(track == RC_HASH_CDTRACK_FIRST_DATA) {
        for(unsigned i = 0; i < count; i++) {
            if(OEChdHashIsData(reader, i)) {
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
        // The largest data track; the first of equal ones, except that the CUE reader prefers the
        // last track when it ties.
        uint64_t largest = 0;
        for(unsigned i = 0; i < count; i++) {
            const uint64_t sectors = OECHDReaderTrackAtIndex(reader, i)->sectors;
            const int lastTrackTies = !gdrom && i == count - 1 && sectors == largest;
            if(OEChdHashIsData(reader, i) && (sectors > largest || lastTrackTies)) {
                largest = sectors;
                *index = i;
            }
        }
        return largest > 0;
    }
    if(track >= 1 && track <= count) {
        *index = track - 1;
        return 1;
    }
    return 0; // RC_HASH_CDTRACK_FIRST_OF_SECOND_SESSION: the sheets these readers see have one session
}

static size_t OEChdHashReadBin(OEChdHashTrack *track, uint64_t offset, void *buffer, size_t length)
{
    return OECHDReaderReadTrack(track->reader, track->index, offset, buffer, length);
}

// The sector a raw sector's header gives (its MSF time), as a sector number from 00:02:00.
static int64_t OEChdHashHeaderSector(const uint8_t header[16])
{
    const int minutes = (header[12] >> 4) * 10 + (header[12] & 0x0F);
    const int seconds = (header[13] >> 4) * 10 + (header[13] & 0x0F);
    const int frames = (header[14] >> 4) * 10 + (header[14] & 0x0F);
    return ((minutes * 60) + seconds) * 75 + frames - 150;
}

// rcheevos's cdreader_determine_sector_size on the track's .bin: the sync pattern or the "CD001"
// volume descriptor at sector 16 of the track, tried as 2352-, 2336- and 2048-byte sectors. A raw
// sector's header also gives where the track starts on the disc. Returns 0 when none is found.
static int OEChdHashFindSectorLayout(OEChdHashTrack *track)
{
    static const uint8_t sync[] = { 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
    static const uint32_t sizes[] = { 2352, 2336, 2048 };
    const uint32_t tocSector = 16 + track->pregapSectors;
    uint8_t header[32];

    // Like rcheevos, give up on finding it when the track is too short to hold that sector.
    for(size_t i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
        if(OEChdHashReadBin(track, (uint64_t)tocSector * sizes[i], header, sizeof(header)) < sizeof(header))
            return 0;
        if(sizes[i] != 2048 && memcmp(header, sync, sizeof(sync)) == 0) {
            track->sectorSize = sizes[i];
            track->headerSize = memcmp(&header[25], "CD001", 5) == 0 ? 24 : 16;
            track->firstSector = OEChdHashHeaderSector(header) - tocSector;
            return 1;
        }
        if(sizes[i] == 2048 && memcmp(&header[1], "CD001", 5) == 0) {
            track->sectorSize = 2048;
            track->headerSize = 0;
            return 1;
        }
    }
    return 0;
}

// What rcheevos assumes when the sectors do not say: the track's mode from the sheet. A GDI calls
// every track MODE1/<sector size>.
static void OEChdHashAssumeSectorLayout(OEChdHashTrack *track, const OECHDTrack *info, int gdrom)
{
    track->sectorSize = info->sectorSize;
    if(gdrom) {
        track->headerSize = info->sectorSize == 2352 ? 16 : info->sectorSize == 2336 ? 8 : 0;
        return;
    }
    switch(info->type) {
        case OECHDTrackTypeMode1:    track->headerSize = 0; break;
        case OECHDTrackTypeMode1Raw: track->headerSize = 16; break;
        case OECHDTrackTypeMode2:    track->headerSize = 8; break;
        case OECHDTrackTypeMode2Raw: track->headerSize = 24; break;
        case OECHDTrackTypeAudio:    track->headerSize = 0; track->dataSize = 2352; break;
    }
}

static void *OEChdHashOpenCHDTrack(const char *path, uint32_t track)
{
    OECHDReader *reader = NULL;
    int gdrom = 1;
    if(OECHDReaderOpenGDROM(path, &reader) != OECHDReaderStatusOK) {
        gdrom = 0;
        if(OECHDReaderOpenCD(path, &reader) != OECHDReaderStatusOK)
            return NULL;
    }

    OEChdHashTrack *handle = calloc(1, sizeof(OEChdHashTrack));
    if(handle == NULL || !OEChdHashTrackIndex(reader, gdrom, track, &handle->index)) {
        free(handle);
        OECHDReaderClose(reader);
        return NULL;
    }
    handle->reader = reader;
    handle->dataSize = 2048;

    const OECHDTrack *info = OECHDReaderTrackAtIndex(reader, handle->index);
    if(gdrom) {
        // The GDI gives the track's first sector, whatever its sectors' headers say.
        if(!OEChdHashFindSectorLayout(handle))
            OEChdHashAssumeSectorLayout(handle, info, gdrom);
        handle->firstSector = info->lba;
    } else {
        // The CUE sheet OECHDReader writes has one .bin per track, so a track starts where the .bin
        // files before it end; its stored pregap (INDEX 00) comes first.
        for(unsigned i = 0; i < handle->index; i++)
            handle->firstSector += OECHDReaderTrackAtIndex(reader, i)->sectors;
        handle->pregapSectors = info->pregapStored ? info->pregap : 0;
        if(!OEChdHashFindSectorLayout(handle))
            OEChdHashAssumeSectorLayout(handle, info, gdrom);
    }
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
    if((int64_t)sector < track->firstSector)
        return 0;

    uint8_t *output = buffer;
    uint64_t start = (uint64_t)((int64_t)sector - track->firstSector) * track->sectorSize + track->headerSize;
    size_t total = 0;
    while(requested > track->dataSize) {
        const size_t got = OEChdHashReadBin(track, start, output, track->dataSize);
        total += got;
        if(got < track->dataSize)
            return total;
        output += track->dataSize;
        start += track->sectorSize;
        requested -= track->dataSize;
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
    return (uint32_t)(track->firstSector + track->pregapSectors);
}

const rc_hash_cdreader_t OEChdHashCDReader = {
    OEChdHashOpenTrack,
    OEChdHashReadSector,
    OEChdHashCloseTrack,
    OEChdHashFirstTrackSector,
    OEChdHashOpenTrackIterator,
};
