#!/usr/bin/env bash
# Prepare the Azahar (Nintendo 3DS) engine source used by the Azahar core.
#
# This checks out a pinned commit of the OpenEmu-Silicon/azahar fork, which is an
# untouched snapshot of the Azahar 2126.2 release. Our own changes to the engine are
# small patches in Azahar/patches/*.patch, which this script applies in name order.
# Updating means merging upstream Azahar into the fork and bumping the revision below.
#
# Azahar's CMake refuses to configure unless every submodule listed in .gitmodules is
# present, including the desktop-only ones (SDL2, openal-soft, cubeb, libusb, ...), so
# this fetches all of them. See docs/3ds-azahar-port.md, "Submodules and the snapshot".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
AZAHAR_DIR="$REPO_ROOT/Azahar"
DEPS_DIR="$AZAHAR_DIR/deps"
SRC_DIR="$DEPS_DIR/azahar"
# The fork lives in the OpenEmu-Silicon org (a fork of azahar-emu/azahar).
REMOTE="https://github.com/OpenEmu-Silicon/azahar.git"
# Keep in sync with Azahar/deps-azahar-revision.txt.
REVISION="219d743a1e698101fe1ab8bef43e6563126c3c27"

# Ignore the user's and the system's git config for everything below. Some Azahar
# submodules (teakra) mark one test file for Git LFS, and a global "lfs required" setting
# on a Mac without git-lfs makes the whole checkout fail with a misleading "remote end
# hung up". Nothing here needs LFS, and all the sources are public.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1

mkdir -p "$DEPS_DIR"

if [ ! -e "$SRC_DIR/.git" ]; then
  echo "Cloning the Azahar fork into $SRC_DIR (shallow)..."
  git init -q "$SRC_DIR"
  git -C "$SRC_DIR" remote add origin "$REMOTE"
fi

cd "$SRC_DIR"

# Repoint origin so the pinned revision resolves against the current fork.
git remote set-url origin "$REMOTE"

# Discard earlier patches before switching revision, so they apply to a clean tree.
git reset -q --hard
git fetch --no-tags --depth=1 origin "$REVISION"
git checkout -q --detach FETCH_HEAD

if [ "$(git rev-parse HEAD)" != "$REVISION" ]; then
  echo "error: fetched commit does not match the pinned revision" >&2
  exit 1
fi

# The submodule commits are recorded by the fork's own gitlinks, so pinning the fork
# commit pins them too. Never use --remote here. A host can drop a connection halfway,
# so each attempt resumes where the last stopped.
git submodule sync --recursive >/dev/null
attempt=1
until git submodule update --init --depth 1 --recursive --jobs 4; do
  if [ "$attempt" -ge 4 ]; then
    echo "error: could not fetch every Azahar submodule after $attempt tries" >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  echo "Retrying the submodule fetch (try $attempt of 4)..." >&2
  sleep 5
done

# A fetch that drops partway can leave a submodule on the right commit with only some of
# its files checked out, and git then treats it as done. Restore every submodule's files
# from its recorded commit and fail if a submodule still has none.
git submodule foreach --quiet --recursive 'git reset -q --hard HEAD'
incomplete=0
while read -r path; do
  if [ -z "$(git -C "$SRC_DIR/$path" ls-files | head -n 1)" ]; then
    echo "error: submodule $path has no files checked out" >&2
    incomplete=1
  fi
done < <(git submodule foreach --quiet --recursive 'echo "$displaypath"')
if [ "$incomplete" -ne 0 ]; then
  exit 1
fi

missing=0
while read -r _ path; do
  if [ ! -e "$path/.git" ]; then
    echo "error: submodule $path is missing" >&2
    missing=1
  fi
done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$')
if [ "$missing" -ne 0 ]; then
  exit 1
fi

shopt -s nullglob
for patch in "$AZAHAR_DIR"/patches/*.patch; do
  echo "Applying $(basename "$patch")"
  git apply "$patch"
done

echo "Azahar source ready at $SRC_DIR (revision $REVISION)"
