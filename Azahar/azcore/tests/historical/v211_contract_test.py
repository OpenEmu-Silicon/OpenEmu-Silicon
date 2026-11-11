#!/usr/bin/env python3
"""Source-level release contract. Run on any platform (not a Mac compile)."""
from pathlib import Path
import plistlib,re
p=Path(__file__).resolve().parents[2]
s=(p/'AzaharCore/AzaharGameCore.mm').read_text()
info=plistlib.loads((p/'AzaharCore/Info.plist').read_bytes())
checks={
 'identity':info['CFBundleVersion']=='211' and info['CFBundleShortVersionString']=='0.211',
 'build_marker':'V211 BUILD_ID 3DS_AZAHAR_CORE_211_' in s,
 'res_menu':'for (NSInteger factor = 1; factor <= 6; ++factor)' in s and '@"7×",@"8×"' not in s,
 'change_handler':'@"1× (Native)",@"2×",@"3×",@"4×",@"5×",@"6×"]' in s,
 'libretro_limit':'core->_az191Resolution <= 6' in s,
 'saved_v210_migration':'std::min(savedResolution, (NSInteger)6)' in s and 'std::min(persistedResolution193.integerValue,(NSInteger)6)' in s,
 'persistence':'@"resolution": @(resolution)' in s and '@"hostScale": @(requestedHostScale207)' not in s,
 'auto_rect':'const unsigned outputScale=(core->_az191Resolution>1) ? 2u : 1u;' in s,
 'fixed_2x_buffer':'unsigned scale=2u;' in s and 'maxW=logicalW*2u; maxH=logicalH*2u;' in s,
 'window_dwell':'core->_az208StartupFrames<180u' in s,
 'padded_host_copy':'Az208CopyRowsToHost(view,frame208' in s and 'Az208CopyRowsToHost(core,dst' in s,
 'integrity_audit':'Az209AuditHostPitch(view,frame208' in s and 'Az209AuditHostPitch(core,dst' in s,
 'host_bitmap':'return OEGameCoreRenderingBitmap;' in s and 'OEGameCoreRenderingMetal2' not in s,
 'no_metal_wait':not re.search(r'\[\s*\w+\s+waitUntil(?:Completed|Scheduled)\s*\]',re.sub(r'//[^\n]*','',s)),
 'readme':(p.parent/'README.md').is_file(),
 'binary':(p/'AzaharCore/azahar_libretro.dylib').is_file(),
}
for k,v in checks.items():print(('PASS' if v else 'FAIL'),k)
assert all(checks.values())
print('V211 CONTRACT PASS')
