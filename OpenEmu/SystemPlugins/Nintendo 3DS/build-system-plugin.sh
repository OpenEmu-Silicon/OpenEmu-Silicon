#!/bin/bash
set -euo pipefail
# Local development helper only. Ad-hoc signing is NOT a Developer ID
# signature or Apple notarization; official distribution should follow the
# OpenEmu maintainers' release and signing workflow.
HERE="$(cd "$(dirname "$0")" && pwd)"
if ! command -v xcodebuild >/dev/null 2>&1; then
    printf '%s\n' 'ERROR: xcodebuild is required (run on a Mac with Xcode).' >&2
    exit 1
fi
for framework in OpenEmuSystem OpenEmuBase; do
    if [ ! -e "$HERE/Frameworks/$framework.framework/Versions/Current/$framework" ]; then
        printf 'ERROR: %s framework is missing or its symlinks are broken.\n' "$framework" >&2
        exit 1
    fi
done
# The Xcode project's first build phase calls prepare-openemu-frameworks.sh.
# Both GUI and command-line builds automatically refresh SDK-specific modules.
xcodebuild -project "$HERE/Nintendo3DSSystemPlugin.xcodeproj" -target Nintendo3DSSystemPlugin -configuration Release -derivedDataPath "$HERE/.derivedData" CONFIGURATION_BUILD_DIR="$HERE/build" CODE_SIGN_IDENTITY=- build
codesign --force --sign - "$HERE/build/Nintendo 3DS.oesystemplugin"
printf '\nBuild output: %s\n' "$HERE/build/Nintendo 3DS.oesystemplugin"
printf '%s\n' 'Manually drag this .oesystemplugin to OpenEmu.app/Contents/PlugIns/Systems with OpenEmu closed.'
