#!/usr/bin/env bash
# core.sh — Build one core, install it, and prove the installed copy is the one just built.
#
# Usage:
#   ./Scripts/core.sh <CoreName>              # Debug build
#   ./Scripts/core.sh <CoreName> --release    # Release build (for Release-only bugs)
#
# Steps: core feed-URL check, build, plist lint, codesign the build, install with install-core.sh,
# codesign the installed plugin, then verify-core-installed.sh (the installed binary matches the build).
# Each step prints one PASS/FAIL line. Exit code is the number of failed steps; 0 means all passed.
#
# OpenEmu loads cores from ~/Library/Application Support/OpenEmu/Cores/, not from the build folder, so a
# successful build alone proves nothing about what the app runs. Do not report an in-game core result
# until this script ends with ALL PASS.
#
# Most cores build through the "OpenEmu + <Name>" workspace scheme (some use the bare name). Cores whose
# upstream source is not vendored (FBNeo, MAME) build through Scripts/build-<name>-core.sh, Release only.
#
# In a linked git worktree the build goes to ~/Builds/openemu/<branch>/ so macOS permissions stay stable
# across rebuilds. See docs/worktree-workflow.md.

set -uo pipefail

# A truncated consumer (`| head`) must not kill the script and orphan xcodebuild, which would leave
# build.db locked for the next run.
trap '' PIPE
trap 'pkill -TERM -P $$ 2>/dev/null || true' EXIT

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORKSPACE="OpenEmu-metal.xcworkspace"
INSTALLED_CORES="$HOME/Library/Application Support/OpenEmu/Cores"

CORE=""
CONFIG="Debug"
FAILURES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --release) CONFIG="Release"; shift ;;
    --debug) CONFIG="Debug"; shift ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) CORE="$1"; shift ;;
  esac
done
[ -n "$CORE" ] || { echo "usage: Scripts/core.sh <CoreName> [--release]" >&2; exit 2; }

# The core's source folder usually has the core's name, but not always (Potator lives in Potator-Core).
CORE_DIR=""
for _d in "$CORE" "$CORE-Core"; do [ -d "$_d" ] && { CORE_DIR="$_d"; break; }; done

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILURES=$((FAILURES+1)); }
info() { echo "----  $1"; }

# Cores whose upstream source isn't vendored (FBNeo, MAME) build through a dedicated script that clones the
# pinned source and builds the plugin into <Core>/build/XcodeDerived. Those are Release-only.
CORE_BUILD_SCRIPT=""
_core_lc=$(echo "$CORE" | tr '[:upper:]' '[:lower:]')
if [ -x "./Scripts/build-${_core_lc}-core.sh" ]; then
  CORE_BUILD_SCRIPT="./Scripts/build-${_core_lc}-core.sh"
  CONFIG="Release"
fi

# A linked worktree has .git as a file, not a directory.
BUILD_DIR_OVERRIDE=""
if [ -f .git ]; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's|/|-|g')
  if [ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ]; then
    BUILD_DIR_OVERRIDE="$HOME/Builds/openemu/$BRANCH"
    mkdir -p "$BUILD_DIR_OVERRIDE"
  else
    echo "warning: in a worktree but cannot determine the branch name; falling back to DerivedData" >&2
  fi
fi

# Wait until SWBBuildService releases build.db, so a concurrent xcodebuild (another hook, the IDE) does not
# make this build fail with "database is locked".
wait_for_build_db() {
  local db_path
  if [ -n "$BUILD_DIR_OVERRIDE" ]; then
    db_path="$BUILD_DIR_OVERRIDE/Build/Intermediates.noindex/XCBuildData/build.db"
  else
    db_path=$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 7 -name "build.db" \
      -path "*/OpenEmu-metal-*/Build/Intermediates.noindex/XCBuildData/build.db" -print -quit 2>/dev/null)
  fi
  [ -z "$db_path" ] || [ ! -f "$db_path" ] && return 0
  local elapsed=0
  while [ "$elapsed" -lt 40 ]; do
    lsof "$db_path" 2>/dev/null | grep -q "SWBBuildService" || return 0
    [ "$elapsed" -eq 0 ] && info "build.db locked by SWBBuildService — waiting for it to release..."
    sleep 2
    elapsed=$((elapsed + 2))
  done
}

# --- Core feed-URL guardrail (no upstream update URLs, every core has an appcast) ---

if ./Scripts/check-core-feed-urls.sh >/dev/null 2>&1; then
  pass "check-core-feed-urls.sh"
else
  fail "check-core-feed-urls.sh — upstream URL or missing appcast detected"
  ./Scripts/check-core-feed-urls.sh || true
fi

# --- Build ---

BUILD_LOG=$(mktemp -t core_build.XXXXXX)
if [ -n "$CORE_BUILD_SCRIPT" ]; then
  info "Building core via $CORE_BUILD_SCRIPT (Release only for this core; clones the pinned source)"
  wait_for_build_db
  if "$CORE_BUILD_SCRIPT" > "$BUILD_LOG" 2>&1; then
    pass "build ($CORE_BUILD_SCRIPT)"
  else
    fail "build ($CORE_BUILD_SCRIPT) — see $BUILD_LOG (last 30 lines below)"
    tail -30 "$BUILD_LOG"
  fi
else
  # Workspace schemes are named "OpenEmu + <Core>" for the combined host+core build. A few cores also have a
  # bare scheme (e.g. "4DO", "BSNES"); prefer the combined one.
  AVAILABLE=$(xcodebuild -workspace "$WORKSPACE" -list 2>/dev/null | awk '/Schemes:/,0' | tail -n +2)
  if echo "$AVAILABLE" | grep -qxF "        OpenEmu + $CORE"; then
    SCHEME="OpenEmu + $CORE"
  else
    SCHEME="$CORE"
  fi
  info "Building core scheme: $SCHEME ($CONFIG)"
  XCODEBUILD_ARGS=(-workspace "$WORKSPACE" -scheme "$SCHEME" -configuration "$CONFIG"
                   -destination 'platform=macOS,arch=arm64')
  if [ -n "$BUILD_DIR_OVERRIDE" ]; then
    XCODEBUILD_ARGS+=(-derivedDataPath "$BUILD_DIR_OVERRIDE")
    info "worktree mode — building to $BUILD_DIR_OVERRIDE"
  fi
  wait_for_build_db
  if xcodebuild "${XCODEBUILD_ARGS[@]}" build > "$BUILD_LOG" 2>&1; then
    pass "build ($SCHEME)"
  else
    fail "build ($SCHEME) — see $BUILD_LOG (last 30 lines below)"
    tail -30 "$BUILD_LOG"
  fi
fi

WARN_COUNT=$(grep -cE ': (warning|error):' "$BUILD_LOG" 2>/dev/null || true)
if [ "${WARN_COUNT:-0}" -gt 0 ]; then
  info "$WARN_COUNT warning/error lines in build log — first 10:"
  grep -E ': (warning|error):' "$BUILD_LOG" | head -10
fi

# --- Plist lint ---

while IFS= read -r p; do
  [ -z "$p" ] && continue
  if plutil -lint "$p" >/dev/null 2>&1; then
    pass "plutil $p"
  else
    fail "plutil $p"
    plutil -lint "$p" || true
  fi
done < <([ -n "$CORE_DIR" ] && find "$CORE_DIR" -maxdepth 3 -name 'Info.plist' 2>/dev/null)

# --- Locate the built plugin and codesign it ---

if [ -n "$CORE_BUILD_SCRIPT" ]; then
  ARTIFACT="${CORE_DIR:-$CORE}/build/XcodeDerived/Build/Products/${CONFIG}/${CORE}.oecoreplugin"
  [ -e "$ARTIFACT" ] || ARTIFACT=""
elif [ -n "$BUILD_DIR_OVERRIDE" ]; then
  ARTIFACT="$BUILD_DIR_OVERRIDE/Build/Products/${CONFIG}/${CORE}.oecoreplugin"
  [ -e "$ARTIFACT" ] || ARTIFACT=""
else
  ARTIFACT=$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 5 \
    -path "*OpenEmu-metal-*/Build/Products/${CONFIG}/${CORE}.oecoreplugin" -print -quit 2>/dev/null)
fi

if [ -z "$ARTIFACT" ] || [ ! -e "$ARTIFACT" ]; then
  fail "locate built plugin (expected in DerivedData or the worktree build folder)"
else
  info "plugin: $ARTIFACT"
  if codesign --verify --deep --strict "$ARTIFACT" 2>/dev/null; then
    pass "codesign built plugin"
  else
    fail "codesign built plugin"
    codesign --verify --deep --strict "$ARTIFACT" || true
  fi

  # --- Install, then prove the installed copy is the one just built ---

  CONFIG_FLAG="--$(echo "$CONFIG" | tr '[:upper:]' '[:lower:]')"
  info "installing core via Scripts/install-core.sh ($CONFIG)"
  if ./Scripts/install-core.sh "$CORE" "$CONFIG_FLAG" >/dev/null 2>&1; then
    pass "install-core.sh $CORE $CONFIG_FLAG"
  else
    fail "install-core.sh $CORE $CONFIG_FLAG"
  fi

  INSTALL_DEST="$INSTALLED_CORES/${CORE}.oecoreplugin"
  if [ -e "$INSTALL_DEST" ]; then
    if codesign --verify --deep --strict "$INSTALL_DEST" 2>/dev/null; then
      pass "codesign installed plugin"
    else
      fail "codesign installed plugin"
    fi
  fi

  # Catches silent install failures (e.g. OpenEmu still holding the binary open) that codesign would not.
  if ./Scripts/verify-core-installed.sh "$CORE" "$CONFIG_FLAG" >/dev/null 2>&1; then
    pass "verify-core-installed.sh $CORE $CONFIG_FLAG"
  else
    fail "verify-core-installed.sh $CORE $CONFIG_FLAG — installed plugin does not match build"
    ./Scripts/verify-core-installed.sh "$CORE" "$CONFIG_FLAG" || true
  fi
fi

# --- Summary ---

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "===================="
  echo "core.sh $CORE: ALL PASS"
  echo "===================="
  exit 0
fi
echo "===================="
echo "core.sh $CORE: $FAILURES FAILED"
echo "===================="
exit "$FAILURES"
