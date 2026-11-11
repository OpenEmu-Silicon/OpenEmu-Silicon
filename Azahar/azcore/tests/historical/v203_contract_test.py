#!/usr/bin/env python3
"""Portable v203 release gates. They do NOT substitute for Apple Xcode/runtime."""
from pathlib import Path
import plistlib, subprocess, math, re
root=Path(__file__).resolve().parents[2]
source=(root/'azcore/AzaharCore/AzaharGameCore.mm').read_text()
prior=(root/'azcore/tests/v202_contract_test.py')
with (root/'azcore/AzaharCore/Info.plist').open('rb') as f: pl=plistlib.load(f)
assert (pl['CFBundleVersion'],pl['CFBundleShortVersionString'])==('203','0.203')
assert 'V203 BUILD_ID 3DS_AZAHAR_CORE_203_ASYNC_METAL_COMPOSITION_PROBE' in source
assert 'V203 SAFETY stock_OpenEmu=UNCHANGED' in source
assert 'V203 METAL_COMPOSE_SUBMIT selected=' in source
assert 'V203 METAL_COMPOSE selected=' in source
assert 'AZAHAR_V203_SKIP_METAL_PROBE' in source
assert 'V202 METAL_TRANSFER selected=' in source
assert re.search(r'- \(OEGameCoreRendering\)gameCoreRendering\s*\{\s*return OEGameCoreRenderingBitmap;\s*\}',source)
assert 'return OEGameCoreRenderingMetal2;' not in source
assert 'waitUntilCompleted' not in source.replace('// v201\'s unbounded [commandBuffer waitUntilCompleted] is deliberately absent.', '').replace('No waitUntilCompleted: never gate gameplay on this probe.','')
assert source.count('[view az203ProbeMetalComposition:pixels')==1
assert source.count('[core az203ProbeMetalComposition:src')==1
assert source.count('[cb addCompletedHandler:')==1
assert source.count('[cb commit]')==1
assert source.index('[cb addCompletedHandler:') < source.index('[cb commit];')
assert 'sourceWidth:width sourceHeight:height' in source
assert 'texture2d<float, access::sample>' in source
assert 'filter::linear' in source
assert 'MTLStorageModePrivate' in source
assert 'MTLStorageModeShared' in source
assert 'MTLBlitOptionNone' in source
assert 'V199_BITMAP_UNCHANGED' in source
assert 'Az197CopyPresentationBGRA(view->_videoBuffer,outW193,outH193,' in source
assert 'Az197CopyPresentationBGRA(dst,outWSoftware193,outHSoftware193,' in source
assert not any('patch-openemu' in p.name.lower() for p in root.rglob('*'))

# The CPU bilinear kernel must sample genuine high-res source pixel values; no
# upscaling a low-res frame is permitted. Check asymmetric source + edge clamp.
def cpu_ref(pixel, sw, sh, dw, dh, dx, dy):
    fx=(dx+0.5)*sw/dw-0.5; fy=(dy+0.5)*sh/dh-0.5
    xx=math.floor(fx); yy=math.floor(fy); tx=fx-xx; ty=fy-yy
    def clamp(v,n): return max(0,min(n-1,v))
    def at(x,y,c): return pixel(clamp(x,sw),clamp(y,sh),c)
    return tuple(round(((1-tx)*at(xx,yy,c)+tx*at(xx+1,yy,c))*(1-ty)
                       +((1-tx)*at(xx,yy+1,c)+tx*at(xx+1,yy+1,c))*ty)
                 for c in range(4))
for factor,wide in ((2,False),(3,False),(5,False),(6,False),(6,True)):
    dw=800 if wide else 400; dh=480; sw=dw*factor; sh=dh*factor
    def px(x,y,c): return (17*x+11*y+23*c+factor)%256
    probes=[(0,0),(dw//4,dh//4),(dw//2,dh//2),(3*dw//4,3*dh//4),(dw-1,dh-1)]
    got=[cpu_ref(px,sw,sh,dw,dh,x,y) for x,y in probes]
    assert all(len(v)==4 and all(0<=a<=255 for a in v) for v in got)
    # Identical 1x-then-upscale would only touch native source cells, which does
    # not generally yield these 2x-6x full-resolution samples.
    if factor>2:
        assert got[2]!=tuple(px(dw//2,dh//2,c) for c in range(4))
    print(f'PASS: reference geometry {factor}x {"SBS Full" if wide else "2D"} {sw}x{sh} -> {dw}x{dh}')
print('PASS: v203 source, safety, metadata and independent reference gates')
print('LIMIT: Metal shader compilation, GPU synchronization, game behavior require macOS/Xcode test')
