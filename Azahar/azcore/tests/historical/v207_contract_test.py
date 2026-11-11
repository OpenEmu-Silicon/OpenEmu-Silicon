#!/usr/bin/env python3
from pathlib import Path
import plistlib,re
p=Path(__file__).resolve().parents[2]/'AzaharCore/AzaharGameCore.mm'
s=p.read_text(); pl=plistlib.loads((p.parent/'Info.plist').read_bytes())
checks={
'build_version': int(pl['CFBundleVersion'])>=207 and float(pl['CFBundleShortVersionString'])>=0.207,
'id': 'V207 BUILD_ID 3DS_AZAHAR_CORE_207_' in s,
'safe_default': '_az207PendingHostScale=1u;' in s and '_az207ActiveHostScale=1u;' in s,
'bitmap_only': 'return OEGameCoreRenderingBitmap;' in s and 'OEGameCoreRenderingMetal2' not in s,
'no_wait': '[cb waitUntilCompleted]' not in s and '[command waitUntilCompleted]' not in s and '[cb waitUntilScheduled]' not in s,
'host_freeze': 'Az197LockSessionGeometry(self,"restored_pre_init")' in s,
'freeze_guard': 'if (!core || core->_az197PresentationLocked) return;' in s,
'owned_surface': 'core->_az207ActiveHostScale=scale;' in s and 'core->_videoSize=OEIntSizeMake' in s,
'failure_fallback': ('V207 HOST_BUFFER_FALLBACK' in s or 'V208 HOST_BUFFER_FALLBACK' in s) and 'scale=1u;' in s,
'byte_budget': '24u*1024u*1024u' in s,
'exact_size': 'srcW==destW && srcH==destH' in s and 'memcpy(out,in,(size_t)destW*4u)' in s,
'rgb_swizzle': 'out[4u*x+0u]=in[4u*x+2u]' in s,
'wide_stereo_pillarbox': '(uint64_t)destW*kNativeHeight==(uint64_t)destH*kAz197FullWidth' in s,
'submenu': 'Physical Output (Experimental)' in s,
'compat_option': 'Compatible (Native Window)' in s,
'hires_options': '2× Physical Pixels (Restart Game)' in s and '3× Physical Pixels (Restart Game)' in s,
'persistence': '@"hostScale": @(requestedHostScale207)' in s,
'host_metadata': 'V207 HOST_PHYSICAL_FRAME' in s and 'V207 HOST_SESSION' in s,
'v205_keep': 'V205 GPU_BATCH_RESULT' in s and 'V205 METAL_VISIBLE' in s,
'v206_keep': 'V206 MATRIX_RESULT' in s and 'V206 GPU_MATRIX' in s,
'no_host_changes': not any('OpenEmuHelperApp.swift'==a.name or 'MTLGameRenderer.swift'==a.name for a in p.parents[1].rglob('*')),
}
for k,v in checks.items(): print(('PASS' if v else 'FAIL'),k)
assert all(checks.values())
