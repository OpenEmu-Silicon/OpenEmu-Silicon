#!/usr/bin/env python3
"""Check the two external source checkouts required by this Xcode project.

No cloning, downloading, patching or file modification is performed. Repos may
be placed anywhere as long as their relative structure matches these settings:
AZAHAR_SOURCE=$(SRCROOT)/../../orig_source/azahar-git
OPENEMU_SOURCE=$(SRCROOT)/../../orig_source/OpenEmu-Silicon-main
"""
from pathlib import Path
import sys


def check_layout(srcroot: Path) -> tuple[bool, list[str]]:
    srcroot = srcroot.resolve()
    upstream = (srcroot / '../../orig_source').resolve()
    cases = [
        ('Azahar CMake sources', upstream/'azahar-git/CMakeLists.txt'),
        ('Azahar libretro core', upstream/'azahar-git/src/citra_libretro/CMakeLists.txt'),
        ('OpenEmu SDK project', upstream/'OpenEmu-Silicon-main/OpenEmu-SDK/OpenEmu-SDK.xcodeproj'),
    ]
    result = []
    passed = True
    for name, path in cases:
        exists = path.is_dir() if path.suffix == '.xcodeproj' else path.is_file()
        result.append(f"{'PASS' if exists else 'MISSING'}: {name}: {path}")
        passed &= exists
    if not passed:
        result += [
            'Fix: place the full Azahar checkout at orig_source/azahar-git',
            'and the OpenEmu source at orig_source/OpenEmu-Silicon-main,',
            'both alongside the 3DS-Azahar-Core directory (not inside azcore).',
            'Azahar submodules must also be initialized before building.',
        ]
    return passed, result


if __name__ == '__main__':
    srcroot = Path(__file__).resolve().parent
    passed, messages = check_layout(srcroot)
    print('3DS Azahar Core upstream source layout (read-only):')
    for message in messages:
        print(message)
    sys.exit(0 if passed else 2)
