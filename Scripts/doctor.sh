#!/usr/bin/env bash
# doctor.sh — Check the Mac and checkout for the things that make check.sh and playtest.sh fail for reasons that
# are not app bugs, and say how to fix each. Runs in a few seconds; builds and launches nothing.
#
# Usage: ./Scripts/doctor.sh        # exit code is the number of problems found

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=lib/harness.sh
. "$REPO_ROOT/Scripts/lib/harness.sh"

PROBLEMS=0
ok()   { echo "ok    $*"; }
bad()  { echo "FAIL  $*"; PROBLEMS=$((PROBLEMS + 1)); }
warn() { echo "warn  $*"; }

# 1. Credential stubs (gitignored, missing in a new worktree).
missing=""
for f in ScreenScraperDevCredentials CheatWorksSecrets; do [ -f "OpenEmu/$f.swift" ] || missing="$missing $f.swift"; done
if [ -z "$missing" ]; then ok "credential stubs present"
else bad "missing:$missing   (fix: check.sh and playtest.sh create them, or copy the *.template.swift files)"; fi

# 2. Signing certificate.
NAME="${OE_DEBUG_SIGN_IDENTITY:-OpenEmu Debug}"
N=$(harness_sign_hashes "$NAME" | wc -l | tr -d ' ')
if [ "$N" -eq 0 ]; then bad "no \"$NAME\" certificate   (fix: ./Scripts/setup-debug-signing.sh, run by you once)"
elif [ "$N" -gt 1 ]; then bad "$N certificates named \"$NAME\"   (fix: delete the extras in Keychain Access; permission grants stick to one)"
else ok "one \"$NAME\" certificate"; fi

# 3. Built runner signature: ad hoc means the Accessibility grant is lost on every rebuild.
RUNNER="$(harness_build_dir)/Build/Products/Debug/OpenEmuUITests-Runner.app"
if [ -d "$RUNNER" ]; then
  if codesign -dv "$RUNNER" 2>&1 | grep -q "Signature=adhoc"; then
    bad "test runner is ad-hoc signed   (fix: re-run check.sh without --no-build so it re-signs; grant Accessibility again)"
  else ok "test runner has a real signature"; fi
else warn "no built test runner yet ($RUNNER); first check.sh run will build it"; fi

# 4. A running OpenEmu blocks both scripts.
if pgrep -x OpenEmu > /dev/null; then bad "OpenEmu is running   (quit it)"; harness_describe_running
else ok "OpenEmu is not running"; fi

# 5. Things this script cannot see.
warn "Accessibility for OpenEmuUITests-Runner (System Settings > Privacy & Security > Accessibility) cannot be read from a script; check.sh stops at the first test that hits it and says so."

echo ""
if [ "$PROBLEMS" -eq 0 ]; then echo "doctor: no problems found"; else echo "doctor: $PROBLEMS problem(s)"; fi
exit "$PROBLEMS"
