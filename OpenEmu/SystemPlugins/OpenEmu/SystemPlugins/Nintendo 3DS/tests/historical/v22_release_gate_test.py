#!/usr/bin/env python3
"""Release evidence is fail-closed about missing proof and stays read-only."""
from pathlib import Path
import tempfile,importlib.util,json,plistlib,hashlib
here=Path(__file__).resolve()
root=here.parents[2] if 'azcore' in here.parts else here.parents[1]
spec=importlib.util.spec_from_file_location('release_gate',root/'tools/release-gate.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as t:
    ws=Path(t)
    for rel in module.EXPECTED_BINARIES.values():
        p=ws/rel;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b'development-fixture-only')
    for name,rel,v,sv in [
       ('3DS-Azahar-Core','azcore/AzaharCore/Info.plist','218','0.218'),
       ('3DS-System-Plugin','Resources/Nintendo3DS-Info.plist','22','1.22')]:
        p=ws/name/rel;p.parent.mkdir(parents=True,exist_ok=True)
        p.write_bytes(plistlib.dumps({'CFBundleVersion':v,'CFBundleShortVersionString':sv}))
    inventory,gate=module.binary_inventory(ws)
    assert gate['state']=='PASS' and len(inventory)==4
    assert all(x['sha256']==hashlib.sha256(b'development-fixture-only').hexdigest() for x in inventory.values())
    before=sorted((str(x.relative_to(ws)),x.read_bytes()) for x in ws.rglob('*') if x.is_file())
    report=module.build_report(ws,run_tests=False)
    assert report['overall']=='PENDING'
    assert report['gates']['source_lock']['state']=='PENDING'
    assert report['gates']['runtime_diagnostics']['state']=='PENDING'
    assert report['gates']['fresh_checkout_macos_build']['state']=='PENDING'
    assert report['gates']['licensing_signing_host_review']['state']=='PENDING'
    assert report['gates']['core_version']['state']=='PASS' and report['gates']['system_version']['state']=='PASS'
    after=sorted((str(x.relative_to(ws)),x.read_bytes()) for x in ws.rglob('*') if x.is_file())
    assert before==after, 'Read-only audit modified the project!'
    log=ws/'diagnostic.log'
    log.write_text('V218 BUILD_ID example\nV213 RELEASE_HEALTH frames=24 gpu_readbacks=24 readback_errors=0 copy_errors=0 bad_formats=0 pitched=24 pitch_pass=24 pitch_fail=0 hw_promoted=1 status=PASS\nV188 LIVE_HARDWARE_TEARDOWN unpublish_mask=0x7 retired_mask=0x1f status=PASS\n')
    assert module.runtime_evidence(log)['state']=='PASS'
    assert '24 hardware frames' in module.runtime_evidence(log)['detail']
    log.write_text(log.read_text().replace('copy_errors=0','copy_errors=1'))
    assert module.runtime_evidence(log)['state']=='FAIL'
    log.write_text(log.read_text().replace('V218 BUILD_ID','V217 BUILD_ID').replace('copy_errors=1','copy_errors=0'))
    assert module.runtime_evidence(log)['state']=='FAIL'
    assert module.runtime_evidence(ws/'missing.log')['state']=='FAIL'
print('RELEASE GATE honest PENDING, mismatch FAIL, valid PASS, read-only PASS')
