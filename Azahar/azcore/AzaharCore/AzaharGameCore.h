/*
 * 3DS-Azahar-Core public OpenEmu game-core declaration.
 *
 * OEGameCore owns the OpenEmu renderer contract and frame scheduling;
 * OEAudioBuffer bridges libretro audio; OENDSSystemResponderClient receives
 * the controls that the independently installed 3DS System Plugin defines.
 * Implementation details and mutable Vulkan/Metal state live in the .mm file.
 */

#import <Cocoa/Cocoa.h>
#import <OpenEmuBase/OEGameCore.h>
#import <OpenEmuBase/OEAudioBuffer.h>
#import "OENDSSystemResponderClient.h"

OE_EXPORTED_CLASS
// OpenEmu supplies id<OEAudioBuffer> via audioBufferAtIndex:; this core is not one.
@interface AzaharGameCore : OEGameCore <OENDSSystemResponderClient>
@end
