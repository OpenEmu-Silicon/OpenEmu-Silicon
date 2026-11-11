#!/usr/bin/env python3
"""Source/ABI safety gates for v202. Not a substitute for macOS Xcode testing."""
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[2]
CORE = (ROOT / "azcore/AzaharCore/AzaharGameCore.mm").read_text()
PROJECT = (ROOT / "azcore/Azahar.xcodeproj/project.pbxproj").read_text()
with (ROOT / "azcore/AzaharCore/Info.plist").open("rb") as f:
    PLIST = plistlib.load(f)

assert PLIST["CFBundleVersion"] == "202"
assert PLIST["CFBundleShortVersionString"] == "0.202"
assert "V202 BUILD_ID 3DS_AZAHAR_CORE_202" in CORE
assert "V202 SAFETY stock_OpenEmu=UNCHANGED" in CORE
assert re.search(r"- \(OEGameCoreRendering\)gameCoreRendering\s*\{\s*return OEGameCoreRenderingBitmap;\s*\}", CORE)
assert "return OEGameCoreRenderingMetal2;" not in CORE
assert "- (void)createMetalTextureWithDevice:" not in CORE
assert "- (id<MTLTexture>)metalTexture" not in CORE
assert "[cb waitUntilCompleted]" not in CORE
assert "[command waitUntilCompleted]" not in CORE
assert "V202 METAL_TRANSFER selected=" in CORE
assert "V202 SOURCE_CHECK selected=" in CORE
assert "V202 METAL_SUBMIT selected=" in CORE
assert "MTLCreateSystemDefaultDevice()" in CORE
assert "MTLResourceStorageModeShared" in CORE
assert "MTLStorageModePrivate" in CORE
assert "[command addCompletedHandler:" in CORE
assert "[command commit];" in CORE
assert CORE.index("[command addCompletedHandler:") < CORE.index("[command commit];")
assert "AZAHAR_V202_SKIP_METAL_PROBE" in CORE
assert "Az197CopyPresentationBGRA(view->_videoBuffer,outW193,outH193," in CORE
assert "Az197CopyPresentationBGRA(dst,outWSoftware193,outHSoftware193," in CORE
assert "Az197FullSelected(view)" in CORE
assert PROJECT.count('"-framework", "Metal"') == 2
assert not any("patch-openemu" in p.name.lower() for p in ROOT.rglob("*"))

# Standalone row-hash verification: identical rows pass, a changed byte fails.
def row_hash(data):
    h = 1469598103934665603
    for value in data:
        h = ((h ^ value) * 1099511628211) & ((1 << 64) - 1)
    return h

for scale, side_by_side in ((2, False), (4, False), (6, False), (6, True)):
    w = (800 if side_by_side else 400) * scale
    h = 480 * scale
    row = bytes((i * 19 + scale) % 256 for i in range(w * 4))
    assert row_hash(row) == row_hash(bytes(row))
    changed = bytearray(row)
    changed[len(changed) // 2] ^= 0x7f
    assert row_hash(row) != row_hash(changed)
    assert w * h * 4 <= 128 * 1024 * 1024
    print(f"PASS: {scale}x {'full-stereo' if side_by_side else '2D'} size={w}x{h}, hash detects mutations")

print("PASS: v202 metadata, binary package invariants, no host patch, stable presenter, nonblocking Metal probe")
print("NOTE: Mac Objective-C++ compile, driver behavior and gameplay still require Xcode/macOS")
