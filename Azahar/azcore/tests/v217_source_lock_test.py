#!/usr/bin/env python3
"""Test source locking/bootstrapping with disposable local Git repositories.

The tests do not use network, change the user's repositories or compile Xcode.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

root=next(p for p in Path(__file__).resolve().parents if (p/'tools/source-lock.py').exists())
tool=root/'tools/source-lock.py'
patch=root/'azcore/patch-azahar-full-stereo-v199.py'
if not patch.is_file():
    patch=root.parent/'3DS-Azahar-Core/azcore/patch-azahar-full-stereo-v199.py'
assert patch.is_file()
if not shutil.which('git'):
    print('SKIP: git missing; cannot exercise local clone contract')
    raise SystemExit(0)

env=os.environ.copy()
env.update({'GIT_AUTHOR_NAME':'Offline Test','GIT_AUTHOR_EMAIL':'offline@example.invalid',
            'GIT_COMMITTER_NAME':'Offline Test','GIT_COMMITTER_EMAIL':'offline@example.invalid',
            'GIT_TERMINAL_PROMPT':'0'})

def command(*args, okay=True):
    r=subprocess.run([str(x) for x in args], capture_output=True,text=True,env=env)
    if okay:
        assert r.returncode==0, f'{args!r} failed: {r.stderr[-900:]}'
    return r

with tempfile.TemporaryDirectory(prefix='3ds-openemu-source-lock-') as d:
    t=Path(d)
    ws=t/'workspace'
    core=ws/'3DS-Azahar-Core'/'azcore'
    core.mkdir(parents=True)
    shutil.copy2(patch,core/patch.name)
    src=ws/'orig_source'; src.mkdir()
    a=src/'azahar-git'; o=src/'OpenEmu-Silicon-main'
    files_a={
        'CMakeLists.txt':'project(Azahar)\n',
        'src/citra_libretro/CMakeLists.txt':'# mock libretro\n',
        'src/citra_libretro/emu_window/libretro_window.cpp': 'LayoutGeometry ComputeLayoutGeometry() {\n    unsigned baseX = Core::kScreenTopWidth;\n    unsigned baseY = Core::kScreenTopHeight + Core::kScreenBottomHeight;\n    const auto scale = Settings::values.resolution_factor.GetValue();\n    const auto layout = Settings::values.layout_option.GetValue();\n    bool emulated_pointer = false;\n    return {baseX, baseY, emulated_pointer};\n}\nvoid EmuWindow_LibRetro::UpdateLayout() {}\n',
        'externals/cryptopp/CMakeLists.txt':'# offline mock\n',
        'externals/libretro-common/libretro-common/include/libretro.h':'/* offline mock */\n'
    }
    files_o={'OpenEmu-SDK/OpenEmu-SDK.xcodeproj/project.pbxproj':'// offline mock\n'}
    for repo,entries in [(a,files_a),(o,files_o)]:
        repo.mkdir()
        for name,contents in entries.items():
            file=repo/name;file.parent.mkdir(parents=True,exist_ok=True);file.write_text(contents)
        command('git','-C',repo,'init','-q')
        command('git','-C',repo,'add','.')
        command('git','-C',repo,'commit','-qm','Offline fixture')
    lock=t/'source-lock.json'
    capture=[sys.executable,tool,'capture','--workspace',ws,'--lock',lock,
             '--azahar-url',str(a),'--openemu-url',str(o),'--allow-local-url']
    command(*capture)
    raw=lock.read_text()
    assert str(t) in raw # local fixture URLs are explicit, never inferred
    data=json.loads(raw)
    assert data['schema']=='3ds-openemu-source-lock-v1'
    assert all(len(data['repositories'][k]['commit'])==40 for k in ('azahar','openemu'))
    assert data['repositories']['azahar']['submodules']==[]
    verify=[sys.executable,tool,'verify','--workspace',ws,'--lock',lock]
    command(*verify)
    # Real v199 patch applied to the fixture must be the ONLY accepted edit.
    command(sys.executable,patch,a)
    check=command(*verify)
    assert 'known_v199_patch' in check.stdout
    f=a/'src/citra_libretro/emu_window/libretro_window.cpp'
    f.write_text(f.read_text()+'// unexpected developer modification\n')
    assert command(*verify,okay=False).returncode!=0
    command('git','-C',a,'checkout','--',f.relative_to(a))
    command(*verify)
    # Bootstrap from lock into a DIFFERENT, empty workspace; no overwrite.
    new=t/'fresh'; (new/'3DS-Azahar-Core/azcore').mkdir(parents=True)
    shutil.copy2(patch,new/'3DS-Azahar-Core/azcore'/patch.name)
    bootstrap=[sys.executable,tool,'bootstrap','--workspace',new,'--lock',lock,'--allow-local-url']
    result=command(*bootstrap)
    assert 'PASS fresh locked source checkouts' in result.stdout
    command(sys.executable,tool,'verify','--workspace',new,'--lock',lock)
    assert command(*bootstrap,okay=False).returncode!=0
    # A bad pin must fail BEFORE modifying workspace.
    damaged=json.loads(lock.read_text())
    damaged['repositories']['openemu']['commit']='0'*40
    bad=t/'bad-lock.json';bad.write_text(json.dumps(damaged))
    failspace=t/'failspace'; (failspace/'3DS-Azahar-Core/azcore').mkdir(parents=True)
    shutil.copy2(patch,failspace/'3DS-Azahar-Core/azcore'/patch.name)
    result=command(sys.executable,tool,'bootstrap','--workspace',failspace,'--lock',bad,
                   '--allow-local-url',okay=False)
    assert result.returncode!=0
    assert not (failspace/'orig_source/azahar-git').exists()
    assert not (failspace/'orig_source/OpenEmu-Silicon-main').exists()
    # An incomplete pin must be refused, never silently use HEAD.
    damaged=json.loads(lock.read_text()); damaged['repositories']['azahar']['url']=None
    bad.write_text(json.dumps(damaged))
    result=command(sys.executable,tool,'bootstrap','--workspace',failspace,'--lock',bad,
                   '--allow-local-url',okay=False)
    assert result.returncode!=0
    assert not (failspace/'orig_source/azahar-git').exists()
    print('SOURCE LOCK OFFLINE PASS capture/verify/known-patch/reject-edits/bootstrap/no-overwrite/fail-closed')
