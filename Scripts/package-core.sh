#!/usr/bin/env bash
# package-core.sh — Sign, upload dSYM to Sentry, and zip a built core plugin for release.
#
# Run this after core.sh <Name> --release confirms a clean build.
# It produces a signed, verified zip at /tmp/<CoreName>.oecoreplugin.zip ready
# for upload to the GitHub Release, and prints the byte count needed for the appcast.
#
# Usage:
#   ./Scripts/package-core.sh <CoreName> <Version>
#
# Example:
#   ./Scripts/package-core.sh Gambatte 0.5.3
#
# Prerequisites:
#   - Core built in Release config (core.sh <Name> --release passes)
#   - Developer ID Application cert in keychain
#   - sentry-cli installed and authenticated (non-fatal if absent — warns and continues)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die()  { echo ""; echo "ERROR: $*" >&2; exit 1; }
ok()   { echo "PASS  $*"; }
warn() { echo "WARN  $*"; }
step() { echo ""; echo "──── $*"; }

[ $# -eq 2 ] || die "Usage: $0 <CoreName> <Version>  (e.g. $0 Gambatte 0.5.3)"
CORE="$1"
VERSION="$2"

# ── 1. Locate the Release artifact ───────────────────────────────────────────
step "Locating Release artifact"

DERIVED_DATA=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 \
  -name "OpenEmu-metal-*" -type d 2>/dev/null | head -1)
[ -n "$DERIVED_DATA" ] || die "DerivedData for OpenEmu-metal not found. Build via: ./Scripts/core.sh $CORE --release"

PLUGIN="$DERIVED_DATA/Build/Products/Release/${CORE}.oecoreplugin"
[ -d "$PLUGIN" ] || die "Plugin not found: $PLUGIN — run ./Scripts/core.sh $CORE --release first."
ok "Found: $PLUGIN"

# ── 2. Verify CFBundleVersion matches ────────────────────────────────────────
step "Verifying CFBundleVersion"

BUILT_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" \
  "$PLUGIN/Contents/Info.plist" 2>/dev/null || true)
[ "$BUILT_VERSION" = "$VERSION" ] \
  || die "CFBundleVersion mismatch: plugin has '$BUILT_VERSION', expected '$VERSION'.
  Did the plist bump land in this build? Re-run: ./Scripts/core.sh $CORE --release"
ok "CFBundleVersion = $BUILT_VERSION"

# ── 3. Sign with Developer ID Application ────────────────────────────────────
step "Signing with Developer ID"

# Require the full identity so signing is deterministic, not just the first
# matching cert. AJC82Q6789 is Nick Blackmon's Developer Program Team ID.
IDENTITY="Developer ID Application: Nick Blackmon (AJC82Q6789)"
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || die "Developer ID Application certificate not found in keychain.
  Check with: security find-identity -v | grep 'Developer ID Application'"

codesign --force --sign "$IDENTITY" --options runtime --timestamp "$PLUGIN"
codesign --verify --deep --strict "$PLUGIN" \
  && ok "codesign --verify passed" \
  || die "codesign --verify failed after signing. Bundle may be malformed."

# ── 4. Verify and upload dSYM to Sentry ──────────────────────────────────────
step "Verifying and uploading dSYM to Sentry"

"$SCRIPT_DIR/verify-sentry-symbols.sh" \
  --upload \
  --wait-for 120 \
  --binary-root "$PLUGIN" \
  --dsym-root "$DERIVED_DATA/Build/Products/Release" \
  --allow-missing '\.so$'

# ── 5. Zip with ditto ────────────────────────────────────────────────────────
step "Creating zip"

ZIP="/tmp/${CORE}.oecoreplugin.zip"
rm -f "$ZIP"
ditto -c -k --keepParent --norsrc "$PLUGIN" "$ZIP"
ok "Zip: $ZIP"

# ── 6. Verify zip contents ───────────────────────────────────────────────────
step "Verifying zip"

VERIFY_DIR=$(mktemp -d)
ditto -x -k "$ZIP" "$VERIFY_DIR"
ZIP_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" \
  "$VERIFY_DIR/${CORE}.oecoreplugin/Contents/Info.plist" 2>/dev/null || true)
rm -rf "$VERIFY_DIR"

[ "$ZIP_VERSION" = "$VERSION" ] \
  || die "Zip version mismatch: zip contains '$ZIP_VERSION', expected '$VERSION'. Do not upload this zip."
ok "Zip CFBundleVersion = $ZIP_VERSION"

# ── Done ─────────────────────────────────────────────────────────────────────
BYTE_COUNT=$(wc -c < "$ZIP" | tr -d ' ')

echo ""
echo "══════════════════════════════════════════════"
echo "  $CORE $VERSION packaged successfully"
echo "══════════════════════════════════════════════"
echo "  Zip:   $ZIP"
echo "  Bytes: $BYTE_COUNT"
echo ""
echo "Next steps:"
echo "  1. Upload to GitHub Release:"
echo "     gh release upload <cores-tag> \"$ZIP\" --repo OpenEmu-Silicon/OpenEmu-Silicon"
echo ""
echo "  2. Update appcast (generates EdDSA signature automatically):"
echo "     python3 Scripts/update_core_appcast.py \\"
echo "       Appcasts/<core>.xml \"$CORE\" \"$VERSION\" \\"
echo "       https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/releases/download/<cores-tag>/${CORE}.oecoreplugin.zip \\"
echo "       $BYTE_COUNT \\"
echo "       --sign-zip \"$ZIP\""
