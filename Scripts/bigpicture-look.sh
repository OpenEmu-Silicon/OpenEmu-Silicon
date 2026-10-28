#!/usr/bin/env bash
# bigpicture-look.sh — Open big picture on your real library, walk through it, and save screenshots.
#
# Usage:
#   ./Scripts/bigpicture-look.sh                       # a standard tour: home, shelves, sidebar, library, filters
#   ./Scripts/bigpicture-look.sh --steps "shot:home,play:10,shot:returned"   # launch the featured game and come back
#   ./Scripts/bigpicture-look.sh --steps "shot:a,down,shot:b,select,shot:c"
#   ./Scripts/bigpicture-look.sh --no-build
#   ./Scripts/bigpicture-look.sh --app-arg -OEBigPictureRediscoverDays 0   # pass a launch argument for this run only
#   ./Scripts/bigpicture-look.sh --no-steamgriddb      # see the fallbacks a user without a SteamGridDB key gets
#
# Steps are controller actions (up down left right select back menu) plus "shot:<name>" to save a picture of the
# screen, "wait:<seconds>", and "play:<seconds>" to choose what is highlighted (Resume on the hero), let that real game
# run, save what it drew, close it and check big picture comes back. Closing skips the auto save, so nothing is written
# to your library saves (play count and last-played time do change). Nothing is imported. OpenEmu must be closed. The debug app has a built-in driver (OpenEmu/PlaytestDriver.swift) and no
# UI-test runner is involved, so there are no permission prompts. Pictures are in the folder it prints.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=lib/harness.sh
. "$REPO_ROOT/Scripts/lib/harness.sh"
harness_ensure_stubs "$REPO_ROOT"

STEPS="shot:home,down,shot:shelf,up,up,right,right,shot:tabbar,left,left,left,right,right,right,right,shot:library,down,select,shot:menu,select,shot:filtered"
NO_BUILD=0
NO_SGDB=0
EXTRA_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --steps) STEPS="${2:-}"; shift 2 ;;
    --no-build) NO_BUILD=1; shift ;;
    --no-steamgriddb) NO_SGDB=1; shift ;;
    --app-arg) EXTRA_ARGS+=("${2:-}" "${3:-}"); shift 3 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

harness_take_lock || exit 2
trap harness_release_lock EXIT
if pgrep -x OpenEmu > /dev/null; then
  echo "FAIL  OpenEmu is running. Quit it first: it shares the library with this run." >&2
  harness_describe_running >&2
  exit 2
fi

OUT="${TMPDIR:-/tmp}/openemu-bigpicture/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
BUILD="$(harness_build_dir)"
trap 'harness_kill_debug_app "$BUILD"; harness_release_lock' EXIT
APP="$BUILD/Build/Products/Debug/OpenEmu.app"

if [ "$NO_BUILD" -eq 1 ] && [ -d "$APP" ]; then
  echo "----  reusing the existing build ($BUILD)"
elif ! { echo "----  building the debug app"; xcodebuild build -workspace OpenEmu-metal.xcworkspace -scheme OpenEmu -configuration Debug \
     -destination 'platform=macOS,arch=arm64' -derivedDataPath "$BUILD" > "$OUT/build.log" 2>&1; }; then
  echo "FAIL  build failed, see $OUT/build.log"; grep "error:" "$OUT/build.log" | head -10; exit 1
fi

STEPS="$STEPS" OUTDIR="$OUT" python3 - <<'PY'
import json, os
steps = [s.strip() for s in os.environ["STEPS"].split(",") if s.strip()]
plan = {"romPath": "", "seconds": 0, "steps": [], "outputDirectory": os.environ["OUTDIR"], "bigPicture": steps}
json.dump(plan, open(os.path.join(os.environ["OUTDIR"], "plan.json"), "w"), indent=2)
PY

echo "----  walking through big picture (${STEPS})"
APP_ARGS=(-OEPlaytestPlan "$OUT/plan.json" -OESkipDiscGuideMessageKey 1 -OESkipAutosaveOnStop 1 -stopEmulationWithoutConfirmation 1 -loadAutosaveDialogChoice 1)
[ "$NO_SGDB" -eq 1 ] && APP_ARGS+=(-OEBigPictureDisableSteamGridDB 1)
[ "${#EXTRA_ARGS[@]}" -gt 0 ] && APP_ARGS+=("${EXTRA_ARGS[@]}")
/usr/bin/open -n -W --stdout "$OUT/app.log" --stderr "$OUT/app.log" "$APP" --args "${APP_ARGS[@]}" &
LAUNCHER_PID=$!
WAITED=0
while kill -0 "$LAUNCHER_PID" 2>/dev/null && [ "$WAITED" -lt 180 ]; do sleep 2; WAITED=$(( WAITED + 2 )); done
if kill -0 "$LAUNCHER_PID" 2>/dev/null; then
  echo "FAIL  timed out"; harness_kill_debug_app "$BUILD"; exit 1
fi

if [ -f "$OUT/result.json" ]; then
  python3 -c "import json,sys; r=json.load(open(sys.argv[1])); print(r['status'], '-', r['message'])" "$OUT/result.json"
else
  echo "FAIL  no result.json; the app did not finish (see $OUT/app.log)"; exit 1
fi
echo "pictures: $OUT"
ls "$OUT"/bp-*.png 2>/dev/null
