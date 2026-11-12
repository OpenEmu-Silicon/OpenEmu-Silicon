#!/usr/bin/env bash
# The PlayStation 2 core is built by build-armsx2-core.sh (it builds the ARMSX2 engine, then PCSX2.oecoreplugin).
# This wrapper lets the generic "Scripts/build-<core>-core.sh" lookup in core.sh and
# Scripts/prerelease/build-preview-dmg.sh find it under the plugin name.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-armsx2-core.sh" "$@"
