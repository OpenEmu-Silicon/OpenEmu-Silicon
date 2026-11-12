#!/usr/bin/env bash
# Build the OpenEmu-Silicon MAME core from source.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MAME_DIR="$REPO_ROOT/MAME"
DD="$MAME_DIR/build/XcodeDerived"

# MAME's project generator mishandles absolute paths containing spaces. The
# repository often lives in "Open Emu", so transparently mirror the checkout to
# a temporary no-space path, build there, then copy the derived products back so
# install-core.sh and verify-core-installed.sh keep working from this checkout.
if [[ -z "${MAME_BUILD_NO_REEXEC:-}" && "$REPO_ROOT" =~ [[:space:]] ]]; then
  TMP_ROOT="$(mktemp -d /tmp/openemu-mame-build.XXXXXX)"
  TMP_REPO="$TMP_ROOT/repo"
  cleanup() {
    rm -rf "$TMP_ROOT"
  }
  trap cleanup EXIT

  echo "Repository path contains whitespace; building MAME from temporary path:"
  echo "  $TMP_REPO"
  mkdir -p "$TMP_REPO"
  rsync -a --delete \
    --exclude '.git' \
    --exclude 'MAME/deps' \
    --exclude 'MAME/build' \
    "$REPO_ROOT/" "$TMP_REPO/"

  MAME_BUILD_NO_REEXEC=1 "$TMP_REPO/Scripts/build-mame-core.sh"

  rm -rf "$DD"
  mkdir -p "$(dirname "$DD")" "$MAME_DIR/deps/mame"
  rsync -a --delete "$TMP_REPO/MAME/build/XcodeDerived/" "$DD/"
  cp -f "$TMP_REPO/MAME/deps/mame/mamearcade_headless.dylib" "$MAME_DIR/deps/mame/mamearcade_headless.dylib"

  PLUGIN="$DD/Build/Products/Release/MAME.oecoreplugin"
  echo ""
  echo "Copied build products back to: $PLUGIN"
  file "$PLUGIN/Contents/MacOS/MAME"
  file "$PLUGIN/Contents/Frameworks/mamearcade_headless.dylib"
  exit 0
fi

"$SCRIPT_DIR/prepare-mame-core.sh"

cd "$MAME_DIR/deps/mame"
make NOWERROR=1 REGENIE=1 macosx_arm64_clang \
  OSD="headless" verbose=1 TARGETOS="macosx" CONFIG="release" \
  TARGET=mame SUBTARGET=arcade MACOSX_DEPLOYMENT_TARGET=12.0 \
  -j"$(sysctl -n hw.ncpu)"

install_name_tool -id mamearcade_headless.dylib mamearcade_headless.dylib

xcodebuild \
  -project "$REPO_ROOT/OpenEmu-SDK/OpenEmu-SDK.xcodeproj" \
  -scheme OpenEmuBase \
  -configuration Release \
  -derivedDataPath "$DD" \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  build

xcodebuild \
  -project "$MAME_DIR/MAME.xcodeproj" \
  -scheme MAME \
  -configuration Release \
  -derivedDataPath "$DD" \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  build

PLUGIN="$DD/Build/Products/Release/MAME.oecoreplugin"

echo ""
echo "Built: $PLUGIN"
file "$PLUGIN/Contents/MacOS/MAME"
file "$PLUGIN/Contents/Frameworks/mamearcade_headless.dylib"
