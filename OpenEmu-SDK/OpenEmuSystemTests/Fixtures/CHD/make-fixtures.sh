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
# make-fixtures.sh — Remake the small CHDs OECHDReaderTests.c reads. They hold a made-up 80 KB
# image (no game data). Needs chdman: brew install rom-tools.
#
#   dvd.chd       chdman createdvd, default compression
#   dvd-zstd.chd  chdman createdvd, zstd only
#   cd.chd        chdman createcd (a CD image: must be refused)
#   hd.chd        chdman createhd (a hard disk: must be refused)
#   child.chd     chdman createdvd with dvd.chd as its parent (must be refused)

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

OE_SANITIZE=undefined "$repo/Scripts/test-chd-reader.sh" --write-iso "$work/image.iso"

# A second image, one sector different, for the child CHD.
cp "$work/image.iso" "$work/changed.iso"
printf 'CHANGED' | dd of="$work/changed.iso" bs=1 seek=$((20 * 2048)) conv=notrunc 2>/dev/null

printf 'FILE "image.iso" BINARY\n  TRACK 01 MODE1/2048\n    INDEX 01 00:00:00\n' > "$work/image.cue"

cd "$here"
rm -f dvd.chd dvd-zstd.chd cd.chd hd.chd child.chd
chdman createdvd -i "$work/image.iso" -o dvd.chd -hs 4096
chdman createdvd -i "$work/image.iso" -o dvd-zstd.chd -hs 4096 -c zstd
chdman createcd -i "$work/image.cue" -o cd.chd
chdman createhd -i "$work/image.iso" -o hd.chd
chdman createdvd -i "$work/changed.iso" -o child.chd -hs 4096 -op dvd.chd
ls -l "$here"/*.chd
