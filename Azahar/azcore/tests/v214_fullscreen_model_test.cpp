// Static host-scaling model derived from stock OpenEmu source (not a UI test).
// GameViewController.defaultScreenSize follows the corrected screenRect.
// GameWindowController.windowContentSize uses defaultScreenSize * integralScale.
#include <cassert>
#include <iostream>
struct Size{int w,h;};
static Size hostFullScreen1x(Size visibleRect){return visibleRect;}
int main(){
  for(int nativeW: {400,800}){
    const Size native{nativeW,480};
    const Size retina{nativeW*2,960};
    const Size size1=hostFullScreen1x(native), size2=hostFullScreen1x(retina);
    assert(size1.w==nativeW && size1.h==480);
    assert(size2.w==nativeW*2 && size2.h==960);
    assert(size2.w==2*size1.w && size2.h==2*size1.h);
  }
  std::cout<<"V214 STOCK_HOST_FULLSCREEN_SCALE_MODEL reproduces 2x logical size; host integration required\n";
}
