#!/usr/bin/env python3
"""V24 Xcode-script warning cleanup is explicit, not a dependency skip."""
from pathlib import Path
import plistlib
root=Path(__file__).resolve().parents[1]
p=(root/'Nintendo3DSSystemPlugin.xcodeproj/project.pbxproj').read_text()
r=(root/'OE3DSSystemResponder.m').read_text()
i=plistlib.loads((root/'Resources/Nintendo3DS-Info.plist').read_bytes())
assert (i['CFBundleVersion'],i['CFBundleShortVersionString'])==('24','1.24')
assert p.count('ALWAYS_SEARCH_USER_PATHS = NO;')==2
assert p.count('ALWAYS_USE_SEPARATE_HEADERMAPS = YES;')==2
assert p.count('alwaysOutOfDate = 1;')==1
assert 'Check OpenEmu frameworks for active Xcode SDK' in p
assert 'prepare-openemu-frameworks.sh' in p
assert 'v24 responder class loaded' in r
assert len(i['OEGenericControlNamesKey'])==22
print('V24 BUILD SCRIPT + 22 CONTROL CONTRACT PASS')
