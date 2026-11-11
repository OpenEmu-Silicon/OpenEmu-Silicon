#!/usr/bin/env python3
"""Regression guard for v204 ObjC++ array captures (no Mac SDK required)."""
from pathlib import Path
import shutil, subprocess, tempfile
source=(Path(__file__).resolve().parents[1]/'AzaharCore/AzaharGameCore.mm').read_text()
assert '#include <array>' in source
assert 'const std::array<unsigned,5> xs=' in source
assert 'const std::array<unsigned,5> ys=' in source
assert 'const unsigned xs[5]' not in source
assert 'const unsigned ys[5]' not in source
assert 'V204 FIX_ID 204F_OBJCXX_ARRAY_BLOCK_CAPTURE_20261101' in source
cc=shutil.which('clang++')
assert cc, 'clang++ required for ObjC++ compile regression gate'
snippet = """
#include <array>
#include <cstdint>
#include <cstddef>
using std::size_t;
void accept(void (^)());
void test(unsigned dw, unsigned dh, size_t pitch, const uint8_t *a) {
    const std::array<unsigned,5> xs={0u,dw/4u,dw/2u,3u*dw/4u,dw-1u};
    const std::array<unsigned,5> ys={0u,dh/4u,dh/2u,3u*dh/4u,dh-1u};
    accept(^{ for(unsigned y=0;y<5;y++) for(unsigned x=0;x<5;x++) {
        const uint8_t *got=a+(size_t)ys[y]*pitch+(size_t)xs[x]*4u;
        (void)got;
    }});
}
"""
with tempfile.TemporaryDirectory() as d:
 p=Path(d)/'capture.mm'; p.write_text(snippet)
 r=subprocess.run([cc,'-fsyntax-only','-fblocks','-std=gnu++20',str(p)],capture_output=True,text=True)
 assert r.returncode==0,r.stderr
print('PASS: Objective-C++ block safely captures std::array by value')
