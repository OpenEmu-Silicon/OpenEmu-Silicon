#!/bin/bash
set -euo pipefail
# This phase runs BEFORE Swift compilation when opening the Xcode project.
# OpenEmuBase/OpenEmuSystem .swiftmodule files are SDK-specific. Swift will
# reject v18's previously bundled modules after Xcode SDK upgrades (27.2).
HERE="$(cd "$(dirname "$0")" && pwd)"
OPENEMU_SOURCE="${OPENEMU_SOURCE:-${HERE}/../orig_source/OpenEmu-Silicon-main}"
SDK_PROJECT="${OPENEMU_SOURCE}/OpenEmu-SDK/OpenEmu-SDK.xcodeproj"
if [ ! -d "${SDK_PROJECT}" ]; then
    echo "error: OpenEmu SDK source is missing: ${SDK_PROJECT}" >&2
    echo "Keep orig_source/OpenEmu-Silicon-main next to 3DS-System-Plugin, or set OPENEMU_SOURCE." >&2
    exit 2
fi
if ! command -v xcodebuild >/dev/null 2>&1 || ! command -v xcrun >/dev/null 2>&1; then
    echo 'error: building the OpenEmu frameworks requires full Xcode and xcrun.' >&2
    exit 2
fi
if [[ "${SDKROOT:-}" == *.sdk ]] && [ -d "${SDKROOT}" ]; then
    SDK_PATH="${SDKROOT}"
else
    SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
fi
if [ ! -d "${SDK_PATH}" ]; then
    echo "error: macOS SDK is unavailable: ${SDK_PATH}" >&2
    exit 2
fi
# Use a toolchain fingerprint. Do not rebuild the OpenEmu SDK on each Xcode
# invocation if already current; on a new compiler/SDK, rebuild both modules.
FINGERPRINT="${SDK_PATH}|$(xcodebuild -version | tr '\n' ' ')|${OPENEMU_SOURCE}|macos12.0|Debug"
STAMP="${HERE}/.build/OpenEmuFrameworks/.xcode-sdk-fingerprint"
VALID=YES
for name in OpenEmuBase OpenEmuSystem; do
    framework="${HERE}/Frameworks/${name}.framework"
    if [ ! -f "${framework}/Versions/Current/${name}" ] || \
       [ ! -d "${framework}/Modules/${name}.swiftmodule" ]; then
        VALID=NO
    fi
done
if [ "${VALID}" = YES ] && [ -f "${STAMP}" ] && \
   [ "$(cat "${STAMP}")" = "${FINGERPRINT}" ]; then
    echo "V19 OPENEMU_FRAMEWORKS sdk=${SDK_PATH} status=REUSED"
    exit 0
fi
BUILD_ROOT="${HERE}/.build/OpenEmuFrameworks"
# Build within the same OpenEmu-SDK Xcode project that supplies BOTH modules.
# The OpenEmuSystem scheme builds its OpenEmuBase target dependency.
echo "V19 OPENEMU_FRAMEWORKS sdk=${SDK_PATH} action=REBUILD"
xcodebuild -project "${SDK_PROJECT}" -scheme OpenEmuSystem \
    -configuration Debug -derivedDataPath "${BUILD_ROOT}" \
    -destination 'platform=macOS,arch=arm64' \
    MACOSX_DEPLOYMENT_TARGET=12.0 CODE_SIGNING_ALLOWED=NO build
PRODUCTS="${BUILD_ROOT}/Build/Products/Debug"
for name in OpenEmuBase OpenEmuSystem; do
    fresh="${PRODUCTS}/${name}.framework"
    if [ ! -f "${fresh}/Versions/Current/${name}" ]; then
        echo "error: Xcode did not produce ${fresh}" >&2
        exit 3
    fi
    # ditto keeps macOS framework symlinks intact. Replace old opaque Swift
    # modules completely: mixing SDK versions is not safe.
    rm -rf "${HERE}/Frameworks/${name}.framework"
    /usr/bin/ditto "${fresh}" "${HERE}/Frameworks/${name}.framework"
done
printf '%s\n' "${FINGERPRINT}" > "${STAMP}"
echo 'V19 OPENEMU_FRAMEWORKS status=READY modules=CURRENT_XCODE_SDK'
