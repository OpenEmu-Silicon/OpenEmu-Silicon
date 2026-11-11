#!/usr/bin/env python3
"""Check Objective-C++ capture of value-type arrays (fix from v204)."""
from pathlib import Path
import subprocess, tempfile
src='''#include <array>\n#include <memory>\n#include <atomic>\n#include <cstddef>\nvoid fixture(){\n const std::array<unsigned,4> proposed={1u,2u,3u,6u};\n std::array<unsigned,4> scales=proposed;\n std::array<unsigned,4> widths={400,800,1200,2400};\n unsigned count=4;\n constexpr size_t kSamplePitch=256u;\n auto state=std::make_shared<std::atomic<unsigned>>(0);\n auto block=^{for(unsigned i=0;i<count;i++){state->fetch_add(scales[i]+widths[i]+(unsigned)kSamplePitch);}};\n block();\n}\n'''
with tempfile.TemporaryDirectory() as t:
 f=Path(t)/'t.mm'; f.write_text(src)
 r=subprocess.run(['clang++','-std=c++17','-fblocks','-fsyntax-only',str(f)],capture_output=True,text=True)
 assert r.returncode==0,r.stderr
print('v206 Objective-C++ array and scalar block captures: PASS')
