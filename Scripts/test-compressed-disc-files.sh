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
# test-compressed-disc-files.sh — Build and run the OEGCZFile and OECSOFile tests (GCZ, CSO and ZSO
# disc images, valid and malformed), with sanitizers on.
#
#   ./Scripts/test-compressed-disc-files.sh
#
# The readers are compiled straight from OpenEmu-SDK/OpenEmuSystem, without the framework. OEFile.m is
# built with NS_BLOCK_ASSERTIONS: its +initialize registers the other OEFile subclasses by name, which
# this build leaves out. The tests themselves use C assert.
#
# OE_SANITIZE picks the sanitizers (default address,undefined, as in CI); see test-chd-reader.sh.

set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The readers import <OpenEmuSystem/OEFile.h>, as inside the framework.
mkdir -p "$work/include"
ln -s "$repo/OpenEmu-SDK/OpenEmuSystem" "$work/include/OpenEmuSystem"

sdk="$repo/OpenEmu-SDK/OpenEmuSystem"
sanitize=(-fsanitize="${OE_SANITIZE:-address,undefined}")
flags=(-fobjc-arc -UNDEBUG -Wall -Wextra -Werror "${sanitize[@]}" -I"$work/include")

xcrun clang -c "${flags[@]}" -DNS_BLOCK_ASSERTIONS=1 "$sdk/OEFile.m" -o "$work/OEFile.o"
xcrun clang -c "${flags[@]}" "$sdk/OEGCZFile.m" -o "$work/OEGCZFile.o"
xcrun clang -c "${flags[@]}" "$sdk/OECSOFile.m" -o "$work/OECSOFile.o"
xcrun clang "${flags[@]}" "$repo/OpenEmu-SDK/OpenEmuSystemTests/OECompressedDiscFileTests.m" \
    "$work/OEFile.o" "$work/OEGCZFile.o" "$work/OECSOFile.o" \
    -framework Foundation -lz -lcompression -o "$work/compressed-disc-file-tests"

mkdir -p "$work/scratch"
"$work/compressed-disc-file-tests" "$work/scratch"
