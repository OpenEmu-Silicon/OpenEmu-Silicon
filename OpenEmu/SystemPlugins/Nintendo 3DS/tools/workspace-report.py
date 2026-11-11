#!/usr/bin/env python3
"""Print a read-only, privacy-conscious report about the *working* Mac sources.

Usage (from either plugin): python3 tools/workspace-report.py
For tests, --workspace points to a disposable fixture. The report deliberately
omits absolute paths, usernames, Git remotes, shell environment and file names
from modified worktrees. It neither downloads nor alters any source checkout.
It does NOT produce a source lock, certify a fresh build or authorize releases.
"""
import argparse
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

SCHEMA='3ds-openemu-workspace-observation-v1'
NAMES={'azahar':'azahar-git','openemu':'OpenEmu-Silicon-main'}
REQUIRED={
    'azahar':['CMakeLists.txt','src/citra_libretro/CMakeLists.txt',
              'src/citra_libretro/emu_window/libretro_window.cpp',
              'externals/cryptopp/CMakeLists.txt',
              'externals/libretro-common/libretro-common/include/libretro.h'],
    'openemu':['OpenEmu-SDK/OpenEmu-SDK.xcodeproj/project.pbxproj'],
}


def run(argv,timeout=20):
    try:
        result=subprocess.run(argv,text=True,stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL,timeout=timeout,check=False)
    except (OSError,subprocess.TimeoutExpired):
        return None
    if result.returncode:return None
    return result.stdout.strip()


def git_status(repo):
    info={'checkout':'missing','git_commit':None,'tracked_changes':None,
          'untracked_changes':None,'submodules':None,'uninitialized_submodules':None,
          'required_inputs_present':False}
    if not repo.is_dir():return info
    info['checkout']='archive_or_unversioned'
    info['required_inputs_present']=all((repo/path).is_file() for path in REQUIRED[next(k for k,v in NAMES.items() if repo.name==v)])
    # Require .git inside THIS checkout so a parent repository is not mistaken
    # for a pinned upstream. A .git file is valid for a worktree/submodule.
    if not (repo/'.git').exists():return info
    sha=run(['git','-C',str(repo),'rev-parse','HEAD'])
    if not sha or not re.fullmatch(r'[0-9a-f]{40}',sha):
        info['checkout']='git_unreadable'
        return info
    info['checkout']='git'
    info['git_commit']=sha
    changes=run(['git','-C',str(repo),'status','--porcelain','--untracked-files=normal'],timeout=45)
    if changes is not None:
        status=changes.splitlines()
        info['untracked_changes']=sum(x.startswith('??') for x in status)
        info['tracked_changes']=len(status)-info['untracked_changes']
    subs=run(['git','-C',str(repo),'submodule','status','--recursive'],timeout=45)
    if subs is not None:
        entries=subs.splitlines()
        info['submodules']=len(entries)
        info['uninitialized_submodules']=sum(x.startswith(('-', '+', 'U')) for x in entries)
    return info


def digest(path):
    if not path.is_file():return None
    h=hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''): h.update(chunk)
    return h.hexdigest()


def versions(workspace):
    result={}
    for key,rel in [('core','3DS-Azahar-Core/azcore/AzaharCore/Info.plist'),
                    ('system','3DS-System-Plugin/Resources/Nintendo3DS-Info.plist')]:
        path=workspace/rel
        try:
            p=plistlib.loads(path.read_bytes())
            result[key]={'bundle_version':str(p['CFBundleVersion']),
                         'display_version':str(p['CFBundleShortVersionString'])}
        except (OSError,KeyError,ValueError,TypeError):
            result[key]=None
    return result


def toolchain():
    xcode=run(['xcodebuild','-version'],timeout=15) if shutil.which('xcodebuild') else None
    sdk=run(['xcrun','--sdk','macosx','--show-sdk-version'],timeout=15) if shutil.which('xcrun') else None
    m=re.search(r'^Xcode\s+([\w.]+)',xcode or '',re.M)
    n=re.search(r'^[0-9]+(?:\.[0-9]+)*$',sdk or '')
    return {'xcode_version':m.group(1) if m else None,
            'macos_sdk_version':n.group(0) if n else None}


def report(workspace):
    source=workspace/'orig_source'
    repos={key:git_status(source/name) for key,name in NAMES.items()}
    patch=workspace/'3DS-Azahar-Core/azcore/patch-azahar-full-stereo-v199.py'
    lock=workspace/'3DS-Azahar-Core/source-lock.json'
    # This is a local observation only; a Git HEAD does not certify the
    # expected recursive submodule states or all edits in a build tree.
    return {'schema':SCHEMA,'projects':versions(workspace),'sources':repos,
            'stereo_patch_sha256':digest(patch),
            'source_lock_present':lock.is_file(),
            'toolchain':toolchain(),
            'next_step':('run tools/source-lock.py capture then verify on the working Mac'
                         if all(r['checkout']=='git' for r in repos.values())
                         else 'preserve existing orig_source folders; a missing Git checkout cannot yield verifiable commit pins'),
            'limitations':'Read-only observations only; no remote URLs or personal paths included. Not proof of clean build, license permission, or release eligibility.'}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace',type=Path,default=None,help='Parent of both plugins and orig_source')
    a=parser.parse_args()
    root=Path(__file__).resolve().parents[1]
    ws=(a.workspace or root.parent).resolve()
    print(json.dumps(report(ws),indent=2,sort_keys=True))
    return 0

if __name__=='__main__':sys.exit(main())
