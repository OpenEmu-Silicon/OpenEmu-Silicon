#!/usr/bin/env python3
"""Read-only handoff readiness audit for the paired 3DS OpenEmu plugins.

This audits *evidence*, not release eligibility. A source ZIP containing the
right files is not a fresh Xcode build. A working game is not proof that third-
party binaries or artwork may legally be redistributed. Missing evidence is
reported as PENDING, never silently converted into PASS.

Run from either project: python3 tools/release-gate.py [--runtime-log FILE]
Optional --report FILE creates a reviewable report OUTSIDE the project by
explicit request. Without it the tool writes nothing to the project.
"""
import argparse
import hashlib
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path

CORE_VERSION='220'
SYSTEM_VERSION='24'
SCHEMA='3ds-openemu-release-readiness-v1'
EXPECTED_BINARIES={
  'core_libretro':'3DS-Azahar-Core/azcore/AzaharCore/azahar_libretro.dylib',
  'moltenvk':'3DS-Azahar-Core/azcore/AzaharCore/Vulkan/libMoltenVK.dylib',
  'openemu_base':'3DS-System-Plugin/Frameworks/OpenEmuBase.framework/Versions/Current/OpenEmuBase',
  'openemu_system':'3DS-System-Plugin/Frameworks/OpenEmuSystem.framework/Versions/Current/OpenEmuSystem',
}


def result(state, detail):
    assert state in ('PASS','PENDING','FAIL')
    return {'state':state,'detail':detail}


def version_check(root, rel, expected, short):
    path=root/rel
    if not path.is_file():return result('FAIL','Missing '+rel)
    try:
        meta=plistlib.loads(path.read_bytes())
    except (OSError, ValueError) as exc:
        return result('FAIL','Invalid plist: '+str(exc))
    if meta.get('CFBundleVersion')!=expected or meta.get('CFBundleShortVersionString')!=short:
        return result('FAIL','Unexpected version in '+rel)
    return result('PASS',f'{expected} / {short}')


def binary_inventory(workspace):
    inventory={}
    missing=[]
    for key,relative in EXPECTED_BINARIES.items():
        path=workspace/relative
        if not path.is_file():
            missing.append(relative)
            inventory[key]={'path':relative,'status':'MISSING'}
        else:
            digest=hashlib.sha256()
            with path.open('rb') as file:
                for chunk in iter(lambda:file.read(1024*1024),b''):
                    digest.update(chunk)
            inventory[key]={'path':relative,'sha256':digest.hexdigest(),'size_bytes':path.stat().st_size,
                            'status':'PRESENT_UNREVIEWED'}
    return inventory, result('FAIL' if missing else 'PASS',
            'Missing required development binaries: '+', '.join(missing) if missing
            else 'Four bundled development binaries inventoried by SHA-256; redistribution NOT approved')


def runtime_evidence(path, version=CORE_VERSION):
    if path is None:
        return result('PENDING','No new runtime diagnostic log supplied for this version')
    try:
        content=Path(path).read_text(encoding='utf-8',errors='replace')
    except OSError as exc:
        return result('FAIL','Cannot read runtime log: '+str(exc))
    match=list(re.finditer(r'\bV'+re.escape(version)+r' BUILD_ID\b',content))
    if not match:
        return result('FAIL','The log does not identify Core v'+version)
    # Only accept session summaries after the last candidate build marker;
    # rolling diagnostic files can contain complete earlier-version sessions.
    content=content[match[-1].start():]
    sessions=re.findall(r'V213 RELEASE_HEALTH frames=(\d+) gpu_readbacks=(\d+) readback_errors=(\d+) copy_errors=(\d+) bad_formats=(\d+) pitched=(\d+) pitch_pass=(\d+) pitch_fail=(\d+) hw_promoted=(\d+) status=(\S+)',content)
    if not sessions:
        return result('FAIL','No V213 RELEASE_HEALTH session summary found')
    if not re.search(r'V188 LIVE_HARDWARE_TEARDOWN[^\n]*status=PASS',content):
        return result('FAIL','No clean GPU teardown recorded')
    total=0
    for vals in sessions:
        frames,readbacks,rerr,cerr,ferr,pitched,passcopies,failcopies,promoted,status=vals
        frames,readbacks,rerr,cerr,ferr,pitched,passcopies,failcopies,promoted=map(int,(frames,readbacks,rerr,cerr,ferr,pitched,passcopies,failcopies,promoted))
        if frames<1 or frames!=readbacks or frames!=pitched or pitched!=passcopies or any((rerr,cerr,ferr,failcopies)) or promoted!=1 or status!='PASS':
            return result('FAIL','A release-health session did not satisfy full error-free frame contract')
        total+=frames
    return result('PASS',f'{len(sessions)} session(s), {total} hardware frames, no frame errors, clean teardown; this is not an input/save-state certification')


def source_lock_evidence(core, workspace, lock):
    lock=lock if lock is not None else core/'source-lock.json'
    if not lock.is_file():
        return result('PENDING','No reviewed source-lock.json; run source-lock.py inspect/capture/verify on the working Mac')
    try:
        data=json.loads(lock.read_text(encoding='utf-8'))
    except (ValueError,OSError) as exc:
        return result('FAIL','Source lock is unreadable/invalid: '+str(exc))
    if data.get('schema')!='3ds-openemu-source-lock-v1':
        return result('FAIL','Unrecognized source lock schema')
    repos=data.get('repositories')
    if not isinstance(repos,dict) or set(repos)!=set(('azahar','openemu')):
        return result('FAIL','Incomplete source lock repository set')
    if not all(isinstance(repos[n],dict) and re.fullmatch(r'[0-9a-f]{40}',str(repos[n].get('commit','')))
               for n in ('azahar','openemu')):
        return result('FAIL','Missing real upstream 40-character commit pins')
    def reviewed_url(value):
        if not isinstance(value,str):return False
        if value.startswith('https://'):
            return '@' not in value[8:].split('/')[0] and bool(value[8:].split('/')[0])
        return value.startswith(('ssh://','git@'))
    if not all(reviewed_url(repos[n].get('url')) for n in ('azahar','openemu')):
        return result('PENDING','Source commits recorded, but explicit reviewed remote Git URLs are missing or require review')
    # Even a syntactically valid lock is not a source verification. Ask the
    # existing strict tool to check upstream worktrees, submodules and patch.
    tool=core/'tools/source-lock.py'
    if not tool.is_file():return result('FAIL','Missing source lock verification tool')
    run=subprocess.run([sys.executable,str(tool),'verify','--lock',str(lock),'--workspace',str(workspace)],
                       cwd=core,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=90)
    if run.returncode:
        # A Git source tree must be available to verify; this may simply be
        # a developer ZIP without the upstream worktrees. Do not call that a
        # failure in the runtime, but do not accept a lock as fully proven.
        return result('PENDING','Source lock exists, but the workspace was not verified: '+
                      (run.stderr or run.stdout).strip()[-400:])
    return result('PASS','Actual Git commits/submodules and known source patch match reviewed remote pins')


def portable_tests(core, system):
    found=[]
    for project in (core,system):
        runner=project/'tools/run-source-checks.py'
        if not runner.is_file():return result('FAIL','Missing portable regression runner in '+project.name)
        run=subprocess.run([sys.executable,str(runner)],cwd=project,
                           stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=180)
        if run.returncode:
            return result('FAIL',project.name+' source checks failed: '+(run.stderr or run.stdout)[-700:])
        if 'PASS portable_regression_tests failures=0' not in run.stdout:
            return result('FAIL',project.name+' runner did not produce its completion marker')
        count=sum(line.startswith('PASS v') for line in run.stdout.splitlines())
        found.append(f'{project.name}: {count} tests')
    return result('PASS',', '.join(found)+'; portable tests are not macOS builds')


def build_report(workspace, lock=None, runtime_log=None, run_tests=True):
    workspace=Path(workspace).resolve()
    core=workspace/'3DS-Azahar-Core'
    system=workspace/'3DS-System-Plugin'
    gates={
      'core_version':version_check(core,'azcore/AzaharCore/Info.plist',CORE_VERSION,'0.'+CORE_VERSION),
      'system_version':version_check(system,'Resources/Nintendo3DS-Info.plist',SYSTEM_VERSION,'1.'+SYSTEM_VERSION),
    }
    inventory,gate=binary_inventory(workspace)
    gates['development_artifacts']=gate
    gates['portable_source_tests']=(portable_tests(core,system) if run_tests else
                                   result('PENDING','Portable tests explicitly not run'))
    gates['source_lock']=source_lock_evidence(core,workspace,lock)
    gates['runtime_diagnostics']=runtime_evidence(runtime_log)
    gates['fresh_checkout_macos_build']=result('PENDING','Requires a clean separate workspace compiled with Xcode on an Apple Silicon Mac; not demonstrated by source checks')
    gates['manual_functional_acceptance']=result('PENDING','Record external controller, touchscreen, stereo, 1–6x, shader, game diversity, saves and restore on final candidate')
    gates['licensing_signing_host_review']=result('PENDING','Upstream notices, binary/framework redistribution, artwork ownership, OpenEmu maintainer review, signing/notarization still require explicit human sign-off')
    blockers=[name for name,g in gates.items() if g['state']!='PASS']
    return {'schema':SCHEMA,'core_version':CORE_VERSION,'system_version':SYSTEM_VERSION,
            'overall':'FAIL' if any(g['state']=='FAIL' for g in gates.values()) else ('PENDING' if blockers else 'PASS'),
            'gates':gates,'open_gates':blockers,'development_binary_inventory':inventory,
            'meaning':'PASS verifies only reported evidence; does not grant redistribution rights or certify an official OpenEmu release.'}


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace',type=Path,help='Parent directory containing both plugins')
    parser.add_argument('--lock',type=Path,help='Reviewed source-lock.json from the known-working Mac')
    parser.add_argument('--runtime-log',type=Path,help='Diagnostic log from the final candidate, not an older build')
    parser.add_argument('--report',type=Path,help='Optional JSON evidence report to write (no implicit file writes)')
    parser.add_argument('--strict',action='store_true',help='Return nonzero if ANY gate remains pending')
    args=parser.parse_args(argv)
    here=Path(__file__).resolve().parents[1]
    ws=args.workspace if args.workspace else here.parent
    report=build_report(ws,args.lock,args.runtime_log)
    for key,item in report['gates'].items():
        print(f'{item["state"]:7} {key}: {item["detail"]}')
    print('OVERALL',report['overall'],'— source/build/runtime/license readiness; PENDING is not release approval')
    if args.report:
        # Deliberate and explicit; fail if attempting to store evidence in a
        # project code folder or write an existing file without consent.
        output=args.report.resolve()
        roots=[(ws/'3DS-Azahar-Core').resolve(),(ws/'3DS-System-Plugin').resolve()]
        if any(output==p or p in output.parents for p in roots):
            parser.error('Please write the evidence report OUTSIDE the source project folders')
        if output.exists():parser.error('Report file exists; refusing to overwrite')
        output.parent.mkdir(parents=True,exist_ok=True)
        output.write_text(json.dumps(report,indent=2,sort_keys=True)+'\n',encoding='utf-8')
        print('Saved reviewable report:',output)
    if report['overall']=='FAIL' or (args.strict and report['overall']!='PASS'):
        return 2
    return 0


if __name__=='__main__':
    raise SystemExit(main())
