#!/usr/bin/env python3
"""Read-only manifest of upstream source revisions used for a developer build.

Usage (from either plugin):
  python3 tools/capture-source-revisions.py
  python3 tools/capture-source-revisions.py --strict --output source-revisions.json

This tool never downloads sources or changes Git working trees. It deliberately
omits absolute paths, usernames, environment variables, credentials and ROMs.
A dirty Azahar checkout is expected after applying the v199 stereo patch: the
base Git commit alone is NOT enough to reproduce that patched working tree.
"""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path


def git(repo, *args):
    if shutil.which('git') is None:
        return None
    try:
        return subprocess.check_output(
            ['git', '-C', str(repo), *args], stderr=subprocess.DEVNULL,
            text=True, timeout=12).strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError):
        return None


def describe_repo(repo):
    if not repo.is_dir() or git(repo, 'rev-parse', '--show-toplevel') is None:
        return {'available': False, 'commit': None, 'dirty': None,
                'changed_paths': None, 'submodules': []}
    commit = git(repo, 'rev-parse', 'HEAD')
    porcelain = git(repo, 'status', '--porcelain', '--untracked-files=no')
    submodule_lines = git(repo, 'submodule', 'status', '--recursive')
    submodules = []
    if submodule_lines is not None:
        for line in submodule_lines.splitlines():
            match = re.match(r'^([ +\-U]?)([0-9a-f]{40})\s+(\S+)', line)
            if match:
                submodules.append({'path': match.group(3),
                                   'commit': match.group(2),
                                   'status': {'-': 'not_initialized',
                                              '+': 'different_commit',
                                              'U': 'conflict'}.get(match.group(1), 'present')})
    return {'available': bool(commit), 'commit': commit,
            'dirty': None if porcelain is None else bool(porcelain),
            'changed_paths': None if porcelain is None else len(porcelain.splitlines()),
            'submodules': submodules}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--azahar-source', type=Path)
    parser.add_argument('--openemu-source', type=Path)
    parser.add_argument('--output', type=Path, help='Optional JSON output file; default stdout')
    parser.add_argument('--strict', action='store_true',
                        help='Exit nonzero if source repositories or initialized submodules are missing')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    sources = root.parent / 'orig_source'
    azahar = args.azahar_source or (sources/'azahar-git')
    openemu = args.openemu_source or (sources/'OpenEmu-Silicon-main')
    azahar_record = describe_repo(azahar)
    openemu_record = describe_repo(openemu)
    patch = root/'azcore/patch-azahar-full-stereo-v199.py'
    manifest = {
        'schema': '3ds-openemu-source-provenance-v1',
        'component': 'Core' if (root/'azcore/Azahar.xcodeproj').exists() else 'System Plugin',
        'upstream': {'azahar': azahar_record, 'openemu': openemu_record},
        'local_patch_sha256': sha256(patch),
        'notes': [
            'Commits identify the BASE upstream revision, not uncommitted modifications.',
            'Azahar full-width side-by-side libretro patch is applied during Core build.',
            'Review local patch and all submodule commits before a reproducible public release.',
            'This is a source manifest, not proof of a successful Xcode build or an audit of licenses.'
        ]
    }
    serialized = json.dumps(manifest, indent=2, sort_keys=True) + '\n'
    if args.output:
        args.output.write_text(serialized, encoding='utf-8')
        print('Wrote source revision manifest (no absolute paths or credentials).')
    else:
        print(serialized, end='')
    missing = (not azahar_record['available'] or not openemu_record['available'] or
               any(sub['status'] != 'present' for sub in azahar_record['submodules']) or
               any(sub['status'] != 'present' for sub in openemu_record['submodules']))
    if args.strict and missing:
        print('Source provenance incomplete: provide full Git checkouts and submodules.', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
