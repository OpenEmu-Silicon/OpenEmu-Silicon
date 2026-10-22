#!/usr/bin/env bash
# Prepare the FBNeo (FinalBurn Neo) source used by FBNeo/FBNeo.xcodeproj.
#
# This checks out the OpenEmu-Silicon/fbneo fork's `fbneo-headless` branch, which
# carries our headless burner interface. Unlike the MAME core there is no separate
# local patch file: all OpenEmu-specific changes live on that branch, so updating
# upstream means merging finalburnneo/FBNeo master into fbneo-headless and bumping
# the revision below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
FBNEO_DIR="$REPO_ROOT/FBNeo"
DEPS_DIR="$FBNEO_DIR/deps"
SRC_DIR="$DEPS_DIR/fbneo"
REMOTE="https://github.com/OpenEmu-Silicon/fbneo.git"
BRANCH="fbneo-headless"
# Keep in sync with FBNeo/deps-fbneo-revision.txt.
REVISION="b42f3c264338d01a344be18201aec22622daf980"

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
