#!/usr/bin/env bash
# build-review-dmg.sh — Build an all-in-one RA review DMG with app + core plugins.
#
# Usage:
#   ./Scripts/retro-achievements/build-review-dmg.sh
#
# Output:
#   Scripts/retro-achievements/build/OpenEmu-Silicon-RA-Review-<version>-RC-<date>-<sha>.dmg

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
WORKSPACE="$REPO_ROOT/OpenEmu-metal.xcworkspace"
ASSETS_DIR="$SCRIPT_DIR/dmg-assets"
BUILD_DIR="$SCRIPT_DIR/build"
VERSIONS_FILE="$ASSETS_DIR/ra-core-versions.txt"
README_FILE="$ASSETS_DIR/readme.html"
DESTINATION='platform=macOS,arch=arm64'

die() { echo ""; echo "ERROR: $*" >&2; exit 1; }
step() { echo ""; echo "══════════════════════════════════════"; echo "  $*"; echo "══════════════════════════════════════"; }
info() { echo "  $*"; }

# Sign every Mach-O binary inside a bundle from the inside out
deep_sign() {
  local bundle="$1" identity="$2"
  # Find all Mach-O files, sort by path depth (deepest first)
  find "$bundle" -type f \( -perm +111 -o -name "*.dylib" -o -name "*.so" \) -print0 \
    | xargs -0 file \
    | { grep -E "Mach-O|bundle" || true; } \
    | cut -d: -f1 \
    | awk -F/ '{print NF, $0}' | sort -rn | cut -d' ' -f2- \
    | while read -r binary; do
        codesign --force --sign "$identity" --options runtime --timestamp "$binary" 2>/dev/null || true
      done
  # Sign the bundle itself last
  codesign --force --sign "$identity" --options runtime --timestamp "$bundle"
}

# ── Preflight ─────────────────────────────────────────────────────────────────
[ -f "$VERSIONS_FILE" ] || die "ra-core-versions.txt not found at $VERSIONS_FILE"
[ -f "$README_FILE" ]   || die "readme.html not found at $README_FILE"

# Detect signing identity
SIGN_ID=""
if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  SIGN_ID="Developer ID Application"
  info "Signing: Developer ID Application (notarization-ready)"
else
  echo ""
  echo "WARNING: No Developer ID Application certificate found."
  echo "         The DMG will be ad-hoc signed. The reviewer will need to run:"
  echo "         xattr -cr /Applications/OpenEmu.app"
  echo ""
  SIGN_ID="-"
fi

# ── 1. Determine version and commit ──────────────────────────────────────────
step "1/8  Determining build identity"

COMMIT_SHORT=$(git -C "$REPO_ROOT" rev-parse --short HEAD)
TODAY=$(date +%Y-%m-%d)

# Suggest next patch version as default
CURRENT_VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$REPO_ROOT/OpenEmu/OpenEmu-Info.plist")
DEFAULT_VER="${CURRENT_VER%.*}.$((${CURRENT_VER##*.} + 1))"

read -r -p "  App version for this RC (default $DEFAULT_VER): " APP_VERSION
APP_VERSION="${APP_VERSION:-$DEFAULT_VER}"
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Version must be X.Y.Z"

DMG_NAME="OpenEmu-Silicon-RA-Review-${APP_VERSION}-RC-${TODAY}-${COMMIT_SHORT}.dmg"
info "Commit: $COMMIT_SHORT"
info "Date: $TODAY"
info "DMG name: $DMG_NAME"

# Update commit hash in ra-core-versions.txt
sed -i '' "s/^Core plugin versions built from commit .*/Core plugin versions built from commit $COMMIT_SHORT/" "$VERSIONS_FILE"

# Update readme Build Identity
sed -i '' "s|<code>[^<]*</code></p>$|<code>$COMMIT_SHORT</code></p>|" "$README_FILE"
sed -i '' "s|App version:</strong> [^<]*|App version:</strong> $APP_VERSION (release candidate)|" "$README_FILE"

# ── 2. Parse core list and bump versions ──────────────────────────────────────
step "2/8  Checking and bumping core versions"

# Auto-discover plugin plist: every .oecoreplugin Info.plist contains OEGameCoreClass
find_plugin_plist() {
  local core="$1"
  local core_dir="$REPO_ROOT/$core"

  # Try exact directory first, then case-insensitive glob for mismatches like Potator-Core
  if [ ! -d "$core_dir" ]; then
    core_dir=$(find "$REPO_ROOT" -maxdepth 1 -iname "${core}*" -type d | head -1)
  fi
  [ -d "$core_dir" ] || return

  find "$core_dir" -name "*.plist" -not -path "*/build/*" -not -path "*/DerivedData/*" \
    -exec grep -l "OEGameCoreClass" {} \; 2>/dev/null | head -1
}

# Parse cores from ra-core-versions.txt (skip header line)
CORE_NAMES=()
CORE_VERSIONS=()
while IFS=' ' read -r name version; do
  [ -z "$name" ] && continue
  [[ "$name" == "Core" ]] && continue
  CORE_NAMES+=("$name")
  CORE_VERSIONS+=("$version")
done < <(tail -n +3 "$VERSIONS_FILE")

# Track plist files modified for later revert
MODIFIED_PLISTS=()

# Revert the version bumps on any exit — including declining the failed-cores
# prompt, which exits before step 4. Scoped to MODIFIED_PLISTS only; each entry
# is restored with `git checkout --`. Guard the expansion for bash 3.2 + set -u.
revert_modified_plists() {
  [ ${#MODIFIED_PLISTS[@]} -gt 0 ] || return 0
  local plist
  for plist in "${MODIFIED_PLISTS[@]}"; do
    git -C "$REPO_ROOT" checkout -- "$plist" 2>/dev/null || true
  done
}
trap revert_modified_plists EXIT

bump_last_segment() {
  local ver="$1"
  local prefix="${ver%.*}"
  local last="${ver##*.}"
  echo "${prefix}.$((last + 1))"
}

get_current_version() {
  local core="$1"
  local plist
  plist=$(find_plugin_plist "$core")
  [ -n "$plist" ] || { echo "0"; return; }

  local raw
  raw=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$plist" 2>/dev/null || echo "")
  # If plist uses a build-setting variable, fall back to the pbxproj
  if [[ "$raw" == *'$('* ]] || [ -z "$raw" ]; then
    local pbxproj
    pbxproj=$(find "$REPO_ROOT" -maxdepth 4 -ipath "*${core}*" -name "project.pbxproj" 2>/dev/null | head -1)
    [ -n "$pbxproj" ] || { echo "0"; return; }
    grep "CURRENT_PROJECT_VERSION" "$pbxproj" | head -1 | grep -o '[0-9.]*'
  else
    echo "$raw"
  fi
}

set_version() {
  local core="$1"
  local new_ver="$2"
  local plist
  plist=$(find_plugin_plist "$core")
  [ -n "$plist" ] || die "Could not find plugin plist for $core"

  local raw
  raw=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$plist" 2>/dev/null || echo "")
  if [[ "$raw" == *'$('* ]] || [ -z "$raw" ]; then
    # Version lives in the pbxproj
    local pbxproj
    pbxproj=$(find "$REPO_ROOT" -maxdepth 4 -ipath "*${core}*" -name "project.pbxproj" 2>/dev/null | head -1)
    [ -n "$pbxproj" ] || die "Could not find pbxproj for $core"
    sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9.]*/CURRENT_PROJECT_VERSION = $new_ver/" "$pbxproj"
    MODIFIED_PLISTS+=("$pbxproj")
  else
    /usr/libexec/PlistBuddy -c "Set CFBundleVersion $new_ver" "$plist"
    MODIFIED_PLISTS+=("$plist")
  fi
}

for i in "${!CORE_NAMES[@]}"; do
  core="${CORE_NAMES[$i]}"
  target="${CORE_VERSIONS[$i]}"
  current=$(get_current_version "$core")

  # Compare: target must be higher than current
  if [ "$(printf '%s\n' "$current" "$target" | sort -V | tail -1)" = "$current" ] && [ "$current" != "$target" ]; then
    # Current is higher than target — bump target to current+1
    new_ver=$(bump_last_segment "$current")
    info "$core: current $current >= target $target → bumping to $new_ver"
    CORE_VERSIONS[$i]="$new_ver"
    # Update ra-core-versions.txt
    sed -i '' "s/^$core .*/$core $new_ver/" "$VERSIONS_FILE"
  else
    new_ver="$target"
    info "$core: current $current → target $new_ver ✓"
  fi

  # Set the version in the plist/pbxproj
  set_version "$core" "$new_ver"
done

# ── 3. Build all cores ────────────────────────────────────────────────────────
step "3/8  Building cores (Release)"

STAGING_DIR="$BUILD_DIR/staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
CORES_STAGING="$STAGING_DIR/RA Review Cores"
mkdir -p "$CORES_STAGING"

# Pin a script-owned DerivedData so every build writes here and every lookup
# reads the artifact THIS run produced — not a stale hash Xcode rotated away.
DERIVED_DATA="$BUILD_DIR/DerivedData"

FAILED_CORES=()

for core in "${CORE_NAMES[@]}"; do
  info "Building $core..."

  # Determine scheme: prefer "OpenEmu + Core" combined scheme
  COMBINED_SCHEME="OpenEmu + $core"
  AVAILABLE=$(xcodebuild -workspace "$WORKSPACE" -list 2>/dev/null | awk '/Schemes:/,0' | tail -n +2)
  if echo "$AVAILABLE" | grep -qxF "        $COMBINED_SCHEME"; then
    SCHEME="$COMBINED_SCHEME"
  elif echo "$AVAILABLE" | grep -qxF "        $core"; then
    SCHEME="$core"
  else
    echo "  WARNING: No scheme found for $core — skipping"
    FAILED_CORES+=("$core")
    continue
  fi

  if ! xcodebuild \
      -workspace "$WORKSPACE" \
      -scheme "$SCHEME" \
      -configuration Release \
      -destination "$DESTINATION" \
      -derivedDataPath "$DERIVED_DATA" \
      build 2>&1 | tail -3; then
    echo "  FAILED: $core"
    FAILED_CORES+=("$core")
    continue
  fi

  # Locate the built plugin
  PLUGIN="$DERIVED_DATA/Build/Products/Release/${core}.oecoreplugin"
  if [ ! -d "$PLUGIN" ]; then
    echo "  WARNING: Plugin not found at $PLUGIN"
    FAILED_CORES+=("$core")
    continue
  fi

  # Sign the core (every nested binary must be signed individually for notarization)
  if [ "$SIGN_ID" != "-" ]; then
    deep_sign "$PLUGIN" "$SIGN_ID"
  else
    codesign --force --deep --sign - "$PLUGIN" 2>&1 || true
  fi

  # Copy to staging
  rm -rf "$CORES_STAGING/${core}.oecoreplugin"
  ditto "$PLUGIN" "$CORES_STAGING/${core}.oecoreplugin"
  info "$core ✓"
done

if [ ${#FAILED_CORES[@]} -gt 0 ]; then
  echo ""
  echo "WARNING: Failed cores: ${FAILED_CORES[*]}"
  read -r -p "Continue without them? [y/N] " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { rm -rf "$STAGING_DIR"; die "Aborted."; }
fi

# ── 4. Revert plist version changes ──────────────────────────────────────────
step "4/8  Reverting plist version changes"

for plist in "${MODIFIED_PLISTS[@]}"; do
  git -C "$REPO_ROOT" checkout -- "$plist" 2>/dev/null || true
  info "Reverted: $(basename "$plist")"
done
# Reverted here; clear so the EXIT trap is a no-op on the normal path.
MODIFIED_PLISTS=()

# ── 5. Build the app ─────────────────────────────────────────────────────────
step "5/8  Building OpenEmu app (Release)"

# Temporarily bump the app version
APP_PLIST="$REPO_ROOT/OpenEmu/OpenEmu-Info.plist"
ORIGINAL_APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_PLIST")
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $APP_VERSION" "$APP_PLIST"
# Cover the app plist under the EXIT trap in case the build below fails.
MODIFIED_PLISTS=("$APP_PLIST")

xcodebuild \
  -workspace "$WORKSPACE" \
  -scheme OpenEmu \
  -configuration Release \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  build 2>&1 | tail -5

# Revert app version bump
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $ORIGINAL_APP_VERSION" "$APP_PLIST"
MODIFIED_PLISTS=()

# Locate the built app
APP_PATH="$DERIVED_DATA/Build/Products/Release/OpenEmu.app"
[ -d "$APP_PATH" ] || die "Built app not found at $APP_PATH"

# Sign the app (every nested binary must be signed individually for notarization)
if [ "$SIGN_ID" != "-" ]; then
  info "Signing app with Developer ID..."
  deep_sign "$APP_PATH" "$SIGN_ID"
  # Re-sign with entitlements: helper needs JIT/library-validation for core loading
  HELPER_ENT="$REPO_ROOT/OpenEmu/OpenEmuHelperApp/OpenEmuHelperApp.entitlements"
  APP_ENT="$REPO_ROOT/OpenEmu/OpenEmu.entitlements"
  # Sign BOTH copies — MacOS/ is the one launched via Bundle.main.url(forAuxiliaryExecutable:)
  for helper in "$APP_PATH/Contents/MacOS/OpenEmuHelperApp" "$APP_PATH/Contents/Resources/OpenEmuHelperApp"; do
    [ -f "$helper" ] && codesign --force --sign "$SIGN_ID" --options runtime --timestamp --entitlements "$HELPER_ENT" "$helper"
  done
  codesign --force --sign "$SIGN_ID" --options runtime --timestamp --entitlements "$APP_ENT" "$APP_PATH"
else
  info "Ad-hoc signing app..."
  codesign --force --deep --sign - "$APP_PATH"
fi

# Stage the app
ditto "$APP_PATH" "$STAGING_DIR/OpenEmu.app"

# ── 6. Stage DMG assets ──────────────────────────────────────────────────────
step "6/8  Staging DMG assets"

cp "$README_FILE" "$STAGING_DIR/readme.html"
# Inject core versions from ra-core-versions.txt into the HTML table cells
while IFS=' ' read -r name version; do
  [ -z "$name" ] && continue
  [[ "$name" == "Core" ]] && continue
  sed -i '' "s|<td>${name}</td>|<td>${name} (${version})</td>|g" "$STAGING_DIR/readme.html"
done < <(tail -n +3 "$VERSIONS_FILE")

cp "$VERSIONS_FILE" "$STAGING_DIR/core-versions.txt"
cp "$ASSETS_DIR/install.command" "$STAGING_DIR/Install.command"
chmod +x "$STAGING_DIR/Install.command"

# Set custom icon and hide extension on the .command file
INSTALL_ICON="$ASSETS_DIR/icon.png"
if [ -f "$INSTALL_ICON" ]; then
  osascript -e "
    use framework \"AppKit\"
    set iconImage to current application's NSImage's alloc()'s initWithContentsOfFile:\"$INSTALL_ICON\"
    current application's NSWorkspace's sharedWorkspace()'s setIcon:iconImage forFile:\"$STAGING_DIR/Install.command\" options:0
  " 2>/dev/null || true
fi
SetFile -a CE "$STAGING_DIR/Install.command"
# Reinforce extension-hidden via URL resource value (most reliable across DMG tools)
python3 -c "
from Foundation import NSURL, NSURLHasHiddenExtensionKey
url = NSURL.fileURLWithPath_('$STAGING_DIR/Install.command')
url.setResourceValue_forKey_error_(True, NSURLHasHiddenExtensionKey, None)
" 2>/dev/null || true

# Hide everything except Install.command and readme.txt
for item in "$STAGING_DIR"/*; do
  name="$(basename "$item")"
  case "$name" in
    Install.command|readme.html) ;;
    *) SetFile -a V "$item" ;;
  esac
done

info "Staged:"
ls -1A "$STAGING_DIR/" | sed 's/^/  /'

# ── 7. Create DMG ────────────────────────────────────────────────────────────
# dmgbuild's Python-written .DS_Store uses an alias/bookmark format that macOS 26
# Finder no longer recognises. AppleScript lets Finder write its own native format.
step "7/8  Creating DMG"

mkdir -p "$BUILD_DIR"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
DMG_RW="$BUILD_DIR/.dmg-rw-temp.dmg"
VOLNAME="OpenEmu RA Review"

# Detach any stale mounts from previous runs
for vol in "/Volumes/$VOLNAME"*; do
  [ -d "$vol" ] && hdiutil detach "$vol" -force 2>/dev/null || true
done

rm -f "$DMG_PATH" "$DMG_RW"

# Estimate required size: staging contents + 20% headroom for HFS+ overhead
STAGING_SIZE_KB=$(du -sk "$STAGING_DIR" | awk '{print $1}')
DMG_SIZE_MB=$(( (STAGING_SIZE_KB * 120 / 100) / 1024 + 10 ))

info "Creating R/W DMG (${DMG_SIZE_MB} MB)..."
hdiutil create -size "${DMG_SIZE_MB}m" -fs HFS+ -volname "$VOLNAME" "$DMG_RW" -ov 2>&1
hdiutil attach "$DMG_RW" -readwrite -noverify -noautoopen 2>&1 | tail -1

MOUNT_POINT="/Volumes/$VOLNAME"
[ -d "$MOUNT_POINT" ] || die "Volume not mounted at $MOUNT_POINT"

# Copy staging contents into the volume
ditto "$STAGING_DIR/" "$MOUNT_POINT/"

# Copy background image into hidden directory
mkdir -p "$MOUNT_POINT/.background"
cp "$ASSETS_DIR/background.png" "$MOUNT_POINT/.background/background.png"

# Configure Finder window via AppleScript
info "Setting background and icon layout via Finder..."
osascript << ASCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        -- 600 wide × 440 tall = 400 content + 28 title bar + 12 status bar slack
        set the bounds of container window to {200, 100, 800, 532}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.png"
        set position of item "OpenEmu.app" of container window to {2000, 2000}
        set position of item "RA Review Cores" of container window to {2000, 2000}
        set position of item "core-versions.txt" of container window to {2000, 2000}
        set position of item ".background" of container window to {2000, 2000}
        set position of item ".fseventsd" of container window to {2000, 2000}
        set position of item "Install.command" of container window to {204, 273}
        set position of item "readme.html" of container window to {391, 273}
        close
        open
        delay 2
        close
    end tell
end tell
ASCRIPT

# Let Finder flush .DS_Store
sync

# Eject via Finder first (releases its file handles), fall back to force detach
osascript -e "tell application \"Finder\" to eject disk \"$VOLNAME\"" 2>/dev/null || true
sleep 1
[ -d "$MOUNT_POINT" ] && hdiutil detach "$MOUNT_POINT" -force 2>/dev/null || true
info "Converting to compressed DMG..."
hdiutil convert "$DMG_RW" -format UDZO -o "$DMG_PATH" -ov 2>&1 | tail -2
rm -f "$DMG_RW"

[ -f "$DMG_PATH" ] || die "DMG creation failed"

# Notarize if Developer ID is available
if [ "$SIGN_ID" != "-" ]; then
  info "Signing DMG..."
  codesign --force --sign "$SIGN_ID" --timestamp "$DMG_PATH"

  if xcrun notarytool history --keychain-profile "OpenEmu" &>/dev/null 2>&1; then
    info "Submitting DMG for notarization..."
    if xcrun notarytool submit "$DMG_PATH" --keychain-profile "OpenEmu" --wait 2>&1 | tee /tmp/ra-review-notarize.log; then
      if grep -q "status: Accepted" /tmp/ra-review-notarize.log; then
        xcrun stapler staple "$DMG_PATH"
        info "Notarization: accepted and stapled"
      else
        echo "  WARNING: Notarization was not accepted. DMG is signed but not notarized."
      fi
    fi
    rm -f /tmp/ra-review-notarize.log
  else
    echo "  WARNING: No notarytool credentials found. DMG is signed but not notarized."
    echo "           Run: xcrun notarytool store-credentials OpenEmu"
  fi
fi

# ── 8. Cleanup ────────────────────────────────────────────────────────────────
step "8/8  Cleanup"

rm -rf "$STAGING_DIR"
info "Staging directory removed."

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
DMG_SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')

# Write .sha256 checksum file alongside the DMG
(cd "$(dirname "$DMG_PATH")" && shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256")

echo "╔══════════════════════════════════════════════════════╗"
echo "║  RA Review DMG ready                                ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  DMG:    $DMG_PATH"
echo "  Size:   $DMG_SIZE"
echo "  SHA256: $DMG_SHA"
echo ""
if [ "$SIGN_ID" = "-" ]; then
  echo "  NOTE: Ad-hoc signed."
fi
echo "  Next: upload to a GitHub pre-release tagged ra-review-$TODAY-$COMMIT_SHORT"
