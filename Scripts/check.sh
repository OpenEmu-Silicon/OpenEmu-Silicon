#!/usr/bin/env bash
# check.sh — Drive the real app with UI tests and collect screenshots, results and crash reports.
#
# Usage:
#   ./Scripts/check.sh                               # run every UI test (game tests play the built-in test ROM)
#   ./Scripts/check.sh --rom "/path/to/game.sfc"     # also load that ROM, check it draws and moves, quick save, screenshot, quit
#   ./Scripts/check.sh --game "Super Mario 64"       # same checks on a game already in your real library, found by name
#   ./Scripts/check.sh --no-build                    # reuse the last build as is (skip xcodebuild and re-signing)
#   ./Scripts/check.sh --throwaway-library           # use an empty temporary library instead of your real one
#   ./Scripts/check.sh --test testPreferencesPanesAllOpen   # run one test by name (repeat --test for several)
#
# By default the tests launch the Debug build against your real library (read-only checks: windows, panes, tabs).
# --rom imports the ROM, so it switches to a throwaway empty library (add --real-library to import into yours).
# --game plays a game from your real library (a read-only lookup, no import, no file path). It runs only the tests that
# make sense for any game (loads and runs, pause and resume) and never writes saves: no quick save, and closing the game
# does not replace its auto save, and the run fails if any of that game's save states changed. It does update play count and
# last-played time. If a game sits on a static screen the picture check fails; that is the game, not the app.
# Only one check.sh or playtest.sh run may use the library at a time; a second one refuses to start.
# The ROM file itself is not modified or copied into the repo.
# The build folder is shared with playtest.sh (override with OE_BUILD_DIR), so one build serves both.
# The tests click and type, so leave the mouse and keyboard alone while this runs (about 30 seconds).
# Output goes to $TMPDIR/openemu-check/<timestamp>/: result bundle, screenshots/, summary on stdout.
#
# Exit code is 0 only when every test passed and no new OpenEmu crash report appeared.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=lib/harness.sh
. "$REPO_ROOT/Scripts/lib/harness.sh"

BUILD_DIR="$(harness_build_dir)"
OUT_DIR="${TMPDIR:-/tmp}/openemu-check/$(date +%Y%m%d-%H%M%S)"
RESULT="$OUT_DIR/result.xcresult"
LOG="$OUT_DIR/xcodebuild.log"
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"

harness_take_lock || exit 2
trap harness_release_lock EXIT
if pgrep -x OpenEmu >/dev/null; then
  echo "FAIL  OpenEmu is running. Quit it first so the tests do not clobber your session." >&2
  harness_describe_running >&2
  exit 2
fi

mkdir -p "$OUT_DIR"
touch "$OUT_DIR/.start"
harness_ensure_stubs "$REPO_ROOT"

# Never leave a debug OpenEmu or a test runner behind, whatever way the script ends.
cleanup() { pkill -TERM -f "OpenEmuUITests-Runner" 2>/dev/null; harness_kill_debug_app "$BUILD_DIR"; harness_release_lock; }
trap cleanup EXIT

ONLY=(); NO_BUILD=0; LIBRARY=""; HAS_ROM=0; GAME=
while [ $# -gt 0 ]; do
  case "$1" in
    --rom)
      [ -f "${2:-}" ] || { echo "FAIL  --rom needs an existing file" >&2; exit 2; }
      # xcodebuild passes TEST_RUNNER_-prefixed variables to the test runner.
      export TEST_RUNNER_OE_TEST_ROM="$2"; HAS_ROM=1; shift 2 ;;
    --game) GAME="${2:-}"; [ -n "$GAME" ] || { echo "FAIL  --game needs the name of a game in your library" >&2; exit 2; }; shift 2 ;;
    --no-build) NO_BUILD=1; shift ;;
    --real-library) LIBRARY=real; shift ;;
    --throwaway-library) LIBRARY=throwaway; shift ;;
    --test) ONLY+=(-only-testing:"OpenEmuUITests/OpenEmuSmokeUITests/${2:-}"); shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# --game: find the game in the real library by name, the way playtest.sh does, and run the checks that work on any game.
if [ -n "$GAME" ]; then
  [ "$HAS_ROM" -eq 0 ] || { echo "FAIL  use --game or --rom, not both" >&2; exit 2; }
  MATCH="$(python3 "$REPO_ROOT/Scripts/playtest/library.py" find "$GAME")" || exit 2
  GAME_NAME="$(printf '%s' "$MATCH" | cut -f2)"; GAME_PATH="$(printf '%s' "$MATCH" | cut -f3)"
  [ -f "$GAME_PATH" ] || { echo "FAIL  \"$GAME_NAME\" is in your library but its file is missing: $GAME_PATH" >&2; exit 2; }
  echo "----  game: $GAME_NAME ($GAME_PATH)"
  # "find" takes the first match. Say so when the name also matches other games, so the wrong game is easy to spot.
  OTHER_MATCHES="$(python3 "$REPO_ROOT/Scripts/playtest/library.py" list | awk -F'\t' -v q="$(printf '%s' "$GAME" | tr '[:upper:]' '[:lower:]')" \
    'index(tolower($2), q) { print $2 }' | grep -vxF "$GAME_NAME" | head -3)"
  [ -z "$OTHER_MATCHES" ] || echo "      also matches: $(printf '%s' "$OTHER_MATCHES" | paste -sd ';' - | sed 's/;/; /g') (use more of the name to pick another)"
  # Snapshot this game's save states so the run can prove it left them alone.
  SAVES_DIR="$(find "$HOME/Library/Application Support/OpenEmu/Save States" -maxdepth 2 -type d -name "$GAME_NAME" 2>/dev/null | head -1)"
  saves_snapshot() { [ -n "$SAVES_DIR" ] && find "$SAVES_DIR" -exec stat -f '%m %z %N' {} + 2>/dev/null | sort; }
  SAVES_BEFORE="$(saves_snapshot)"
  export TEST_RUNNER_OE_TEST_ROM="$GAME_PATH"; LIBRARY=real
  if [ ${#ONLY[@]} -eq 0 ]; then
    ONLY=(-only-testing:OpenEmuUITests/OpenEmuSmokeUITests/testGameLoadsAndRuns
          -only-testing:OpenEmuUITests/OpenEmuSmokeUITests/testPauseFreezesPictureAndResumeContinues)
  fi
fi

# Without --rom, play the built-in Game Boy test ROM (written for this repo, always moving, no licensing issues)
# so the game tests run instead of being skipped. It needs the Gambatte core installed, like any Game Boy game.
if [ -z "${TEST_RUNNER_OE_TEST_ROM:-}" ]; then
  python3 "$REPO_ROOT/Scripts/headless/make-test-rom.py" "$OUT_DIR/oetest.gb" && export TEST_RUNNER_OE_TEST_ROM="$OUT_DIR/oetest.gb"
fi

rm -rf /private/tmp/openemu-ui-* /private/tmp/openemu-ui-backup-* 2>/dev/null  # leftovers from earlier runs (the sandboxed runner cannot always delete them)
# Real library unless a ROM is being imported (or the caller chose).
[ -n "$LIBRARY" ] || { [ "$HAS_ROM" -eq 1 ] && LIBRARY=throwaway || LIBRARY=real; }
[ "$LIBRARY" = real ] && export TEST_RUNNER_OE_USE_REAL_LIBRARY=1
echo "----  library: $LIBRARY"

XC_ARGS=(-workspace OpenEmu-metal.xcworkspace -scheme OpenEmuUITests -configuration Debug
         -destination 'platform=macOS,arch=arm64' -derivedDataPath "$BUILD_DIR")

RUNNER="$BUILD_DIR/Build/Products/Debug/OpenEmuUITests-Runner.app"
if [ "$NO_BUILD" -eq 1 ] && [ -d "$RUNNER" ]; then
  echo "----  reusing the existing build ($BUILD_DIR)"
  : > "$LOG"; XC_STATUS=0
else
  echo "----  building UI tests"
  xcodebuild build-for-testing "${XC_ARGS[@]}" > "$LOG" 2>&1
  XC_STATUS=$?
  BUILT=1
fi

# Re-sign the test runner with a stable local certificate so the macOS Accessibility grant survives rebuilds.
# Ad-hoc signatures change on every build, which silently revokes the grant (same cause as launch-debug.sh's
# Input Monitoring note). Uses the same certificate: "OpenEmu Debug", or OE_DEBUG_SIGN_IDENTITY.
SIGN_NAME="${OE_DEBUG_SIGN_IDENTITY:-OpenEmu Debug}"
SIGN_ID="$(harness_sign_identity)"
if [ "$XC_STATUS" -eq 0 ]; then
  if [ "${BUILT:-0}" -eq 1 ] && [ -n "$SIGN_ID" ]; then
    harness_warn_duplicate_certs
    echo "----  signing UI test runner with \"$SIGN_NAME\""
    # The runner is signed without its entitlements on purpose: Xcode gives it the app sandbox, and once it
    # has a real signature macOS enforces that sandbox, so OpenEmu can no longer write into the runner's
    # temp folder where the tests put their libraries. The app under test keeps its entitlements.
    codesign --force --deep --sign "$SIGN_ID" "$RUNNER" >> "$LOG" 2>&1 \
      || echo "WARN  signing the UI test runner failed; it stays ad-hoc signed and permissions may need re-granting" >&2
    codesign --force --deep --preserve-metadata=entitlements,requirements,flags,runtime \
      --sign "$SIGN_ID" "$BUILD_DIR/Build/Products/Debug/OpenEmu.app" >> "$LOG" 2>&1 \
      || echo "WARN  signing OpenEmu.app failed; it stays ad-hoc signed and permissions may need re-granting" >&2
  elif [ "${BUILT:-0}" -eq 1 ]; then
    echo "WARN  no \"$SIGN_NAME\" certificate found; Accessibility will need re-granting after each rebuild" >&2
  fi

  echo "----  running UI tests"
  xcodebuild test-without-building "${XC_ARGS[@]}" -resultBundlePath "$RESULT" \
    ${ONLY[@]+"${ONLY[@]}"} >> "$LOG" 2>&1 &
  XC_PID=$!
  # Without the Accessibility grant every test fails the same way after launching the app. Stop at the first one.
  AX_STOP=0
  while kill -0 "$XC_PID" 2>/dev/null; do
    if grep -q "Not authorized for performing UI testing" "$LOG"; then
      AX_STOP=1; kill "$XC_PID" 2>/dev/null; pkill -f "OpenEmuUITests-Runner" 2>/dev/null; break
    fi
    sleep 2
  done
  wait "$XC_PID" 2>/dev/null
  XC_STATUS=$?
  if [ "$AX_STOP" -eq 1 ]; then
    XC_STATUS=1
    echo "FAIL  macOS has not granted Accessibility to OpenEmuUITests-Runner (stopped at the first test)."
    echo "      Fix: System Settings > Privacy & Security > Accessibility: remove and re-add"
    echo "      $RUNNER"
    echo "      then run ./Scripts/doctor.sh and ./Scripts/check.sh --no-build."
  fi
fi

FAILURES=0
grep -E "^Test Case .* (passed|failed)" "$LOG" | sed -E "s/^Test Case '-\[OpenEmuUITests\.[A-Za-z]+ ([A-Za-z0-9_]+)\]' (passed|failed) \((.*)\)\./\2  \1 (\3)/" | while read -r line; do
  case "$line" in
    passed*) echo "PASS  ${line#passed  }" ;;
    failed*) echo "FAIL  ${line#failed  }" ;;
  esac
done
if grep -qE "^Test Case .* failed" "$LOG"; then FAILURES=1; fi
grep -E "error:" "$LOG" | grep -v "CoreDevice\|CoreSimulator" | head -10

if [ -d "$RESULT" ]; then
  xcrun xcresulttool export attachments --path "$RESULT" --output-path "$OUT_DIR/screenshots" >/dev/null 2>&1
  echo "----  screenshots: $OUT_DIR/screenshots (names in manifest.json)"
fi

NEW_CRASHES=$(find "$CRASH_DIR" -name 'OpenEmu*' -newer "$OUT_DIR/.start" 2>/dev/null)
if [ -n "$NEW_CRASHES" ]; then
  echo "FAIL  new crash report(s):"
  echo "$NEW_CRASHES"
  FAILURES=1
else
  echo "PASS  no new OpenEmu crash reports"
fi

# Error-level log lines from OpenEmu's own code (subsystem org.openemu) during the run. Reported for review, not a failure on their own.
START_STAMP=$(date -r "$(stat -f %m "$OUT_DIR/.start")" '+%Y-%m-%d %H:%M:%S')
log show --start "$START_STAMP" --style compact \
  --predicate '(process == "OpenEmu" OR process == "OpenEmuHelperApp") AND subsystem BEGINSWITH "org.openemu" AND messageType == error' \
  2>/dev/null | grep -v "^Timestamp\|^Filtering" > "$OUT_DIR/app-errors.log"
# Known, tracked errors (Scripts/known-errors.txt) are left out of the count.
KNOWN_SKIPPED=$(python3 -I "$REPO_ROOT/Scripts/lib/filter-known-errors.py" "$OUT_DIR/app-errors.log" "$REPO_ROOT/Scripts/known-errors.txt" 2>/dev/null || echo 0)
ERR_COUNT=$(grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} ' "$OUT_DIR/app-errors.log")
echo "----  $ERR_COUNT new error-level log lines from OpenEmu, $KNOWN_SKIPPED known ones left out (full list: $OUT_DIR/app-errors.log)"
head -8 "$OUT_DIR/app-errors.log" | cut -c1-200

# Core-level failures (for example an unimplemented CPU instruction that stops the emulator).
# These come from the emulator core's own messages, not from OpenEmu's subsystems, so they need their own query.
/usr/bin/log show --start "$START_STAMP" --style compact \
  --predicate 'process == "OpenEmuHelperApp" AND (eventMessage CONTAINS "(Error)" OR eventMessage CONTAINS "opcode not implemented" OR eventMessage CONTAINS "emulator finished")' \
  2>/dev/null | grep -v "^Timestamp\|^Filtering" | sed -E 's/^[0-9-]+ ([0-9:.]+) +[A-Za-z]+ +OpenEmuHelperApp\[[0-9]+:[0-9a-f]+\] /\1 /' > "$OUT_DIR/core-errors.log"
if grep -q "opcode not implemented\|(Error)" "$OUT_DIR/core-errors.log"; then
  echo "FAIL  emulator core reported errors:"
  head -6 "$OUT_DIR/core-errors.log" | cut -c1-200
  FAILURES=1
else
  echo "PASS  no emulator core errors"
fi

# --game promises to write no saves. Prove it: this game's save states must be exactly as they were.
if [ -n "$GAME" ]; then
  if [ "$(saves_snapshot)" = "$SAVES_BEFORE" ]; then
    echo "PASS  no save state of \"$GAME_NAME\" changed"
  else
    echo "FAIL  save states of \"$GAME_NAME\" changed during the run (another OpenEmu session may have played it, or the no-autosave switch broke)"
    FAILURES=1
  fi
fi

if [ "$XC_STATUS" -ne 0 ]; then FAILURES=1; echo "FAIL  xcodebuild exited $XC_STATUS (log: $LOG)"; fi

echo "===================="
if [ "$FAILURES" -eq 0 ]; then echo "check.sh: ALL PASS"; else echo "check.sh: FAILED"; fi
echo "===================="
exit "$FAILURES"
