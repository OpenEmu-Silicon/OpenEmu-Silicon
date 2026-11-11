#!/usr/bin/env python3
"""Release gate: v213 counter audit + non-mutating upstream-source layout check."""
from pathlib import Path
import subprocess, tempfile
core=Path(__file__).resolve().parents[1]
source=(core/'AzaharCore/AzaharGameCore.mm').read_text()
for marker in (
    'V213 BUILD_ID 3DS_AZAHAR_CORE_213_', 'V213 RELEASE_HEALTH',
    'gAzV187HwReadbacks == gAzV188FrameCopies',
    '_az209PitchCopies == _az209PitchPass',
    'gAzV187HwReadbackFailures == 0u',
    'gAzV188VideoCopyFailures == 0u',
    'gAzV188RejectedFormats == 0u',
    'const unsigned outputScale=(core->_az191Resolution>1) ? 2u : 1u;',
    'core->_az208StartupFrames<180u',
    'Az212LogIsRelevant', 'V212 SAVE_FILE_WRITE', 'V212 SAVE_FILE_READ',
): assert marker in source, marker
assert source.count('V213 RELEASE_HEALTH')==1
v=core/'verify-source-layout.py'
namespace={'__file__':str(v), '__name__':'test-import'}
exec(compile(v.read_text(),str(v),'exec'),namespace)
check_layout=namespace['check_layout']
with tempfile.TemporaryDirectory() as directory:
    d=Path(directory)
    srcroot=d/'3DS-Azahar-Core/azcore';srcroot.mkdir(parents=True)
    success,messages=check_layout(srcroot)
    assert not success and sum(x.startswith('MISSING') for x in messages)==3
    files=[d/'orig_source/azahar-git/CMakeLists.txt',
           d/'orig_source/azahar-git/src/citra_libretro/CMakeLists.txt',
           d/'orig_source/OpenEmu-Silicon-main/OpenEmu-SDK/OpenEmu-SDK.xcodeproj/project.pbxproj']
    for f in files:
        f.parent.mkdir(parents=True,exist_ok=True)
        if f.suffix == '.pbxproj': f.parent.mkdir(parents=True,exist_ok=True)
        f.write_text('fixture')
    success,messages=check_layout(srcroot)
    assert success, messages
    assert all(x.startswith('PASS') for x in messages)
    assert all(f.read_text()=='fixture' for f in files)
# Compile and exercise the real production invariant expressions with stand-in
# counter values; failures must reliably produce CHECK on the real Mac build.
start=source.index('const bool hadHardwareFrames = gAzV188HardwarePromoted')
end=source.index('char health213[400];', start)
body=source[start:end]
expr=r'''#include <cstdint>
#include <cassert>
unsigned gAzV188FrameCopies=100, gAzV187HwReadbacks=100;
unsigned gAzV187HwReadbackFailures=0, gAzV188VideoCopyFailures=0, gAzV188RejectedFormats=0;
bool gAzV188HardwarePromoted=true;
uint64_t _az209PitchCopies=100,_az209PitchPass=100,_az209PitchFail=0;
bool audit() {
''' + body + r'''return healthy;
}
int main(){
assert(audit());gAzV187HwReadbacks=99;assert(!audit());
gAzV187HwReadbacks=100;_az209PitchFail=1;assert(!audit());
_az209PitchFail=0;_az209PitchPass=99;assert(!audit());
_az209PitchPass=100;gAzV188RejectedFormats=1;assert(!audit());
}
'''
with tempfile.TemporaryDirectory() as td:
    test=Path(td)/'health.cpp';test.write_text(expr)
    binary=Path(td)/'health'
    subprocess.run(['c++','-std=c++17','-Wall','-Wextra','-Werror',str(test),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
print('V213 READONLY SOURCE LAYOUT + COMPILED HEALTH TEST PASS')
