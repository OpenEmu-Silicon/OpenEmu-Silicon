#!/usr/bin/env python3
"""Source/package contract tests for the nonblocking v206 GPU output matrix."""
from pathlib import Path
import re
base=Path(__file__).resolve().parents[2]
s=(base/'AzaharCore/AzaharGameCore.mm').read_text()
assert 'V206 BUILD_ID 3DS_AZAHAR_CORE_206_PARALLEL_FULL_RESOLUTION_MATRIX_20261101' in s
assert 'return OEGameCoreRenderingBitmap;' in s
assert 'OEGameCoreRenderingMetal2' not in s
assert s.count('[view az206ProbeOutputMatrix:pixels') == 1
assert s.count('az206ProbeOutputMatrix:(const uint8_t *)pixels') == 2
part=s.split('// v206: Use one genuine Azahar frame',1)[1].split('// v205: the first live Metal handoff',1)[0]
assert 'if(factor<2 || factor>6) return;' in part
assert 'if(width!=nativeW*requested || height!=nativeH*requested) return;' in part
assert 'std::array<unsigned,4> proposed={1u,2u,3u,requested}' in part
assert 'private_bytes=%zu' in part
assert 'compare_exchange_strong(expected,1u)' in part
assert 'scales[i]==requested' in part
assert 'copyFromTexture:src sourceSlice:0' in part
assert 'Az203CPUReferenceSample' in part
assert 'copyFromTexture:target sourceSlice:0' in part
assert 'sourceSize:MTLSizeMake(1,1,1)' in part
assert 'destinationBytesPerRow:kSamplePitch' in part
assert 'kSamplePitch*kSampleCount' in part
assert 'if(err>(scales[i]==requested?0:2)) same=false;' in part
assert 'gpu_wait=NONE' in part
assert 'waitUntilCompleted' not in part and 'waitUntilScheduled' not in part
assert '[command commit]' in part
assert 'self' not in part.split('[command addCompletedHandler:',1)[1].split('}];',1)[0]
assert 'Az206MatrixTracker' in s and 'state->inFlight.store(0)' in part
assert 'V206 SESSION_MATRIX' in s
assert 'AZAHAR_V206_SKIP_MATRIX' in part
assert 'V206 GEOMETRY_MATRIX simulated=YES' in s
assert (base.parent/'V206-HOST-PRESENTATION-AUDIT.md').exists()
print('v206 source-contract assertions: PASS (28 checks)')
