#!/usr/bin/env bash
# Fetch the third-party binaries the Azahar engine needs, from pinned sources.
#
# Azahar's own CMake downloads MoltenVK from a fixed release tag at configure time with
# no checksum, so a changed or swapped file would go unnoticed. This downloads the
# same release once, checks its SHA-256 against the value pinned below, and installs
# libMoltenVK.dylib into a private prefix that build-azahar-core.sh passes to CMake
# (with USE_SYSTEM_MOLTENVK=ON). Nothing comes from Homebrew.
#
# Usage: build-azahar-deps.sh <build dir> <install prefix>

set -euo pipefail

BUILD_DIR="$1"
PREFIX="$2"

SRC_CACHE="$BUILD_DIR/deps-src"
# Bump this when a pin below changes, so an old install is replaced.
STAMP="$PREFIX/.deps-stamp-v1"

# MoltenVK is the Vulkan-on-Metal layer Azahar draws through. v1.4.1 is the version
# Azahar's CMake pins at the commit we build. The SHA-256 is the digest GitHub
# publishes for this release asset.
MVK_VERSION="1.4.1"
MVK_URL="https://github.com/KhronosGroup/MoltenVK/releases/download/v$MVK_VERSION/MoltenVK-macos.tar"
MVK_SHA256="5ea0c259df7ded9a275444820f09cced54d6e5a7c7a31d262de62a5cdb7e15cf"
MVK_DYLIB_IN_TAR="MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"

if [ -f "$STAMP" ]; then
  echo "Third-party binaries already installed ($STAMP)"
  exit 0
fi

rm -rf "$PREFIX"
mkdir -p "$PREFIX/lib" "$SRC_CACHE"

file="$SRC_CACHE/MoltenVK-macos-$MVK_VERSION.tar"
if [ ! -f "$file" ]; then
  echo "Downloading MoltenVK $MVK_VERSION..."
  curl -fsSL --retry 3 -o "$file.part" "$MVK_URL"
  mv "$file.part" "$file"
fi
got="$(shasum -a 256 "$file" | cut -d' ' -f1)"
if [ "$got" != "$MVK_SHA256" ]; then
  echo "error: the MoltenVK archive does not match its pinned checksum" >&2
  echo "       expected $MVK_SHA256" >&2
  echo "       got      $got" >&2
  rm -f "$file"
  exit 1
fi

work="$(mktemp -d "$BUILD_DIR/mvk-extract.XXXXXX")"
trap 'rm -rf "$work"' EXIT
tar -xf "$file" -C "$work" "$MVK_DYLIB_IN_TAR"
cp "$work/$MVK_DYLIB_IN_TAR" "$PREFIX/lib/libMoltenVK.dylib"

if ! lipo -archs "$PREFIX/lib/libMoltenVK.dylib" | grep -q arm64; then
  echo "error: libMoltenVK.dylib has no arm64 slice" >&2
  exit 1
fi

touch "$STAMP"
echo "MoltenVK $MVK_VERSION installed at $PREFIX/lib/libMoltenVK.dylib"
