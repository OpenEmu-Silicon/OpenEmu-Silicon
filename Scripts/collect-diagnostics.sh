#!/usr/bin/env bash
# collect-diagnostics.sh — Gather what an agent needs to explain a failure without asking anyone.
#
# Usage:
#   ./Scripts/collect-diagnostics.sh                 # last 10 minutes
#   ./Scripts/collect-diagnostics.sh --minutes 30
#   ./Scripts/collect-diagnostics.sh --since-file F  # only things newer than file F (prove.sh uses this)
#   ./Scripts/collect-diagnostics.sh --out DIR       # also save the log and crash reports to DIR
#
# Prints, in order:
#   1. Which OpenEmu processes are running, from which path, and the hash of that binary.
#   2. New crash reports for OpenEmu, OpenEmuHelperApp, test hosts and the headless runner, each
#      with the crash reason and the top frames of the crashing thread.
#   3. The app's own log lines (subsystems starting with org.openemu), errors and faults first.
#
# Exit code is 1 when a new crash report was found, otherwise 0. A missing log is not an error.

set -uo pipefail

MINUTES=10
SINCE_FILE=""
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --minutes) MINUTES="${2:?}"; shift 2 ;;
    --since-file) SINCE_FILE="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$OUT" ] && mkdir -p "$OUT"

CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
CRASHED=0

echo "==== running processes"
FOUND=0
while IFS= read -r pid; do
  [ -n "$pid" ] || continue
  FOUND=1
  CMD=$(ps -p "$pid" -o command= 2>/dev/null | cut -c1-200)
  EXE=$(ps -p "$pid" -o comm= 2>/dev/null)
  HASH=$( [ -f "$EXE" ] && shasum -a 256 "$EXE" 2>/dev/null | cut -c1-12 || echo "?" )
  echo "pid $pid  sha256:$HASH  $CMD"
done < <(pgrep -x OpenEmu; pgrep -x OpenEmuHelperApp)
[ "$FOUND" -eq 0 ] && echo "(no OpenEmu process is running)"

echo ""
echo "==== new crash reports"
if [ -n "$SINCE_FILE" ] && [ -e "$SINCE_FILE" ]; then
  NEWER=(-newer "$SINCE_FILE")
else
  NEWER=(-mmin "-$MINUTES")
fi
REPORTS=()
while IFS= read -r f; do REPORTS+=("$f"); done < <(
  find "$CRASH_DIR" -maxdepth 1 -name '*.ips' "${NEWER[@]}" 2>/dev/null \
    | grep -E '/(OpenEmu|OpenEmuHelperApp|oe-headless|xctest|OpenEmuUITests-Runner)[-.]' | sort)
if [ ${#REPORTS[@]} -eq 0 ]; then
  echo "(none)"
else
  CRASHED=1
  for f in "${REPORTS[@]}"; do
    echo "---- $f"
    [ -n "$OUT" ] && cp "$f" "$OUT/"
    /usr/bin/python3 -I - "$f" <<'PY'
import json, sys
text = open(sys.argv[1], errors="replace").read()
dec = json.JSONDecoder()
try:
    head, i = dec.raw_decode(text)
    while text[i] in "\r\n ":
        i += 1
    body, _ = dec.raw_decode(text, i)
except Exception as e:
    print("(could not parse report: %s)" % e)
    sys.exit(0)
print("app: %s %s   os: %s" % (head.get("app_name"), head.get("app_version", ""), head.get("os_version")))
exc = body.get("exception", {})
term = body.get("termination", {})
print("exception: %s / %s   termination: %s" % (exc.get("type"), exc.get("signal"), term.get("indicator")))
if body.get("asi"):
    print("assertion info:", json.dumps(body["asi"])[:400])
crashed = [t for t in body.get("threads", []) if t.get("triggered")]
if crashed:
    thread = crashed[0]
    print("crashing thread: %s" % (thread.get("name") or thread.get("queue") or thread.get("id")))
    images = body.get("usedImages", [])
    for n, frame in enumerate(thread.get("frames", [])[:14]):
        image = images[frame["imageIndex"]].get("name", "?") if frame.get("imageIndex") is not None else "?"
        where = ""
        if frame.get("sourceFile"):
            where = "  (%s:%s)" % (frame["sourceFile"], frame.get("sourceLine", "?"))
        print("  %2d  %-28s %s%s" % (n, image, frame.get("symbol", "?"), where))
PY
  done
fi

echo ""
echo "==== app log (subsystems starting with org.openemu)"
LOG_ARGS=(--style compact --predicate 'subsystem BEGINSWITH "org.openemu"')
if [ -n "$SINCE_FILE" ] && [ -e "$SINCE_FILE" ]; then
  START=$(date -r "$(stat -f %m "$SINCE_FILE")" '+%Y-%m-%d %H:%M:%S')
  LOG_ARGS+=(--start "$START")
else
  LOG_ARGS+=(--last "${MINUTES}m")
fi
LOG_TEXT=$(log show "${LOG_ARGS[@]}" 2>/dev/null || true)
[ -n "$OUT" ] && printf '%s\n' "$LOG_TEXT" > "$OUT/openemu.log"
ISSUES=$(grep -E ' (E|Fa) ' <<<"$LOG_TEXT" | grep -v "^Timestamp" | tail -40)
if [ -n "$ISSUES" ]; then
  echo "-- errors and faults (last 40)"
  echo "$ISSUES" | cut -c1-260
else
  echo "-- no errors or faults logged"
fi
echo "-- most recent lines (last 25)"
grep -v "^Timestamp" <<<"$LOG_TEXT" | tail -25 | cut -c1-260

echo ""
if [ "$CRASHED" -eq 1 ]; then echo "RESULT  crash report(s) found"; exit 1; fi
echo "RESULT  no new crash reports"
exit 0
