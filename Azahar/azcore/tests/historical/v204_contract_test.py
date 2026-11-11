#!/usr/bin/env python3
"""v204 portable static gates (macOS GPU compilation remains user-tested)."""
from pathlib import Path
import plistlib,re,subprocess,shutil,tempfile
root=Path(__file__).resolve().parents[2]
s=(root/'azcore/AzaharCore/AzaharGameCore.mm').read_text()
with (root/'azcore/AzaharCore/Info.plist').open('rb') as f:pl=plistlib.load(f)
assert (pl['CFBundleVersion'],pl['CFBundleShortVersionString'])==('204','0.204')
assert 'V204 BUILD_ID 3DS_AZAHAR_CORE_204_BOUNDED_ASYNC_METAL_STREAM_' in s
assert 'V204 SAFETY stock_OpenEmu=UNCHANGED renderer=V199_BITMAP' in s
assert 'V204 STREAM_BEGIN' in s and 'V204 STREAM_RESULT' in s
assert 'V204 STREAM_SOURCE' in s
assert 'AZAHAR_V204_SKIP_METAL_STREAM' in s
assert 'V203 METAL_COMPOSE selected=' in s
assert 'V202 METAL_TRANSFER selected=' in s
assert re.search(r'- \(OEGameCoreRendering\)gameCoreRendering\s*\{\s*return OEGameCoreRenderingBitmap;\s*\}',s)
assert 'return OEGameCoreRenderingMetal2' not in s
assert re.search(r'\[(?:command|cb) waitUntilCompleted\]\s*;',s) is None
assert re.search(r'\[(?:command|cb) waitUntilScheduled\]\s*;',s) is None
assert s.count('[view az204ProbeContinuousMetalComposition:pixels')==1
assert s.count('[core az204ProbeContinuousMetalComposition:src')==1
assert s.count('[cb addCompletedHandler:')==2
assert s.count('[cb commit]')==2
assert 'std::atomic<unsigned> inflight{0}' in s
assert 'while(busy<2 && !state->inflight.compare_exchange_weak' in s
assert 'state->busy_skips[idx].fetch_add(1' in s
assert 'static constexpr unsigned kStreamFrames=12' in s
assert 'state->inflight.fetch_sub(1' in s
assert 'state->passes[idx].fetch_add(1)' in s
assert 'state->failures[idx].fetch_add(1)' in s
assert 'const std::shared_ptr<Az204StreamTracker> state=_az204Tracker;' in s
assert 'Az203CPUReferenceSample(pixels,width,height,pitch,dw,dh,xs[x],ys[y]' in s
assert 'MTLBlitOptionNone' in s
assert s.count('Az197CopyPresentationBGRA(view->_videoBuffer')==1
assert s.count('Az197CopyPresentationBGRA(dst')==1
assert not any('patch-openemu' in p.name.lower() for p in root.rglob('*'))
# Validate C++ C++17 shared atomic stream accounting contract with UBSan and ASan.
cc=shutil.which('clang++') or shutil.which('g++')
assert cc, 'Need portable C++ compiler to test atomics'
cpp=r'''
#include <atomic>
#include <memory>
#include <cassert>
#include <thread>
#include <vector>
struct S { std::atomic<unsigned> inflight{0}; std::atomic<unsigned> submitted{0};
 std::atomic<unsigned> completed{0}; };
int main() {
 auto s=std::make_shared<S>();
 std::vector<std::thread> jobs;
 for(int i=0;i<1000;i++) {
   unsigned busy=s->inflight.load(std::memory_order_acquire);
   while(busy<2 && !s->inflight.compare_exchange_weak(busy,busy+1,
       std::memory_order_acq_rel,std::memory_order_acquire)) {}
   if(busy>=2) continue;
   assert(s->inflight.load()<=2);
   s->submitted.fetch_add(1);
   jobs.emplace_back([s]() { s->completed.fetch_add(1);
                                s->inflight.fetch_sub(1,std::memory_order_release); });
 }
 for(auto &t:jobs)t.join();
 assert(s->inflight.load()==0);
 assert(s->submitted.load()==s->completed.load());
 assert(s->submitted.load()>0);
}
'''
with tempfile.TemporaryDirectory() as temp:
 t=Path(temp); (t/'test.cpp').write_text(cpp)
 cmd=[cc,'-std=c++17','-O1','-fsanitize=address,undefined','-fno-omit-frame-pointer',str(t/'test.cpp'),'-o',str(t/'test')]
 subprocess.run(cmd,check=True,capture_output=True,text=True)
 subprocess.run([str(t/'test')],check=True,capture_output=True,text=True)
print('PASS: v204 metadata, host portability, renderer isolation, GPU wait elimination')
print('PASS: v202 and v203 diagnostics retained, v204 stream caps and callbacks installed')
print('PASS: C++17 2-slot atomic lifetime test under address/undefined-behavior sanitizers')
print('LIMIT: macOS Objective-C++ Metal compilation, Xcode, real-time video remain unverified')
