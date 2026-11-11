#!/usr/bin/env python3
"""Pin, verify or reconstruct *upstream* source trees for 3DS OpenEmu.

No source modification is performed by `capture` or `verify`; bootstrap only
creates previously absent upstream checkouts under a chosen workspace. In
particular, no command in this tool patches Azahar or edits OpenEmu.

Run `capture` on the working Mac to record actual upstream commits; then
explicitly supply the public/reviewed repository URLs before `bootstrap`.
An incomplete lock is useful for review but cannot bootstrap. No URLs or
revision hashes are guessed.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SCHEMA = '3ds-openemu-source-lock-v1'
NAMES = {'azahar': 'azahar-git', 'openemu': 'OpenEmu-Silicon-main'}
PATCH_REL = Path('src/citra_libretro/emu_window/libretro_window.cpp')
HEX40 = re.compile(r'^[0-9a-f]{40}$')
HEX64 = re.compile(r'^[0-9a-f]{64}$')


def execute(*argv, cwd=None, timeout=120):
    p = subprocess.run(list(map(str, argv)), cwd=cwd, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       timeout=timeout, check=False)
    if p.returncode:
        raise RuntimeError(f'{argv[0]} {argv[1] if len(argv)>1 else ""} failed: '
                           + p.stderr.strip()[-550:])
    return p.stdout.rstrip('\n')


def git(repo, *args):
    return execute('git', '-C', repo, *args)


def project_paths(root, workspace):
    core = root if (root/'azcore/Azahar.xcodeproj').exists() else workspace/'3DS-Azahar-Core'
    patch = core/'azcore/patch-azahar-full-stereo-v199.py'
    return patch, workspace/'orig_source'


def patch_sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def exact_v199_only(repo, patch_file):
    """Allow the sole known dirty file only if bytes match the reviewed patch.

    Compare to `git show HEAD:...`, not merely a marker name or filename.
    An unrelated manual edit to the same source file is not reproducible.
    """
    changes = [x for x in git(repo, 'diff', '--name-only', 'HEAD', '--').splitlines() if x]
    if not changes:
        return 'clean'
    if changes != [PATCH_REL.as_posix()] or not patch_file.is_file():
        raise RuntimeError(f'Unreproducible tracked edits in {repo.name}: {len(changes)} changed paths')
    p = subprocess.run(['git','-C',str(repo),'show','HEAD:'+PATCH_REL.as_posix()], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    original = p.stdout.decode('utf-8')
    current = (repo/PATCH_REL).read_text(encoding='utf-8')
    # The patch file is source-controlled in the Core project, but do not
    # execute it or alter the upstream checkout while checking provenance.
    marker = 'AZAHAR_OPENEMU_V199_STEREO_GEOMETRY'
    patch = '    // AZAHAR_OPENEMU_V199_STEREO_GEOMETRY\n    // Unlike half-width stereo, Full SBS must keep the normal horizontal\n    // resolution for EACH eye. EmuWindow::UpdateCurrentFramebufferLayout()\n    // later halves the supplied width to lay out each eye, so give it twice\n    // the ordinary libretro framebuffer width in Full mode only.\n    if (Settings::values.render_3d.GetValue() ==\n        Settings::StereoRenderOption::SideBySideFull) {\n        baseX *= 2u;\n    }\n\n'
    start = 'LayoutGeometry ComputeLayoutGeometry() {'
    end = 'void EmuWindow_LibRetro::UpdateLayout() {'
    if original.count(start)!=1 or original.count(end)!=1 or marker in original:
        raise RuntimeError('Cannot confirm known v199 patch against upstream baseline')
    a = original.index(start)
    b = original.index(end,a)
    segment = original[a:b]
    positions=list(re.finditer(r'(?m)^([ \t]*)return\s*\{\s*baseX\s*,\s*baseY\s*,\s*emulated_pointer\s*\}\s*;',segment))
    if len(positions)!=1:
        raise RuntimeError('Upstream source structure changed; v199 patch must be reviewed')
    expected = original[:a] + segment[:positions[0].start()] + patch + segment[positions[0].start():] + original[b:]
    if current != expected:
        raise RuntimeError('Azahar tracked modifications are not exclusively the known v199 stereo patch')
    return 'known_v199_patch'


def source_record(repo, key, patch):
    if not (repo/'.git').exists():
        # A directory with .git as a FILE is still a valid git worktree.
        if not (repo/'.git').is_file():
            raise RuntimeError(f'{NAMES[key]} must be a real Git checkout (not a source ZIP)')
    top = Path(git(repo, 'rev-parse', '--show-toplevel')).resolve()
    if top != repo.resolve():
        raise RuntimeError(f'{NAMES[key]} is not a standalone repository root')
    sha = git(repo, 'rev-parse', 'HEAD')
    if not HEX40.fullmatch(sha):
        raise RuntimeError('Invalid Git commit hash')
    changed = git(repo, 'diff', '--name-only', 'HEAD', '--').splitlines()
    untracked=[x for x in git(repo,'ls-files','--others','--exclude-standard').splitlines()
               if x and (key!='azahar' or x != str(PATCH_REL)+'.openemu-v199-original.bak')]
    if untracked:
        raise RuntimeError(f'Untracked upstream files are not reproducible from Git: {key} ({len(untracked)} paths)')
    if key == 'azahar':
        state = exact_v199_only(repo, patch) if changed else 'clean'
    elif changed:
        raise RuntimeError('OpenEmu checkout has tracked edits not captured by a commit')
    else:
        state = 'clean'
    # Untracked files are not included in a Git clone; warn rather than
    # treating the known v199 backup or normal local build output as source.
    submodule_lines = git(repo, 'submodule', 'status', '--recursive')
    submodules=[]
    for line in submodule_lines.splitlines():
        m=re.match(r'^([ +\-U]?)([0-9a-f]{40})\s+(\S+)',line)
        if not m:
            raise RuntimeError('Cannot parse submodule status; inspect Git repository')
        if m.group(1)!=' ':
            raise RuntimeError(f'Submodule not at recorded commit: {m.group(3)}')
        submodules.append({'path':m.group(3),'commit':m.group(2)})
    return {'commit':sha,'submodules':submodules},state


def check_layout(source):
    required = [
        (source/'azahar-git/CMakeLists.txt','Azahar CMakeLists'),
        (source/'azahar-git/src/citra_libretro/CMakeLists.txt','Azahar libretro target'),
        (source/'azahar-git/src/citra_libretro/emu_window/libretro_window.cpp','Azahar stereo source'),
        (source/'azahar-git/externals/cryptopp/CMakeLists.txt','Azahar cryptopp submodule'),
        (source/'azahar-git/externals/libretro-common/libretro-common/include/libretro.h','Azahar libretro-common submodule'),
        (source/'OpenEmu-Silicon-main/OpenEmu-SDK/OpenEmu-SDK.xcodeproj/project.pbxproj','OpenEmu SDK Xcode project'),
    ]
    missing=[label for path,label in required if not path.is_file()]
    if missing:
        raise RuntimeError('Missing upstream build inputs: '+', '.join(missing))


def valid_lock(lock):
    if not isinstance(lock,dict) or lock.get('schema') != SCHEMA:
        raise RuntimeError('Invalid or unsupported source-lock schema')
    repos=lock.get('repositories')
    if not isinstance(repos,dict) or set(repos)!=set(NAMES):
        raise RuntimeError('Source lock must describe exactly azahar and openemu')
    for key in NAMES:
        r=repos[key]
        if not isinstance(r,dict) or not HEX40.fullmatch(str(r.get('commit',''))):
            raise RuntimeError(f'Missing or invalid {key} commit pin')
        subs=r.get('submodules')
        if not isinstance(subs,list):
            raise RuntimeError(f'Missing {key} recursive submodule pins')
        for sub in subs:
            if not isinstance(sub,dict) or not HEX40.fullmatch(str(sub.get('commit',''))) or not isinstance(sub.get('path'),str):
                raise RuntimeError(f'Invalid {key} submodule pin')
    digest=lock.get('patches',{}).get('full_stereo_v199_sha256')
    if not isinstance(digest,str) or not HEX64.fullmatch(digest):
        raise RuntimeError('Source lock requires exact local stereo patch SHA-256')
    return repos


def check_against_lock(lock, source, patch):
    repos = valid_lock(lock)
    if patch_sha(patch) != lock['patches']['full_stereo_v199_sha256']:
        raise RuntimeError('Local v199 patch file differs from source lock')
    check_layout(source)
    for key,name in NAMES.items():
        found,state=source_record(source/name,key,patch)
        expected=repos[key]
        if found['commit'] != expected['commit']:
            raise RuntimeError(f'{key} checkout differs from pinned Git commit')
        if found['submodules'] != expected['submodules']:
            raise RuntimeError(f'{key} submodule revisions differ from source lock')
        print(f'PASS {key} commit={found["commit"][:12]} submodules={len(found["submodules"])} worktree={state}')


def require_url(url, allow_local):
    if not isinstance(url,str) or not url.strip():
        raise RuntimeError('Source lock lacks explicit reviewed repository URL')
    if re.match(r'^https://[^/]*@',url):
        raise RuntimeError('Do not place embedded access tokens/passwords in public source locks')
    if url.startswith(('https://','ssh://','git@')):
        return url
    if allow_local and (url.startswith('file://') or Path(url).is_dir()):
        return url
    raise RuntimeError('Expected HTTPS/SSH Git URL; local fixture paths require --allow-local-url')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['capture','verify','bootstrap','inspect'])
    parser.add_argument('--workspace',type=Path,help='Parent directory of both plugins and orig_source')
    parser.add_argument('--lock',type=Path,help='source-lock.json (defaults to project root)')
    parser.add_argument('--azahar-url',help='Explicit reviewed Azahar repository URL (capture only)')
    parser.add_argument('--openemu-url',help='Explicit reviewed OpenEmu repository URL (capture only)')
    parser.add_argument('--allow-local-url',action='store_true',help='For offline test fixtures only')
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[1]
    workspace=(args.workspace or root.parent).resolve()
    lock_file=(args.lock or (root/'source-lock.json')).resolve()
    patch,default_sources=project_paths(root,workspace)
    sources=workspace/'orig_source'
    if args.action=='inspect':
        check_layout(sources)
        print('PASS external source layout; this is NOT a compilation or revision lock check')
        return 0
    if not patch.is_file():
        raise RuntimeError('Expected sibling 3DS-Azahar-Core stereo patch source is missing')
    if args.action=='capture':
        check_layout(sources)
        result={}
        for key,name in NAMES.items():
            record,state=source_record(sources/name,key,patch)
            url={'azahar':args.azahar_url,'openemu':args.openemu_url}[key]
            if url: require_url(url,args.allow_local_url)
            record['url']=url
            result[key]=record
            print(f'PASS {key} pinned={record["commit"][:12]} state={state}')
        lock={'schema':SCHEMA,'repositories':result,
              'patches':{'full_stereo_v199_sha256':patch_sha(patch)},
              'notes':'Commit pins identify unpatched upstream sources; the reviewed v199 stereo patch is applied by the Core build. Fill in explicit reviewed URLs to enable bootstrap. Do not publish a private URL.'}
        valid_lock(lock)
        lock_file.parent.mkdir(parents=True,exist_ok=True)
        lock_file.write_text(json.dumps(lock,indent=2,sort_keys=True)+'\n',encoding='utf-8')
        print('PASS source lock captured. URLs specified:',all(result[k]['url'] for k in NAMES))
        return 0
    if not lock_file.is_file():
        raise RuntimeError(f'Missing {lock_file.name}; run capture on the working Mac first')
    lock=json.loads(lock_file.read_text(encoding='utf-8'))
    repos=valid_lock(lock)
    if args.action=='verify':
        check_against_lock(lock,sources,patch)
        print('PASS upstream revision lock and known source modifications')
        return 0
    if args.action=='bootstrap':
        if patch_sha(patch)!=lock['patches']['full_stereo_v199_sha256']:
            raise RuntimeError('Local stereo patch SHA-256 differs from the source lock')
        urls={key:require_url(repos[key].get('url'),args.allow_local_url) for key in NAMES}
        sources.mkdir(parents=True,exist_ok=True)
        for name in NAMES.values():
            if (sources/name).exists() or (sources/name).is_symlink():
                raise RuntimeError(f'Refusing to overwrite existing upstream directory {name}')
        # Clone everything to disposable staging directories. Move into the
        # workspace only after BOTH repositories reach their locked revisions.
        with tempfile.TemporaryDirectory(prefix='.3ds-source-lock-',dir=sources) as temp:
            staged={}
            for key,name in NAMES.items():
                target=Path(temp)/name
                print(f'Cloning locked {key} upstream checkout...')
                execute('git','clone','--no-checkout',urls[key],target,timeout=1200)
                git(target,'checkout','--detach',repos[key]['commit'])
                execute('git','-C',target,'submodule','update','--init','--recursive',timeout=1200)
                staged[key]=target
                found,state=source_record(target,key,patch)
                if state!='clean' or found['commit']!=repos[key]['commit'] or found['submodules']!=repos[key]['submodules']:
                    raise RuntimeError(f'{key} checkout or submodule pins do not match lock')
            # This preflight is done before publishing any staged directory.
            check_layout(Path(temp))
            moved=[]
            try:
                for key,name in NAMES.items():
                    final=sources/name
                    if final.exists() or final.is_symlink():
                        raise RuntimeError(f'Refusing to replace {final}')
                    staged[key].rename(final)
                    moved.append(final)
            except Exception:
                # Only delete folders that THIS call just created.
                for final in moved: shutil.rmtree(final)
                raise
        check_against_lock(lock,sources,patch)
        print('PASS fresh locked source checkouts. Xcode compilation not yet performed.')
        return 0
    raise AssertionError('Unknown action')

if __name__=='__main__':
    try: sys.exit(main())
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as exc:
        print('FAIL source-lock: '+str(exc),file=sys.stderr)
        sys.exit(2)
