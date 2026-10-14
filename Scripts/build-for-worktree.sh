#!/usr/bin/env bash
# build-for-worktree.sh — Build OpenEmu to a stable per-branch path so
# macOS privacy permissions persist across rebuilds of the same branch.
#
# Why: macOS binds permissions (Input Monitoring, Accessibility, etc.) to
# a specific app path + code signature. Xcode's default DerivedData uses a
# random hash per checkout — every fresh worktree = different path = lost
# permissions. This script forces a stable path: ~/Builds/openemu/<branch>/.
#
# Usage:
#   ./Scripts/build-for-worktree.sh                  # builds the OpenEmu scheme
#   ./Scripts/build-for-worktree.sh "OpenEmu + FCEU" # builds a specific scheme
#
# After building once, grant Input Monitoring (and any other permissions you
# need) to the printed app path in System Settings → Privacy & Security.
# Subsequent builds of the same branch land at the same path and inherit
# the granted permissions automatically.
#
# See docs/worktree-workflow.md for the full workflow and known caveats.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

# Personal agent rules (gitignored) don't exist in a fresh worktree. Copy them
# over from the main checkout so sessions here behave the same way.
MAIN_CHECKOUT="$(git worktree list --porcelain | awk '/^worktree /{print substr($0,10); exit}')"
if [ -n "$MAIN_CHECKOUT" ] && [ "$MAIN_CHECKOUT" != "$REPO_ROOT" ] \
   && [ -f "$MAIN_CHECKOUT/CLAUDE.local.md" ] && [ ! -f "$REPO_ROOT/CLAUDE.local.md" ]; then
  cp "$MAIN_CHECKOUT/CLAUDE.local.md" "$REPO_ROOT/CLAUDE.local.md"
fi

WORKSPACE="OpenEmu-metal.xcworkspace"
SCHEME="${1:-OpenEmu}"

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's|/|-|g')
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  echo "error: cannot determine branch name (detached HEAD or not a git repo)" >&2
  exit 1
fi

BUILD_DIR="$HOME/Builds/openemu/$BRANCH"
mkdir -p "$BUILD_DIR"

echo "Building scheme '$SCHEME' for branch '$BRANCH'"
echo "Output: $BUILD_DIR/Build/Products/Debug/"
echo ""

xcodebuild \
  -workspace "$WORKSPACE" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD_DIR" \
  build

# Auto-resolve a stable Apple Development signing identity if available.
# Falls back to ad-hoc (-) if no Developer cert is in the keychain.
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
SIGN_ID="${SIGN_ID:--}"

APP_PATH="$BUILD_DIR/Build/Products/Debug/OpenEmu.app"
if [ -d "$APP_PATH" ]; then
  codesign --force --deep --sign "$SIGN_ID" "$APP_PATH" 2>/dev/null || true
  echo ""
  echo "===================="
  echo "Build complete."
  echo "App:    $APP_PATH"
  echo "Signed: $SIGN_ID"
  echo ""
  echo "Launch:  open '$APP_PATH'"
  echo ""
  echo "First time on this branch? Grant Input Monitoring + any other"
  echo "permissions you need in System Settings → Privacy & Security."
  echo "Permissions persist for this branch's path across rebuilds."
  echo "===================="
else
  echo "warning: expected app at $APP_PATH but it doesn't exist" >&2
  echo "(scheme '$SCHEME' may not produce OpenEmu.app — check the Build/Products/Debug dir)" >&2
  ls "$BUILD_DIR/Build/Products/Debug/" 2>/dev/null || true
fi
