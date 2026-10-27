#!/usr/bin/env bash
# check-core-feed-urls.sh — Guardrail against regressing the core update channel.
#
# Three rules:
#   1. No tracked Info.plist references the dormant upstream OpenEmu-Update
#      appcast host (raw.github.com/OpenEmu, appcast.openemu.org).
#   2. Every canonical SUFeedURL points at an Appcasts/<name>.xml file that
#      actually exists in the tree.
#   3. Every core Info.plist (one that defines OEGameCoreClass) MUST have a
#      SUFeedURL key. Catches the Flycast-class slip-through where a core was
#      shipped without any SUFeedURL at all, leaving it dependent on
#      CoreUpdater's oecores.xml override for updates.
#
# Runs in CI (build-check.yml, the "Core sources present" job) and as the first step of
# Scripts/core.sh. Cheap to run anywhere else too.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

fail=0

PLISTS=$(git ls-files '*.plist' | grep -v -E '(^|/)archived/')

# 1. No upstream URLs anywhere in tracked plists.
upstream_hits=$(echo "$PLISTS" \
  | xargs grep -l -E 'OpenEmu-Update|raw\.github\.com/OpenEmu|appcast\.openemu\.org' 2>/dev/null \
  || true)

if [ -n "$upstream_hits" ]; then
  echo "ERROR: upstream OpenEmu-Update/openemu.org SUFeedURL still present in:" >&2
  echo "$upstream_hits" >&2
  echo "Replace with https://raw.githubusercontent.com/OpenEmu-Silicon/OpenEmu-Silicon/main/Appcasts/<core>.xml" >&2
  fail=1
fi

# 2. Every canonical SUFeedURL must resolve to an Appcasts/<name>.xml in the tree.
missing=()
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  plist="${hit%%:*}"
  appcast_name=$(echo "$hit" | sed -E 's#.*/Appcasts/([^"<]+)\.xml.*#\1#')
  if [ ! -f "Appcasts/${appcast_name}.xml" ]; then
    missing+=("$plist → Appcasts/${appcast_name}.xml")
  fi
done < <(echo "$PLISTS" \
  | xargs grep -H -E 'raw\.githubusercontent\.com/OpenEmu-Silicon/OpenEmu-Silicon/main/Appcasts/' 2>/dev/null \
  || true)

if [ ${#missing[@]} -gt 0 ]; then
  echo "ERROR: SUFeedURL points at appcast files that don't exist in the tree:" >&2
  for m in "${missing[@]}"; do
    echo "  $m" >&2
  done
  fail=1
fi

# 3. Every core plist (defines OEGameCoreClass) must have a SUFeedURL key.
#    Without this, Sparkle's per-plugin update path is broken; the core's
#    updates only flow through CoreUpdater's oecores.xml override, which is
#    not guaranteed to exist forever and is silently bypassed by anything
#    that drives Sparkle directly.
missing_sufeedurl=()
while IFS= read -r plist; do
  [ -z "$plist" ] && continue
  if grep -q '<key>OEGameCoreClass</key>' "$plist" 2>/dev/null \
     && ! grep -q '<key>SUFeedURL</key>' "$plist" 2>/dev/null; then
    missing_sufeedurl+=("$plist")
  fi
done <<< "$PLISTS"

if [ ${#missing_sufeedurl[@]} -gt 0 ]; then
  echo "ERROR: core Info.plist (has OEGameCoreClass) is missing SUFeedURL:" >&2
  for p in "${missing_sufeedurl[@]}"; do
    echo "  $p" >&2
  done
  echo "Add: <key>SUFeedURL</key><string>https://raw.githubusercontent.com/OpenEmu-Silicon/OpenEmu-Silicon/main/Appcasts/<core>.xml</string>" >&2
  fail=1
fi

if [ $fail -ne 0 ]; then
  exit 1
fi

echo "OK: no upstream references; all core SUFeedURLs resolve; all core plists have SUFeedURL."
