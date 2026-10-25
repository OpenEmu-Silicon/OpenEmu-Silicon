#!/usr/bin/env bash
# run.sh — Run a core with no window: load a ROM, step frames, press buttons, hash picture and sound.
#
# Usage:
#   ./Scripts/headless/run.sh <CoreName> --rom <file> [--frames N] [--hash-at N]... [--audio]
#                             [--input FRAME:SELECTOR:INT]... [--save-state-at N] [--load-state-at N]
#   ./Scripts/headless/run.sh <CoreName> --build-only
#
# Example (press Game Boy A at frame 61, compare picture at frame 62):
#   ./Scripts/headless/run.sh Gambatte --rom test.gb --frames 62 --hash-at 62 --input 61:didPushGBButton:4
#
# Builds OpenEmuBase and the core fresh into $OE_HEADLESS_BUILD (default ~/Builds/openemu/headless) every run,
# so it never tests the copy installed in ~/Library/Application Support/OpenEmu/Cores. That copy is the one
# the real app uses, but its code signature can stop it loading in a plain process, and testing a stale
# install is the mistake this repo's docs warn about. Output lines are described in oe-headless.m.
# Set OE_HEADLESS_NO_BUILD=1 to reuse what is already built.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$REPO_ROOT/Scripts/headless"
BUILD="${OE_HEADLESS_BUILD:-$HOME/Builds/openemu/headless}"
PRODUCTS="$BUILD/Build/Products/Debug"
TOOL="$BUILD/oe-headless"

[ $# -ge 1 ] || { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
CORE="$1"; shift
BUILD_ONLY=0
ARGS=()
for a in "$@"; do
  if [ "$a" = "--build-only" ]; then BUILD_ONLY=1; else ARGS+=("$a"); fi
done

build() {
  local log="$BUILD/build.log"
  mkdir -p "$BUILD"
  echo "----  building OpenEmuBase" >&2
  xcodebuild build -project "$REPO_ROOT/OpenEmu-SDK/OpenEmu-SDK.xcodeproj" -scheme OpenEmuBase -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$BUILD" CODE_SIGNING_ALLOWED=NO > "$log" 2>&1 \
    || { echo "FAIL  OpenEmuBase build failed, see $log" >&2; tail -20 "$log" >&2; exit 1; }

  echo "----  building core $CORE" >&2
  local project="$REPO_ROOT/$CORE/$CORE.xcodeproj"
  if [ -d "$project" ]; then
    xcodebuild build -project "$project" -scheme "$CORE" -configuration Debug \
      -destination 'platform=macOS,arch=arm64' -derivedDataPath "$BUILD" CODE_SIGNING_ALLOWED=NO >> "$log" 2>&1
  else
    xcodebuild build -workspace "$REPO_ROOT/OpenEmu-metal.xcworkspace" -scheme "$CORE" -configuration Debug \
      -destination 'platform=macOS,arch=arm64' -derivedDataPath "$BUILD" CODE_SIGNING_ALLOWED=NO >> "$log" 2>&1
  fi || { echo "FAIL  $CORE build failed, see $log" >&2; tail -20 "$log" >&2; exit 1; }

  echo "----  building oe-headless" >&2
  xcrun clang -fobjc-arc -arch arm64 -F "$PRODUCTS" -framework OpenEmuBase -framework Foundation -framework Cocoa \
    -Wl,-rpath,"$PRODUCTS" "$HERE/oe-headless.m" -o "$TOOL" >> "$log" 2>&1 \
    || { echo "FAIL  oe-headless would not compile, see $log" >&2; tail -20 "$log" >&2; exit 1; }
  codesign -f -s - "$TOOL" >> "$log" 2>&1
}

if [ "${OE_HEADLESS_NO_BUILD:-0}" != "1" ] || [ ! -x "$TOOL" ]; then build; fi
[ "$BUILD_ONLY" -eq 1 ] && exit 0

PLUGIN="$(find "$PRODUCTS" -maxdepth 1 -iname "$CORE.oecoreplugin" | head -1)"
[ -n "$PLUGIN" ] || { echo "FAIL  no $CORE.oecoreplugin in $PRODUCTS" >&2; exit 1; }

exec "$TOOL" --core "$PLUGIN" ${ARGS[@]+"${ARGS[@]}"}
