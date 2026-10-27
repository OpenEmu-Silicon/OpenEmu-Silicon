#!/usr/bin/env bash
# Build the OpenEmu-Silicon FBNeo core from source.
#
# Stage 1: build the headless FinalBurn Neo engine into fbneo_headless.dylib.
# Stage 2: build OpenEmuBase and the FBNeo.oecoreplugin that links the dylib,
# mirroring build-mame-core.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
FBNEO_DIR="$REPO_ROOT/FBNeo"
SRC_DIR="$FBNEO_DIR/deps/fbneo"
DYLIB="$SRC_DIR/fbneo_headless.dylib"
DD="$FBNEO_DIR/build/XcodeDerived"

"$SCRIPT_DIR/prepare-fbneo-core.sh"

cd "$SRC_DIR"

# Clean build: the obj tree is kept out of git and can hold stale dependency
# files after a revision bump (source files move upstream), so start fresh for a
# reproducible result.
rm -rf obj fbneo_headless.dylib

# Pre-create the obj tree mirroring the source dirs (src/ -> obj/) so the
# parallel dependency generation never races on a missing directory.
find src -type d | sed 's|^src|obj|' | xargs mkdir -p
mkdir -p obj/dep/generated

# makefile.headless is designed as a sub-make (its link rule is guarded on
# MAKELEVEL), so build via the root `headless:` target, not `-f makefile.headless`.
make headless -j"$(sysctl -n hw.ncpu)"

if [ ! -f "$DYLIB" ]; then
  echo "error: build did not produce $DYLIB" >&2
  exit 1
fi

echo ""
echo "Built: $DYLIB"
file "$DYLIB"
echo "Exported FBHeadless C API symbols: $(nm -gU "$DYLIB" 2>/dev/null | grep -c FBHeadless)"

# --- Stage 2: OpenEmuBase + the FBNeo.oecoreplugin that links the dylib ---

xcodebuild \
  -project "$REPO_ROOT/OpenEmu-SDK/OpenEmu-SDK.xcodeproj" \
  -scheme OpenEmuBase \
  -configuration Release \
  -derivedDataPath "$DD" \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  build

xcodebuild \
  -project "$FBNEO_DIR/FBNeo.xcodeproj" \
  -scheme FBNeo \
  -configuration Release \
  -derivedDataPath "$DD" \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  build

PLUGIN="$DD/Build/Products/Release/FBNeo.oecoreplugin"
if [ ! -d "$PLUGIN" ]; then
  echo "error: build did not produce $PLUGIN" >&2
  exit 1
fi

echo ""
echo "Built plugin: $PLUGIN"
file "$PLUGIN/Contents/MacOS/FBNeo"
file "$PLUGIN/Contents/Frameworks/fbneo_headless.dylib"
