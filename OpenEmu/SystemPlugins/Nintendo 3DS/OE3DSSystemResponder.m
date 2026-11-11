#import "OE3DSSystemResponder.h"
#import <math.h>

// Stable libretro NDS button IDs (0..9, Start=10, Select=11).
// OpenEmu's UI key order is *different*: ZL/ZR occupy UI slots 10/11, while
// Start/Select occupy UI slots 12/13. Mapping by raw ordinal would silently
// map Start into an unrelated input (the bug fixed after plugin v11).
// v17 removed the nonfunctional Home UI control. This enum must follow the
// ordered OEGenericControlNamesKey manifest after the removal.
// Never forward a raw OpenEmu OESystemKey.key index: in v11 Start was 12.
// The basic inputs retain the historical NDS libretro selectors used by
// OpenEmu. ZL/ZR and the two analog sticks use separate selectors below.
// Unknown or extra keys MUST NOT be converted to libretro button IDs.
static NSInteger OE3DSNDSButtonForKey(NSUInteger key) {
    if(key <= OE3DSButtonR) return (NSInteger)key;
    if(key == OE3DSButtonStart) return 10;
    if(key == OE3DSButtonSelect) return 11;
    return -1;
}
// Analog directions are UI bindings, not raw libretro input IDs.
static BOOL OE3DSIsAnalog(NSUInteger key) {
    return key >= OE3DSButtonCirclePadUp && key <= OE3DSButtonCStickRight;
}
// v17 reviewer note: Both analog controls are represented by four DIGITAL
// directional keys in the OpenEmu bindings UI. The bridge sends normalized
// signed axis values; axis 0/1 = Circle Pad X/Y; axis 2/3 = C-stick X/Y.
// Positive and negative directions are cached separately so releasing one
// pressed key cannot accidentally cancel another still-held key.
static unsigned OE3DSAxisForKey(NSUInteger key) {
    switch(key) {
      case OE3DSButtonCirclePadLeft: case OE3DSButtonCirclePadRight: return 0;
      case OE3DSButtonCirclePadUp: case OE3DSButtonCirclePadDown: return 1;
      case OE3DSButtonCStickLeft: case OE3DSButtonCStickRight: return 2;
      default: return 3;
    }
}
static int OE3DSDirectionForKey(NSUInteger key) {
    switch(key) {
      case OE3DSButtonCirclePadLeft: case OE3DSButtonCirclePadUp:
      case OE3DSButtonCStickLeft: case OE3DSButtonCStickUp: return -1;
      default:return 1;
    }
}

@implementation OE3DSSystemResponder {
    // Opposing direction components are retained independently to handle
    // diagonals and multi-key input without cancelling an active direction.
    float _axisComponent[4][2];
}
@dynamic client;

+ (void)load { NSLog(@"[3DSResponderDiag] v24 responder class loaded (Home UI removed, other mappings retained)"); }
+ (Protocol *)gameSystemResponderClientProtocol { return @protocol(OE3DSSystemResponderClient); }

- (instancetype)initWithController:(OESystemController *)controller {
    if((self=[super initWithController:controller])) {
        memset(_axisComponent,0,sizeof(_axisComponent));
        NSLog(@"[3DSResponderDiag] v24 init complete controller=%@",controller);
    }
    return self;
}
- (void)setClient:(id<OE3DSSystemResponderClient>)client { [super setClient:client]; }

- (void)updateAnalogKey:(OESystemKey *)key magnitude:(float)magnitude {
    NSUInteger code=(NSUInteger)key.key;
    if(!OE3DSIsAnalog(code))return;
    unsigned axis=OE3DSAxisForKey(code);
    unsigned side=OE3DSDirectionForKey(code)>0?1:0;
    // Do not allow a malformed analog value to poison the cached state.
    if(!isfinite(magnitude))return;
    _axisComponent[axis][side]=fmaxf(0.0f,fminf(1.0f,fabsf(magnitude)));
    // Opposing directions cancel algebraically; releasing either side leaves
    // the other untouched. Preserve this ordering across refactors.
    const float value=_axisComponent[axis][1]-_axisComponent[axis][0];
    [self.client didChange3DSAnalogAxis:axis value:value forPlayer:key.player];
}

- (void)pressEmulatorKey:(OESystemKey *)key {
    const NSUInteger code=(NSUInteger)key.key;
    if(OE3DSIsAnalog(code)){[self updateAnalogKey:key magnitude:1.0f];return;}
    if(code==OE3DSButtonZL || code==OE3DSButtonZR){
        [self.client didChange3DSExtraButton:code==OE3DSButtonZL?0:1 pressed:YES forPlayer:key.player];
        return;
    }
    const NSInteger nds=OE3DSNDSButtonForKey(code);
    if(nds>=0){
        if(code==OE3DSButtonStart || code==OE3DSButtonSelect)
            NSLog(@"[3DSResponderDiag] v24 mapped %@ UI=%lu core=%ld DOWN",code==OE3DSButtonStart?@"START":@"SELECT",(unsigned long)code,(long)nds);
        [self.client didPushNDSButton:(NSUInteger)nds forPlayer:key.player];
    }
}
- (void)releaseEmulatorKey:(OESystemKey *)key {
    const NSUInteger code=(NSUInteger)key.key;
    if(OE3DSIsAnalog(code)){[self updateAnalogKey:key magnitude:0.0f];return;}
    if(code==OE3DSButtonZL || code==OE3DSButtonZR){
        [self.client didChange3DSExtraButton:code==OE3DSButtonZL?0:1 pressed:NO forPlayer:key.player];
        return;
    }
    const NSInteger nds=OE3DSNDSButtonForKey(code);
    if(nds>=0){
        if(code==OE3DSButtonStart || code==OE3DSButtonSelect)
            NSLog(@"[3DSResponderDiag] v24 mapped %@ UI=%lu core=%ld UP",code==OE3DSButtonStart?@"START":@"SELECT",(unsigned long)code,(long)nds);
        [self.client didReleaseNDSButton:(NSUInteger)nds forPlayer:key.player];
    }
}
- (void)changeAnalogEmulatorKey:(OESystemKey *)key value:(CGFloat)value {
    [self updateAnalogKey:key magnitude:(float)value];
}
// Touch input is forwarded to the companion core; no coordinate transform
// belongs in the System Plugin's controller mapping layer.
- (void)mouseDownAtPoint:(OEIntPoint)point {[self.client didTouchScreenPoint:point];}
- (void)mouseUpAtPoint {[self.client didReleaseTouch];}
@end
