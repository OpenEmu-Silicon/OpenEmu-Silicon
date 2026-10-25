#!/usr/bin/env bash
# check.sh — Drive the real app with UI tests and collect screenshots, results and crash reports.
#
# Usage:
#   ./Scripts/check.sh                               # run every UI test (game test is skipped)
#   ./Scripts/check.sh --rom "/path/to/game.sfc"     # also load that ROM, check it draws and moves, quick save, screenshot, quit
#   ./Scripts/check.sh --test testPreferencesPanesAllOpen   # run one test by name
#
# The ROM is imported into the throwaway library; the ROM file itself is not modified or copied into the repo.
# Each test launches the Debug build against a throwaway empty library (see OpenEmuSmokeUITests).
# The tests click and type, so leave the mouse and keyboard alone while this runs (about 30 seconds).
# Output goes to $TMPDIR/openemu-check/<timestamp>/: result bundle, screenshots/, summary on stdout.
#
# Exit code is 0 only when every test passed and no new OpenEmu crash report appeared.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="$HOME/Builds/openemu/ui-tests"
OUT_DIR="${TMPDIR:-/tmp}/openemu-check/$(date +%Y%m%d-%H%M%S)"
RESULT="$OUT_DIR/result.xcresult"
LOG="$OUT_DIR/xcodebuild.log"
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"

if pgrep -x OpenEmu >/dev/null; then
  echo "FAIL  OpenEmu is running. Quit it first so the tests do not clobber your session." >&2
  exit 2
fi

mkdir -p "$OUT_DIR"
touch "$OUT_DIR/.start"

ONLY=()
while [ $# -gt 0 ]; do
  case "$1" in
    --rom)
      [ -f "${2:-}" ] || { echo "FAIL  --rom needs an existing file" >&2; exit 2; }
      # xcodebuild passes TEST_RUNNER_-prefixed variables to the test runner.
      export TEST_RUNNER_OE_TEST_ROM="$2"; shift 2 ;;
    --test) ONLY=(-only-testing:"OpenEmuUITests/OpenEmuSmokeUITests/${2:-}"); shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

XC_ARGS=(-workspace OpenEmu-metal.xcworkspace -scheme OpenEmuUITests -configuration Debug
         -destination 'platform=macOS,arch=arm64' -derivedDataPath "$BUILD_DIR")

echo "----  building UI tests"
xcodebuild build-for-testing "${XC_ARGS[@]}" > "$LOG" 2>&1
XC_STATUS=$?

# Re-sign the test runner with a stable local certificate so the macOS Accessibility grant survives rebuilds.
# Ad-hoc signatures change on every build, which silently revokes the grant (same cause as launch-debug.sh's
# Input Monitoring note). Uses the same certificate: "OpenEmu Debug", or OE_DEBUG_SIGN_IDENTITY.
RUNNER="$BUILD_DIR/Build/Products/Debug/OpenEmuUITests-Runner.app"
SIGN_NAME="${OE_DEBUG_SIGN_IDENTITY:-OpenEmu Debug}"
if [ "$XC_STATUS" -eq 0 ]; then
  if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$SIGN_NAME\""; then
    echo "----  signing UI test runner with \"$SIGN_NAME\""
    # The runner is signed without its entitlements on purpose: Xcode gives it the app sandbox, and once it
    # has a real signature macOS enforces that sandbox, so OpenEmu can no longer write into the runner's
    # temp folder where the tests put their libraries. The app under test keeps its entitlements.
    codesign --force --deep --sign "$SIGN_NAME" "$RUNNER" >> "$LOG" 2>&1 \
      || echo "WARN  signing the UI test runner failed; it stays ad-hoc signed and permissions may need re-granting" >&2
    codesign --force --deep --preserve-metadata=entitlements,requirements,flags,runtime \
      --sign "$SIGN_NAME" "$BUILD_DIR/Build/Products/Debug/OpenEmu.app" >> "$LOG" 2>&1 \
      || echo "WARN  signing OpenEmu.app failed; it stays ad-hoc signed and permissions may need re-granting" >&2
  else
    echo "WARN  no \"$SIGN_NAME\" certificate found; Accessibility will need re-granting after each rebuild" >&2
  fi

  echo "----  running UI tests"
  xcodebuild test-without-building "${XC_ARGS[@]}" -resultBundlePath "$RESULT" \
    ${ONLY[@]+"${ONLY[@]}"} >> "$LOG" 2>&1
  XC_STATUS=$?
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
ERR_COUNT=$(wc -l < "$OUT_DIR/app-errors.log" | tr -d ' ')
echo "----  $ERR_COUNT error-level log lines from OpenEmu (full list: $OUT_DIR/app-errors.log)"
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

if [ "$XC_STATUS" -ne 0 ]; then FAILURES=1; echo "FAIL  xcodebuild exited $XC_STATUS (log: $LOG)"; fi

echo "===================="
if [ "$FAILURES" -eq 0 ]; then echo "check.sh: ALL PASS"; else echo "check.sh: FAILED"; fi
echo "===================="
exit "$FAILURES"
