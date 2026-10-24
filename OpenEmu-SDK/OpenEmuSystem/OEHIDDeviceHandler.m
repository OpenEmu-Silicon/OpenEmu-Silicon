/*
 Copyright (c) 2012, OpenEmu Team

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

#import "OEHIDDeviceHandler.h"
#import "OEControllerDescription.h"
#import "OEDeviceDescription.h"
#import "OEControlDescription.h"
#import "OEHIDEvent_Internal.h"
#import "OEDeviceManager.h"
#import "OEDeviceManager_Internal.h"
#import "OEHIDDeviceParser.h"
#import <IOKit/usb/USBSpec.h>

NS_ASSUME_NONNULL_BEGIN

@interface OEHIDEvent ()
+ (instancetype)OE_eventWithElement:(IOHIDElementRef)element value:(NSInteger)value;
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-designated-initializers"

@implementation OEHIDDeviceHandler {
    NSMutableDictionary<NSNumber *, OEHIDEvent *> *_latestEvents;
    NSString *_uniqueIdentifier;

    //force feedback support
    FFDeviceObjectReference _ffDevice;
    FFEFFECT *_effect;
    FFCUSTOMFORCE *_customforce;
    FFEffectObjectReference _effectRef;

    BOOL _isFunctionKeyPressed;
}

+ (id<OEHIDDeviceParser>)deviceParser;
{
    static OEHIDDeviceParser *parser = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        parser = [[OEHIDDeviceParser alloc] init];
    });

    return parser;
}

+ (BOOL)canHandleDevice:(IOHIDDeviceRef)device
{
    return YES;
}

- (instancetype)initWithDeviceDescription:(nullable OEDeviceDescription *)deviceDescription
{
    return nil;
}

- (instancetype)initWithIOHIDDevice:(IOHIDDeviceRef)aDevice deviceDescription:(nullable OEDeviceDescription *)deviceDescription;
{
    if(aDevice == NULL)
        return nil;

    if((self = [super initWithDeviceDescription:deviceDescription])) {
        _device = (void *)CFRetain(aDevice);
        NSAssert(deviceDescription != nil || [self isKeyboardDevice], @"Non-keyboard devices must have device descriptions.");
        if(deviceDescription != nil) {
            _latestEvents = [[NSMutableDictionary alloc] initWithCapacity:[[self controllerDescription] numberOfControls]];
            [self OE_setUpInitialEvents];
        }

        [self setUpCallbacks];
    }

    return self;
}

- (void)dealloc
{
    if (_device == NULL)
        return;

    /* IOHIDDeviceUnscheduleFromRunLoop does not actually stop all callbacks immediately,
     * while IOHIDDeviceClose does. */
    IOHIDDeviceClose(_device, 0);
    CFRelease(_device);

    if(_ffDevice != NULL)
        FFReleaseDevice(_ffDevice);
}

- (CFRunLoopRef)eventRunLoop
{
    return CFRunLoopGetMain();
}

- (BOOL)isUSBDevice
{
    return [(__bridge NSNumber *)IOHIDDeviceGetProperty(_device, CFSTR(kUSBInterfaceClass)) integerValue] == kUSBHIDClass;
}

- (NSString *)uniqueIdentifier
{
    if (_uniqueIdentifier) {
        return _uniqueIdentifier;
    }

    _uniqueIdentifier = [[self locationID] stringValue];
    if (!_uniqueIdentifier) {
        // Workaround for devices with null locationID but hopefully have a unique product name.
        // Steam Controller's user mode driver emulation has unique names, at least.
        _uniqueIdentifier = [self product];
    }

    if (self.isUSBDevice) {
        NSNumber *interfaceNumber = self.interfaceNumber;
        if (interfaceNumber) {
            if (_uniqueIdentifier)
                _uniqueIdentifier = [_uniqueIdentifier stringByAppendingFormat:@"_%@", interfaceNumber];
            else
                _uniqueIdentifier = interfaceNumber.stringValue;
        }
    }

    if (!_uniqueIdentifier) {
        _uniqueIdentifier = @"";
    }

    return _uniqueIdentifier;
}

- (NSString *)serialNumber
{
    return (__bridge NSString *)IOHIDDeviceGetProperty(_device, CFSTR(kIOHIDSerialNumberKey));
}

- (NSString *)manufacturer
{
    return (__bridge NSString *)IOHIDDeviceGetProperty(_device, CFSTR(kIOHIDManufacturerKey));
}

- (NSString *)product
{
    return (__bridge NSString *)IOHIDDeviceGetProperty(_device, CFSTR(kIOHIDProductKey));
}

- (NSUInteger)vendorID
{
    return [(__bridge NSNumber *)IOHIDDeviceGetProperty(_device, CFSTR(kIOHIDVendorIDKey)) integerValue];
}

- (NSUInteger)productID
{
    return [(__bridge NSNumber *)IOHIDDeviceGetProperty(_device, CFSTR(kIOHIDProductIDKey)) integerValue];
}

- (NSNumber *)locationID
{
    return (__bridge NSNumber *)IOHIDDeviceGetProperty(_device, CFSTR(kIOHIDLocationIDKey));
}

- (NSNumber *)interfaceNumber
{
    return (__bridge NSNumber *)IOHIDDeviceGetProperty(_device, CFSTR(kUSBInterfaceNumber));
}

+ (BOOL)deviceIsKeyboardOnly:(IOHIDDeviceRef)device
{
    return IOHIDDeviceConformsTo(device, kHIDPage_GenericDesktop, kHIDUsage_GD_Keyboard)
        && !IOHIDDeviceConformsTo(device, kHIDPage_GenericDesktop, kHIDUsage_GD_GamePad)
        && !IOHIDDeviceConformsTo(device, kHIDPage_GenericDesktop, kHIDUsage_GD_Joystick);
}

- (BOOL)isKeyboardDevice;
{
    return [OEHIDDeviceHandler deviceIsKeyboardOnly:_device];
}

- (BOOL)isFunctionKeyPressed
{
    return _isFunctionKeyPressed;
}

- (void)dispatchEvent:(OEHIDEvent *)event
{
    if(event == nil)
        return;

    NSNumber *cookieKey = @([event cookie]);
    OEHIDEvent *existingEvent = _latestEvents[cookieKey];

    if([event isEqualToEvent:existingEvent])
        return;

    if([event isAxisDirectionOppositeToEvent:existingEvent])
        [[OEDeviceManager sharedDeviceManager] deviceHandler:self didReceiveEvent:[event axisEventWithDirection:OEHIDEventAxisDirectionNull]];

    _latestEvents[cookieKey] = event;
    [[OEDeviceManager sharedDeviceManager] deviceHandler:self didReceiveEvent:event];
}

- (OEHIDEvent *)eventWithHIDValue:(IOHIDValueRef)aValue
{
    return [OEHIDEvent eventWithDeviceHandler:self value:aValue];
}

- (void)dispatchEventWithHIDValue:(IOHIDValueRef)aValue
{
    OEHIDEvent *event = [self eventWithHIDValue:aValue];
    if (event.type == OEHIDEventTypeKeyboard && event.keycode == OEHIDUsage_KeyboardFunctionKey) {
        _isFunctionKeyPressed = (event.state == OEHIDEventStateOn);
    }

    [self dispatchEvent:event];
}

- (void)dispatchFunctionKeyEventWithHIDValue:(IOHIDValueRef)aValue
{
    _isFunctionKeyPressed = !!IOHIDValueGetIntegerValue(aValue);
    [self dispatchEventWithHIDValue:aValue];
}

- (io_service_t)serviceRef
{
    return IOHIDDeviceGetService(_device);
}

//- (BOOL)connect
//{
// Example code to test the vibration.
//    [self enableForceFeedback];
//    dispatch_queue_t rumbleTest = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
//    dispatch_async(rumbleTest, ^{
//        while(true) {
//            [self rumbleWithStrongIntensity:0xFF weakIntensity:0xFF];
//            usleep(100);
//        }
//    });
//    return YES;
//}

- (void)forceFeedbackWithStrongIntensity:(CGFloat)strongIntensity weakIntensity:(CGFloat)weakIntensity
{
    if(_ffDevice == NULL)
        [self enableForceFeedback];

    if(_ffDevice  == NULL)
        return;

    if(_effectRef == NULL)
        return;

    _customforce->rglForceData[0] = strongIntensity * 10000;
    _customforce->rglForceData[1] = weakIntensity * 10000;
    FFEffectSetParameters(_effectRef, _effect, FFEP_TYPESPECIFICPARAMS);
    FFEffectStart(_effectRef, 1, 0);
}

- (BOOL)supportsForceFeedback
{
    io_service_t service = [self serviceRef];
    if(service == MACH_PORT_NULL)
        return NO;

    return FFIsForceFeedback(service) == FF_OK;
}

- (void)enableForceFeedback
{
    if(![self supportsForceFeedback])
        return;

    io_service_t service = [self serviceRef];
    if(service == MACH_PORT_NULL)
        return;

    FFCreateDevice(service, &_ffDevice);
    FFCAPABILITIES capabs;
    FFDeviceGetForceFeedbackCapabilities(_ffDevice, &capabs);

    // TODO: adjust for less than one axis of feedback
    if(capabs.numFfAxes != 2)
        return;

    _effect      = calloc(1, sizeof(FFEFFECT));
    _customforce = calloc(1, sizeof(FFCUSTOMFORCE));
    LONG  *c = calloc(2, sizeof(LONG));
    DWORD *a = calloc(2, sizeof(DWORD));
    LONG  *d = calloc(2, sizeof(LONG));

    c[0] = 0;
    c[1] = 0;
    a[0] = capabs.ffAxes[0];
    a[1] = capabs.ffAxes[1];
    d[0] = 0;
    d[1] = 0;

    _customforce->cChannels      = 2;
    _customforce->cSamples       = 2;
    _customforce->rglForceData   = c;
    _customforce->dwSamplePeriod = 100*1000;

    _effect->cAxes                 = capabs.numFfAxes;
    _effect->rglDirection          = d;
    _effect->rgdwAxes              = a;
    _effect->dwSamplePeriod        = 0;
    _effect->dwGain                = 10000;
    _effect->dwFlags               = FFEFF_OBJECTOFFSETS | FFEFF_SPHERICAL;
    _effect->dwSize                = sizeof(FFEFFECT);
    _effect->dwDuration            = FF_INFINITE;
    _effect->dwSamplePeriod        = 100 * 1000;
    _effect->cbTypeSpecificParams  = sizeof(FFCUSTOMFORCE);
    _effect->lpvTypeSpecificParams = _customforce;
    _effect->lpEnvelope            = NULL;
    FFDeviceCreateEffect(_ffDevice, kFFEffectType_CustomForce_ID, _effect, &_effectRef);
}

- (void)disableForceFeedback
{
    if(_ffDevice == NULL)
        return;

    FFDeviceReleaseEffect(_ffDevice, _effectRef);
    FFReleaseDevice(_ffDevice);
    _ffDevice = NULL;
}

- (void)OE_setUpInitialEvents;
{
    for(OEControlDescription *control in [[self controllerDescription] controls]) {
        OEHIDEvent *event = [control genericEvent];
        _latestEvents[@([event cookie])] = [[event nullEvent] eventWithDeviceHandler:self];
    }
}

- (NSArray<NSDictionary<NSString *, id> *> *)inputValueMatchingProperties;
{
    NOTE("If supporting additional HID Usage Pages add them here to whitelist!");
    return @[
        @{ @kIOHIDElementUsagePageKey: @(kHIDPage_GenericDesktop) },
        @{ @kIOHIDElementUsagePageKey: @(kHIDPage_Consumer) },
        @{ @kIOHIDElementUsagePageKey: @(kHIDPage_Simulation) },
        @{ @kIOHIDElementUsagePageKey: @(kHIDPage_VR) },
        @{ @kIOHIDElementUsagePageKey: @(kHIDPage_Sport) },
        @{ @kIOHIDElementUsagePageKey: @(kHIDPage_Game) },
        @{ @kIOHIDElementUsagePageKey: @(kHIDPage_Button) },
        @{ @kIOHIDElementUsagePageKey: @(kHIDPage_KeyboardOrKeypad) },
        @{ @kIOHIDElementUsagePageKey: @0xFF, @kIOHIDElementUsageKey: @3, }
    ];
}

- (void)setUpCallbacks;
{
    // Register for removal
    IOHIDDeviceRegisterRemovalCallback(_device, OEHandle_DeviceRemovalCallback, (__bridge void *)self);

    // Register for input
    IOHIDDeviceSetInputValueMatchingMultiple(_device, (__bridge CFArrayRef)[self inputValueMatchingProperties]);
    IOHIDDeviceRegisterInputValueCallback(_device, OEHandle_InputValueCallback, (__bridge void *)self);

    // Attach to the runloop
    IOHIDDeviceScheduleWithRunLoop(_device, self.eventRunLoop, kCFRunLoopDefaultMode);
}

- (void)OE_removeDeviceHandlerForDevice:(IOHIDDeviceRef)aDevice
{
    NSAssert(aDevice == _device, @"Device remove callback called on the wrong object.");

    IOHIDDeviceUnscheduleFromRunLoop(_device, self.eventRunLoop, kCFRunLoopDefaultMode);

    dispatch_async(dispatch_get_main_queue(), ^{
        [[OEDeviceManager sharedDeviceManager] OE_removeDeviceHandler:self];
    });
}

static void OEHandle_InputValueCallback(void *inContext, IOReturn inResult, void *inSender, IOHIDValueRef inIOHIDValueRef)
{
    [(__bridge OEHIDDeviceHandler *)inContext dispatchEventWithHIDValue:inIOHIDValueRef];
}

static void OEHandle_DeviceRemovalCallback(void *inContext, IOReturn inResult, void *inSender)
{
    IOHIDDeviceRef hidDevice = (IOHIDDeviceRef)inSender;

    [(__bridge OEHIDDeviceHandler *)inContext OE_removeDeviceHandlerForDevice:hidDevice];
}

@end

#pragma clang diagnostic pop

NS_ASSUME_NONNULL_END
