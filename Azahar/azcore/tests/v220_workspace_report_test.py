#!/usr/bin/env python3
"""V220 developer workspace report: correct, read-only and privacy-conscious."""
import importlib.util,json,plistlib,subprocess,sys,tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('workspace_report',root/'tools/workspace-report.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
assert m.SCHEMA=='3ds-openemu-workspace-observation-v1'
with tempfile.TemporaryDirectory() as temp:
    ws=Path(temp)
    for rel,v,short in [
        ('3DS-Azahar-Core/azcore/AzaharCore/Info.plist','220','0.220'),
        ('3DS-System-Plugin/Resources/Nintendo3DS-Info.plist','24','1.24')]:
        p=ws/rel;p.parent.mkdir(parents=True,exist_ok=True)
        p.write_bytes(plistlib.dumps({'CFBundleVersion':v,'CFBundleShortVersionString':short}))
    p=ws/'3DS-Azahar-Core/azcore/patch-azahar-full-stereo-v199.py'
    p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b'fixture-patch')
    a=m.report(ws)
    assert a['sources']['azahar']['checkout']=='missing'
    assert a['projects']['core']['bundle_version']=='220'
    assert a['projects']['system']['bundle_version']=='24'
    assert a['stereo_patch_sha256'] is not None
    az=ws/'orig_source/azahar-git';az.mkdir(parents=True)
    a=m.report(ws)
    assert a['sources']['azahar']['checkout']=='archive_or_unversioned'
    def git(*args):
        return subprocess.run(['git','-C',str(az),*args],check=True,capture_output=True,text=True)
    git('init','-q');git('config','user.name','Fixture');git('config','user.email','example@example.invalid')
    (az/'CMakeLists.txt').write_text('fixture')
    git('add','CMakeLists.txt');git('commit','-qm','fixture')
    git('remote','add','origin','https://fake_user:DO_NOT_LEAK@example.invalid/private.git')
    a=m.report(ws)
    assert a['sources']['azahar']['checkout']=='git'
    assert len(a['sources']['azahar']['git_commit'])==40
    assert a['sources']['azahar']['tracked_changes']==0
    assert a['sources']['azahar']['required_inputs_present'] is False
    (az/'CMakeLists.txt').write_text('edited')
    assert m.report(ws)['sources']['azahar']['tracked_changes']==1
    before=sorted((str(x.relative_to(ws)),x.read_bytes()) for x in ws.rglob('*') if x.is_file())
    cli=subprocess.run([sys.executable,str(root/'tools/workspace-report.py'),'--workspace',str(ws)],
                       check=True,capture_output=True,text=True)
    after=sorted((str(x.relative_to(ws)),x.read_bytes()) for x in ws.rglob('*') if x.is_file())
    assert before==after,'Report changed source files'
    obj=json.loads(cli.stdout)
    assert obj['schema']==m.SCHEMA
    assert str(ws) not in cli.stdout
    assert 'DO_NOT_LEAK' not in cli.stdout
    assert 'fake_user' not in cli.stdout
    assert 'example.invalid' not in cli.stdout
    assert obj['source_lock_present'] is False
print('V220 WORKSPACE REPORT OFFLINE GIT + NON-GIT + PRIVACY + READ-ONLY PASS')
