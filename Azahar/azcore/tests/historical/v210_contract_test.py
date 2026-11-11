#!/usr/bin/env python3
from pathlib import Path
import plistlib,re,zipfile
p=Path(__file__).resolve().parents[2]
s=(p/'AzaharCore/AzaharGameCore.mm').read_text()
info=plistlib.loads((p/'AzaharCore/Info.plist').read_bytes())
checks={
 'version': info['CFBundleVersion']=='210' and info['CFBundleShortVersionString']=='0.210',
 'build_id': s.count('V210 BUILD_ID 3DS_AZAHAR_CORE_210_')==1,
 'legacy_phys_removed': 'OEDisplayMode_Submenu(@"Physical Output (Experimental)"' not in s and 'OEDisplayMode_OptionWithStateValue(@"3× Physical Pixels' not in s,
 'options_1_to_8': 'for (NSInteger factor = 1; factor <= 8; ++factor)' in s and '@"7×",@"8×"' in s,
 'saved_7_8': 'savedResolution <= 8' in s and 'persistedResolution193.integerValue<=8' in s,
 'libretro_7_8': 'core->_az191Resolution <= 8' in s,
 'legacy_migrated': 'legacy_hostScale=IGNORED' in s and '_az207PendingHostScale=2u;' in s,
 'no_hostscale_write': '@"hostScale": @(requestedHostScale207)' not in s,
 'no_manual_hostscale': 'requestedHostScale207=3u' not in s and 'requestedHostScale207=1u' not in s,
 'frozen_2x': 'unsigned scale=2u;' in s and 'maxW=logicalW*2u; maxH=logicalH*2u;' in s and 'maxW=logicalW*3u' not in s,
 'visible_toggle': 'const unsigned outputScale=(core->_az191Resolution>1) ? 2u : 1u;' in s,
 'window_delay': 'core->_az208StartupFrames<180u' in s,
 'no_realloc_live': 'core->_az208VisibleWidth=targetW;' in s and 'core->_az208HiResPublished=(outputScale==2u);' in s,
 '2x_rowcopy': 'Az208CopyRowsToHost(view,frame208' in s and 'Az208CopyRowsToHost(core,dst' in s,
 'pixel_audit': 'Az209AuditHostPitch(view,frame208' in s and 'Az209AuditHostPitch(core,dst' in s,
 'source_guard': 'kAz191MaxFrameBytes = 128u * 1024u * 1024u' in s,
 'v208_logs': 'V208 RECT_PUBLISH' in s and 'V208 BUFFER_AND_WINDOW_LOCK' in s,
 'bitmap_not_metal2': 'return OEGameCoreRenderingBitmap;' in s and 'OEGameCoreRenderingMetal2' not in s,
 'no_wait': not re.search(r'\[\s*\w+\s+waitUntil(?:Completed|Scheduled)\s*\]',re.sub(r'//[^\n]*','',s)),
 'upstream_executables': (p/'AzaharCore/azahar_libretro.dylib').is_file() and (p/'AzaharCore/Vulkan/libMoltenVK.dylib').is_file(),
}
for k,v in checks.items():print(('PASS' if v else 'FAIL'),k)
assert all(checks.values())
print('V210 CONTRACT PASS')
