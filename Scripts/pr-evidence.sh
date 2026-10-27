#!/usr/bin/env bash
# pr-evidence.sh — Put screenshots on a pull request as proof: that a bug is fixed, that a feature looks and
# behaves the way it was specified, or that something seen in a play test works.
#
# Usage:
#   ./Scripts/pr-evidence.sh --claim "Space Invaders starts without the Still Syncing alert" \
#       --from-playtest [--pick 2,4] [--pr 796] [--post]
#   ./Scripts/pr-evidence.sh --claim "The pause menu shows the new button" \
#       --before before.png --after after.png [--note "Matches the agreed layout"] --post
#   ./Scripts/pr-evidence.sh --claim "..." shot1.png "Caption for shot 2=shot2.png" --post
#
#   --claim TEXT        What the pictures prove, in one plain sentence. Required.
#   --note TEXT         Extra detail (what was done, which game, what to look at). Optional.
#   --from-playtest     Use the pictures and the result summary of the latest Scripts/playtest.sh run
#                       (or --run <folder> to name a run). --pick 2,4 keeps only those pictures (default: all).
#   --before F --after F  Show a before/after pair.
#   --pr N              The pull request. Default: the one for the current branch.
#   --post              Actually upload and comment. Without it, nothing leaves this Mac: the script only
#                       shows what it would post.
#
# Pictures are shrunk to 1200 px wide, uploaded to the "pr-evidence" branch of the repo (created on first use,
# one folder per PR), and shown in a comment on the PR. They are public if the repo is public and cannot be
# fully deleted from GitHub history afterwards, so look at every picture first: no personal windows,
# notifications, or games other people should not see.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CLAIM="" NOTE="" PR="" POST=0 FROM_PLAYTEST=0 RUN_DIR="" PICK="" BEFORE="" AFTER=""
FILES=() CAPTIONS=()

die() { echo "FAIL  $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --claim) CLAIM="${2:-}"; shift 2 ;;
    --note) NOTE="${2:-}"; shift 2 ;;
    --pr) PR="${2:-}"; shift 2 ;;
    --post) POST=1; shift ;;
    --from-playtest) FROM_PLAYTEST=1; shift ;;
    --run) RUN_DIR="${2:-}"; FROM_PLAYTEST=1; shift 2 ;;
    --pick) PICK="${2:-}"; shift 2 ;;
    --before) BEFORE="${2:-}"; shift 2 ;;
    --after) AFTER="${2:-}"; shift 2 ;;
    -h|--help) sed -n 2,25p "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *)
      if [[ "$1" == *=* && ! -f "$1" ]]; then CAPTIONS+=("${1%%=*}"); FILES+=("${1#*=}")
      else CAPTIONS+=(""); FILES+=("$1"); fi
      shift ;;
  esac
done

[ -n "$CLAIM" ] || die "--claim is required: say in one sentence what these pictures prove"
command -v gh >/dev/null || die "the GitHub command line tool (gh) is needed"

SUMMARY=""
if [ "$FROM_PLAYTEST" -eq 1 ]; then
  [ -n "$RUN_DIR" ] || RUN_DIR="$(ls -d "${TMPDIR:-/tmp}"/openemu-playtest/*/ 2>/dev/null | sort | tail -1)"
  RUN_DIR="${RUN_DIR%/}"
  [ -f "$RUN_DIR/result.json" ] || die "no play test result found in '$RUN_DIR' (run Scripts/playtest.sh first)"
  # Prints "file<TAB>caption" lines, then a SUMMARY line.
  PT="$(python3 - "$RUN_DIR" "$PICK" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1] + "/result.json"))
pick = {int(x) for x in sys.argv[2].split(",") if x.strip()} if sys.argv[2] else None
for i, s in enumerate(d.get("shots", []), 1):
    if pick and i not in pick:
        continue
    cap = f"{s['secondsIn']:.0f}s in, last key: {s['lastKey']}" + (", picture changed" if s.get("changedFromPrevious") else "")
    print(f"{sys.argv[1]}/{s['file']}\t{cap}")
keys = d.get("keysSent") or []
print("SUMMARY\t" + f"Play test of {d.get('game','?')}: {d.get('status','?')}; played {d.get('secondsPlayed',0):.0f}s; keys sent: {', '.join(keys) if keys else 'none'}. {d.get('message','')}")
EOF
)" || die "could not read the play test result"
  while IFS=$'\t' read -r a b; do
    if [ "$a" = "SUMMARY" ]; then SUMMARY="$b"; else FILES+=("$a"); CAPTIONS+=("$b"); fi
  done <<< "$PT"
fi

if [ -n "$BEFORE" ] || [ -n "$AFTER" ]; then
  [ -n "$BEFORE" ] && [ -n "$AFTER" ] || die "--before and --after go together"
fi

[ ${#FILES[@]} -gt 0 ] || [ -n "$BEFORE" ] || die "no pictures given"
for f in ${FILES[@]+"${FILES[@]}"} ${BEFORE:+"$BEFORE"} ${AFTER:+"$AFTER"}; do [ -f "$f" ] || die "picture not found: $f"; done

REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" || die "cannot tell which GitHub repo this is"
[ -n "$PR" ] || PR="$(gh pr view --json number --jq .number 2>/dev/null)" || die "no pull request for this branch; pass --pr N"

STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BASE_URL="https://raw.githubusercontent.com/$REPO/pr-evidence/pr-$PR/$STAMP"

# Shrink copies; never touch the originals.
prep() {  # prep <source> <name-prefix> -> prints the uploaded file name
  local out="$2-$(basename "$1" | tr ' ' '-')"
  case "$out" in *.png|*.PNG|*.jpg|*.jpeg) ;; *) out="$out.png" ;; esac
  cp "$1" "$WORK/$out"
  sips -Z 1200 "$WORK/$out" >/dev/null 2>&1 || true
  echo "$out"
}

BODY="### Evidence: $CLAIM"$'\n\n'
[ -n "$NOTE" ] && BODY+="$NOTE"$'\n\n'
[ -n "$SUMMARY" ] && BODY+="_${SUMMARY}_"$'\n\n'
UPLOADS=()

if [ -n "$BEFORE" ]; then
  b="$(prep "$BEFORE" "before")"; a="$(prep "$AFTER" "after")"; UPLOADS+=("$b" "$a")
  BODY+="| Before | After |"$'\n'"|---|---|"$'\n'"| ![before]($BASE_URL/$b) | ![after]($BASE_URL/$a) |"$'\n\n'
fi
n=0
for i in "${!FILES[@]}"; do
  n=$((n+1)); name="$(prep "${FILES[$i]}" "$(printf '%02d' $n)")"; UPLOADS+=("$name")
  cap="${CAPTIONS[$i]}"; [ -n "$cap" ] || cap="$(basename "${FILES[$i]}")"
  BODY+="**$cap**"$'\n\n'"![${cap}]($BASE_URL/$name)"$'\n\n'
done
BODY+="<sub>Posted with Scripts/pr-evidence.sh by Claude Code on $(date '+%Y-%m-%d %H:%M'). Pictures were taken from a real run on the maintainer's Mac.</sub>"

if [ "$POST" -ne 1 ]; then
  echo "DRY RUN  (nothing uploaded). Would post to $REPO#$PR, with ${#UPLOADS[@]} picture(s):"
  for u in "${UPLOADS[@]}"; do ls -l "$WORK/$u" | awk '{printf "   %s (%d KB)\n", $NF, $5/1024}'; done
  echo "----"; echo "$BODY"; echo "----"
  echo "Look at the pictures, then run again with --post."
  exit 0
fi

# Make sure the evidence branch exists (an empty branch with only a README, created once).
if ! gh api "repos/$REPO/git/ref/heads/pr-evidence" >/dev/null 2>&1; then
  echo "----  creating the pr-evidence branch"
  TREE="$(gh api "repos/$REPO/git/trees" -f 'tree[][path]=README.md' -f 'tree[][mode]=100644' -f 'tree[][type]=blob' \
          -f 'tree[][content]=Screenshots posted as proof on pull requests by Scripts/pr-evidence.sh. Not part of the app.' --jq .sha)" || die "could not create the branch"
  COMMIT="$(gh api "repos/$REPO/git/commits" -f message='chore: start the pr-evidence branch' -f "tree=$TREE" --jq .sha)" || die "could not create the branch"
  gh api "repos/$REPO/git/refs" -f ref=refs/heads/pr-evidence -f "sha=$COMMIT" >/dev/null || die "could not create the branch"
fi

echo "----  uploading ${#UPLOADS[@]} picture(s)"
for u in "${UPLOADS[@]}"; do
  # The picture goes in through a file, not the command line: a base64 picture can be bigger than a command may be.
  python3 -c 'import base64,json,sys; print(json.dumps({"message": sys.argv[2], "branch": "pr-evidence", "content": base64.b64encode(open(sys.argv[1],"rb").read()).decode()}))' \
     "$WORK/$u" "evidence for #$PR: $u" > "$WORK/upload.json"
  gh api -X PUT "repos/$REPO/contents/pr-$PR/$STAMP/$u" --input "$WORK/upload.json" >/dev/null || die "upload failed for $u"
done

echo "----  commenting on #$PR"
URL="$(gh pr comment "$PR" --repo "$REPO" --body "$BODY")" || die "could not comment"
echo "PASS  $URL"
