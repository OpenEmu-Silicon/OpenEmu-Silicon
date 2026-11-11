#!/usr/bin/env python3
"""Compile production v208 copy + v209 audit in a portable C++ harness."""
from pathlib import Path
import tempfile,subprocess
p=Path(__file__).resolve().parents[1]
s=(p/'AzaharCore/AzaharGameCore.mm').read_text()
a=s.index('static inline void Az208CopyRowsToHost(')
b=s.index('static inline void Az208AdvanceScreenRect(',a)
c=s.index('static inline void Az209AuditHostPitch(',b)
d=s.index('// v199: Prefer',c)
code=s[a:b]+s[c:d]
harness=r'''
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>
#include <cassert>
struct Size {int width,height;};
struct AzaharGameCore {
 uint8_t *_videoBuffer;
 size_t _videoBufferCapacity;
 Size _videoSize;
 bool _az208PaddedHost;
 size_t _az208CompactCapacity;
 unsigned _az208HiResPublished;
 uint64_t _az209PitchCopies=0,_az209PitchPass=0,_az209PitchFail=0;
 uint64_t _az209PitchTotalUs=0,_az209PitchMaxUs=0;
 unsigned _az209NativeStartCopies=0,_az209HiResCopies=0;
};
static inline void AzTrace(const char *s){(void)s;}
'''+code+r'''
int main() {
 for (unsigned nativeW : {400u,800u}) for(unsigned factor:{2u,3u}){
  const unsigned strideW=nativeW*3u,strideH=480u*3u;
  std::vector<uint8_t> host((size_t)strideW*strideH*4u,0);
  AzaharGameCore core{};core._videoBuffer=host.data();core._videoBufferCapacity=host.size();
  core._videoSize={int(strideW),int(strideH)};core._az208PaddedHost=true;
  for(unsigned published=0;published<2;++published){
   const unsigned w=nativeW*(published?factor:1u),h=480u*(published?factor:1u);
   std::vector<uint8_t> frame((size_t)w*h*4u);
   for(size_t i=0;i<frame.size();++i)frame[i]=(uint8_t)((i*73u+21u)%251u);
   core._az208CompactCapacity=frame.size();core._az208HiResPublished=published;
   Az208CopyRowsToHost(&core,frame.data(),w,h);
   Az209AuditHostPitch(&core,frame.data(),w,h,17u);
   assert(core._az209PitchFail==published && core._az209PitchPass==published+1);
   // Corrupt a corner to confirm detection.
   host[(size_t)(h-1u)*strideW*4u+(size_t)(w-1u)*4u]^=1u;
   Az209AuditHostPitch(&core,frame.data(),w,h,12u);
   assert(core._az209PitchFail==published+1);
  }
 }
 printf("V209 extracted production copy+audit code PASS: 2D/SBS x 2x/3x x native/high-res with intentional corruption\n");
}
'''
with tempfile.TemporaryDirectory() as t:
 cpp=Path(t)/'test.cpp';exe=Path(t)/'test'
 cpp.write_text(harness)
 cmd=['c++','-std=c++17','-O1','-Wall','-Wextra','-pedantic',str(cpp),'-o',str(exe)]
 cp=subprocess.run(cmd,text=True,capture_output=True)
 if cp.returncode:raise RuntimeError(cp.stderr)
 r=subprocess.run([str(exe)],text=True,capture_output=True)
 if r.returncode:raise RuntimeError(r.stderr)
 print(r.stdout.strip())
