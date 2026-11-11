#!/usr/bin/env bash
# Build the Azahar (Nintendo 3DS) engine for the Azahar core (arm64, Vulkan through MoltenVK).
#
# Stage 1: build the engine as static libraries with CMake. No Qt, no desktop
# frontends, no libretro. The libraries land under Azahar/build/engine.
# Stage 2 (not written yet): write the compile flags and link line the Xcode project
# needs, then build Azahar.oecoreplugin. That arrives with the core plugin (item 3 of #814).
#
# Needs Apple Silicon, Xcode and cmake (brew install cmake). Set AZAHAR_EXTRA_CMAKE_ARGS
# to pass more flags to CMake.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
AZAHAR_DIR="$REPO_ROOT/Azahar"
SRC_DIR="$AZAHAR_DIR/deps/azahar"
BUILD_DIR="$AZAHAR_DIR/build"
DEPS_PREFIX="$BUILD_DIR/deps-prefix"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "error: this build needs an Apple Silicon Mac (found $(uname -s) $(uname -m))" >&2
  exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
  echo "error: cmake is not installed" >&2
  echo "Run: brew install cmake" >&2
  exit 1
fi

"$SCRIPT_DIR/prepare-azahar-core.sh"

mkdir -p "$BUILD_DIR"
"$SCRIPT_DIR/build-azahar-deps.sh" "$BUILD_DIR" "$DEPS_PREFIX"

# Why these switches (see docs/3ds-azahar-port.md):
# - ENABLE_LIBRETRO stays OFF. Turned on, Azahar leaves out the Vulkan present window
#   (the place the OpenEmu output patch goes) and takes its Vulkan device from a
#   libretro frontend. PS2 turns its same-named switch on; for Azahar it is the wrong path.
# - USE_SYSTEM_MOLTENVK=ON with CMAKE_PREFIX_PATH makes Azahar use the checked
#   MoltenVK from build-azahar-deps.sh instead of downloading one.
# - Qt, SDL2, cubeb, OpenAL, libusb, tests, room, web services, scripting, the GDB stub
#   and Discord are off. The engine libraries are all we want.
# - Vulkan and the software renderer are on; OpenGL is not available on macOS.
# shellcheck disable=SC2086
cmake -S "$SRC_DIR" -B "$BUILD_DIR/engine" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.4 \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DCMAKE_PREFIX_PATH="$DEPS_PREFIX" \
  -DUSE_SYSTEM_MOLTENVK=ON \
  -DENABLE_LIBRETRO=OFF \
  -DENABLE_QT=OFF -DENABLE_SDL2=OFF -DENABLE_CUBEB=OFF -DENABLE_OPENAL=OFF \
  -DENABLE_LIBUSB=OFF -DENABLE_TESTS=OFF -DENABLE_ROOM=OFF -DENABLE_ROOM_STANDALONE=OFF \
  -DENABLE_WEB_SERVICE=OFF -DENABLE_SCRIPTING=OFF -DENABLE_GDBSTUB=OFF \
  -DENABLE_DISCORD_RPC=OFF \
  -DENABLE_VULKAN=ON -DENABLE_SOFTWARE_RENDERER=ON \
  -DENABLE_LTO=OFF -DCITRA_WARNINGS_AS_ERRORS=OFF -DCITRA_USE_PRECOMPILED_HEADERS=OFF \
  ${AZAHAR_EXTRA_CMAKE_ARGS:-}

# The engine libraries are not part of CMake's default target, so name them.
cmake --build "$BUILD_DIR/engine" \
  --target citra_core video_core audio_core input_common citra_common network \
  -j"$(sysctl -n hw.ncpu)"

git -C "$SRC_DIR" rev-parse HEAD > "$BUILD_DIR/ENGINE_COMMIT"
echo ""
echo "Built the Azahar engine libraries in $BUILD_DIR/engine (commit $(cat "$BUILD_DIR/ENGINE_COMMIT"))."
