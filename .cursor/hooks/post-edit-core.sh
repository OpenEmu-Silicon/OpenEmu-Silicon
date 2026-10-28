#!/bin/bash
#
# post-edit-core.sh — Cursor postToolUse hook for Write/Edit tool calls.
#
# When the agent edits a file inside a core plugin directory, surface a
# reminder that any in-game test result must be preceded by install-core.sh
# and verify-core-installed.sh, or it is invalid.
#
# Why this hook exists:
#   The single most expensive failure mode in this repo is claiming a core
#   test result against a stale installed plugin while the freshly-built
#   binary sits unused in DerivedData. The protocol to prevent this is
#   already documented in AGENTS.md and CLAUDE.md, and the tooling already
#   exists in Scripts/. But agents (including the one that wrote this hook)
#   have demonstrably ignored that protocol. This hook is the mechanical
#   enforcement layer: every edit to a core file produces a fresh reminder
#   in the agent's tool output, which the agent has to acknowledge.
#
# This hook does not block edits. It only surfaces context.
#
# Input (stdin, JSON):
#   {
#     "tool_name": "Write" | "Edit" | "StrReplace" | ...,
#     "tool_input": { "path": "..." | "filePath": "...", ... },
#     ...
#   }
#
# Output (stdout, JSON):
#   { "additional_context": "..." }
#
# Exit code 0 always (fail-open by design — never break the agent's flow).

set -uo pipefail

# Always exit 0 — failures here must not break the agent.
trap 'exit 0' ERR

input=$(cat)

# Try to extract the edited file path from common shapes. Different Cursor
# tools use different key names (path / filePath / target_notebook).
# Use a single jq invocation that tries each in order.
if ! command -v jq >/dev/null 2>&1; then
  # No jq available — silently no-op. The hook is informational only.
  echo '{}'
  exit 0
fi

path=$(echo "$input" | jq -r '
  .tool_input.path //
  .tool_input.filePath //
  .tool_input.file_path //
  .tool_input.target_notebook //
  empty
')

if [ -z "$path" ]; then
  echo '{}'
  exit 0
fi

# Determine the repo root from this script's location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Normalise: if the edited path is absolute and inside the repo, strip the
# repo prefix. Otherwise treat it as already-relative.
case "$path" in
  "$REPO_ROOT"/*) rel_path="${path#$REPO_ROOT/}" ;;
  /*)             # absolute but outside repo — not interesting
                  echo '{}'; exit 0 ;;
  *)              rel_path="$path" ;;
esac

# The first path component is the core directory candidate.
core="${rel_path%%/*}"

# Skip non-core paths quickly. Core directories are top-level and contain
# an `Info.plist` plus a `*.xcodeproj` (or are referenced by the workspace).
# Use a simple filesystem check rather than maintaining a hardcoded list.
if [ -z "$core" ] || [ ! -d "$REPO_ROOT/$core" ]; then
  echo '{}'
  exit 0
fi
if [ ! -f "$REPO_ROOT/$core/Info.plist" ]; then
  # Not a core directory.
  echo '{}'
  exit 0
fi
# Filter further: only fire for source-file edits (skip docs, READMEs, etc.).
case "$rel_path" in
  *.m|*.mm|*.h|*.hpp|*.c|*.cpp|*.swift|*.metal|*.plist) ;;
  *) echo '{}'; exit 0 ;;
esac

# Build the reminder. If a verify script is available, also run it and
# include its current verdict so the agent knows whether the installed
# plugin already matches a recent build.
verify_status=""
if [ -x "$REPO_ROOT/Scripts/verify-core-installed.sh" ]; then
  for cfg in --debug --release; do
    out=$("$REPO_ROOT/Scripts/verify-core-installed.sh" "$core" "$cfg" 2>&1) && code=0 || code=$?
    case "$code" in
      0) verify_status="${verify_status}  [${cfg#--}] OK ($(echo "$out" | head -1))"$'\n' ;;
      1) verify_status="${verify_status}  [${cfg#--}] STALE — installed plugin does NOT match latest build. Run: ./Scripts/install-core.sh ${core} ${cfg}"$'\n' ;;
      3) verify_status="${verify_status}  [${cfg#--}] no installed plugin yet (first run will install it)"$'\n' ;;
      4) verify_status="${verify_status}  [${cfg#--}] no ${cfg#--} build of ${core} exists yet"$'\n' ;;
      *) verify_status="${verify_status}  [${cfg#--}] verify script returned exit ${code}"$'\n' ;;
    esac
  done
fi

reminder=$(cat <<EOF
You just edited a file in the **${core}** core plugin directory (${rel_path}).

Before you (or the user) report any in-game test result for ${core}:

  1. Build:   xcodebuild -workspace OpenEmu-metal.xcworkspace -scheme "OpenEmu + ${core}" -configuration <Debug|Release> -destination 'platform=macOS,arch=arm64' build
              or:    ./Scripts/core.sh ${core}            (Debug)
                     ./Scripts/core.sh ${core} --release  (Release)

  2. Install: ./Scripts/install-core.sh ${core} [--debug|--release]
              (core.sh does this automatically)

  3. Preflight: ./Scripts/verify-core-installed.sh ${core} [--debug|--release]
                Confirm it prints "OK" before claiming any test result.

OpenEmu loads cores from ~/Library/Application Support/OpenEmu/Cores/, NOT
from the build directory. Skipping step 2 means OpenEmu will load the
previously installed plugin regardless of what you just built. This is the
exact failure mode that wasted hours during the FCEU grey-screen
investigation (#214).

Current preflight status:
${verify_status:-  (Scripts/verify-core-installed.sh not present yet; cannot check.)}
EOF
)

# Emit the reminder as additional_context for postToolUse.
jq -n --arg ctx "$reminder" '{additional_context: $ctx}'
exit 0
