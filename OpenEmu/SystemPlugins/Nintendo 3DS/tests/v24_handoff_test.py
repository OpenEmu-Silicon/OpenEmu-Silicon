#!/usr/bin/env python3
"""V22 controller ABI and release-preparation contract."""
import hashlib,plistlib,re
from pathlib import Path
root=Path(__file__).resolve().parents[1]
info=plistlib.loads((root/'Resources/Nintendo3DS-Info.plist').read_bytes())
assert (info['CFBundleVersion'],info['CFBundleShortVersionString'])==('24','1.24')
controls=info['OEGenericControlNamesKey']
assert len(controls)==22 and controls[12:14]==['OE3DSButtonStart','OE3DSButtonSelect']
responder=(root/'OE3DSSystemResponder.m').read_text()
assert 'v24 responder class loaded' in responder
assert 'v24 init complete' in responder
assert responder.count('v24 mapped')==2
assert 'if(key == OE3DSButtonStart) return 10;' in responder
assert 'if(key == OE3DSButtonSelect) return 11;' in responder
assert 'didChange3DSAnalogAxis:' in responder
assert 'OE3DSButtonZL?0:1' in responder
assert (root/'tests/historical/v21_contract_test.py').is_file()
for part in ['RELEASE_READINESS.md','FRESH_CHECKOUT.md','DEVELOPER_HANDOFF.md','tools/release-gate.py','tools/source-lock.py']:
    assert (root/part).is_file(),part
print('V22 22-CONTROL + RELEASE HANDOFF CONTRACT PASS')
