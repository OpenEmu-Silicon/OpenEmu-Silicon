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

/* Unity build file: compiles the zstd decoder libchdr needs as a single translation unit.
 * Only for projects that have no zstd of their own (see libchdr_build.c).
 * Same file list and settings as zstd's own single-file decoder (build/single_file_libs/zstddeclib-in.c).
 */

#define ZSTDLIB_VISIBLE
#define ZSTDERRORLIB_VISIBLE
#define DEBUGLEVEL 0
#define MEM_MODULE
#undef  XXH_NAMESPACE
#define XXH_NAMESPACE ZSTD_
#undef  XXH_PRIVATE_API
#define XXH_PRIVATE_API
#undef  XXH_INLINE_ALL
#define XXH_INLINE_ALL
#define ZSTD_LEGACY_SUPPORT 0
#define ZSTD_LIB_COMPRESSION 0
#define ZSTD_LIB_DEPRECATED 0
#define ZSTD_NOBENCH
#define ZSTD_TRACE 0
#define ZSTD_DISABLE_ASM 1

#include "deps/zstd-1.5.6/lib/common/debug.c"
#include "deps/zstd-1.5.6/lib/common/entropy_common.c"
#include "deps/zstd-1.5.6/lib/common/error_private.c"
#include "deps/zstd-1.5.6/lib/common/fse_decompress.c"
#include "deps/zstd-1.5.6/lib/common/zstd_common.c"

#include "deps/zstd-1.5.6/lib/decompress/huf_decompress.c"
#include "deps/zstd-1.5.6/lib/decompress/zstd_ddict.c"
#include "deps/zstd-1.5.6/lib/decompress/zstd_decompress.c"
#include "deps/zstd-1.5.6/lib/decompress/zstd_decompress_block.c"
