#include <cassert>
#include <array>
#include <cstddef>
#include <iostream>
int main(){
  unsigned tested=0;
  for(unsigned stereo=0;stereo<4;stereo++) for(unsigned factor=2;factor<=6;factor++){
    unsigned nativeW=stereo==2?800:400;
    unsigned nativeH=480;
    unsigned sourceW=nativeW*factor, sourceH=nativeH*factor;
    std::array<unsigned,4> candidates{1,2,3,factor};
    std::array<unsigned,4> levels{};
    unsigned count=0;
    for(auto scale:candidates){
      if(scale>factor)continue;
      bool seen=false;
      for(unsigned i=0;i<count;i++) if(levels[i]==scale)seen=true;
      if(!seen)levels[count++]=scale;
    }
    assert(count>=2&&count<=4);
    assert(levels[0]==1&&levels[count-1]==factor);
    std::size_t total=(std::size_t)sourceW*sourceH*4;
    for(unsigned i=0;i<count;i++) {
      unsigned w=nativeW*levels[i],h=nativeH*levels[i];
      assert(w<=sourceW&&h<=sourceH);
      assert(w/levels[i]==nativeW && h/levels[i]==nativeH);
      total+=(std::size_t)w*h*4;
    }
    assert(total<=192ull*1024*1024);
    tested++;
  }
  assert(tested==20);
  std::cout<<"v206 geometry and private texture budget: PASS ("<<tested<<" mode-factor cases)\n";
}
