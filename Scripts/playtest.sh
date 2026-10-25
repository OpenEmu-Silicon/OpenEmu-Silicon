#!/usr/bin/env bash
# playtest.sh — Play a game in the real app without anyone at the keyboard, then report what happened.
#
# Usage:
#   ./Scripts/playtest.sh --game "Super Mario 64" [--seconds 30] [--keys "start,up,ok,ok"]
#   ./Scripts/playtest.sh --rom <file> [--seconds 30] [--keys "return,a,right"]    # a file outside the library
#
# --game finds the game in your real OpenEmu library by name (read-only lookup) and plays it from there, using
# your real library, settings and saved key bindings. Actions in --keys (up down left right start select ok cancel
# x y l r z) are turned into the keys you have saved for that game's system. OpenEmu must be closed.
# A run adds the usual traces of playing a game: play count and last-played time, and an auto save state when
# the game quits. It never deletes anything, and it skips Quick Save unless you add --save.
# --rom uses a throwaway library instead and takes literal key names.
#
# What it does: opens the game, types the keys in order (one about every two seconds), and screenshots the
# game window after each. Then it reads the app log for the run and prints a report:
#   - frame pacing: frames per second per 3-second window, and the longest gap between two frames
#   - audio: how many times the sound buffer overflowed
#   - errors and faults logged by the app and the game helper
#   - crash reports
#   - where the screenshots are (open them to see what the game looked like)
# The tests click and type, so leave the mouse and keyboard alone while it runs.
# Keyboard input here reaches the game as real key events; it does not need Input Monitoring permission.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ROM=""; GAME=""; SAVE=0; SECONDS_TO_PLAY=30; KEYS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rom) ROM="${2:-}"; shift 2 ;;
    --game) GAME="${2:-}"; shift 2 ;;
    --save) SAVE=1; shift ;;
    --seconds) SECONDS_TO_PLAY="${2:-}"; shift 2 ;;
    --keys) KEYS="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ -n "$GAME" ]; then
  MATCH="$(python3 Scripts/playtest/library.py find "$GAME")" || exit 2
  SYSTEM="$(echo "$MATCH" | cut -f1)"; TITLE="$(echo "$MATCH" | cut -f2)"; ROM="$(echo "$MATCH" | cut -f3)"
  echo "game: $TITLE ($SYSTEM)"
  if [ -n "$KEYS" ]; then
    KEYS="$(python3 Scripts/playtest/library.py keys "$SYSTEM" "$KEYS")" || exit 2
    echo "keys (from your saved bindings): $KEYS"
  fi
  export TEST_RUNNER_OE_USE_REAL_LIBRARY=1
  [ "$SAVE" -eq 1 ] && export TEST_RUNNER_OE_PLAYTEST_SAVE=1
fi
[ -f "$ROM" ] || { echo "FAIL  need --game <name in your library> or --rom <existing file>" >&2; exit 2; }

export TEST_RUNNER_OE_PLAYTEST_SECONDS="$SECONDS_TO_PLAY"
export TEST_RUNNER_OE_PLAYTEST_KEYS="$KEYS"

START_MARK="$(mktemp "${TMPDIR:-/tmp}/oe-playtest.XXXXXX")"
RUN_OUT="$(./Scripts/check.sh --rom "$ROM" --test testPlaytest 2>&1)"
STATUS=$?
echo "$RUN_OUT" | grep -aE "^(PASS|FAIL)|error:" | cut -c1-220

SHOTS="$(echo "$RUN_OUT" | sed -n 's/^.*screenshots: \(.*\) (names in manifest.json)$/\1/p' | tail -1)"
START_TIME="$(date -r "$(stat -f %m "$START_MARK")" '+%Y-%m-%d %H:%M:%S')"
LOG="$(log show --start "$START_TIME" --style compact --predicate 'subsystem BEGINSWITH "org.openemu"' 2>/dev/null)"
rm -f "$START_MARK"

echo ""
echo "==== playtest report: $(basename "$ROM"), ${SECONDS_TO_PLAY}s, keys: ${KEYS:-none}"
LOG_TEXT="$LOG" /usr/bin/python3 -I - <<'PY'
import os, re
log = os.environ["LOG_TEXT"].splitlines()
stats = [re.search(r"\((\d+\.?\d*) fps\), worst gap (\d+\.?\d*) ms", l) for l in log if "frame stats" in l]
stats = [(float(m.group(1)), float(m.group(2))) for m in stats if m]
if stats:
    fps = [f for f, _ in stats]
    gaps = [g for _, g in stats]
    print("frame pacing: %d windows, fps min %.1f / avg %.1f / max %.1f, longest gap between frames %.1f ms"
          % (len(stats), min(fps), sum(fps) / len(fps), max(fps), max(gaps)))
else:
    print("frame pacing: no 'frame stats' lines found (the game may not have reached the running state)")
overruns = sum(1 for l in log if "Tried to write" in l)
print("audio: %d buffer-full warnings" % overruns)
problems = [l for l in log if re.search(r"\s(E|Fa)\s", l) and "Tried to write" not in l and "CredentialStore" not in l]
print("errors/faults (excluding audio and credential-store noise): %d" % len(problems))
for l in problems[:10]:
    print("   ", l[:230])
for l in log:
    if "Input Monitoring access" in l:
        print("input permission:", l.split("]")[-1].strip()); break
PY
CRASHES=$(find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -name 'OpenEmu*.ips' -newermt "$START_TIME" 2>/dev/null | wc -l | tr -d ' ')
echo "crash reports: $CRASHES"
[ -n "$SHOTS" ] && echo "screenshots and manifest: $SHOTS   (files are named by UUID; manifest.json maps each to playtest-<seconds>s-<key>)"
echo ""
if [ "$STATUS" -eq 0 ] && [ "$CRASHES" = "0" ]; then echo "PLAYTEST COMPLETED: game loaded, ran, accepted keys and quit cleanly."; exit 0; fi
echo "PLAYTEST PROBLEM: see above."; exit 1
