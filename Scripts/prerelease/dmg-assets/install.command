#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$HERE/OpenEmu.app"
CORES_SRC="$HERE/Preview Cores"
APP_DEST="/Applications/OpenEmu.app"
CORES_DEST="$HOME/Library/Application Support/OpenEmu/Cores"

echo "OpenEmu-Silicon Pre-release Installer"
echo ""

# Quit OpenEmu if running
osascript -e 'tell application "OpenEmu" to quit' >/dev/null 2>&1 || true
sleep 1

# Install app
echo "Installing OpenEmu.app to /Applications..."
rm -rf "$APP_DEST"
ditto "$APP_SRC" "$APP_DEST"
xattr -cr "$APP_DEST"
chflags -R nohidden "$APP_DEST"
echo "  App installed."
echo ""

# Install cores
echo "Installing the pre-release cores..."
mkdir -p "$CORES_DEST"

for plugin in "$CORES_SRC"/*.oecoreplugin; do
  name="$(basename "$plugin")"
  echo "  $name"
  rm -rf "$CORES_DEST/$name"
  ditto "$plugin" "$CORES_DEST/$name"
  xattr -cr "$CORES_DEST/$name"
done

echo ""
echo "Installed cores:"
ls -1d "$CORES_DEST"/*.oecoreplugin 2>/dev/null | sed 's|.*/|- |'
echo ""
echo "Done. Launch OpenEmu from /Applications."
read -r -p "Press Return to close this window."
