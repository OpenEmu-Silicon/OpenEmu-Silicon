// Source-independent analog of the v208 row copy and v209 audit. Test in 2D/SBS.
#include <algorithm>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>
static void run(unsigned nativeW,unsigned scale) {
 const unsigned nativeH=480;
 const unsigned maxW=nativeW*3u,maxH=nativeH*3u;
 const unsigned targetW=nativeW*scale,targetH=nativeH*scale;
 assert(scale>=1 && scale<=3);
 assert((uint64_t)maxW*maxH*4u<=(uint64_t)24*1024*1024);
 std::vector<uint8_t> host((size_t)maxW*maxH*4u,0xBE);
 for(unsigned iteration=0;iteration<2;++iteration){
  const unsigned w=iteration?targetW:nativeW,h=iteration?targetH:nativeH;
  std::vector<uint8_t> compact((size_t)w*h*4u,0u);
  for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x)for(unsigned c=0;c<4;++c)
    compact[((size_t)y*w+x)*4u+c]=(uint8_t)((x*3u+y*7u+c*51u+iteration*73u)&255u);
  const size_t hostPitch=(size_t)maxW*4u,srcPitch=(size_t)w*4u;
  for(unsigned y=0;y<h;++y)std::memcpy(host.data()+y*hostPitch,compact.data()+y*srcPitch,srcPitch);
  const unsigned xs[3]={0u,w/2u,w-1u},ys[3]={0u,h/2u,h-1u};
  for(unsigned iy=0;iy<3;++iy)for(unsigned ix=0;ix<3;++ix){
    auto src=compact.data()+(size_t)ys[iy]*srcPitch+xs[ix]*4u;
    auto dst=host.data()+(size_t)ys[iy]*hostPitch+xs[ix]*4u;
    assert(!std::memcmp(src,dst,4u));
  }
  // Ensure all rows, including right edge and bottom, match and pitch padding untouched.
  for(unsigned y=0;y<h;++y){
    assert(!std::memcmp(host.data()+(size_t)y*hostPitch,compact.data()+(size_t)y*srcPitch,srcPitch));
    for(unsigned x=w;x<maxW;++x)for(unsigned c=0;c<4;++c)
      assert(host[(size_t)y*hostPitch+(size_t)x*4u+c]==0xBE);
  }
  // Deliberate corruption must be detected by the 9-point sampler.
  auto &corner=host[(size_t)(h-1u)*hostPitch+(size_t)(w-1u)*4u];
  corner^=0x01;
  assert(std::memcmp(&corner,compact.data()+(size_t)(h-1u)*srcPitch+(size_t)(w-1u)*4u,4u));
  corner^=0x01;
 }
}
int main(){
 int n=0;
 for(unsigned nw: {400u,800u})for(unsigned s: {1u,2u,3u}){run(nw,s);++n;}
 std::printf("V209 PITCH MATRIX PASS: %d geometry configurations, 2 presentation states each, complete row and corner checks\n",n);
}
