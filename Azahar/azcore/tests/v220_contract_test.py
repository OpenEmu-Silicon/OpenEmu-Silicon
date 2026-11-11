#!/usr/bin/env python3
"""V218 source-level release evidence contract; no macOS build is inferred."""
import hashlib,importlib.util,plistlib
from pathlib import Path
root=Path(__file__).resolve().parents[2]
core=root/'azcore'
src=(core/'AzaharCore/AzaharGameCore.mm').read_text()
p=plistlib.loads((core/'AzaharCore/Info.plist').read_bytes())
assert (p['CFBundleVersion'],p['CFBundleShortVersionString'])==('220','0.220')
assert src.count('V220 BUILD_ID 3DS_AZAHAR_CORE_220_HANDOFF_PROVENANCE_REVIEW_20261107')==1
assert src.count('V219 BUILD_ID 3DS_AZAHAR_CORE_219_XCODE_WARNING_CLEANUP_20261107')==1
assert 'V219 POLICY rendering_audio_input=V218_UNCHANGED' in src
assert 'V217 BUILD_ID 3DS_AZAHAR_CORE_217_SOURCE_LOCK_AND_FRESH_CHECKOUT_20261107' in src
assert 'V213 RELEASE_HEALTH' in src
for part in ['RELEASE_READINESS.md','FRESH_CHECKOUT.md','DEVELOPER_HANDOFF.md','tools/release-gate.py','tools/source-lock.py']:
    assert (root/part).is_file(),part
print('V220 CORE SOURCE/IDENTITY/RELEASE HANDOFF CONTRACT PASS')
