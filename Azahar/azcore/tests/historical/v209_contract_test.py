#!/usr/bin/env python3
from pathlib import Path
import re,plistlib
p=Path(__file__).resolve().parents[2]
s=(p/'AzaharCore/AzaharGameCore.mm').read_text()
i=plistlib.loads((p/'AzaharCore/Info.plist').read_bytes())
assert i['CFBundleVersion']=='209' and i['CFBundleShortVersionString']=='0.209'
for marker in ('V209 BUILD_ID','V209 POLICY','V209 PITCH_AUDIT','V209 SESSION_AUDIT',
               'Az209AuditHostPitch','_az209PitchCopies','_az209PitchFail',
               'Az208AdvanceScreenRect(view)','Az208AdvanceScreenRect(core)',
               'Az208CopyRowsToHost(view,frame208','Az208CopyRowsToHost(core,dst',
               'V208 RECT_PUBLISH','V207 HOST_PHYSICAL_FRAME',
               'return OEGameCoreRenderingBitmap;'):
 assert marker in s,marker
assert s.count('Az209AuditHostPitch(view,frame208')==1
assert s.count('Az209AuditHostPitch(core,dst')==1
assert s.count('V209 BUILD_ID')==1
assert 'OEGameCoreRenderingMetal2' not in s
assert 'maxW=logicalW*3u' in s
assert '_az208StartupFrames<180u' in s
assert 'core->_videoSize=OEIntSizeMake(maxW,maxH)' in s
assert 'if(core->_az208PaddedHost)' in s
assert not re.search(r'\[\s*\w+\s+waitUntil(?:Completed|Scheduled)\s*\]',re.sub(r'//[^\n]*','',s))
print('V209 CONTRACT PASS')
