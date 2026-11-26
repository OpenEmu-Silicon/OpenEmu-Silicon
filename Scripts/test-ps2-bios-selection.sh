#!/usr/bin/env bash
# test-ps2-bios-selection.sh — build and run the PS2 BIOS selection test. Needs no engine and
# touches no real BIOS folder (it builds fake files in a temp folder).
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
clang -fobjc-arc -Wall -framework Foundation PCSX2/OEPS2BIOSSelection.m PCSX2/Tests/OEPS2BIOSSelectionTests.m -o "$out/test"
"$out/test"
