#!/bin/bash
set -euo pipefail

# Usage:
#   ./build-azahar-libretro.sh /path/to/azahar-git /path/to/output
#
# Azahar's macOS libretro link flags currently mishandle source paths containing
# spaces (for example, "3ds Core Development"). Configure and build through a
# no-space symlink in the user's home directory, while keeping the real checkout
# in the requested project folder. The finished dylib is copied back to OUTPUT_DIR.

AZAHAR_SRC="${1:?Azahar source directory required}"
OUTPUT_DIR="${2:?Output directory required}"

if [ ! -d "${AZAHAR_SRC}" ]; then
    echo "error: Azahar source directory does not exist: ${AZAHAR_SRC}" >&2
    exit 2
fi

# Fail early if the recursive submodules have not been initialized.
REQUIRED_FILES=(
    "${AZAHAR_SRC}/CMakeLists.txt"
    "${AZAHAR_SRC}/dist/compatibility_list/compatibility_list.qrc"
    "${AZAHAR_SRC}/externals/cryptopp/CMakeLists.txt"
    "${AZAHAR_SRC}/externals/libretro-common/libretro-common/include/libretro.h"
)
for required_file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "${required_file}" ]; then
        echo "error: required Azahar source file is missing: ${required_file}" >&2
        echo "From the azahar-git folder, run: git submodule update --init --recursive" >&2
        exit 2
    fi
done

# Xcode build phases do not inherit the interactive shell's PATH. Find CMake
# in the standalone app, common Homebrew prefixes, Homebrew's package prefix,
# or the PATH supplied by Xcode.
CMAKE=""
CANDIDATES=(
    "/Applications/CMake.app/Contents/bin/cmake"
    "$HOME/Applications/CMake.app/Contents/bin/cmake"
    "/opt/homebrew/bin/cmake"
    "/usr/local/bin/cmake"
)
for candidate in "${CANDIDATES[@]}"; do
    if [ -x "${candidate}" ]; then
        CMAKE="${candidate}"
        break
    fi
done

if [ -z "${CMAKE}" ]; then
    for brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "${brew}" ]; then
            prefix="$("${brew}" --prefix cmake 2>/dev/null || true)"
            if [ -x "${prefix}/bin/cmake" ]; then
                CMAKE="${prefix}/bin/cmake"
                break
            fi
        fi
    done
fi

if [ -z "${CMAKE}" ] && command -v cmake >/dev/null 2>&1; then
    CMAKE="$(command -v cmake)"
fi
if [ -z "${CMAKE}" ]; then
    echo "error: CMake was not found. Install CMake, then rebuild." >&2
    exit 127
fi

echo "Using CMake: ${CMAKE}"

# The Xcode build environment supplies SDKROOT. Prefer it over an old CMake
# cache: Xcode 27.2 can retain a 27.0 SDK path in an existing Azahar CMake tree.
# xcrun is the fallback when the helper is invoked directly from Terminal.
SDK_PATH=""
if [[ "${SDKROOT:-}" == *.sdk ]] && [ -d "${SDKROOT}" ]; then
    SDK_PATH="${SDKROOT}"
elif command -v xcrun >/dev/null 2>&1; then
    SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
fi
if [ -z "${SDK_PATH}" ] || [ ! -d "${SDK_PATH}" ]; then
    echo "error: Cannot resolve installed macOS SDK. Check Xcode > Settings > Locations, and xcode-select." >&2
    exit 2
fi
# Dynarmic's MIG-generated exception handler uses this exact SDK header.
MIG_DEFS="${SDK_PATH}/System/Library/Frameworks/Kernel.framework/Headers/mach/mach_exc.defs"
if [ ! -f "${MIG_DEFS}" ]; then
    echo "error: The selected SDK is missing mach_exc.defs: ${MIG_DEFS}" >&2
    echo "Check the active Xcode installation and installed macOS platform support." >&2
    exit 2
fi
printf 'V215 MACOS_SDK active=%s\n' "${SDK_PATH}"

# Keep both CMake's source/build paths free of spaces. CMake preserves the
# symlink path supplied with -S, which prevents the upstream exported-symbols
# linker argument from being split at spaces in the actual Desktop path.
SOURCE_LINK="${HOME}/.azahar-openemu-source-link"
BUILD_DIR="${HOME}/.azahar-openemu-build"
# Configuration persists between Xcode releases. When the SDK or toolchain
# changes, CMake's cached MIG arguments can still reference the removed SDK.
# Only the private Azahar CMake build directory is reset; upstream sources,
# user saves, and the OpenEmu/3DS plugin projects are not touched.
SDK_FINGERPRINT="${SDK_PATH}|$(xcodebuild -version 2>/dev/null | tr '\n' ' ' || true)"
SDK_STAMP="${BUILD_DIR}/.azahar-openemu-sdk-fingerprint"
if [ -f "${BUILD_DIR}/CMakeCache.txt" ]; then
    OLD_FINGERPRINT="$(cat "${SDK_STAMP}" 2>/dev/null || true)"
    if [ "${OLD_FINGERPRINT}" != "${SDK_FINGERPRINT}" ]; then
        echo "V215 CMAKE_CACHE_RESET reason=SDK_OR_XCODE_CHANGED private_build=${BUILD_DIR}"
        rm -rf "${BUILD_DIR}"
    fi
fi
mkdir -p "${BUILD_DIR}"
if [ -e "${SOURCE_LINK}" ] && [ ! -L "${SOURCE_LINK}" ]; then
    echo "error: ${SOURCE_LINK} exists and is not a symlink; please rename it and rebuild." >&2
    exit 2
fi
rm -f "${SOURCE_LINK}"
ln -s "${AZAHAR_SRC}" "${SOURCE_LINK}"

"${CMAKE}" -S "${SOURCE_LINK}" -B "${BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_SYSROOT="${SDK_PATH}" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.4 \
  -DENABLE_LIBRETRO=ON \
  -DENABLE_SDL2=OFF \
  -DENABLE_QT=OFF \
  -DENABLE_TESTS=OFF \
  -DENABLE_ROOM=OFF \
  -DENABLE_WEB_SERVICE=OFF \
  -DENABLE_SCRIPTING=OFF \
  -DENABLE_CUBEB=OFF \
  -DENABLE_OPENAL=OFF \
  -DENABLE_LIBUSB=OFF \
  -DCITRA_WARNINGS_AS_ERRORS=OFF \
  -DENABLE_LTO=OFF

# Save the fingerprint only after a successful reconfiguration. If CMake
# fails, a new run will not trust the incomplete cache.
printf '%s\n' "${SDK_FINGERPRINT}" > "${SDK_STAMP}"

"${CMAKE}" --build "${BUILD_DIR}" --target citra_libretro -j"$(sysctl -n hw.ncpu)"

BUILT_DYLIB="${BUILD_DIR}/bin/Release/azahar_libretro.dylib"
if [ ! -f "${BUILT_DYLIB}" ]; then
    echo "error: build completed without producing ${BUILT_DYLIB}" >&2
    exit 3
fi
mkdir -p "${OUTPUT_DIR}"
cp "${BUILT_DYLIB}" "${OUTPUT_DIR}/azahar_libretro.dylib"
# Mac Xcode needs a real rebuilt ARM64 dylib, not the bundled v198 seed.
file "${OUTPUT_DIR}/azahar_libretro.dylib"
if command -v lipo >/dev/null 2>&1; then
    case " $(lipo -archs "${OUTPUT_DIR}/azahar_libretro.dylib") " in
        *" arm64 "*) : ;;
        *) echo "V199 error: rebuilt dylib is not arm64" >&2; exit 4 ;;
    esac
fi
(
    cd "${OUTPUT_DIR}"
    shasum -a 256 azahar_libretro.dylib > .v199_libretro_built.sha256
    shasum -a 256 -c .v199_libretro_built.sha256
)
echo "V199: rebuilt and verified Azahar arm64 dylib at ${OUTPUT_DIR}/azahar_libretro.dylib"
