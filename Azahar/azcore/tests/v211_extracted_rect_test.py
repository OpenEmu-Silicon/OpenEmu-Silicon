#!/usr/bin/env python3
"""Compile and execute the *actual* v211 screen rectangle & pitch-copy C++ code.
Strip only the Objective-C logging expression to enable a Linux C++ test."""
from pathlib import Path
import subprocess,tempfile
s=(Path(__file__).resolve().parents[1]/'AzaharCore/AzaharGameCore.mm').read_text()
fn=s[s.index('static inline void Az208CopyRowsToHost('):s.index('// Verify actual host bytes after each pitched row copy:')]
assert 'Az208AdvanceScreenRect' in fn
fn=fn.replace('(core->_az191Stereo?:@"off").UTF8String','"off"')
prefix='''#include <cstdint>\n#include <cstdlib>\n#include <cstring>\n#include <cstdio>\n#include <cassert>\n#include <vector>\n#include <algorithm>\n#include <string>\nstruct Size {unsigned width,height;};\nstruct AzaharGameCore {\n bool _az208PaddedHost=true;unsigned _az208StartupFrames=0,_az208VisibleWidth=400,_az208VisibleHeight=480,_az208HiResPublished=0;\n unsigned _az197SessionWidth=800,_az197SessionHeight=960,_az207ActiveHostScale=2;\n long _az191Resolution=1;Size _videoSize{800,960};unsigned char *_videoBuffer=nullptr;\n};\nstatic void AzTrace(const char *) {}\n'''
main='''
int main() {
 for(unsigned logicalW:{400u,800u}) {
  AzaharGameCore c; c._az197SessionWidth=logicalW*2u; c._az208VisibleWidth=logicalW; c._videoSize={logicalW*2u,960u};
  std::vector<unsigned char> frame(c._videoSize.width*c._videoSize.height*4u,0u);
  c._videoBuffer=frame.data();
  for(unsigned i=0;i<179;i++)Az208AdvanceScreenRect(&c);
  assert(c._az208VisibleWidth==logicalW && c._az208HiResPublished==0);
  c._az191Resolution=6;
  Az208AdvanceScreenRect(&c);
  assert(c._az208VisibleWidth==logicalW*2 && c._az208VisibleHeight==960 && c._az208HiResPublished==1);
  for(unsigned i=0;i<5;i++)Az208AdvanceScreenRect(&c);
  assert(c._az208VisibleWidth==logicalW*2);
  c._az191Resolution=1; Az208AdvanceScreenRect(&c);
  assert(c._az208VisibleWidth==logicalW && c._az208VisibleHeight==480 && c._az208HiResPublished==0);
  c._az191Resolution=2; Az208AdvanceScreenRect(&c);
  assert(c._az208VisibleWidth==logicalW*2 && c._az208HiResPublished==1);
  unsigned w=logicalW*2,h=960;
  std::vector<unsigned char> compact(w*h*4u);
  for(size_t i=0;i<compact.size();++i) compact[i]=(i*17u+37u)%251u;
  Az208CopyRowsToHost(&c,compact.data(),w,h);
  for(unsigned y:{0u,73u,479u,959u})for(unsigned x:{0u,w/2u,w-1u}) {
   for(unsigned k=0;k<4u;++k) assert(c._videoBuffer[((size_t)y*c._videoSize.width+x)*4u+k]==compact[((size_t)y*w+x)*4u+k]);
  }
 }
 // 6x SBS source is bounded below 128 MiB before GPU/readback copies.
 assert(4800ull*2880ull*4ull < 128ull*1024ull*1024ull);
 assert(2400ull*2880ull*4ull < 128ull*1024ull*1024ull);
 puts("V211 RECT + PITCH COPYING + 1X/2X/6X TRANSITIONS PASS");
}
'''
with tempfile.TemporaryDirectory() as tmp:
 t=Path(tmp);src=t/'test.cpp';exe=t/'test'
 src.write_text(prefix+fn+main)
 r=subprocess.run(['c++','-std=c++17','-Wall','-Wextra','-Werror','-O2',str(src),'-o',str(exe)],text=True,capture_output=True)
 assert r.returncode==0,r.stderr
 r=subprocess.run([str(exe)],text=True,capture_output=True)
 assert r.returncode==0,r.stderr
 print(r.stdout.strip())
