#!/usr/bin/env python3
from pathlib import Path
import plistlib, re, subprocess, shutil, tempfile
p=Path(__file__).resolve().parents[2]/'AzaharCore/AzaharGameCore.mm'
s=p.read_text()
pl=plistlib.loads((p.parent/"Info.plist").read_bytes())
assert (pl["CFBundleVersion"],pl["CFBundleShortVersionString"]) == ("205","0.205")
checks={
 'normal_mode_allowed': '(wide && Az198HasCompactFullStereoLayout(width,height))' in s,
 'no_metal2_switch': 'return OEGameCoreRenderingMetal2;' not in s,
 'previous_gpu_probes': 'V204 STREAM_RESULT' in s and 'V203 METAL_COMPOSE' in s and 'V202 METAL_TRANSFER' in s,
 'no_host_patch': not any('patch-openemu' in f.name.lower() for f in p.parents[1].rglob('*')),
 'version': 'V205 BUILD_ID 3DS_AZAHAR_CORE_205_' in s,
 'host_bitmap': 'return OEGameCoreRenderingBitmap;' in s,
 'true_source': 'Az203CPUReferenceSample(pixels,width,height,pitch,dw,dh' in s,
 'nonblocking_gpu': '[cb commit]; // No wait, ever.' in s and '[cb waitUntilCompleted]' not in s,
 'nonblocking_consumer': 'state->mutex.try_lock()' in s,
 'fallback_before_metal': s.index('Az197CopyPresentationBGRA(view->_videoBuffer') < s.index('const uint64_t v205Seq='),
 'source_format_conversion': 'if(rgba) for(unsigned x=0;x<dw;++x)' in s,
 'stereo_and_depth_guard': 'state->readyMode==mode' in s,
 'source_dimension_guard': 'state->readySourceW==sw' in s,
 'freshness_guard': 'sequence-state->readySequence<=2u' in s,
 'bounded_frames_per_mode': 'state->modeSubmitted[idx].load()>=120u' in s and 'modeSubmitted[24]' in s,
 'disabled_on_failure': 'state->disabled.store(true)' in s,
 'outlives_host_safely': 'std::shared_ptr<Az205PresentState> state=_az205Present' in s and '_az205Present.reset();' in s,
 'runtime_optout': 'AZAHAR_V205_DISABLE_METAL_PRESENT' in s,
}
for name,ok in checks.items(): print(('PASS' if ok else 'FAIL'),name)
assert all(checks.values())

# Exercise thread-safe bounded publish/consume logic under sanitizers, independent
# of Metal/macOS headers. This deliberately uses a temporary C++17 harness.
compiler=shutil.which('clang++') or shutil.which('g++')
assert compiler
cpp=r"""
#include <memory>
#include <atomic>
#include <vector>
#include <mutex>
#include <thread>
#include <cassert>
#include <cstring>
struct S { std::mutex m; std::vector<unsigned char> pixels;
 unsigned ready=0,presented=0; std::atomic<unsigned> inflight{0}; };
int main() {
 auto s=std::make_shared<S>();
 std::vector<std::thread> jobs;
 for(unsigned seq=1;seq<=120;++seq) {
  unsigned old=s->inflight.load();
  while(old<2 && !s->inflight.compare_exchange_weak(old,old+1)){}
  if(old>=2)continue;
  jobs.emplace_back([s,seq] {
   std::vector<unsigned char> a(400u*480u*4u, (unsigned char)(seq&255u));
   {std::lock_guard<std::mutex> lock(s->m);
    if(seq>s->ready) {s->pixels.swap(a);s->ready=seq;} }
   s->inflight.fetch_sub(1);
  });
  if(s->m.try_lock()) {
   if(s->ready>s->presented) {assert(s->pixels.size()==400u*480u*4u);
      s->presented=s->ready;}
   s->m.unlock();
  }
 }
 for(auto &t:jobs)t.join();
 assert(s->inflight.load()==0);
 assert(s->ready>=s->presented);
}
"""
with tempfile.TemporaryDirectory() as tmp:
    f=Path(tmp)/'handoff.cpp'; f.write_text(cpp)
    exe=Path(tmp)/'handoff'
    subprocess.run([compiler,'-std=c++17','-O1','-pthread',
                    '-fsanitize=address,undefined','-fno-omit-frame-pointer',
                    str(f),'-o',str(exe)],check=True,capture_output=True,text=True)
    subprocess.run([str(exe)],check=True,capture_output=True,text=True)
print('PASS: C++17 async shared-state publish/try-consume lifetime test under sanitizers')
print('LIMIT: macOS Objective-C++ build and real Metal display not verified')
