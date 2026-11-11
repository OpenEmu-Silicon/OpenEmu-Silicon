#!/usr/bin/env python3
"""V219 documented Xcode warning cleanup, preserving live runtime code."""
from pathlib import Path
import re
root=Path(__file__).resolve().parents[2]
src=(root/'azcore/AzaharCore/AzaharGameCore.mm').read_text()
h=(root/'azcore/AzaharCore/AzaharGameCore.h').read_text()
project=(root/'azcore/Azahar.xcodeproj/project.pbxproj').read_text()
assert '@interface AzaharGameCore : OEGameCore <OENDSSystemResponderClient>' in h
assert '<OEAudioBuffer, OENDSSystemResponderClient>' not in h
assert 'id<OEAudioBuffer> buffer = [core audioBufferAtIndex:0]' in src
assert 'V219 BUILD_ID 3DS_AZAHAR_CORE_219_XCODE_WARNING_CLEANUP_20261107' in src
assert src.count('#pragma clang diagnostic ignored "-Wconstant-logical-operand"')==1
assert src.count('#pragma clang diagnostic push')==1
assert src.count('#pragma clang diagnostic pop')==1
for marker in ('const unsigned handshake106=0;','const unsigned exchange107=0,presenter107=0;','const unsigned retainedAfterGate108=0;','const unsigned abiImported108=0;'):
    assert marker in src,marker
assert project.count('ALWAYS_SEARCH_USER_PATHS = NO;')==2
assert project.count('ALWAYS_USE_SEPARATE_HEADERMAPS = YES;')==2
assert 'V188 LIVE_HARDWARE_TEARDOWN' in src
print('V219 WARNING CLEANUP + SAFETY GATES CONTRACT PASS')
