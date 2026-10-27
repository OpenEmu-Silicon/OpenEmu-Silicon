#!/usr/bin/env bash
# unit-tests.sh — Run the OpenEmuTests unit target (the app's own tests).
#
# Usage:
#   ./Scripts/unit-tests.sh
#
# Builds the OpenEmu scheme if needed, then runs `xcodebuild test`. Output goes to a temp log; only the
# tail is printed on failure. Exit code is 0 only when the tests passed.
#
# With the stable "OpenEmu Debug" certificate (Scripts/setup-debug-signing.sh) the test app keeps the same
# signature across rebuilds, so macOS asks for folder access (Documents) once instead of blocking every run.
# SDK tests (OpenEmuBase) are separate: see Scripts/prove.sh.

set -uo pipefail

# A truncated consumer (`| head`) must not kill the script and orphan xcodebuild, which would leave
# build.db locked for the next run.
trap '' PIPE
trap 'pkill -TERM -P $$ 2>/dev/null || true' EXIT

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "----  running OpenEmuTests (xcodebuild test)"
TEST_LOG=$(mktemp -t oe_unit_tests.XXXXXX)

SIGN_ARGS=()
if "$REPO_ROOT/Scripts/setup-debug-signing.sh" --check >/dev/null 2>&1; then
  SIGN_ARGS=(CODE_SIGN_IDENTITY="${OE_DEBUG_SIGN_IDENTITY:-OpenEmu Debug}")
fi

if xcodebuild test \
     -workspace OpenEmu-metal.xcworkspace \
     -scheme OpenEmu \
     -configuration Debug \
     -destination 'platform=macOS,arch=arm64' \
     -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
     ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
     > "$TEST_LOG" 2>&1; then
  PASS_COUNT=$(grep -c 'passed' "$TEST_LOG" 2>/dev/null || true)
  echo "PASS  OpenEmuTests ($PASS_COUNT tests passed)"
  exit 0
fi

echo "FAIL  OpenEmuTests — see $TEST_LOG (last 30 lines below)"
tail -30 "$TEST_LOG"
exit 1
