#!/usr/bin/env bash
# Build the third-party libraries the ARMSX2 engine needs, as static libraries.
#
# Why not Homebrew: Homebrew builds its libraries for the macOS version it runs on, so a
# plugin linked against them only loads on that macOS or newer, and only on a Mac that
# has Homebrew. OpenEmu supports macOS 12 and later. Building from pinned source
# archives with a macOS 13 deployment target and linking them statically removes both
# problems. This follows the same idea as the plutovg and plutosvg build in
# build-armsx2-core.sh.
#
# Usage: build-armsx2-deps.sh <build dir> <install prefix> <engine source dir>
# Needs cmake and a compiler. Downloads the archives below once into <build dir>/deps-src.

set -euo pipefail

BUILD_DIR="$1"
PREFIX="$2"
ENGINE_SRC="$3"

DEPLOYMENT_TARGET="13.0"
SRC_CACHE="$BUILD_DIR/deps-src"
WORK="$BUILD_DIR/deps-build"
JOBS="$(sysctl -n hw.ncpu)"
# Bump this when a recipe or version below changes, so old output is rebuilt.
STAMP="$PREFIX/.deps-stamp-v2-macos$DEPLOYMENT_TARGET"

if [ -f "$STAMP" ]; then
  echo "Third-party libraries already built ($STAMP)"
  exit 0
fi

rm -rf "$PREFIX" "$WORK"
mkdir -p "$PREFIX" "$SRC_CACHE" "$WORK"

# name | version | url | sha256
DEPS=(
  "libpng|1.6.59|https://github.com/pnggroup/libpng/archive/refs/tags/v1.6.59.tar.gz|2540302a1844ad2b2b501977abecfa850f265f97b78f065a712ab4074a89f5b5"
  "libjpeg-turbo|3.2.0|https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.0/libjpeg-turbo-3.2.0.tar.gz|6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e"
  "libwebp|1.6.0|https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz|e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564"
  "zstd|1.5.7|https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz|eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3"
  "lz4|1.10.0|https://github.com/lz4/lz4/releases/download/v1.10.0/lz4-1.10.0.tar.gz|537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b"
  "freetype|2.15.0|https://download.savannah.gnu.org/releases/freetype/freetype-2.15.0.tar.xz|93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5"
  "SDL3|3.4.18|https://github.com/libsdl-org/SDL/releases/download/release-3.4.18/SDL3-3.4.18.tar.gz|9c75cf16330322c217dedd2e0609f1124f1b54b8633e763467b4684d0f4334a3"
)

COMMON=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
  -DCMAKE_PREFIX_PATH="$PREFIX"
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DBUILD_SHARED_LIBS=OFF
)

fetch() {
  local name="$1" version="$2" url="$3" sha="$4"
  local file
  case "$url" in
    *.tar.xz) file="$SRC_CACHE/$name-$version.tar.xz" ;;
    *) file="$SRC_CACHE/$name-$version.tar.gz" ;;
  esac
  if [ ! -f "$file" ]; then
    echo "Downloading $name $version..." >&2
    curl -fsSL --retry 3 -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  local got
  got="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  if [ "$got" != "$sha" ]; then
    echo "error: $name archive does not match its pinned checksum" >&2
    echo "       expected $sha" >&2
    echo "       got      $got" >&2
    rm -f "$file"
    exit 1
  fi
  rm -rf "$WORK/$name-src"
  mkdir -p "$WORK/$name-src"
  tar -xf "$file" -C "$WORK/$name-src" --strip-components=1
  echo "$WORK/$name-src"
}

build() {
  local name="$1" src="$2"
  shift 2
  echo "Building $name..."
  cmake -S "$src" -B "$WORK/$name-build" "${COMMON[@]}" "$@" >"$WORK/$name-configure.log" 2>&1 \
    || { tail -30 "$WORK/$name-configure.log" >&2; echo "error: $name configure failed" >&2; exit 1; }
  cmake --build "$WORK/$name-build" -j"$JOBS" >"$WORK/$name-build.log" 2>&1 \
    || { tail -30 "$WORK/$name-build.log" >&2; echo "error: $name build failed" >&2; exit 1; }
  cmake --install "$WORK/$name-build" >>"$WORK/$name-build.log" 2>&1
}

# plutovg and plutosvg are vendored in the engine.
for dep in plutovg plutosvg; do
  upper="$(echo "$dep" | tr a-z A-Z)"
  extra=()
  [ "$dep" = "plutosvg" ] && extra=(-DPLUTOSVG_ENABLE_FREETYPE=OFF)
  build "$dep" "$ENGINE_SRC/3rdparty/$dep" -D"${upper}_BUILD_EXAMPLES=OFF" ${extra[@]+"${extra[@]}"}
done

for entry in "${DEPS[@]}"; do
  IFS='|' read -r name version url sha <<<"$entry"
  src="$(fetch "$name" "$version" "$url" "$sha")"
  case "$name" in
    libpng)
      build "$name" "$src" -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_FRAMEWORK=OFF ;;
    libjpeg-turbo)
      build "$name" "$src" -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF -DWITH_JPEG8=1 ;;
    libwebp)
      build "$name" "$src" -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
        -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
        -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF ;;
    zstd)
      build "$name" "$src/build/cmake" -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_STATIC=ON \
        -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_TESTS=OFF -DZSTD_BUILD_CONTRIB=OFF ;;
    lz4)
      build "$name" "$src/build/cmake" -DLZ4_BUILD_CLI=OFF -DLZ4_BUILD_LEGACY_LZ4C=OFF -DBUILD_STATIC_LIBS=ON ;;
    freetype)
      build "$name" "$src" -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_HARFBUZZ=ON \
        -DFT_DISABLE_HVF=TRUE -DFT_REQUIRE_PNG=ON -DFT_REQUIRE_ZLIB=ON ;;
    SDL3)
      build "$name" "$src" -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
        -DSDL_INSTALL_TESTS=OFF ;;
  esac
done

touch "$STAMP"
echo "Third-party libraries built into $PREFIX"
