# harness.sh — Shared helpers for check.sh, playtest.sh and doctor.sh. Source it; do not run it.

# Default build folder, shared so one build serves check.sh and playtest.sh.
harness_build_dir() { echo "${OE_BUILD_DIR:-${OE_PLAYTEST_BUILD:-$HOME/Builds/openemu/harness}}"; }

# A fresh worktree has no copy of the gitignored credential stubs, and the app does not build without them.
harness_ensure_stubs() {
  local root="$1" f
  for f in ScreenScraperDevCredentials CheatWorksSecrets; do
    if [ ! -f "$root/OpenEmu/$f.swift" ] && [ -f "$root/OpenEmu/$f.template.swift" ]; then
      cp "$root/OpenEmu/$f.template.swift" "$root/OpenEmu/$f.swift" && echo "----  created OpenEmu/$f.swift from its template"
    fi
  done
}

# SHA-1 hashes of the valid code-signing identities with this name (one per line). With two certificates of the
# same name, signing by name is ambiguous; signing by hash is not.
harness_sign_hashes() {
  security find-identity -v -p codesigning 2>/dev/null | awk -v n="\"$1\"" 'index($0, n) { print $2 }'
}

# Prints the identity to sign with: the hash of the first valid certificate, or nothing when there is none.
harness_sign_identity() {
  local name="${OE_DEBUG_SIGN_IDENTITY:-OpenEmu Debug}"
  harness_sign_hashes "$name" | head -1
}

# Prints a warning when more than one certificate has the signing name.
harness_warn_duplicate_certs() {
  local name="${OE_DEBUG_SIGN_IDENTITY:-OpenEmu Debug}" n
  n=$(harness_sign_hashes "$name" | wc -l | tr -d ' ')
  if [ "$n" -gt 1 ]; then
    echo "WARN  $n certificates named \"$name\" in your keychain; signing with the first one by hash ($(harness_sign_identity))." >&2
    echo "      Delete the extras in Keychain Access so the macOS permission grants stay tied to one certificate." >&2
  fi
}

# Quit any debug OpenEmu started from this build folder (used from an EXIT trap).
harness_kill_debug_app() {
  local app="$1/Build/Products/Debug/OpenEmu.app/Contents/MacOS/OpenEmu"
  pkill -TERM -f "$app" 2>/dev/null || true
  sleep 1
  pkill -KILL -f "$app" 2>/dev/null || true
}

# What is holding the way: "OpenEmu is running" with its pid and the path it runs from.
harness_describe_running() {
  local pid
  for pid in $(pgrep -x OpenEmu); do
    echo "      pid $pid: $(ps -o comm= -p "$pid")"
  done
}
