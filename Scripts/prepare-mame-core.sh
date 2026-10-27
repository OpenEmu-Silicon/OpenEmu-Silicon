#!/usr/bin/env bash
# Prepare the MAME headless source used by MAME/MAME.xcodeproj.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MAME_DIR="$REPO_ROOT/MAME"
DEPS_DIR="$MAME_DIR/deps"
SRC_DIR="$DEPS_DIR/mame"
REVISION="df0d733e8b938ac24f359513b8697f46e4032c90"
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
# pinned revision, so drop those edits, but only on a revision that patch was
# applied to. Any other local change, staged or not, is left alone.
LEGACY_REVISIONS=(
  4fc1f9f16b0dfba6be670367330028635613b04b
  fac13e827b7b8cfa4ee4f5760198d31241e2a544
)
LEGACY_PATCHED=(
  3rdparty/sol2/sol/sol.hpp
  3rdparty/zlib/zutil.h
  src/devices/cpu/v60/op2.hxx
)
CHANGED="$(git diff --name-only HEAD)"
if [ -n "$CHANGED" ]; then
  HEAD_REVISION="$(git rev-parse HEAD)"
  OTHER_CHANGES="$(printf '%s\n' "$CHANGED" | grep -vxF -f <(printf '%s\n' "${LEGACY_PATCHED[@]}") || true)"
  if printf '%s\n' "${LEGACY_REVISIONS[@]}" | grep -qxF "$HEAD_REVISION" && [ -z "$OTHER_CHANGES" ]; then
    echo "Dropping the old 0.250 local patch..."
    git checkout HEAD -- "${LEGACY_PATCHED[@]}"
  else
    echo "error: $SRC_DIR has local changes; commit, stash, or discard them first:" >&2
    git status --short --untracked-files=no >&2
    exit 1
  fi
fi

git checkout --detach "$REVISION"

echo "MAME source ready at $SRC_DIR"
