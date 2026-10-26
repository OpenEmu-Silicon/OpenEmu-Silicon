#!/usr/bin/env bash
# Prepare the ARMSX2 (PlayStation 2) engine source used by the PCSX2 core.
#
# This checks out a pinned commit of the ARMSX2 fork. Our own changes to the
# engine (the Metal output hook, data paths) go in the fork, or for a small
# change in PCSX2/patches/*.patch, which this script applies in name order.
# Updating means merging upstream ARMSX2 into the fork and bumping the
# revision below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PCSX2_DIR="$REPO_ROOT/PCSX2"
DEPS_DIR="$PCSX2_DIR/deps"
SRC_DIR="$DEPS_DIR/armsx2"
# This fork moves to the OpenEmu-Silicon org later; change this one line then.
REMOTE="https://github.com/nickybmon/armsx2.git"
# Keep in sync with PCSX2/deps-armsx2-revision.txt.
REVISION="65fd14b9160e7fa3779794fc45c4e92a86772621"

mkdir -p "$DEPS_DIR"

if [ ! -e "$SRC_DIR/.git" ]; then
  echo "Cloning ARMSX2 fork into $SRC_DIR (shallow)..."
  git init -q "$SRC_DIR"
  git -C "$SRC_DIR" remote add origin "$REMOTE"
fi

cd "$SRC_DIR"

# Repoint origin so the pinned revision resolves against the current fork.
git remote set-url origin "$REMOTE"

# Discard earlier patches before switching revision, so they apply to a clean tree.
git reset -q --hard
GIT_LFS_SKIP_SMUDGE=1 git fetch --no-tags --depth=1 origin "$REVISION"
git checkout -q --detach FETCH_HEAD

if [ "$(git rev-parse HEAD)" != "$REVISION" ]; then
  echo "error: fetched commit does not match the pinned revision" >&2
  exit 1
fi

shopt -s nullglob
for patch in "$PCSX2_DIR"/patches/*.patch; do
  echo "Applying $(basename "$patch")"
  git apply "$patch"
done

echo "ARMSX2 source ready at $SRC_DIR (revision $REVISION)"
