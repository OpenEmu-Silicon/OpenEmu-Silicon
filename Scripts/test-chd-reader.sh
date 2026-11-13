#!/usr/bin/env bash
# Copyright (c) 2026, OpenEmu Team
# Author: Leonardo Kasperavičius
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
# 1. Redistributions of source code must retain the above copyright notice,
#    this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
#
# test-chd-reader.sh — Build and run the OECHDReader tests (CHD disc images), with sanitizers on.
#
#   ./Scripts/test-chd-reader.sh                     # run the tests against the committed fixtures
#   ./Scripts/test-chd-reader.sh --write-iso <path>  # write the made-up image the fixtures come from
#
# libchdr is compiled with its warnings silenced (it is vendored code); the test and OECHDReader.c
# are compiled with -Werror, as the DualSense test is.
#
# OE_SANITIZE picks the sanitizers (default address,undefined, as in CI). On some Macs an
# AddressSanitizer program hangs at startup (seen on macOS 26.6 with Apple clang 17, the DualSense
# test too); OE_SANITIZE=undefined runs the same checks without it.

set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

chdr="$repo/Vendor/libchdr"
includes=(-I"$chdr/include" -I"$chdr/deps/lzma-24.05/include" -I"$chdr/deps/zstd-1.5.6/lib")
sanitize=(-fsanitize="${OE_SANITIZE:-address,undefined}")

xcrun clang -c -std=gnu11 -O1 -w "${sanitize[@]}" "${includes[@]}" "$chdr/libchdr_build.c" -o "$work/libchdr.o"
xcrun clang -c -std=gnu11 -O1 -w "${sanitize[@]}" "${includes[@]}" "$chdr/libchdr_zstd_build.c" -o "$work/zstd.o"
xcrun clang -std=c11 -UNDEBUG -Wall -Wextra -Werror "${sanitize[@]}" "${includes[@]}" \
    "$repo/OpenEmu-SDK/OpenEmuSystem/OECHDReader.c" \
    "$repo/OpenEmu-SDK/OpenEmuSystemTests/OECHDReaderTests.c" \
    "$work/libchdr.o" "$work/zstd.o" -lz -o "$work/chd-reader-tests"

if [ "$#" -gt 0 ]; then
    "$work/chd-reader-tests" "$@"
else
    mkdir -p "$work/scratch"
    "$work/chd-reader-tests" "$repo/OpenEmu-SDK/OpenEmuSystemTests/Fixtures/CHD" "$work/scratch"
fi
