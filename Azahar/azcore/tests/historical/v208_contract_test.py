#!/usr/bin/env python3
from pathlib import Path
import plistlib,re
p=Path(__file__).resolve().parents[2]/'AzaharCore/AzaharGameCore.mm'
s=p.read_text(); info=plistlib.loads((p.parent/'Info.plist').read_bytes())
assert int(info['CFBundleVersion'])>=208
for marker in ['V208 BUILD_ID','V208 BUFFER_AND_WINDOW_LOCK','V208 RECT_PUBLISH','V208 SESSION','Az208CopyRowsToHost','Az208AdvanceScreenRect','_az208PaddedHost','_az208CompactCapacity','maxW=logicalW*3u','_az208StartupFrames<180u','_az208VisibleWidth=logicalW','status=READY','OEGameCoreRenderingBitmap']:
 assert marker in s,marker
assert 'OEGameCoreRenderingMetal2' not in s
active=re.sub(r'//[^\n]*','',s)
assert not re.search(r'\[\s*\w+\s+waitUntil(?:Completed|Scheduled)\s*\]',active)
assert 'Az197CopyPresentationBGRA(frame208' in s
assert 'Az208CopyRowsToHost(view,frame208' in s
assert 'Az208CopyRowsToHost(core,dst' in s
assert 'if(!view->_az208PaddedHost)' in s
assert 'V207 HOST_PHYSICAL_FRAME' in s and 'V205 GPU_BATCH_RESULT' in s
assert 'return OEIntRectMake(0,0,_az208VisibleWidth,_az208VisibleHeight)' in s
print('V208 CONTRACT PASS')
