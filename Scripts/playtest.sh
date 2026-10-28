#!/usr/bin/env bash
# playtest.sh — Play a game in the real app without anyone at the keyboard, then report what happened.
#
# Usage:
#   ./Scripts/playtest.sh --game "Super Mario 64" [--seconds 30] [--keys "start,ok,ok,up"] [--restart] [--shot-every 2]
#
# --game finds the game in your real OpenEmu library by name (a read-only lookup) and plays it from there,
# with your real library, settings and saved key bindings. Actions in --keys (up down left right start select
# ok cancel x y l r z) become the keys you have saved for that game's system; a plain key name such as "k" or
# "return" is sent as is. One key goes in about every two seconds. OpenEmu must be closed.
#
# How it works: the debug app has a built-in driver (OpenEmu/PlaytestDriver.swift, debug builds only). This script
# builds the app, starts it with a plan file, and the driver opens the game, sends the keys through the same path a
# real keyboard uses, saves screenshots of what the core rendered, then closes the game and quits. There is no UI-test
# runner, so no macOS permission prompts, and nothing takes over your mouse or keyboard.
#
# A run leaves the usual traces of playing in the library (play count, last-played time) but writes no saves: it never
# uses Quick Save, closing the game skips the auto save state (debug builds only, -OESkipAutosaveOnStop), and the backup
# check only reads. It never deletes anything. By default it answers "continue your last game?" with Resume;
# --shot-every N takes a screenshot every N seconds (default 2). A screenshot runs on the game's own thread (the first
# one also builds a Core Image context), so it holds the game up for a moment: the frame pacing line is only trustworthy
# with sparse screenshots, for example --shot-every 60. Frame pacing from a default run can show stalls of several
# seconds that the game itself did not have.
# --restart answers Restart (the game boots fresh; the auto save state is not loaded). --no-backup switches the save
# backup folder off for this run, which also avoids the save-sync prompts. The app is started through LaunchServices (`open`), the way a person starts it, so macOS
# treats it as its own program (iCloud Drive and other privacy permissions apply to it, not to the Claude app that ran
# this script). --direct runs the binary straight from this script instead, for comparison.
#
# Report: frame pacing and audio buffer levels (from the core's own log lines), errors and crashes, and for the
# picture how many screenshots were blank and how many differed from the one before. Screenshots and result.json
# are in the output folder it prints.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=lib/harness.sh
. "$REPO_ROOT/Scripts/lib/harness.sh"
harness_ensure_stubs "$REPO_ROOT"

GAME=""; SHOT_EVERY=2; AUDIT_RESTORE=0; SLOW_ICLOUD=0; SECONDS_TO_PLAY=30; KEYS=""; RESUME=1; LAUNCH=open; NO_BACKUP=0; NO_BUILD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --game) GAME="${2:-}"; shift 2 ;;
    --seconds) SECONDS_TO_PLAY="${2:-}"; shift 2 ;;
    --shot-every) SHOT_EVERY="${2:-}"; shift 2 ;;
    --keys) KEYS="${2:-}"; shift 2 ;;
    --restart) RESUME=0; shift ;;
    --direct) LAUNCH=direct; shift ;;
    --no-backup) NO_BACKUP=1; shift ;;
    --audit-restore) AUDIT_RESTORE=1; shift ;;
    --slow-icloud) SLOW_ICLOUD="${2:-}"; shift 2 ;;
    --no-build) NO_BUILD=1; shift ;;
    -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$GAME" ] || { echo "FAIL  need --game <name of a game in your library>" >&2; exit 2; }
harness_take_lock || exit 2
trap harness_release_lock EXIT
if pgrep -x OpenEmu > /dev/null; then
  echo "FAIL  OpenEmu is running. Quit it first: it shares the library with the play test." >&2
  harness_describe_running >&2
  exit 2
fi

MATCH="$(python3 Scripts/playtest/library.py find "$GAME")" || exit 2
SYSTEM="$(echo "$MATCH" | cut -f1)"; TITLE="$(echo "$MATCH" | cut -f2)"; ROM="$(echo "$MATCH" | cut -f3)"
echo "game: $TITLE ($SYSTEM)"
KEYLIST=""
if [ -n "$KEYS" ]; then
  # Actions like "start" become saved keys; anything that is not an action is sent as a literal key.
  KEYLIST="$(python3 - "$SYSTEM" "$KEYS" <<'PY'
import subprocess, sys
system, keys = sys.argv[1], [k.strip() for k in sys.argv[2].split(",") if k.strip()]
actions = {"up","down","left","right","start","select","ok","cancel","x","y","l","r","z"}
out = []
for k in keys:
    if k in actions:
        r = subprocess.run(["python3", "Scripts/playtest/library.py", "keys", system, k], capture_output=True, text=True)
        if r.returncode != 0: sys.exit(r.stderr.strip() or "cannot resolve action " + k)
        out.append(r.stdout.strip())
    else:
        out.append(k)
print(",".join(out))
PY
)" || { echo "FAIL  $KEYLIST" >&2; exit 2; }
  echo "keys (from your saved bindings): $KEYLIST"
fi

OUT="${TMPDIR:-/tmp}/openemu-playtest/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
# One build folder shared with check.sh, so a single build serves both and permissions persist.
# OE_BUILD_DIR (or the older OE_PLAYTEST_BUILD) overrides it.
BUILD="$(harness_build_dir)"
trap 'harness_kill_debug_app "$BUILD"; harness_release_lock' EXIT
APP="$BUILD/Build/Products/Debug/OpenEmu.app"

if [ "$NO_BUILD" -eq 1 ] && [ -d "$APP" ]; then
  echo "----  reusing the existing build ($BUILD)"
elif ! { echo "----  building the debug app"; xcodebuild build -workspace OpenEmu-metal.xcworkspace -scheme OpenEmu -configuration Debug \
     -destination 'platform=macOS,arch=arm64' -derivedDataPath "$BUILD" > "$OUT/build.log" 2>&1; }; then
  echo "FAIL  build failed, see $OUT/build.log"; tail -15 "$OUT/build.log"; exit 1
fi

KEYLIST="$KEYLIST" ROM="$ROM" SECS="$SECONDS_TO_PLAY" SHOT_EVERY="$SHOT_EVERY" OUTDIR="$OUT" AUDIT_RESTORE="$AUDIT_RESTORE" python3 - <<'PY'
import json, os
keys = [k for k in os.environ["KEYLIST"].split(",") if k]
plan = {"romPath": os.environ["ROM"], "seconds": float(os.environ["SECS"]), "screenshotEvery": float(os.environ["SHOT_EVERY"]),
        "outputDirectory": os.environ["OUTDIR"], "auditRestore": os.environ["AUDIT_RESTORE"] == "1",
        "steps": [{"at": 2.0 + 2.0 * i, "key": k} for i, k in enumerate(keys)]}
json.dump(plan, open(os.path.join(os.environ["OUTDIR"], "plan.json"), "w"), indent=2)
PY

START_MARK="$OUT/.start"; touch "$START_MARK"
START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
echo "----  playing for ${SECONDS_TO_PLAY}s"
# OESkipDiscGuideMessageKey: the library shows "Have you read the guide?" whenever it opens on a disc-based system
# (the sidebar remembers the last one used), which would block the run. Launch arguments are never saved to preferences.
APP_ARGS=(-OEPlaytestPlan "$OUT/plan.json" -loadAutosaveDialogChoice "$RESUME" -stopEmulationWithoutConfirmation 1
          -OESkipDiscGuideMessageKey 1 -OESkipAutosaveOnStop 1)
# --no-backup turns the save backup folder off for this run only (a launch argument is never saved to preferences).
[ "$NO_BACKUP" -eq 1 ] && APP_ARGS+=(-OEBackupFolderPath "")
# --slow-icloud MS makes every backup folder listing and copy take MS longer (debug builds), like a slow iCloud Drive.
[ "$SLOW_ICLOUD" -gt 0 ] 2>/dev/null && APP_ARGS+=(-OEBackupSimulateLatencyMs "$SLOW_ICLOUD")
if [ "$LAUNCH" = "direct" ]; then
  "$APP/Contents/MacOS/OpenEmu" "${APP_ARGS[@]}" > "$OUT/app.log" 2>&1 &
else
  /usr/bin/open -n -W --stdout "$OUT/app.log" --stderr "$OUT/app.log" "$APP" --args "${APP_ARGS[@]}" &
fi
LAUNCHER_PID=$!
LIMIT=$(( SECONDS_TO_PLAY + 180 )); WAITED=0
while kill -0 "$LAUNCHER_PID" 2>/dev/null && [ "$WAITED" -lt "$LIMIT" ]; do sleep 2; WAITED=$(( WAITED + 2 )); done
TIMED_OUT=0
if kill -0 "$LAUNCHER_PID" 2>/dev/null; then
  TIMED_OUT=1
  harness_kill_debug_app "$BUILD"
fi

LOG="$(/usr/bin/log show --start "$START_TIME" --style compact --info --predicate 'subsystem BEGINSWITH "org.openemu"' 2>/dev/null)"
CRASHES=$(find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -name 'OpenEmu*.ips' -newer "$START_MARK" 2>/dev/null | wc -l | tr -d ' ')

echo ""
echo "==== playtest report: $TITLE, ${SECONDS_TO_PLAY}s, keys: ${KEYLIST:-none}"
LOG_TEXT="$LOG" OUTDIR="$OUT" TIMED_OUT="$TIMED_OUT" CRASHES="$CRASHES" /usr/bin/python3 -I - <<'PY'
import json, os, re
log = os.environ["LOG_TEXT"].splitlines()
out = os.environ["OUTDIR"]
ok = True

# What the driver did
try:
    result = json.load(open(os.path.join(out, "result.json")))
except Exception:
    result = None
if result is None:
    print("driver: no result.json. The app did not finish the play test%s." % (" (timed out)" if os.environ["TIMED_OUT"] == "1" else ""))
    ok = False
else:
    print("driver: %s, %s. Played %.0fs, sent keys: %s" % (result["status"], result["message"], result["secondsPlayed"], ", ".join(result["keysSent"]) or "none"))
    if result["status"] != "ok": ok = False
    for line in result.get("backupAudit", []): print("backup audit: " + line)
    stall = result.get("longestMainThreadStallMs")
    if stall is not None:
        print("main thread: longest stall %d ms%s" % (stall, "" if stall <= 3000 else "  <-- the app would have shown the spinning wheel"))
        if stall > 3000: ok = False
    opening = [re.sub(r"^.*\[org.openemu.OpenEmu:core\]\s*", "", l) for l in log if "] Opening '" in l]
    if opening: print("start: " + opening[-1])
    shots = result["shots"]
    blank = sum(1 for s in shots if s["blank"]); changes = sum(1 for s in shots if s["changedFromPrevious"])
    src = [s["sourceBlank"] for s in shots if s.get("sourceBlank") is not None]
    print("picture: %d screenshots, %d blank after the shader chain, picture changed %d times between screenshots" % (len(shots), blank, changes))
    if src:
        print("capture stages: core picture before the shader chain blank in %d of %d; after the shader chain blank in %d of %d"
              % (sum(1 for b in src if b), len(src), blank, len(shots)))
    rendering = re.findall(r"this core renders with (\w+)", "\n".join(log))
    rendering = rendering[-1] if rendering else "unknown"
    print("core rendering type: %s" % rendering)
    for l in [l for l in log if "capture source texture" in l or "capture output source texture" in l][:2]:
        print("   " + re.sub(r"^.*\[org.openemu.OpenEmuKit:capture\]\s*", "", l)[:200])
    if shots and blank == len(shots):
        if rendering == "metal2":
            print("NOTE: every screenshot was blank, but this core renders with Metal 2 and the capture may be unreliable for it.")
            print("      A blank result here does NOT show the game drew nothing. Check the window yourself or the frame rate and audio above.")
        else:
            print("PROBLEM: every screenshot was blank. The game may have drawn nothing.")
            ok = False
    elif shots and blank > len(shots) // 2:
        print("NOTE: most screenshots were blank%s." % (" (Metal 2 core: the capture may be unreliable)" if rendering == "metal2" else ""))

# Frame pacing and audio, from the core's own log lines
stats = [re.search(r"\((\d+\.?\d*) fps\), worst gap (\d+\.?\d*) ms", l) for l in log if "frame stats" in l]
stats = [(float(m.group(1)), float(m.group(2))) for m in stats if m]
if stats:
    fps = [f for f, _ in stats]; gaps = [g for _, g in stats]
    print("frame pacing: %d windows of 3s, fps min %.1f / avg %.1f / max %.1f, longest gap between frames %.1f ms"
          % (len(stats), min(fps), sum(fps) / len(fps), max(fps), max(gaps)))
else:
    print("frame pacing: no 'frame stats' lines found (the game may not have reached the running state)")
aud = [re.search(r"core wrote (\d+) bytes/s, buffer fill min (\d+) max (\d+) of (\d+)", l) for l in log if "audio stats" in l]
aud = [tuple(int(g) for g in m.groups()) for m in aud if m]
if aud:
    rates = [a[0] for a in aud]
    print("audio stats: core wrote %d-%d bytes/s per window (avg %d); buffer holds %d bytes, fill ranged %d to %d"
          % (min(rates), max(rates), sum(rates) / len(rates), aud[0][3], min(a[1] for a in aud), max(a[2] for a in aud)))
print("audio: %d buffer-full warnings" % sum(1 for l in log if "Tried to write" in l))
problems = [l for l in log if re.search(r"\s(E|Fa)\s", l) and "Tried to write" not in l and "CredentialStore" not in l]
print("errors/faults (excluding audio and credential-store noise): %d" % len(problems))
for l in problems[:10]: print("   ", l[:230])
copy_failures = [l for l in log if "Copy failed" in l]
print("backup folder: %d copy failure(s)" % len(copy_failures))
for l in copy_failures[:3]: print("   ", re.sub(r"^.*\[org.openemu.OpenEmu:FolderBackup\]\s*", "", l)[:260])
print("crash reports: %s" % os.environ["CRASHES"])
if os.environ["CRASHES"] != "0": ok = False
print("")
print("PLAYTEST COMPLETED: the game ran, took the keys and closed cleanly." if ok else "PLAYTEST PROBLEM: see above.")
raise SystemExit(0 if ok else 1)
PY
STATUS=$?
echo "screenshots, result.json and app.log: $OUT"
exit $STATUS
