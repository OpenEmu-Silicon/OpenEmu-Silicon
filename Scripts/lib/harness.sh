# harness.sh — Shared helpers for check.sh, playtest.sh and doctor.sh. Source it; do not run it.

# Default build folder, shared so one build serves check.sh and playtest.sh.
harness_build_dir() { echo "${OE_BUILD_DIR:-${OE_PLAYTEST_BUILD:-$HOME/Builds/openemu/harness}}"; }

# The text that marks a credential file as the placeholder copy of its template. A build with placeholders compiles
# but cannot sign in to the service (ScreenScraper answers "bad credentials"). Only ScreenScraper is checked: a real
# CheatWorks token is not kept in any worktree on the maintainer's Mac, so a check on it would only ever complain.
harness_placeholder_marker() {
  case "$1" in
    ScreenScraperDevCredentials) echo "YOUR_DEV_ID" ;;
    CheatWorksSecrets) echo "placeholderClientAccessToken" ;;
  esac
}

# Prints the name of each checked credential file that is missing or still holds the placeholders.
harness_placeholder_credentials() {
  local root="$1" f marker
  for f in ScreenScraperDevCredentials; do
    marker=$(harness_placeholder_marker "$f")
    if [ ! -f "$root/OpenEmu/$f.swift" ] || grep -q "$marker" "$root/OpenEmu/$f.swift"; then echo "$f"; fi
  done
}

# The first other worktree of this repository that holds a real (non-placeholder) copy of a credential file.
harness_find_real_credentials() {
  local root="$1" f="$2" marker dir
  marker=$(harness_placeholder_marker "$f")
  git -C "$root" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | while read -r dir; do
    [ "$dir" = "$root" ] && continue
    if [ -f "$dir/OpenEmu/$f.swift" ] && ! grep -q "$marker" "$dir/OpenEmu/$f.swift"; then echo "$dir/OpenEmu/$f.swift"; break; fi
  done
}

# A fresh worktree has no copy of the gitignored credential files, and the app does not build without them. Use a
# real copy from another worktree of this repository when there is one (they are gitignored and stay on this Mac);
# otherwise the template, with a warning, because a build with the placeholders cannot sign in to the service.
harness_ensure_stubs() {
  local root="$1" f real
  for f in ScreenScraperDevCredentials CheatWorksSecrets; do
    if [ ! -f "$root/OpenEmu/$f.swift" ]; then
      real=$(harness_find_real_credentials "$root" "$f")
      if [ -n "$real" ]; then
        cp "$real" "$root/OpenEmu/$f.swift" && echo "----  copied OpenEmu/$f.swift from another worktree of this repository"
      elif [ -f "$root/OpenEmu/$f.template.swift" ]; then
        cp "$root/OpenEmu/$f.template.swift" "$root/OpenEmu/$f.swift" && echo "----  created OpenEmu/$f.swift from its template"
      fi
    fi
  done
  for f in $(harness_placeholder_credentials "$root"); do
    echo "WARN  OpenEmu/$f.swift holds placeholders: this build cannot sign in to its service. Copy the real file from a worktree that has it." >&2
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

# Only one harness run (check.sh, playtest.sh) may use the library at a time: two at once replace each other's
# auto saves and fight over the single OpenEmu process. /private/tmp, not $TMPDIR: sessions can have different ones.
HARNESS_LOCK=/private/tmp/openemu-harness.lock
harness_take_lock() {
  local holder
  if ! mkdir "$HARNESS_LOCK" 2>/dev/null; then
    holder="$(cat "$HARNESS_LOCK/pid" 2>/dev/null)"
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
      echo "FAIL  another harness run is in progress (pid $holder: $(ps -o command= -p "$holder" 2>/dev/null | cut -c1-100))." >&2
      echo "      Wait for it to finish; two runs at once overwrite each other's saves." >&2
      return 1
    fi
    rm -rf "$HARNESS_LOCK"; mkdir "$HARNESS_LOCK" 2>/dev/null || return 1   # the holder died without releasing it
  fi
  echo "$$" > "$HARNESS_LOCK/pid"
}
harness_release_lock() { [ "$(cat "$HARNESS_LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$HARNESS_LOCK"; return 0; }

# Quit any debug OpenEmu started from this build folder (used from an EXIT trap).
harness_kill_debug_app() {
  local app="$1/Build/Products/Debug/OpenEmu.app/Contents/MacOS/OpenEmu"
  pkill -TERM -f "$app" 2>/dev/null || true
  # Give the app up to 15 seconds to finish what it is writing (the library, saves) before the hard kill,
  # which can cut a write in half.
  local waited=0
  while pgrep -f "$app" >/dev/null 2>&1 && [ "$waited" -lt 15 ]; do sleep 1; waited=$((waited + 1)); done
  pkill -KILL -f "$app" 2>/dev/null || true
}

# What is holding the way: "OpenEmu is running" with its pid and the path it runs from.
harness_describe_running() {
  local pid
  for pid in $(pgrep -x OpenEmu); do
    echo "      pid $pid: $(ps -o comm= -p "$pid")"
  done
}
