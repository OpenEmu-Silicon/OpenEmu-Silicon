#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>
#include <algorithm>
int main(){
 unsigned checks=0;
 for(unsigned scale: {1u,2u,3u}) for(unsigned wide: {0u,1u}){
   const unsigned w=(wide?800u:400u)*scale,h=480u*scale;
   const size_t bytes=(size_t)w*h*4u;
   assert(bytes<=(size_t)24u*1024u*1024u);
   assert(w*4u==((size_t)w*4u));
   std::vector<uint8_t> frame(bytes,0);
   for(unsigned y=0;y<h;++y) for(unsigned x=0;x<w;++x){
       size_t off=((size_t)y*w+x)*4u;
       frame[off+0]=(uint8_t)(x%256u);frame[off+1]=(uint8_t)(y%256u);
       frame[off+2]=(uint8_t)((x+y)%256u);frame[off+3]=255;
   }
   // Row-stride correctness for exactly sized full-resolution sources.
   for(unsigned y: {0u,h/2u,h-1u}) for(unsigned x: {0u,w/2u,w-1u}){
       size_t pos=((size_t)y*w+x)*4u;
       assert(frame[pos]==(uint8_t)(x%256u));
       assert(frame[pos+1]==(uint8_t)(y%256u));
       checks++;
   }
   // Wide frame can center its 400/800/1200px equivalent 2D image.
   if(wide){assert(w/2u==400u*scale); checks++;}
 }
 assert(checks==57u);
}
