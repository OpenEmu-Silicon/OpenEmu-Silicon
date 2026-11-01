#!/usr/bin/env bash
# make-synthetic-library.sh — Build a large library of made-up games to try the library window at scale.
#
# Usage:
#   ./Scripts/make-synthetic-library.sh [folder] [game count]
#
# Defaults: a new folder under the temp directory, 5000 games. The games have generated covers (24 shared
# images), no ROM files and no saves. Some are marked "file missing" or "processing" so the grid overlays
# show. It never touches your real library or its saves.
#
# Open the result with:
#   <OpenEmu.app>/Contents/MacOS/OpenEmu -databasePath <folder>
# (launch-debug.sh does not take arguments; start the app binary it prints.)

set -uo pipefail
trap 'pkill -TERM -P $$ 2>/dev/null || true' EXIT

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FOLDER="${1:-$(mktemp -d -t oe_synthetic_library)}"
COUNT="${2:-5000}"

if [ -e "$FOLDER" ] && [ -n "$(ls -A "$FOLDER" 2>/dev/null)" ]; then
  echo "error: $FOLDER is not empty" >&2
  exit 2
fi

if "$REPO_ROOT/Scripts/setup-debug-signing.sh" --check >/dev/null 2>&1; then
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="${OE_DEBUG_SIGN_IDENTITY:-OpenEmu Debug}" DEVELOPMENT_TEAM="")
else
  SIGN_ARGS=(CODE_SIGN_IDENTITY="-")
fi

LOG=$(mktemp -t oe_synthetic_log.XXXXXX)
echo "----  generating $COUNT games in $FOLDER"
if TEST_RUNNER_OE_SYNTHETIC_LIBRARY="$FOLDER" TEST_RUNNER_OE_SYNTHETIC_GAME_COUNT="$COUNT" \
   xcodebuild test \
     -workspace OpenEmu-metal.xcworkspace \
     -scheme OpenEmu \
     -configuration Debug \
     -destination 'platform=macOS,arch=arm64' \
     -only-testing:OpenEmuTests/SyntheticLibraryGenerator \
     -test-timeouts-enabled YES -default-test-execution-time-allowance 1200 \
     "${SIGN_ARGS[@]}" > "$LOG" 2>&1; then
  echo "OK    library: $FOLDER ($COUNT games)"
  echo "      open it:  <OpenEmu.app>/Contents/MacOS/OpenEmu -databasePath \"$FOLDER\""
  exit 0
fi

echo "FAIL  see $LOG (last 30 lines below)"
tail -30 "$LOG"
exit 1
