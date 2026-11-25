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


// The rcheevos cdreader the cores whose discs come as CHD hash them with (the Flycast, Mednafen,
// Genesis Plus GX and PCSX2 wrappers, which compile this file next to OECHDReader.c). rcheevos's own cdreader only opens CUE
// and GDI sheets, so a CHD is read here, track by track through OECHDReader, as the files it was
// made from: a CD-type CHD as its CUE sheet and .bin files, a GD-ROM CHD as its GDI, a DVD-type CHD
// as its ISO. The tracks start at the same sectors rcheevos's own reader would give them, so the hash
// is the original's.
// Any other disc goes to rcheevos's own cdreader.

#ifndef OEChdHashCDReader_h
#define OEChdHashCDReader_h

#include <rc_hash.h>

#ifdef __cplusplus
extern "C" {
#endif

extern const rc_hash_cdreader_t OEChdHashCDReader;

#ifdef __cplusplus
}
#endif

#endif /* OEChdHashCDReader_h */
