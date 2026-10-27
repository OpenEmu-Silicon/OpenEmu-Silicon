#!/usr/bin/env bash
# prove.sh — Run every automated check that can see a change working, then say PROVEN or NOT PROVEN.
#
# Usage:
#   ./Scripts/prove.sh                         # build + unit tests + headless Game Boy checks + crash scan
#   ./Scripts/prove.sh --all                   # run every step even when the diff against main does not touch its area
#   ./Scripts/prove.sh --ui                    # also drive the real app (check.sh); needs OpenEmu closed
#   ./Scripts/prove.sh --ui --rom <file>       # ...and load that ROM in the UI test (quick save, screenshot, quit)
#   ./Scripts/prove.sh --game "<name>"          # ...or play a game from your real library by name (implies --ui; writes no saves)
#   ./Scripts/prove.sh --core <Name> --rom <file> [--frames N]
#                                              # also run that core headless on that ROM and require it to finish
#
# PROVEN means every step that ran passed and no new crash report appeared. It does NOT mean everything was
# covered: the steps that did not run, and the things no script can see (real controllers, Bluetooth,
# macOS permission prompts), are listed at the end so nobody mistakes "proven here" for "proven everywhere".
#
# Each step writes its full output to $TMPDIR/openemu-prove/<timestamp>/<step>.log; only failures are echoed.
# Steps run in this order and the script keeps going after a failure so one run shows everything that is wrong.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

RUN_UI=0
RUN_ALL=0
ROM=""
GAME=""
CORE=""
FRAMES=600
while [ $# -gt 0 ]; do
  case "$1" in
    --ui) RUN_UI=1; shift ;;
    --all) RUN_ALL=1; shift ;;
    --game) GAME="${2:?--game needs the name of a game in your library}"; RUN_UI=1; shift 2 ;;
    --rom) [ -f "${2:-}" ] || { echo "FAIL  --rom needs an existing file" >&2; exit 2; }; ROM="$2"; shift 2 ;;
    --core) CORE="${2:?--core needs a core name}"; shift 2 ;;
    --frames) FRAMES="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -z "$GAME" ] || [ -z "$ROM" ] || { echo "FAIL  use --game or --rom, not both" >&2; exit 2; }
if [ -n "$CORE" ] && [ -z "$ROM" ]; then echo "FAIL  --core needs --rom" >&2; exit 2; fi

OUT="${TMPDIR:-/tmp}/openemu-prove/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
touch "$OUT/.start"
FAILS=0
RAN=()

# Files this branch changes against main, plus uncommitted work. A step whose area has no changed file is skipped
# (and listed as skipped) unless --all is given or main cannot be found.
BASE="$(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD main 2>/dev/null || true)"
if [ -n "$BASE" ] && [ "$RUN_ALL" -eq 0 ]; then
  CHANGED="$( { git diff --name-only "$BASE"; git ls-files --others --exclude-standard; } | sort -u)"
else
  CHANGED=""
fi
touches() { # touches <path-prefix-regex>: true when selecting is off, or a changed file matches
  [ -z "$CHANGED" ] && return 0
  printf '%s\n' "$CHANGED" | grep -qE "$1"
}
SKIPPED=("OpenEmuKit tests (do not compile in this workspace: OpenEmuKitPrivate module cannot be resolved)")

step() { # step <name> <command...>
  local name="$1"; shift
  local log="$OUT/$name.log"
  printf '----  %s\n' "$name"
  if "$@" > "$log" 2>&1; then
    echo "pass  $name"
    RAN+=("$name")
  else
    echo "FAIL  $name   (full log: $log)"
    tail -25 "$log" | sed 's/^/        /'
    if grep -aq "exceeded execution time allowance" "$log"; then
      echo "        hint: a test hung. On this Mac that is usually macOS waiting for you to allow OpenEmu to read your"
      echo "        Documents folder (tests read repo files). It asks again after every rebuild unless the debug app has a"
      echo "        stable signature: run ./Scripts/setup-debug-signing.sh once, then click Allow once."
    fi
    FAILS=$((FAILS + 1))
    RAN+=("$name (FAILED)")
  fi
}

echo "branch: $(git rev-parse --abbrev-ref HEAD)   commit: $(git rev-parse --short HEAD)   dirty files: $(git status --porcelain | wc -l | tr -d ' ')"
echo "output: $OUT"
echo ""

# 1. Build and run OpenEmuTests (the app's own unit tests).
step "app-build-and-unit-tests" ./Scripts/unit-tests.sh

# 2. SDK tests (includes the RetroAchievements hardcore regression suite).
step "sdk-unit-tests" xcodebuild test \
  -project OpenEmu-SDK/OpenEmu-SDK.xcodeproj -scheme OpenEmuBase \
  -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# (OpenEmuKitTests does not compile in this workspace today: 'OpenEmuKitPrivate' cannot be resolved. Tracked as
# a known gap, so it is not run here until that is fixed.)

# 4. DualSense report decoding (plain C, sanitizers on), same as CI.
dualsense() {
  xcrun clang -std=c11 -UNDEBUG -Wall -Wextra -Werror -fsanitize=address,undefined \
    OpenEmu-SDK/OpenEmuSystemTests/OEDualSenseBluetoothReportTests.c -lz -o "$OUT/dualsense-report-tests" \
    && "$OUT/dualsense-report-tests"
}
step "dualsense-decoding" dualsense

# 5. Headless: the Gambatte core loads, draws, takes button presses and round-trips save states, with no window.
if touches '^(OpenEmu-SDK/|OpenEmuKit/|Gambatte/|Scripts/headless/|Scripts/prove\.sh)'; then
  step "headless-gameboy" ./Scripts/headless/gb-checks.sh
else
  SKIPPED+=("headless Game Boy checks (no change under OpenEmu-SDK, OpenEmuKit, Gambatte or Scripts/headless; --all runs them)")
fi

# 6. Optional: any core on any ROM, headless. Passing means it loaded and ran every frame without crashing.
if [ -n "$CORE" ]; then
  step "headless-$CORE" ./Scripts/headless/run.sh "$CORE" --rom "$ROM" --frames "$FRAMES" --audio
else
  SKIPPED+=("headless run of a specific core (give --core <Name> --rom <file>)")
fi

# 7. Optional: drive the real app window.
if [ "$RUN_UI" -eq 1 ]; then
  if pgrep -x OpenEmu > /dev/null; then
    echo "FAIL  ui-tests   (OpenEmu is running; quit it first so the tests do not clobber your session)"
    FAILS=$((FAILS + 1))
    RAN+=("ui-tests (FAILED: OpenEmu was running)")
  elif [ -z "$GAME" ] && ! touches '^(OpenEmu/|OpenEmuKit/|OpenEmu-SDK/|Scripts/check\.sh|Scripts/lib/)'; then
    SKIPPED+=("UI tests (no change under OpenEmu, OpenEmuKit or OpenEmu-SDK; --all runs them)")
  elif [ -n "$GAME" ]; then
    step "ui-tests" ./Scripts/check.sh --game "$GAME"
  elif [ -n "$ROM" ]; then
    step "ui-tests" ./Scripts/check.sh --rom "$ROM"
  else
    step "ui-tests" ./Scripts/check.sh
  fi
else
  SKIPPED+=("UI tests that drive the real app window (add --ui)")
fi

# 8. Anything that crashed while the steps above ran.
printf '----  crash-scan\n'
if ./Scripts/collect-diagnostics.sh --since-file "$OUT/.start" --out "$OUT/diagnostics" > "$OUT/crash-scan.log" 2>&1; then
  echo "pass  crash-scan (no new crash reports)"
  RAN+=("crash-scan")
else
  echo "FAIL  crash-scan   (full log: $OUT/crash-scan.log)"
  grep -A16 "^---- " "$OUT/crash-scan.log" | head -40 | sed 's/^/        /'
  FAILS=$((FAILS + 1))
  RAN+=("crash-scan (FAILED)")
fi

echo ""
echo "ran:"
for r in "${RAN[@]}"; do echo "  - $r"; done
echo "did not run:"
if [ ${#SKIPPED[@]} -gt 0 ]; then for s in "${SKIPPED[@]}"; do echo "  - $s"; done; else echo "  (nothing skipped)"; fi
echo "cannot be checked by a script:"
echo "  - real controllers and Bluetooth pairing"
echo "  - macOS permission prompts (Input Monitoring, Bluetooth)"
echo "  - how a game feels to play (timing, audio crackle)"
if ! ./Scripts/setup-debug-signing.sh --check > /dev/null 2>&1; then
  echo ""
  echo "note: no \"OpenEmu Debug\" signing certificate on this Mac, so keyboard input in a debug build loses its"
  echo "      Input Monitoring grant on every rebuild. One-time fix, run by you: ./Scripts/setup-debug-signing.sh"
fi
echo ""
if [ "$FAILS" -eq 0 ]; then
  echo "PROVEN: every step that ran passed, and no new crash reports appeared."
  exit 0
fi
echo "NOT PROVEN: $FAILS step(s) failed. Logs are in $OUT"
exit 1
