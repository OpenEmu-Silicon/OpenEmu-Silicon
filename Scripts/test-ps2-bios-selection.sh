#!/usr/bin/env bash
# test-ps2-bios-selection.sh — build and run the PS2 BIOS selection test. Needs no engine and
# touches no real BIOS folder (it builds fake files in a temp folder).
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
clang -fobjc-arc -Wall -framework Foundation PCSX2/OEPS2BIOSSelection.m PCSX2/Tests/OEPS2BIOSSelectionTests.m -o "$out/test"
"$out/test"
# The core is Objective-C++ (.mm) and calls the helper from this Objective-C file, so check they link.
cat > "$out/link.mm" <<MM
#import "$PWD/PCSX2/OEPS2BIOSSelection.h"
int main() { return OEPS2ChooseBIOS(@"/nonexistent", @[]) == nil ? 0 : 1; }
MM
clang -c -fobjc-arc PCSX2/OEPS2BIOSSelection.m -o "$out/sel.o"
clang++ -fobjc-arc -framework Foundation "$out/link.mm" "$out/sel.o" -o "$out/link"
"$out/link" && echo "ok:   links from Objective-C++"
