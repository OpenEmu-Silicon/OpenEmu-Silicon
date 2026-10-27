#!/usr/bin/env bash
# Prepare the MAME headless source used by MAME/MAME.xcodeproj.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MAME_DIR="$REPO_ROOT/MAME"
DEPS_DIR="$MAME_DIR/deps"
SRC_DIR="$DEPS_DIR/mame"
REVISION="03d423c25ec27de365e358cfd1851d772dc32b19"
REMOTE="https://github.com/OpenEmu-Silicon/mame.git"

mkdir -p "$DEPS_DIR"

if [ ! -e "$SRC_DIR/.git" ]; then
  echo "Cloning OpenEmu-Silicon/mame into $SRC_DIR..."
  git clone --no-tags "$REMOTE" "$SRC_DIR"
fi

cd "$SRC_DIR"

# Existing checkouts may still point origin at the old stuartcarnie/mame remote;
# repoint before fetching so the pinned revision resolves.
git remote set-url origin "$REMOTE"

git fetch --no-tags origin "$REVISION"

# Checkouts prepared for MAME 0.250 still carry the old local patch
# (patches/mame-headless-clang21-apple.patch). Its fixes are upstream in the
# pinned revision, so drop those edits; refuse to touch any other local change.
LEGACY_PATCHED=(
  3rdparty/sol2/sol/sol.hpp
  3rdparty/zlib/zutil.h
  src/devices/cpu/v60/op2.hxx
)
CHANGED="$(git status --porcelain --untracked-files=no | awk '{print $2}')"
if [ -n "$CHANGED" ]; then
  for f in $CHANGED; do
    if ! printf '%s\n' "${LEGACY_PATCHED[@]}" | grep -qx "$f"; then
      echo "error: $SRC_DIR has local changes; commit, stash, or discard them first:" >&2
      git status --short --untracked-files=no >&2
      exit 1
    fi
  done
  echo "Dropping the old 0.250 local patch..."
  git checkout -- "${LEGACY_PATCHED[@]}"
fi

git checkout --detach "$REVISION"

echo "MAME source ready at $SRC_DIR"
