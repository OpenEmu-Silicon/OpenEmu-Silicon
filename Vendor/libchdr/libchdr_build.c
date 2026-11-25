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

/* Unity build file: compiles libchdr and the LZMA code it needs as a single translation unit,
 * so a project adds one file instead of a dozen.
 *
 * Vendor/libchdr is libchdr (https://github.com/rtissera/libchdr) as Flycast vendors it
 * (Flycast/flycast/core/deps/libchdr at repo commit df91dcc6d), cut down to what reading needs:
 * the LZMA files libchdr uses, the zstd decoder, and no zlib (macOS has it).
 *
 * Header search paths: Vendor/libchdr/include, Vendor/libchdr/deps/lzma-24.05/include, and a
 * folder holding zstd.h (Vendor/libchdr/deps/zstd-1.5.6/lib, or the project's own zstd).
 * Link: macOS zlib (-lz) and zstd. A project without its own zstd also compiles
 * libchdr_zstd_build.c; a project that already has zstd (PPSSPP) links that one instead.
 *
 * Compile with -fvisibility=hidden where the result must not export these symbols (a framework).
 * zstd marks its API visible unless told otherwise; libchdr's CHD_EXPORT always does, so a framework
 * also needs -Wl,-unexported_symbol,_chd_* when it links.
 */

#define ZSTDLIB_VISIBLE
#define ZSTDERRORLIB_VISIBLE
#define Z7_ST

/* LZMA: the decoder, plus the encoder-properties code libchdr uses to set the decoder up */
#include "deps/lzma-24.05/src/Alloc.c"
#include "deps/lzma-24.05/src/CpuArch.c"
#include "deps/lzma-24.05/src/LzFind.c"
#include "deps/lzma-24.05/src/LzmaDec.c"
#include "deps/lzma-24.05/src/LzmaEnc.c"

/* libchdr */
#include "src/libchdr_bitstream.c"
#include "src/libchdr_cdrom.c"
#include "src/libchdr_chd.c"
#include "src/libchdr_flac.c"
#include "src/libchdr_huffman.c"
