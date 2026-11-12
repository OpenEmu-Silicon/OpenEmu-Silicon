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

#import "OE3DSSystemResponder.h"
#import "OE3DSSystemResponderClient.h"
#import <math.h>

// Each stick is bound as four directional keys. The two directions of an axis
// are kept apart, so releasing one key cannot cancel the other while it is
// still held, and opposite keys held together cancel out.
static BOOL OE3DSIsAnalog(NSUInteger key)
{
    return key >= OE3DSButtonCirclePadUp && key <= OE3DSButtonCStickRight;
}

static OE3DSAxis OE3DSAxisForKey(NSUInteger key)
{
    switch (key) {
    case OE3DSButtonCirclePadLeft:
    case OE3DSButtonCirclePadRight:
        return OE3DSAxisCirclePadX;
    case OE3DSButtonCirclePadUp:
    case OE3DSButtonCirclePadDown:
        return OE3DSAxisCirclePadY;
    case OE3DSButtonCStickLeft:
    case OE3DSButtonCStickRight:
        return OE3DSAxisCStickX;
    default:
        return OE3DSAxisCStickY;
    }
}

// Left and up are negative.
static BOOL OE3DSKeyIsPositive(NSUInteger key)
{
    switch (key) {
    case OE3DSButtonCirclePadLeft:
    case OE3DSButtonCirclePadUp:
    case OE3DSButtonCStickLeft:
    case OE3DSButtonCStickUp:
        return NO;
    default:
        return YES;
    }
}

@implementation OE3DSSystemResponder {
    // [axis][0] is the negative side, [axis][1] the positive side.
    float _axisComponent[OE3DSAxisCount][2];
}

@dynamic client;

+ (Protocol *)gameSystemResponderClientProtocol
{
    return @protocol(OE3DSSystemResponderClient);
}

- (void)updateAnalogKey:(OESystemKey *)key magnitude:(float)magnitude
{
    const NSUInteger code = key.key;
    if (!OE3DSIsAnalog(code) || !isfinite(magnitude)) return;

    const OE3DSAxis axis = OE3DSAxisForKey(code);
    _axisComponent[axis][OE3DSKeyIsPositive(code) ? 1 : 0] = fmaxf(0.0f, fminf(1.0f, fabsf(magnitude)));

    const float value = _axisComponent[axis][1] - _axisComponent[axis][0];
    [self.client didChange3DSAxis:axis value:value forPlayer:key.player];
}

- (void)pressEmulatorKey:(OESystemKey *)key
{
    if (OE3DSIsAnalog(key.key)) {
        [self updateAnalogKey:key magnitude:1.0f];
    } else if (key.key < OE3DSButtonCirclePadUp) {
        [self.client didPush3DSButton:(OE3DSButton)key.key forPlayer:key.player];
    }
}

- (void)releaseEmulatorKey:(OESystemKey *)key
{
    if (OE3DSIsAnalog(key.key)) {
        [self updateAnalogKey:key magnitude:0.0f];
    } else if (key.key < OE3DSButtonCirclePadUp) {
        [self.client didRelease3DSButton:(OE3DSButton)key.key forPlayer:key.player];
    }
}

- (void)changeAnalogEmulatorKey:(OESystemKey *)key value:(CGFloat)value
{
    [self updateAnalogKey:key magnitude:(float)value];
}

- (void)mouseDownAtPoint:(OEIntPoint)point
{
    [self.client didTouchScreenPoint:point];
}

- (void)mouseUpAtPoint
{
    [self.client didReleaseTouch];
}

@end
