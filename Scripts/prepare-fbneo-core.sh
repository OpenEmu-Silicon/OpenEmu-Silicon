#!/usr/bin/env bash
# Prepare the FBNeo (FinalBurn Neo) source used by FBNeo/FBNeo.xcodeproj.
#
# This checks out a pinned revision of the OpenEmu-Silicon/fbneo fork, which
# carries our headless burner interface. Unlike the MAME core there is no separate
# local patch file: all OpenEmu-specific changes live on the branch, so updating
# means merging finalburnneo/FBNeo master into that branch and bumping the
# revision below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
FBNEO_DIR="$REPO_ROOT/FBNeo"
DEPS_DIR="$FBNEO_DIR/deps"
SRC_DIR="$DEPS_DIR/fbneo"
REMOTE="https://github.com/OpenEmu-Silicon/fbneo.git"
BRANCH="fbneo-headless"
# Keep in sync with FBNeo/deps-fbneo-revision.txt.
REVISION="cd62b592c67946136e1b731c40441d7d41452262"

mkdir -p "$DEPS_DIR"

if [ ! -e "$SRC_DIR/.git" ]; then
  echo "Cloning OpenEmu-Silicon/fbneo into $SRC_DIR..."
  git clone --no-tags --branch "$BRANCH" "$REMOTE" "$SRC_DIR"
fi

cd "$SRC_DIR"

# Existing checkouts may point origin at a personal fork; repoint before fetching
# so the pinned revision resolves against the OpenEmu-Silicon fork.
git remote set-url origin "$REMOTE"

git fetch --no-tags origin "$REVISION"
git checkout --detach "$REVISION"

echo "FBNeo source ready at $SRC_DIR (revision $REVISION)"
