#!/usr/bin/env python3
"""detect-core-changes.py - decide which core schemes CI needs to build.

Used by .github/workflows/build-check.yml. Reads the list of changed files
(`git diff --name-only <base> <head>`) and prints a JSON object:

    {"cores": [...], "reason": "...", "skipped": [...]}

Rules, from most to least conservative:

1. A change under a core's own directory selects that core.
2. A change to OpenEmu-SDK/, Vendor/ or the workspace selects every core
   (cores link the OpenEmuBase framework from the SDK, and many compile
   Vendor/rcheevos, so the dependency is not per-file).
3. A change under OpenEmuKit/ is narrowed using the cores' Xcode projects:
     - a file a core's project references by path selects that core;
     - a C-family source or header in a directory a core's project puts on
       its header search path selects that core (it could be #imported);
     - a Swift or documentation file selects no core: cores are plain
       ObjC/C++ bundles and cannot see Swift. The `Build (arm64)` job builds
       the app and OpenEmuKit itself.
     - anything else (project files, xcconfig, modulemaps, scripts, new
       kinds of file) selects every core.

The map is read from the .pbxproj files on every run, so there is no
committed table that can drift out of date.

Scripts/ is deliberately not a trigger: no Xcode project calls it.
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

# Scheme/core name -> top-level directory, when they differ from the name.
CORE_DIRS = {"Potator": "Potator-Core", "Picodrive": "picodrive"}

ALL_CORES = [
    "4DO", "Atari800", "Bliss", "BSNES", "CrabEmu", "DeSmuME", "Dolphin",
    "FCEU", "Flycast", "Gambatte", "GenesisPlus", "JollyCV", "Mednafen",
    "mGBA", "Mupen64Plus", "Nestopia", "O2EM", "Picodrive", "PokeMini",
    "Potator", "PPSSPP", "ProSystem", "SNES9x", "Stella", "VecXGL",
    "VirtualJaguar", "blueMSX",
]

# Vendor/ (rcheevos) is on many cores' header search paths and source lists.
SHARED_ALL_PREFIXES = ("OpenEmu-SDK/", "OpenEmu-metal.xcworkspace/", "Vendor/")

# Files a core build could pull in from a header search path.
CORE_VISIBLE_EXTS = {".h", ".hpp", ".m", ".mm", ".c", ".cc", ".cpp", ".pch", ".inc"}
# Files no core build can see.
CORE_INVISIBLE_EXTS = {".swift", ".md", ".rl", ".txt"}

KIT = "OpenEmuKit/"
# A pbxproj mentions the kit as a relative path, e.g. ../OpenEmuKit/Source/X.m
# or $(SRCROOT)/../OpenEmuKit/Source. Stop at whitespace, quote, ; or ,.
KIT_REF = re.compile(r"(?:\.\./)+(OpenEmuKit(?:/[^\s\"\\\\;,]*)?)")
# Xcode search paths often end in /** (recursive); strip it to get the folder.
GLOB_SUFFIX = re.compile(r"/\*+$")


def core_dir(core):
    return CORE_DIRS.get(core, core)


def kit_refs_for_core(core):
    """Return (files, dirs): OpenEmuKit paths this core's projects reference.

    A reference with a file extension is a file; one without is a directory
    (a header search path or group).
    """
    files, dirs = set(), set()
    base = os.path.join(REPO_ROOT, core_dir(core))
    # Projects sit at the core's top level or one folder down (PPSSPP).
    projects = glob.glob(os.path.join(base, "*.xcodeproj", "project.pbxproj"))
    projects += glob.glob(os.path.join(base, "*", "*.xcodeproj", "project.pbxproj"))
    for project in projects:
        with open(project, encoding="utf-8", errors="replace") as f:
            text = f.read()
        for match in KIT_REF.finditer(text):
            ref = GLOB_SUFFIX.sub("", match.group(1)).rstrip("/")
            if os.path.splitext(ref)[1]:
                files.add(ref)
            else:
                dirs.add(ref)
    return files, dirs


def build_map(cores):
    return {core: kit_refs_for_core(core) for core in cores}


def select(changed, cores=ALL_CORES, kit_map=None):
    """Return (selected_cores, reason) for a list of changed paths."""
    changed = [c for c in changed if c]
    if kit_map is None:
        kit_map = build_map(cores)

    selected = set()
    for path in changed:
        if path.startswith(SHARED_ALL_PREFIXES):
            return list(cores), "shared SDK/workspace changed: " + path

        for core in cores:
            if path.startswith(core_dir(core) + "/"):
                selected.add(core)

        if not path.startswith(KIT):
            continue

        ext = os.path.splitext(path)[1].lower()
        hit = False
        for core, (files, dirs) in kit_map.items():
            if path in files:
                selected.add(core)
                hit = True
            elif ext in CORE_VISIBLE_EXTS and any(
                path.startswith(d + "/") for d in dirs
            ):
                selected.add(core)
                hit = True
        if hit:
            continue
        if ext in CORE_INVISIBLE_EXTS:
            continue
        # Unknown kind of change under OpenEmuKit/: stay conservative.
        return list(cores), "unmapped OpenEmuKit change: " + path

    ordered = [c for c in cores if c in selected]
    return ordered, "narrowed from changed files"


def changed_files(base, head):
    out = subprocess.run(
        ["git", "-c", "core.quotePath=false", "diff", "--no-renames", "--name-only", base, head],
        cwd=REPO_ROOT, check=True, capture_output=True, text=True,
    ).stdout
    return out.splitlines()


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", help="diff base commit")
    parser.add_argument("--head", default="HEAD", help="diff head commit")
    parser.add_argument("--files", help="read changed paths from this file instead of git ('-' = stdin)")
    parser.add_argument("--print-map", action="store_true", help="print each core's OpenEmuKit references and exit")
    args = parser.parse_args()

    if args.print_map:
        for core, (files, dirs) in build_map(ALL_CORES).items():
            if files or dirs:
                print(core)
                for d in sorted(dirs):
                    print("  dir ", d)
                for f in sorted(files):
                    print("  file", f)
        return 0

    if args.files:
        src = sys.stdin if args.files == "-" else open(args.files)
        changed = src.read().splitlines()
    elif args.base:
        changed = changed_files(args.base, args.head)
    else:
        parser.error("give --base or --files")

    cores, reason = select(changed)
    skipped = [c for c in ALL_CORES if c not in cores]
    print(json.dumps({"cores": cores, "reason": reason, "skipped": skipped}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
