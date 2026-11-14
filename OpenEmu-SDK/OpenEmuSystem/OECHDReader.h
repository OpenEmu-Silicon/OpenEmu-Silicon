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

// Reads a CHD as the files it was made from, so code written for those files keeps working:
// - a DVD-type CHD (`chdman createdvd`) as the plain ISO: 2048-byte sectors, same size, same bytes;
// - a CD-type CHD (`chdman createcd`) as a CUE sheet plus one .bin per track: the same sectors as the
//   original .bin files, with the subchannel data and padding CHD adds taken out and CD audio back in
//   its original byte order;
// - a GD-ROM CHD (Dreamcast) as a GDI plus one .bin per track, the layout chdman's GDI export writes.
// Shared by the host app (OECHDFile, for import) and by cores: the PPSSPP and Mednafen wrappers, which
// cannot read CHD themselves and compile this file next to Vendor/libchdr/libchdr_build.c, and the
// Flycast wrapper, which builds it against Flycast's own libchdr for RetroAchievements.
// Hard-disk CHDs are not handled.
//
// A reader is not thread safe; a caller that reads from several threads must lock around it.

#ifndef OECHDReader_h
#define OECHDReader_h

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OECHDReader OECHDReader;

typedef enum {
    OECHDReaderStatusOK = 0,
    OECHDReaderStatusCouldNotOpen, // missing, not a CHD, or damaged
    OECHDReaderStatusUnsupported,  // a CHD version or compression method libchdr does not know
    OECHDReaderStatusNeedsParent,  // a child CHD, which only stores differences from another CHD
    OECHDReaderStatusNotDVD,       // a CD, GD-ROM or hard-disk CHD
    OECHDReaderStatusNotCD,        // a DVD, GD-ROM or hard-disk CHD
    OECHDReaderStatusNotGDROM,     // a DVD, CD or hard-disk CHD
} OECHDReaderStatus;

typedef enum {
    OECHDTrackTypeMode1,    // CUE MODE1/2048
    OECHDTrackTypeMode1Raw, // CUE MODE1/2352
    OECHDTrackTypeMode2,    // CUE MODE2/2336
    OECHDTrackTypeMode2Raw, // CUE MODE2/2352
    OECHDTrackTypeAudio,    // CUE AUDIO (2352)
} OECHDTrackType;

/// One track of a CD or GD-ROM CHD, as it appears in the CUE sheet or GDI and its .bin file.
typedef struct {
    unsigned number;      // track number on the disc, from 1
    OECHDTrackType type;
    uint32_t sectorSize;  // bytes per sector in the track's .bin
    uint32_t sectors;     // sectors in the track's .bin, a stored pregap included
    uint32_t pregap;      // pregap sectors (75 per second)
    int pregapStored;     // 1: the pregap is the start of the .bin (CUE INDEX 00); 0: not stored (CUE PREGAP)
    uint32_t postgap;     // postgap sectors, never stored
    uint32_t lba;         // GD-ROM: the sector the track starts at on the disc, as the GDI gives it; 0 on a CD
} OECHDTrack;

/// Opens the CHD at `path` and checks that it holds a DVD image. On success `*reader` must be
/// closed with OECHDReaderClose; on failure it is set to NULL.
OECHDReaderStatus OECHDReaderOpenDVD(const char *path, OECHDReader **reader);

/// DVD: size in bytes of the image inside: the size of the original ISO.
uint64_t OECHDReaderSize(const OECHDReader *reader);

/// DVD: copies up to `length` bytes starting at `offset` of the image. Returns how many bytes were
/// copied: fewer than asked at the end of the image or when part of the CHD cannot be decompressed.
size_t OECHDReaderRead(OECHDReader *reader, uint64_t offset, void *buffer, size_t length);

/// Opens the CHD at `path` and checks that it holds a CD image whose tracks a CUE sheet can describe.
/// On success `*reader` must be closed with OECHDReaderClose; on failure it is set to NULL.
OECHDReaderStatus OECHDReaderOpenCD(const char *path, OECHDReader **reader);

/// Opens the CHD at `path` and checks that it holds a GD-ROM image. Its tracks have no gaps (chdman
/// stores every GD-ROM that way, whether it was made from a GDI or a CUE sheet), and the tracks read
/// as the .bin files of a GDI. On success `*reader` must be closed with OECHDReaderClose; on failure
/// it is set to NULL.
OECHDReaderStatus OECHDReaderOpenGDROM(const char *path, OECHDReader **reader);

/// CD and GD-ROM: the number of tracks, and each track by index (0 is track 1).
unsigned OECHDReaderTrackCount(const OECHDReader *reader);
const OECHDTrack *OECHDReaderTrackAtIndex(const OECHDReader *reader, unsigned index);

/// CD and GD-ROM: size in bytes of the track's .bin.
uint64_t OECHDReaderTrackSize(const OECHDReader *reader, unsigned index);

/// CD and GD-ROM: copies up to `length` bytes starting at `offset` of the track's .bin. Returns how many bytes
/// were copied, like OECHDReaderRead.
size_t OECHDReaderReadTrack(OECHDReader *reader, unsigned index, uint64_t offset, void *buffer, size_t length);

/// CD: the file name the CUE sheet gives a track's .bin: "<baseName> (Track NN).bin". Like snprintf:
/// returns the length of the full name, and writes as much as fits.
size_t OECHDReaderTrackFileName(const char *baseName, unsigned number, char *buffer, size_t capacity);

/// CD: writes a CUE sheet for the tracks, naming their files with OECHDReaderTrackFileName. Like
/// snprintf: returns the length of the full sheet, and writes as much as fits.
size_t OECHDReaderWriteCueSheet(const OECHDReader *reader, const char *baseName, char *buffer, size_t capacity);

void OECHDReaderClose(OECHDReader *reader);

#ifdef __cplusplus
}
#endif

#endif /* OECHDReader_h */
