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

// Reads a DVD-type CHD (made with `chdman createdvd`) as the plain ISO it was made from: 2048-byte
// sectors, same size, same bytes. Shared by the host app (OECHDFile, for import) and by cores that
// cannot read CHD themselves (the PPSSPP wrapper), which compile this file next to
// Vendor/libchdr/libchdr_build.c. CD-type CHDs (`chdman createcd`) are not handled here yet.
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
} OECHDReaderStatus;

/// Opens the CHD at `path` and checks that it holds a DVD image. On success `*reader` must be
/// closed with OECHDReaderClose; on failure it is set to NULL.
OECHDReaderStatus OECHDReaderOpenDVD(const char *path, OECHDReader **reader);

/// Size in bytes of the image inside: the size of the original ISO.
uint64_t OECHDReaderSize(const OECHDReader *reader);

/// Copies up to `length` bytes starting at `offset` of the image. Returns how many bytes were
/// copied: fewer than asked at the end of the image or when part of the CHD cannot be decompressed.
size_t OECHDReaderRead(OECHDReader *reader, uint64_t offset, void *buffer, size_t length);

void OECHDReaderClose(OECHDReader *reader);

#ifdef __cplusplus
}
#endif

#endif /* OECHDReader_h */
