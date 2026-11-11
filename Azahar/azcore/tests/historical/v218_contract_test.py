#!/usr/bin/env python3
"""V218 source-level release evidence contract; no macOS build is inferred."""
import hashlib,importlib.util,plistlib
from pathlib import Path
root=Path(__file__).resolve().parents[2]
core=root/'azcore'
src=(core/'AzaharCore/AzaharGameCore.mm').read_text()
p=plistlib.loads((core/'AzaharCore/Info.plist').read_bytes())
assert (p['CFBundleVersion'],p['CFBundleShortVersionString'])==('218','0.218')
assert src.count('V218 BUILD_ID 3DS_AZAHAR_CORE_218_RELEASE_READINESS_EVIDENCE_20261107')==1
assert 'V218 POLICY video_audio_input=V217_UNCHANGED source_build=V217_UNCHANGED' in src
assert 'V217 BUILD_ID 3DS_AZAHAR_CORE_217_SOURCE_LOCK_AND_FRESH_CHECKOUT_20261107' in src
assert 'V213 RELEASE_HEALTH' in src
for part in ['RELEASE_READINESS.md','FRESH_CHECKOUT.md','DEVELOPER_HANDOFF.md','tools/release-gate.py','tools/source-lock.py']:
    assert (root/part).is_file(),part
print('V218 CORE SOURCE/IDENTITY/RELEASE HANDOFF CONTRACT PASS')
