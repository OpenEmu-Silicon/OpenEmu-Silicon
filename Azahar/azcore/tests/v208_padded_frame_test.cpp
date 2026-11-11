#include <algorithm>
#include <cassert>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <vector>
static void blit(uint8_t *host,unsigned hostW,unsigned hostH,
                 const uint8_t *compact,unsigned frameW,unsigned frameH){
  assert(frameW<=hostW&&frameH<=hostH);
  for(unsigned y=0;y<frameH;++y)
    std::memcpy(host+(size_t)y*hostW*4,compact+(size_t)y*frameW*4,(size_t)frameW*4);
}
int main(){
  for(unsigned logicalW: {400u,800u}) for(unsigned scale:{2u,3u}){
    const unsigned logicalH=480u,maxW=logicalW*3,maxH=logicalH*3;
    std::vector<uint8_t> host((size_t)maxW*maxH*4,0xD0);
    for(unsigned displayScale:{1u,scale}){
      unsigned w=logicalW*displayScale,h=logicalH*displayScale;
      std::vector<uint8_t> compact((size_t)w*h*4);
      for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x){
        size_t ix=((size_t)y*w+x)*4;
        compact[ix]=(uint8_t)(x%251); compact[ix+1]=(uint8_t)(y%251);
        compact[ix+2]=(uint8_t)((x^y)%251);compact[ix+3]=255;
      }
      blit(host.data(),maxW,maxH,compact.data(),w,h);
      for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x){
        size_t ih=((size_t)y*maxW+x)*4;
        size_t ic=((size_t)y*w+x)*4;
        for(unsigned z=0;z<4;++z)assert(host[ih+z]==compact[ic+z]);
      }
    }
  }
  puts("V208 PADDED ROW COPY AND 1x -> 2x/3x STEREO GEOMETRY PASS");
}
