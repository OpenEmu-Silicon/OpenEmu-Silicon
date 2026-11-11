#!/usr/bin/env python3
"""v212 release safeguards; no macOS SDK or running emulator required."""
from pathlib import Path
import re, subprocess, tempfile, os
src = (Path(__file__).resolve().parents[1]/'AzaharCore/AzaharGameCore.mm').read_text()
required = (
    'AZAHAR_DIAG_VERBOSE', 'V212 BUILD_ID', 'V212 DIAGNOSTIC_SUMMARY',
    'V212 SESSION_PROFILE', 'V212 SAVE_FILE_WRITE', 'V212 SAVE_FILE_READ',
    'V212 SAVE_AUDIT', 'Az212LogIsRelevant', 'Az212VerboseDiagnostics',
    'Az209AuditHostPitch', 'Az208CopyRowsToHost',
    'const unsigned outputScale=(core->_az191Resolution>1) ? 2u : 1u;',
    'core->_az208StartupFrames<180u', 'std::min(savedResolution, (NSInteger)6)',
)
for marker in required: assert marker in src, marker
start = src.index('static bool Az212LogIsRelevant(')
stop = src.index('static void AzTrace(', start)
fn = src[start:stop]
test = r"""
#include <cstdlib>
#include <cstring>
#include <cassert>
""" + fn + r"""
int main() {
    assert(!Az212LogIsRelevant("V126 FENCE_SUMMARY status=PASS"));
    assert(Az212LogIsRelevant("V188 LIVE_HARDWARE_TEARDOWN status=PASS"));
    assert(Az212LogIsRelevant("V212 BUILD_ID"));
    assert(Az212LogIsRelevant("V145 OLD_GATE status=FAIL"));
    assert(Az212LogIsRelevant("ERROR: lost Vulkan context"));
    assert(!Az212LogIsRelevant("ENV GET_VARIABLE key=citra_use_hw_shader"));
    assert(!Az212LogIsRelevant("ROM C path valid and nonempty"));
    return 0;
}
"""
with tempfile.TemporaryDirectory() as td:
    f=Path(td)/'audit.cpp'; f.write_text(test)
    binary=Path(td)/'audit'
    subprocess.run(['c++','-std=c++17','-Wall','-Wextra','-Werror',str(f),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
print('V212 LOG FILTER + RELEASE AUDIT PASS')
