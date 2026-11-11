#!/usr/bin/env python3
"""Idempotent, guarded v199 Azahar libretro geometry fix.

Only edits the existing Azahar source checkout's libretro ComputeLayoutGeometry
function. Refuses unknown revisions. Saves a one-time original backup beside
that source file. This is run automatically by the Xcode build phase.
"""
import pathlib
import re
import shutil
import sys

MARKER = "AZAHAR_OPENEMU_V199_STEREO_GEOMETRY"
START = "LayoutGeometry ComputeLayoutGeometry() {"
END = "void EmuWindow_LibRetro::UpdateLayout() {"
PATCH = '''    // AZAHAR_OPENEMU_V199_STEREO_GEOMETRY
    // Unlike half-width stereo, Full SBS must keep the normal horizontal
    // resolution for EACH eye. EmuWindow::UpdateCurrentFramebufferLayout()
    // later halves the supplied width to lay out each eye, so give it twice
    // the ordinary libretro framebuffer width in Full mode only.
    if (Settings::values.render_3d.GetValue() ==
        Settings::StereoRenderOption::SideBySideFull) {
        baseX *= 2u;
    }

'''


def apply(src_root: pathlib.Path) -> str:
    path = src_root / "src/citra_libretro/emu_window/libretro_window.cpp"
    if not path.is_file():
        raise RuntimeError(f"Azahar libretro source not found: {path}")
    old = path.read_text(encoding="utf-8")
    if old.count(MARKER):
        if old.count(MARKER) != 1 or PATCH not in old:
            raise RuntimeError("Existing v199 marker has unexpected content; refusing to modify")
        return "already_applied"
    if old.count(START) != 1 or old.count(END) != 1:
        raise RuntimeError("Unknown Azahar source layout: missing unique geometry function")
    a = old.index(START)
    b = old.index(END, a)
    region = old[a:b]
    if "Settings::values.render_3d.GetValue()" in region:
        raise RuntimeError("Upstream already handles stereo in geometry: please review manually")
    # Do not modify future upstream files with different stereo layout contracts.
    required = (
        "Settings::values.resolution_factor.GetValue()",
        "Settings::values.layout_option.GetValue()",
        "baseX = Core::kScreenTopWidth;",
        "baseY = Core::kScreenTopHeight + Core::kScreenBottomHeight;",
    )
    if not all(x in region for x in required):
        raise RuntimeError("Azahar geometry function does not match the reviewed source; refusing patch")
    match = list(re.finditer(r"(?m)^([ \t]*)return\s*\{\s*baseX\s*,\s*baseY\s*,\s*emulated_pointer\s*\}\s*;",region))
    if len(match) != 1:
        raise RuntimeError(f"Expected one final geometry return, saw {len(match)}; refusing patch")
    m = match[0]
    newregion = region[:m.start()] + PATCH + region[m.start():]
    patched = old[:a] + newregion + old[b:]
    backup = path.with_name(path.name + ".openemu-v199-original.bak")
    if not backup.exists():
        shutil.copy2(path,backup)
    path.write_text(patched,encoding="utf-8")
    if PATCH not in path.read_text(encoding="utf-8"):
        raise RuntimeError("Source file patch verification failed")
    return "applied"


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: patch-azahar-full-stereo-v199.py /path/to/azahar-git")
    try:
        result = apply(pathlib.Path(sys.argv[1]))
        print(f"V199 AZAHAR_LIBRETRO_SOURCE_PATCH result={result} marker={MARKER}",flush=True)
    except Exception as ex:
        print(f"V199 AZAHAR_LIBRETRO_SOURCE_PATCH status=FAILED: {ex}",file=sys.stderr)
        sys.exit(2)
