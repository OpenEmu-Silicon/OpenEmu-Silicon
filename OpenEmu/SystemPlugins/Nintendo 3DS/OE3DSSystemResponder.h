#import <Foundation/Foundation.h>
#import <OpenEmuSystem/OpenEmuSystem.h>

// UI/control ABI contract (see README.md, "Control-order contract"):
// Order MUST match OEGenericControlNamesKey in Nintendo3DS-Info.plist.
// The number/order of entries is frozen for v20 to avoid invalidating saved
// OpenEmu input bindings; new UI controls require an explicit migration.
// Do not reorder enum members to make numeric IDs prettier: OpenEmu stores
// bindings by these positions, while Azahar/libretro use a different button ABI.
// OpenEmu Start/Select are UI keys 12/13, while libretro expects 10/11.
// v17 removes nonfunctional Home; analog UI key ordinals shift by one.
typedef NS_ENUM(NSUInteger, OE3DSButton) {
    OE3DSButtonUp, OE3DSButtonDown, OE3DSButtonLeft, OE3DSButtonRight,
    OE3DSButtonA, OE3DSButtonB, OE3DSButtonX, OE3DSButtonY,
    OE3DSButtonL, OE3DSButtonR, OE3DSButtonZL, OE3DSButtonZR,
    OE3DSButtonStart, OE3DSButtonSelect,
    OE3DSButtonCirclePadUp, OE3DSButtonCirclePadDown,
    OE3DSButtonCirclePadLeft, OE3DSButtonCirclePadRight,
    OE3DSButtonCStickUp, OE3DSButtonCStickDown,
    OE3DSButtonCStickLeft, OE3DSButtonCStickRight,
    OE3DSButtonCount
};

@protocol OE3DSSystemResponderClient <OESystemResponderClient, NSObject>
// Retain these existing selector names to preserve the known working OpenEmu bridge.
- (oneway void)didPushNDSButton:(NSUInteger)button forPlayer:(NSUInteger)player;
- (oneway void)didReleaseNDSButton:(NSUInteger)button forPlayer:(NSUInteger)player;
- (oneway void)didTouchScreenPoint:(OEIntPoint)point;
- (oneway void)didReleaseTouch;
// Remote selectors introduced in v12 and used by Azahar Core v190+.
// These are intentionally 3DS-specific instead of forcing the extra
// shoulder buttons or analog axes through the legacy NDS button namespace.
// They are intentionally unchanged in v17 for backward compatibility.
// axis 0..3: Circle Pad X/Y and C-stick X/Y; button 0/1: ZL/ZR.
- (oneway void)didChange3DSAnalogAxis:(NSUInteger)axis value:(float)value forPlayer:(NSUInteger)player;
- (oneway void)didChange3DSExtraButton:(NSUInteger)button pressed:(BOOL)pressed forPlayer:(NSUInteger)player;
@end

OE_EXPORTED_CLASS
@interface OE3DSSystemResponder : OESystemResponder
@property(nonatomic, weak) id<OE3DSSystemResponderClient> client;
@end
