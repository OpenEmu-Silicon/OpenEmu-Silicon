#!/usr/bin/env bash
# verify.sh — Autonomous verification floor for OpenEmu-Silicon
#
# Usage:
#   ./Scripts/verify.sh                        # build + analyze + plist + codesign on the main app
#   ./Scripts/verify.sh --launch               # above, plus 5s smoke launch with log + crash check, then leaves the app running
#   ./Scripts/verify.sh --test                 # above, plus run OpenEmuTests unit test target
#   ./Scripts/verify.sh --core <CoreName>      # build a core scheme + install + verify the installed plugin
#   ./Scripts/verify.sh --core <CoreName> --release  # use Release configuration (for Release-only bugs)
#   ./Scripts/verify.sh --core <CoreName> --launch
#   ./Scripts/verify.sh --worktree             # build to ~/Builds/openemu/<branch>/ for stable permissions
#
# When run inside a git worktree (or with --worktree), the script builds and
# locates artifacts at ~/Builds/openemu/<branch>/ so macOS privacy permissions
# persist across rebuilds of the same branch. See docs/worktree-workflow.md.
#
# Exit code is the number of failing checks. 0 means everything passed.
# Each check prints a single PASS/FAIL line so the summary is greppable.
#
# Known caveats / limitations (do not assume a failure here means YOUR change is broken):
#   - bash 3.x compatibility: macOS ships bash 3.x by default. This script avoids bash 4+
#     features (mapfile, etc.). If you change it, test under /bin/bash, not /opt/homebrew/bin/bash.
#   - Core schemes: most cores use the "OpenEmu + <Name>" combined scheme convention. The
#     script prefers the combined scheme but falls back to the bare name. If --core <Name>
#     fails to find a scheme, fall back to building manually with the explicit combined name:
#         xcodebuild -workspace OpenEmu-metal.xcworkspace -scheme 'OpenEmu + <Name>' \
#           -configuration Debug -destination 'platform=macOS,arch=arm64' build
#         Scripts/install-core.sh <Name>
#     This has been observed with FCEU specifically.
#   - --test: requires the OpenEmu scheme (which has the test target wired up). Do not pass
#     --test together with --core; tests are app-level.
#   - --launch: skipped if OpenEmu is already running (would clobber user state). Quit OpenEmu
#     first if you want a clean smoke test.
#   - DerivedData artifact resolution: assumes a single OpenEmu-metal-* DerivedData hash.
#     If you have multiple worktrees, see docs/worktree-workflow.md (when added) for the
#     stable-path build convention.
#
# When verify.sh fails for reasons unrelated to your change, fall back to a plain xcodebuild
# build check and note the verify.sh issue in your task report. Do not get stuck trying to
# fix the script — that's a separate concern.

set -uo pipefail

# The plain app mode (no --core, no --test) duplicates CI and Scripts/check.sh, which both build the app.
case " $* " in *" --core "*|*" --test "*) ;; *) echo "NOTE  plain verify.sh is redundant with CI and Scripts/check.sh; prefer check.sh. Continuing." >&2 ;; esac

# Ignore SIGPIPE. A truncated consumer (e.g. `verify.sh | head -30`,
# `... | grep ... | head`) closes its stdin partway through; without this trap,
# the next echo from verify.sh receives SIGPIPE and terminates the script
# mid-run. The currently running xcodebuild child then gets orphaned and keeps
# holding the build.db lock, which causes the *next* verify invocation to fail
# with a "database is locked" build error — the symptom that's been showing up
# across worktrees today.
trap '' PIPE

# On any exit, terminate child processes so xcodebuild cannot outlive the
# script. xcodebuild handles SIGTERM cleanly and propagates to its own
# children (swift-frontend, clang, ld, etc.), which releases the build.db
# lock for the next verify run. Errors are suppressed because there may be
# no children to kill on a clean exit.
verify_cleanup_children() {
  pkill -TERM -P $$ 2>/dev/null || true
}
trap verify_cleanup_children EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

WORKSPACE="OpenEmu-metal.xcworkspace"
APP_PLIST="OpenEmu/OpenEmu-Info.plist"
APP_ENTITLEMENTS="OpenEmu/OpenEmu.entitlements"
INSTALLED_APP_DEFAULT="$HOME/Library/Application Support/OpenEmu"

LAUNCH=0
CORE=""
RUN_TESTS=0
WORKTREE=0
CONFIG="Debug"
FAILURES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --launch) LAUNCH=1; shift ;;
    --core) CORE="${2:-}"; shift 2 ;;
    --test) RUN_TESTS=1; shift ;;
    --worktree) WORKTREE=1; shift ;;
    --debug) CONFIG="Debug"; shift ;;
    --release) CONFIG="Release"; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

# Cores whose upstream source isn't vendored (FBNeo) build through a dedicated
# Scripts/build-<core>-core.sh: it clones the pinned source, builds the headless
# engine, then the plugin into <Core>/build/XcodeDerived. These are Release-only
# and are not workspace schemes, so verify builds them via that script.
CORE_BUILD_SCRIPT=""
if [ -n "${CORE:-}" ]; then
  _core_lc=$(echo "$CORE" | tr '[:upper:]' '[:lower:]')
  if [ -x "./Scripts/build-${_core_lc}-core.sh" ]; then
    CORE_BUILD_SCRIPT="./Scripts/build-${_core_lc}-core.sh"
    CONFIG="Release"
  fi
fi

# Auto-detect worktree if not explicitly set.
# `git rev-parse --show-superproject-working-tree` returns non-empty for submodules; use a different signal.
# A linked worktree has its .git as a *file* (pointing into the main repo's .git/worktrees/), not a directory.
if [ "$WORKTREE" -eq 0 ] && [ -f .git ]; then
  WORKTREE=1
fi

# Determine build directory for worktree mode.
if [ "$WORKTREE" -eq 1 ]; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's|/|-|g')
  if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
    echo "warning: --worktree set but cannot determine branch name; falling back to DerivedData" >&2
    WORKTREE=0
  else
    BUILD_DIR_OVERRIDE="$HOME/Builds/openemu/$BRANCH"
    mkdir -p "$BUILD_DIR_OVERRIDE"
  fi
fi

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILURES=$((FAILURES+1)); }
info() { echo "----  $1"; }

# Wait until SWBBuildService releases the build.db at the target path.
# Called before starting xcodebuild so a concurrent invocation (another hook,
# a manual xcodebuild call, the IDE) doesn't immediately fail with
# "database is locked". Checks the worktree path when WORKTREE=1, otherwise
# the default DerivedData location.
wait_for_build_db() {
  local db_path
  if [ "${WORKTREE:-0}" -eq 1 ] && [ -n "${BUILD_DIR_OVERRIDE:-}" ]; then
    db_path="$BUILD_DIR_OVERRIDE/Build/Intermediates.noindex/XCBuildData/build.db"
  else
    db_path=$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 7 \
      -name "build.db" \
      -path "*/OpenEmu-metal-*/Build/Intermediates.noindex/XCBuildData/build.db" \
      -print -quit 2>/dev/null)
  fi
  [ -z "$db_path" ] || [ ! -f "$db_path" ] && return 0

  local max_wait=40 elapsed=0
  while [ "$elapsed" -lt "$max_wait" ]; do
    lsof "$db_path" 2>/dev/null | grep -q "SWBBuildService" || return 0
    [ "$elapsed" -eq 0 ] && info "build.db locked by SWBBuildService — waiting for it to release..."
    sleep 2
    elapsed=$((elapsed + 2))
  done
  info "build.db still locked after ${max_wait}s — proceeding anyway (may fail)"
}

# --- Prune stale DerivedData directories -----------------------------------
# Xcode rotates OpenEmu-metal-<hash> whenever the workspace path or scheme
# hash changes, leaving old dirs behind. Keeping only the newest means that
# `open ... OpenEmu-metal-*/...` globs never accidentally open multiple apps.
# Worktree builds go to ~/Builds/openemu/<branch>/ and are unaffected.
if [ "$WORKTREE" -eq 0 ]; then
  DD="$HOME/Library/Developer/Xcode/DerivedData"
  pruned=0
  newest=""
  while IFS= read -r dir; do
    if [ -z "$newest" ]; then
      newest="$dir"
    else
      rm -rf "$dir"
      pruned=$((pruned+1))
    fi
  done < <(
    find "$DD" -maxdepth 1 -name 'OpenEmu-metal-*' -type d -print0 2>/dev/null \
      | xargs -0 stat -f '%m %N' 2>/dev/null \
      | sort -rn \
      | awk '{print $2}'
  )
  if [ $pruned -gt 0 ]; then
    info "pruned $pruned stale DerivedData dir(s); keeping $(basename "${newest:-none}")"
  fi
fi

# --- Core feed-URL guardrail (precondition for --core runs) --------------

if [ -n "$CORE" ] && [ -x "./Scripts/check-core-feed-urls.sh" ]; then
  if ./Scripts/check-core-feed-urls.sh >/dev/null 2>&1; then
    pass "check-core-feed-urls.sh"
  else
    fail "check-core-feed-urls.sh — upstream URL or missing appcast detected"
    ./Scripts/check-core-feed-urls.sh || true
  fi
fi

# --- Build ---------------------------------------------------------------

if [ -n "$CORE_BUILD_SCRIPT" ]; then
  info "Building core via $CORE_BUILD_SCRIPT (Release; clones the pinned source)"
  BUILD_LOG=$(mktemp -t verify_build.XXXXXX)
  wait_for_build_db
  if "$CORE_BUILD_SCRIPT" > "$BUILD_LOG" 2>&1; then
    pass "build ($CORE_BUILD_SCRIPT)"
  else
    fail "build ($CORE_BUILD_SCRIPT) — see $BUILD_LOG (last 30 lines below)"
    tail -30 "$BUILD_LOG"
  fi
else
  if [ -n "$CORE" ]; then
    # Workspace schemes are named "OpenEmu + <Core>" for the combined host+core build.
    # Some cores also have a bare scheme (e.g. "4DO", "BSNES") — prefer the combined one.
    COMBINED_SCHEME="OpenEmu + $CORE"
    AVAILABLE=$(xcodebuild -workspace "$WORKSPACE" -list 2>/dev/null | awk '/Schemes:/,0' | tail -n +2)
    if echo "$AVAILABLE" | grep -qxF "        $COMBINED_SCHEME"; then
      SCHEME="$COMBINED_SCHEME"
    else
      SCHEME="$CORE"
    fi
    info "Building core scheme: $SCHEME"
  else
    SCHEME="OpenEmu"
    info "Building main app scheme: $SCHEME"
  fi

  BUILD_LOG=$(mktemp -t verify_build.XXXXXX)
  XCODEBUILD_ARGS=(-workspace "$WORKSPACE" -scheme "$SCHEME"
                   -configuration "$CONFIG" -destination 'platform=macOS,arch=arm64')
  if [ "$WORKTREE" -eq 1 ]; then
    XCODEBUILD_ARGS+=(-derivedDataPath "$BUILD_DIR_OVERRIDE")
    info "worktree mode — building to $BUILD_DIR_OVERRIDE"
  fi

  wait_for_build_db

  if xcodebuild "${XCODEBUILD_ARGS[@]}" build > "$BUILD_LOG" 2>&1; then
    pass "build ($SCHEME)"
  else
    fail "build ($SCHEME) — see $BUILD_LOG (last 30 lines below)"
    tail -30 "$BUILD_LOG"
  fi
fi

# Surface warnings even on a passing build — these are technical debt accumulating silently.
WARN_COUNT=$(grep -cE ': (warning|error):' "$BUILD_LOG" 2>/dev/null || true)
if [ "${WARN_COUNT:-0}" -gt 0 ]; then
  info "$WARN_COUNT warning/error lines in build log — first 10:"
  grep -E ': (warning|error):' "$BUILD_LOG" | head -10
fi

# --- Static analyzer (main app only — core schemes don't all support analyze) ---

if [ -z "$CORE" ]; then
  ANALYZE_LOG=$(mktemp -t verify_analyze.XXXXXX)
  if xcodebuild "${XCODEBUILD_ARGS[@]}" analyze > "$ANALYZE_LOG" 2>&1; then
    pass "analyze ($SCHEME)"
  else
    fail "analyze ($SCHEME) — see $ANALYZE_LOG"
    tail -20 "$ANALYZE_LOG"
  fi
fi

# --- Plist lint ----------------------------------------------------------

if [ -z "$CORE" ]; then
  PLISTS=("$APP_PLIST" "$APP_ENTITLEMENTS")
else
  # Each core has its own Info.plist somewhere in its directory.
  # Use while-read instead of mapfile to stay compatible with macOS bash 3.x.
  PLISTS=()
  while IFS= read -r p; do PLISTS+=("$p"); done < <(find "$CORE" -maxdepth 3 -name 'Info.plist' 2>/dev/null)
fi

for p in "${PLISTS[@]:-}"; do
  [ -z "$p" ] && continue
  if [ ! -f "$p" ]; then
    info "skipping (missing): $p"
    continue
  fi
  if plutil -lint "$p" >/dev/null 2>&1; then
    pass "plutil $p"
  else
    fail "plutil $p"
    plutil -lint "$p" || true
  fi
done

# --- Locate the built artifact and codesign verify ---------------------------

if [ "$WORKTREE" -eq 1 ]; then
  ARTIFACT_BASE="$BUILD_DIR_OVERRIDE"
else
  ARTIFACT_BASE="$HOME/Library/Developer/Xcode/DerivedData"
fi

if [ -z "$CORE" ]; then
  if [ "$WORKTREE" -eq 1 ]; then
    ARTIFACT="$ARTIFACT_BASE/Build/Products/${CONFIG}/OpenEmu.app"
    [ -e "$ARTIFACT" ] || ARTIFACT=""
  else
    ARTIFACT=$(find "$ARTIFACT_BASE" -maxdepth 5 -path "*OpenEmu-metal-*/Build/Products/${CONFIG}/OpenEmu.app" -print -quit 2>/dev/null)
  fi
else
  if [ -n "$CORE_BUILD_SCRIPT" ]; then
    # build-<core>-core.sh emits the plugin into <Core>/build/XcodeDerived.
    ARTIFACT="$CORE/build/XcodeDerived/Build/Products/${CONFIG}/${CORE}.oecoreplugin"
    [ -e "$ARTIFACT" ] || ARTIFACT=""
  elif [ "$WORKTREE" -eq 1 ]; then
    ARTIFACT="$ARTIFACT_BASE/Build/Products/${CONFIG}/${CORE}.oecoreplugin"
    [ -e "$ARTIFACT" ] || ARTIFACT=""
  else
    ARTIFACT=$(find "$ARTIFACT_BASE" -maxdepth 5 -path "*OpenEmu-metal-*/Build/Products/${CONFIG}/${CORE}.oecoreplugin" -print -quit 2>/dev/null)
  fi
fi

if [ -z "$ARTIFACT" ] || [ ! -e "$ARTIFACT" ]; then
  fail "locate built artifact (expected in DerivedData)"
else
  info "artifact: $ARTIFACT"
  if codesign --verify --deep --strict "$ARTIFACT" 2>/dev/null; then
    pass "codesign --verify --deep --strict"
  else
    fail "codesign --verify --deep --strict — output:"
    codesign --verify --deep --strict "$ARTIFACT" || true
  fi
fi

# --- Core install + post-install verification --------------------------------

if [ -n "$CORE" ] && [ -n "${ARTIFACT:-}" ] && [ -e "$ARTIFACT" ]; then
  INSTALL_DEST="$INSTALLED_APP_DEFAULT/Cores/${CORE}.oecoreplugin"
  CONFIG_FLAG="--$(echo "$CONFIG" | tr '[:upper:]' '[:lower:]')"
  if [ -x "./Scripts/install-core.sh" ]; then
    info "installing core via Scripts/install-core.sh ($CONFIG)"
    if ./Scripts/install-core.sh "$CORE" "$CONFIG_FLAG" >/dev/null 2>&1; then
      pass "install-core.sh $CORE $CONFIG_FLAG"
    else
      fail "install-core.sh $CORE $CONFIG_FLAG"
    fi
  else
    info "Scripts/install-core.sh not executable — skipping install"
  fi

  if [ -e "$INSTALL_DEST" ]; then
    if codesign --verify --deep --strict "$INSTALL_DEST" 2>/dev/null; then
      pass "codesign installed plugin"
    else
      fail "codesign installed plugin"
    fi
  fi

  # Final preflight: confirm the installed plugin actually matches what we
  # just built. This catches silent install failures (e.g. OpenEmu still
  # holding the binary open) that the codesign check above would not.
  if [ -x "./Scripts/verify-core-installed.sh" ]; then
    if ./Scripts/verify-core-installed.sh "$CORE" "$CONFIG_FLAG" >/dev/null 2>&1; then
      pass "verify-core-installed.sh $CORE $CONFIG_FLAG"
    else
      fail "verify-core-installed.sh $CORE $CONFIG_FLAG — installed plugin does not match build"
      ./Scripts/verify-core-installed.sh "$CORE" "$CONFIG_FLAG" || true
    fi
  fi
fi

# --- Optional smoke launch -----------------------------------------------

if [ "$LAUNCH" -eq 1 ] && [ -z "$CORE" ] && [ -n "${ARTIFACT:-}" ] && [ -e "$ARTIFACT" ]; then
  if pgrep -x OpenEmu >/dev/null 2>&1; then
    info "OpenEmu is already running — skipping smoke launch (would clobber user state)"
  else
    info "smoke launching (staying open for manual testing after health checks)"
    LAUNCH_START=$(date +"%Y-%m-%d %H:%M:%S")
    open "$ARTIFACT"
    sleep 5

    if pgrep -x OpenEmu >/dev/null 2>&1; then
      pass "process alive after 5s"
    else
      fail "process died within 5s of launch"
    fi

    # Log scan for OpenEmu-related faults/errors during the launch window
    LOG_OUT=$(log show --predicate 'process == "OpenEmu"' \
               --start "$LAUNCH_START" --style compact 2>/dev/null \
               | grep -iE '(fault|error|exception|crash|abort)' \
               | head -20 || true)
    if [ -n "$LOG_OUT" ]; then
      info "log scan found suspicious lines:"
      echo "$LOG_OUT"
    else
      pass "log scan clean"
    fi

    # Crash report check — DiagnosticReports written within the last minute
    CRASH_NEW=$(find "$HOME/Library/Logs/DiagnosticReports" -name 'OpenEmu*' -mmin -1 2>/dev/null)
    if [ -n "$CRASH_NEW" ]; then
      fail "new crash report(s) written:"
      echo "$CRASH_NEW"
    else
      pass "no new crash reports"
    fi
  fi
fi

# --- Optional unit tests (OpenEmuTests target) ---------------------------

if [ "$RUN_TESTS" -eq 1 ] && [ -z "$CORE" ]; then
  info "running OpenEmuTests (xcodebuild test)"
  TEST_LOG=$(mktemp -t verify_test.XXXXXX)
  # With the stable "OpenEmu Debug" certificate (Scripts/setup-debug-signing.sh) the test app keeps the same
  # signature across rebuilds, so macOS asks for folder access (Documents) once instead of blocking every run.
  SIGN_ARGS=()
  if "$(dirname "$0")/setup-debug-signing.sh" --check >/dev/null 2>&1; then
    SIGN_ARGS=(CODE_SIGN_IDENTITY="${OE_DEBUG_SIGN_IDENTITY:-OpenEmu Debug}")
  fi
  if xcodebuild test \
       -workspace "$WORKSPACE" \
       -scheme OpenEmu \
       -configuration Debug \
       -destination 'platform=macOS,arch=arm64' \
       -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
       ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
       > "$TEST_LOG" 2>&1; then
    PASS_COUNT=$(grep -c 'passed' "$TEST_LOG" 2>/dev/null || true)
    pass "OpenEmuTests ($PASS_COUNT tests passed)"
  else
    fail "OpenEmuTests — see $TEST_LOG (last 30 lines below)"
    tail -30 "$TEST_LOG"
  fi
fi

# --- Summary -------------------------------------------------------------

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "===================="
  echo "verify.sh: ALL PASS"
  echo "===================="
  # Stamp the tree hash of the verified build. The pre-push hook reads this
  # to skip re-running verify when the code being pushed is identical to what
  # already passed — regardless of how many commits have been made since.
  # Using the tree hash (HEAD^{tree}) rather than the commit SHA means the
  # stamp survives a commit: verify → commit → push hits the cache instead of
  # re-running a second full build, which is what causes concurrent-xcodebuild
  # pile-ups. Only stamp for full app Debug runs so partial checks can't trick it.
  if [ -z "$CORE" ] && [ "$CONFIG" = "Debug" ]; then
    STAMP_FILE=$(git rev-parse --git-path verify-passed 2>/dev/null || true)
    if [ -n "$STAMP_FILE" ]; then
      TREE_SHA=$(git rev-parse HEAD^{tree} 2>/dev/null || echo "")
      if [ -n "$TREE_SHA" ]; then
        echo "$TREE_SHA" > "$STAMP_FILE"
      fi
    fi
  fi
  exit 0
else
  echo "===================="
  echo "verify.sh: $FAILURES FAILED"
  echo "===================="
  exit "$FAILURES"
fi
