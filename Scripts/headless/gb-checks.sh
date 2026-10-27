#!/usr/bin/env bash
# gb-checks.sh — Headless proof that the Gambatte core loads, runs, takes input and round-trips save states.
#
# Usage: ./Scripts/headless/gb-checks.sh
#
# Uses the test ROM written by make-test-rom.py (made from scratch for this repo, no licensing issues).
# Exit code is 0 only when every check passed. Each failure says which behaviour broke.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/oe-gb-checks.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ROM="$WORK/oetest.gb"
FAILS=0

python3 "$HERE/make-test-rom.py" "$ROM" || { echo "FAIL  could not build the test ROM"; exit 1; }

run() { "$HERE/run.sh" Gambatte --rom "$ROM" "$@"; }
# frame_hash <output> <frame> <video|audio>
frame_hash() { grep "^frame $2 " <<<"$1" | sed -E "s/.* $3=([^ ]+).*/\1/"; }
check() { # check <name> <condition result 0/1>
  if [ "$2" -eq 0 ]; then echo "pass  $1"; else echo "FAIL  $1"; FAILS=$((FAILS + 1)); fi
}

echo "----  baseline run (builds the core the first time)"
BASE=$(run --frames 120 --hash-at 30 --hash-at 31 --hash-at 50 --hash-at 62 --hash-at 80 --hash-at 120 --audio) \
  || { echo "FAIL  baseline run did not finish:"; echo "$BASE"; exit 1; }
grep -q "^rom-loaded" <<<"$BASE"; check "ROM loads" $?
grep -q "^done frames=120" <<<"$BASE"; check "120 frames run to the end" $?

V30=$(frame_hash "$BASE" 30 video); V31=$(frame_hash "$BASE" 31 video)
[ -n "$V30" ] && [ "$V30" != "$V31" ]; check "picture changes between frames" $?

export OE_HEADLESS_NO_BUILD=1
AGAIN=$(run --frames 120 --hash-at 30 --hash-at 31 --hash-at 50 --hash-at 62 --hash-at 80 --hash-at 120 --audio)
[ "$BASE" = "$AGAIN" ]; check "two identical runs give identical picture and sound" $?

# Hold A (button 4) from frame 61 and let go at frame 70.
PRESS=$(run --frames 120 --hash-at 62 --hash-at 80 --input 61:didPushGBButton:4 --input 70:didReleaseGBButton:4)
[ "$(frame_hash "$PRESS" 62 video)" != "$(frame_hash "$BASE" 62 video)" ]; check "pressing A changes the picture" $?
[ "$(frame_hash "$PRESS" 80 video)" = "$(frame_hash "$BASE" 80 video)" ]; check "letting go of A restores the picture" $?

# Start (button 6) is latched by the ROM: after letting go, the picture must stay different from the baseline.
LATCH=$(run --frames 120 --hash-at 120 --input 61:didPushGBButton:6 --input 70:didReleaseGBButton:6)
[ "$(frame_hash "$LATCH" 120 video)" != "$(frame_hash "$BASE" 120 video)" ]; check "Start stays latched after release" $?

# Right on the direction pad (button 3) moves the picture differently from A.
RIGHT=$(run --frames 62 --hash-at 62 --input 61:didPushGBButton:3)
[ "$(frame_hash "$RIGHT" 62 video)" != "$(frame_hash "$BASE" 62 video)" ] \
  && [ "$(frame_hash "$RIGHT" 62 video)" != "$(frame_hash "$PRESS" 62 video)" ]; check "direction pad and A give different pictures" $?

# Save at frame 50, keep going, load at frame 100: the next frame must match what an uninterrupted run drew at frame 50.
STATE=$(run --frames 100 --hash-at 100 --save-state-at 50 --load-state-at 100)
grep -q "^state-saved" <<<"$STATE" && grep -q "^state-loaded" <<<"$STATE"; check "save state and load state both succeed" $?
[ "$(frame_hash "$STATE" 100 video)" = "$(frame_hash "$BASE" 50 video)" ]; check "loading a state brings back the saved picture" $?

echo ""
if [ "$FAILS" -eq 0 ]; then echo "ALL GB HEADLESS CHECKS PASSED"; else echo "$FAILS CHECK(S) FAILED"; fi
exit $((FAILS > 0))
