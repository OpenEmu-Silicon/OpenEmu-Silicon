/*
 Copyright (c) 2026, OpenEmu Team
 Based on the Nintendo 3DS system plugin by Derek Hugger (OpenEmu-Silicon #830).

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import <Foundation/Foundation.h>

@protocol OESystemResponderClient;

// The order must match OEGenericControlNamesKey in Nintendo3DS-Info.plist.
// OpenEmu stores saved bindings by these positions, so do not reorder or
// insert entries without a migration.
typedef NS_ENUM(NSUInteger, OE3DSButton)
{
    OE3DSButtonUp,
    OE3DSButtonDown,
    OE3DSButtonLeft,
    OE3DSButtonRight,
    OE3DSButtonA,
    OE3DSButtonB,
    OE3DSButtonX,
    OE3DSButtonY,
    OE3DSButtonL,
    OE3DSButtonR,
    OE3DSButtonZL,
    OE3DSButtonZR,
    OE3DSButtonStart,
    OE3DSButtonSelect,
    // The analog sticks are bound as four directions each. The responder
    // turns them into axis values and never sends these as buttons.
    OE3DSButtonCirclePadUp,
    OE3DSButtonCirclePadDown,
    OE3DSButtonCirclePadLeft,
    OE3DSButtonCirclePadRight,
    OE3DSButtonCStickUp,
    OE3DSButtonCStickDown,
    OE3DSButtonCStickLeft,
    OE3DSButtonCStickRight,
    OE3DSButtonCount
};

typedef NS_ENUM(NSUInteger, OE3DSAxis)
{
    OE3DSAxisCirclePadX,
    OE3DSAxisCirclePadY,
    OE3DSAxisCStickX,
    OE3DSAxisCStickY,
    OE3DSAxisCount
};

@protocol OE3DSSystemResponderClient <OESystemResponderClient, NSObject>

// Digital buttons only: OE3DSButtonUp through OE3DSButtonSelect.
- (oneway void)didPush3DSButton:(OE3DSButton)button forPlayer:(NSUInteger)player;
- (oneway void)didRelease3DSButton:(OE3DSButton)button forPlayer:(NSUInteger)player;

// value runs from -1.0 to 1.0. Negative is left on X and up on Y.
- (oneway void)didChange3DSAxis:(OE3DSAxis)axis value:(float)value forPlayer:(NSUInteger)player;

// A point in the displayed picture, as OpenEmu reports mouse input. The core
// maps it onto the bottom screen of the current layout.
- (oneway void)didTouchScreenPoint:(OEIntPoint)point;
- (oneway void)didReleaseTouch;

@end
