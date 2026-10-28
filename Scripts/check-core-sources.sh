#!/usr/bin/env bash
# check-core-sources.sh — Guardrail against a flattened core submodule dropping
# its vendored source. Checks every core's .gitmodules against what its Xcode
# project actually builds. The logic lives in check-core-sources.py; this
# wrapper keeps the existing entry point (CI, docs, muscle memory) working.
#
#   ./Scripts/check-core-sources.sh            # pass/fail
#   ./Scripts/check-core-sources.sh --verbose  # also list unused externals

set -euo pipefail
exec python3 "$(dirname "$0")/check-core-sources.py" "$@"
