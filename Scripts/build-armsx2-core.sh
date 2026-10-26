#!/usr/bin/env bash
# Build the ARMSX2 engine for the PCSX2 core (arm64, Metal only).
#
# Stage 1: build the engine as static libraries with CMake and write the compile
# flags and link line the Xcode project needs (PCSX2/build/engine.xcconfig and
# engine-link.rsp).
# Stage 2: build the PCSX2.oecoreplugin that links them (added below).
#
# Needs Apple Silicon, Xcode and cmake (brew install cmake). Set PCSX2_EXTRA_CMAKE_ARGS to pass more
# flags to CMake.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PCSX2_DIR="$REPO_ROOT/PCSX2"
SRC_DIR="$PCSX2_DIR/deps/armsx2"
BUILD_DIR="$PCSX2_DIR/build"
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

"$SCRIPT_DIR/prepare-armsx2-core.sh"

# The libraries the engine links (libpng, libjpeg, libwebp, zstd, lz4, freetype, SDL3,
# plutovg, plutosvg) are built here from pinned source as static libraries for macOS 13,
# so the plugin needs nothing from Homebrew at run time.
"$SCRIPT_DIR/build-armsx2-deps.sh" "$BUILD_DIR" "$DEPS_PREFIX" "$SRC_DIR"

# OE_METAL_OUTPUT turns on PCSX2/patches/0001-openemu-metal-output.patch: the final
# picture is drawn into a Metal texture that OpenEmu owns instead of a window.
#
# No Qt and no frontends. Metal only: Vulkan off drops shaderc and MoltenVK (OpenGL is
# already off on macOS).
#
# ENABLE_LIBRETRO=ON is on purpose, even though we never build or use the libretro
# target or API. In the engine it is the "the host owns pads, audio and video" mode:
# it declares Host::SetPadVibration (our rumble hook), embeds the shaders and game
# database in the binary, and stops the engine defining the frontend callbacks that
# PCSX2/OEHost.cpp defines. Our single-owner rule for g_host_hotkeys depends on it.
# shellcheck disable=SC2086
cmake -S "$SRC_DIR" -B "$BUILD_DIR/engine" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DCMAKE_PREFIX_PATH="$DEPS_PREFIX" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DENABLE_QT_UI=OFF -DENABLE_SDL_FRONTEND=OFF -DENABLE_LIBRETRO=ON \
  -DENABLE_GSRUNNER=OFF -DENABLE_EERUNNER=OFF -DENABLE_VURUNNER=OFF \
  -DENABLE_TESTS=OFF -DENABLE_RECOMPILER_TEST_HOOKS=OFF \
  -DUSE_VULKAN=OFF \
  -DCMAKE_CXX_FLAGS=-DOE_METAL_OUTPUT -DCMAKE_OBJCXX_FLAGS=-DOE_METAL_OUTPUT \
  -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON \
  ${PCSX2_EXTRA_CMAKE_ARGS:-}

cmake --build "$BUILD_DIR/engine" --target PCSX2 common -j"$(sysctl -n hw.ncpu)"

# The engine's CMake only builds its Metal shader library for a full app target, which we
# do not build. Compile it here the way the engine does (its Metal 2.3 build) so the plugin
# can bundle it. The engine looks for Metal23.metallib in the plugin's Resources.
SHADER_DIR="$BUILD_DIR/shaders"
rm -rf "$SHADER_DIR"
mkdir -p "$SHADER_DIR/air"
for shader in "$SRC_DIR"/pcsx2/GS/Renderers/Metal/*.metal; do
  xcrun metal -ffast-math -std=macos-metal2.3 -target air64-apple-macos11.0 \
    -o "$SHADER_DIR/air/$(basename "$shader" .metal).air" -c "$shader"
done
xcrun metallib -o "$SHADER_DIR/Metal23.metallib" "$SHADER_DIR"/air/*.air

# The Xcode project reads the engine's compile flags and link line from these, so
# they follow whatever the engine's CMake decided.
python3 "$SCRIPT_DIR/gen-armsx2-xcconfig.py" "$BUILD_DIR/engine" "$BUILD_DIR"

# Every library or object file the link line names must exist by now.
missing=0
while IFS= read -r arg; do
  case "$arg" in
    /*.a|/*.o) [ -e "$arg" ] || { echo "error: link input missing: $arg" >&2; missing=1; } ;;
  esac
done < "$BUILD_DIR/engine-link.rsp"
if [ "$missing" -ne 0 ]; then
  exit 1
fi

echo "$(git -C "$SRC_DIR" rev-parse HEAD)" > "$BUILD_DIR/ENGINE_COMMIT"
echo ""
echo "Built the ARMSX2 engine. Xcode inputs: $BUILD_DIR/engine.xcconfig and $BUILD_DIR/engine-link.rsp"

# --- Stage 2: OpenEmuBase + the PCSX2.oecoreplugin that links the engine ---

DD="$PCSX2_DIR/build/XcodeDerived"

xcodebuild \
  -project "$REPO_ROOT/OpenEmu-SDK/OpenEmu-SDK.xcodeproj" \
  -scheme OpenEmuBase \
  -configuration Release \
  -derivedDataPath "$DD" \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  build

xcodebuild \
  -project "$PCSX2_DIR/PCSX2.xcodeproj" \
  -scheme PCSX2 \
  -configuration Release \
  -derivedDataPath "$DD" \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  build

PLUGIN="$DD/Build/Products/Release/PCSX2.oecoreplugin"
if [ ! -d "$PLUGIN" ]; then
  echo "error: build did not produce $PLUGIN" >&2
  exit 1
fi

echo ""
echo "Built plugin: $PLUGIN"
file "$PLUGIN/Contents/MacOS/PCSX2"
