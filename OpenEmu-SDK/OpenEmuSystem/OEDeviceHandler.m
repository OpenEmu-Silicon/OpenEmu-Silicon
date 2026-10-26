/*
 Copyright (c) 2009, OpenEmu Team

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

#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/hid/IOHIDUsageTables.h>
#import <ForceFeedback/ForceFeedback.h>

#import "OEDeviceHandler.h"
#import "OEDeviceDescription.h"
#import "OEControllerDescription.h"
#import "OEDeviceManager.h"
#import "OEHIDEvent_Internal.h"
#import "OEHIDDeviceHandler.h"
#import "OEControlDescription.h"

NS_ASSUME_NONNULL_BEGIN

#if __has_feature(objc_bool)
#undef YES
#undef NO
#define YES __objc_yes
#define NO __objc_no
#endif

NSNotificationName const OEDeviceHandlerDidReceiveLowBatteryWarningNotification = @"OEDeviceHandlerDidReceiveLowBatteryWarningNotification";
NSNotificationName const OEDeviceHandlerPlaceholderOriginalDeviceDidBecomeAvailableNotification = @"OEDeviceHandlerPlaceholderOriginalDeviceDidBecomeAvailableNotification";

static NSString *const OEDeviceHandlerUniqueIdentifierKey = @"OEDeviceHandlerUniqueIdentifier";

CGFloat OEScaledValueWithCalibration(OEAxisCalibration cal, NSInteger rawValue)
{
    CGFloat value = OE_CLAMP(cal.min, rawValue, cal.max);

    NSInteger middleValue = cal.center;

    if(cal.min >= 0)
    {
        cal.min -= middleValue;
        value   -= middleValue;
        cal.max -= middleValue;
    }

    if(value < 0)      return -value / (CGFloat)cal.min;
    else if(value > 0) return  value / (CGFloat)cal.max;

    return 0.0;
}

@interface OEDeviceHandler ()
{
    NSMutableDictionary *_deadZones;
    NSMutableDictionary *_calibrations;
}

@property(readwrite) NSUInteger deviceNumber;
@property(readwrite) NSUInteger deviceIdentifier;
@end

@implementation OEDeviceHandler

- (void)forceFeedbackWithStrongIntensity:(CGFloat)strongIntensity weakIntensity:(CGFloat)weakIntensity
{
}

- (instancetype)init
{
    NSAssert(NO, @"Use designated initializer instead.");
    return nil;
}

- (instancetype)initWithDeviceDescription:(nullable OEDeviceDescription *)deviceDescription
{
    if((self = [super init]))
    {
        _deviceDescription = deviceDescription;
        FIXME("Save default dead zones in user defaults based on device description.");
        _defaultDeadZone = 0.125;
        _deadZones = [[NSMutableDictionary alloc] init];
        _calibrations = [[NSMutableDictionary alloc] init];
    }

    return self;
}

- (nullable OEControllerDescription *)controllerDescription
{
    return [[self deviceDescription] controllerDescription];
}

- (void)setUpControllerDescription:(OEControllerDescription *)description usingRepresentation:(NSDictionary *)controlRepresentations
{
    NSAssert(NO, @"Need to implement the method in a subclass.");
}

- (id)copyWithZone:(nullable NSZone *)zone
{
    return self;
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder
{
    return [[OEDeviceManager sharedDeviceManager] deviceHandlerForUniqueIdentifier:[aDecoder decodeObjectOfClass:[NSString class] forKey:OEDeviceHandlerUniqueIdentifierKey]];
}

- (void)encodeWithCoder:(NSCoder *)aCoder
{
    [aCoder encodeObject:[self uniqueIdentifier] forKey:OEDeviceHandlerUniqueIdentifierKey];
}

- (BOOL)isKeyboardDevice;
{
    return NO;
}

- (BOOL)isFunctionKeyPressed
{
    return NO;
}

- (BOOL)isPlaceholder
{
    return NO;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@ %p uniqueIdentifier: '%@' deviceDescription: '%@' manufacturer: %@ product: %@ serialNumber: %@ deviceIdentifier: %lu deviceNumber: %lu isKeyboard: %@>", [self class], self, [self uniqueIdentifier], [self deviceDescription], [self manufacturer], [self product], [self serialNumber], [self deviceIdentifier], [self deviceNumber], [self isKeyboardDevice] ? @"YES" : @"NO"];
}

- (NSString *)uniqueIdentifier
{
    return nil;
}

- (NSString *)serialNumber;
{
    return nil;
}

- (NSString *)manufacturer;
{
    return nil;
}

- (NSString *)product;
{
    return nil;
}

- (NSUInteger)vendorID;
{
    return [_deviceDescription vendorID];
}

- (NSUInteger)productID;
{
    return [_deviceDescription productID];
}

- (NSNumber *)locationID;
{
    return nil;
}

- (BOOL)connect;
{
    return YES;
}

- (void)disconnect;
{
}

- (CGFloat)deadZoneForControlCookie:(NSUInteger)controlCookie;
{
    NSNumber *deadZone = _deadZones[@(controlCookie)];

    return deadZone != nil ? [deadZone doubleValue] : _defaultDeadZone;
}

- (BOOL)isAutoCalibrated
{
    return self.deviceDescription.controllerDescription.wantsCalibration;
}

- (BOOL)calibration:(OEAxisCalibration *)outCalib forControlCookie:(NSUInteger)controlCookie
{
    NSValue *cal = _calibrations[@(controlCookie)];
    if (cal == nil)
    {
        return NO;
    }
    else
    {
        [cal getValue:outCalib];
        return YES;
    }
}

- (void)setCalibration:(OEAxisCalibration)calibration forControlCookie:(NSUInteger)controlCookie
{
    NSValue *cal = [NSValue valueWithBytes:&calibration objCType:@encode(OEAxisCalibration)];
    [_calibrations setObject:cal forKey:@(controlCookie)];
}

- (CGFloat)deadZoneForControlDescription:(OEControlDescription *)controlDesc;
{
    return [self deadZoneForControlCookie:[[controlDesc genericEvent] cookie]];
}

- (void)setDeadZone:(CGFloat)deadZone forControlDescription:(OEControlDescription *)controlDesc;
{
    FIXME("Save dead zones in user defaults based on the serial number.");
    NSAssert(controlDesc != nil, @"Cannot set the dead zone of nil!");
    NSAssert([controlDesc type] == OEHIDEventTypeAxis || [controlDesc type] == OEHIDEventTypeTrigger, @"Only analogic controls have dead zones.");
    _deadZones[@([[controlDesc genericEvent] cookie])] = @(deadZone);
}

- (OEAxisCalibration)OE_updateAutoCalibrationWithScaledValue:(NSInteger)rawValue axis:(OEHIDEventAxis)axis controlCookie:(NSUInteger)cookie defaultCalibration:(OEAxisCalibration)fallback
{
    OEAxisCalibration cal = OEAxisCalibrationMake(100000, -100000);
    [self calibration:&cal forControlCookie:cookie];
    cal.center = fallback.center;
    BOOL changed = NO;
    if (rawValue < cal.min)
    {
        cal.min = rawValue;
        changed = YES;
    }
    if (rawValue > cal.max)
    {
        cal.max = rawValue;
        changed = YES;
    }
    if (changed)
    {
        NSLog(@"AutoCal: cookie=%lu rawValue=%ld min=%ld max=%ld",
              cookie, (long)rawValue, (long)cal.min, (long)cal.max);
        [self setCalibration:cal forControlCookie:cookie];
    }
    
    CGFloat deadZone = [self deadZoneForControlCookie:cookie];
    if (((CGFloat)(cal.center - cal.min) / (CGFloat)(fallback.center - fallback.min)) < deadZone * 1.5) {
        cal.min = fallback.min;
    }
    if (((CGFloat)(cal.max - cal.center) / (CGFloat)(fallback.max - fallback.center)) < deadZone * 1.5) {
        cal.max = fallback.max;
    }
    
    return cal;
}

- (CGFloat)scaledValue:(NSInteger)rawValue forAxis:(OEHIDEventAxis)axis controlCookie:(NSUInteger)cookie defaultCalibration:(OEAxisCalibration)fallback
{
    OEAxisCalibration cal = fallback;
    if (self.autoCalibrated) {
        cal = [self OE_updateAutoCalibrationWithScaledValue:rawValue axis:axis controlCookie:cookie defaultCalibration:fallback];
    } else {
        [self calibration:&cal forControlCookie:cookie];
    }
    return OEScaledValueWithCalibration(cal, rawValue);
}

- (CGFloat)applyDeadZoneToScaledValue:(CGFloat)scaledValue forAxis:(OEHIDEventAxis)axis controlCookie:(NSUInteger)cookie
{
    CGFloat deadZone = [self deadZoneForControlCookie:cookie];
    if(-deadZone <= scaledValue && scaledValue <= deadZone)
        scaledValue = 0.0;
    return scaledValue;
}

- (CGFloat)calibratedValue:(NSInteger)rawValue forAxis:(OEHIDEventAxis)axis controlCookie:(NSUInteger)cookie defaultCalibration:(OEAxisCalibration)fallback
{
    CGFloat scaled = [self scaledValue:rawValue forAxis:axis controlCookie:cookie defaultCalibration:fallback];
    return [self applyDeadZoneToScaledValue:scaled forAxis:axis controlCookie:cookie];
}

@end

@implementation OEDeviceHandlerPlaceholder {
    NSString *_uniqueIdentifier;
}

- (instancetype)initWithUniqueIdentifier:(NSString *)uniqueIdentifier
{
    if (!(self = [super initWithDeviceDescription:nil]))
        return nil;

    _uniqueIdentifier = [uniqueIdentifier copy];

    return self;
}

- (NSString *)uniqueIdentifier
{
    return _uniqueIdentifier;
}

- (BOOL)isPlaceholder
{
    return YES;
}

- (NSUInteger)hash
{
    return _uniqueIdentifier.hash;
}

- (BOOL)isEqual:(id)object
{
    if (self == object)
        return YES;

    if (![object isKindOfClass:[OEDeviceHandlerPlaceholder class]])
        return NO;

    return [_uniqueIdentifier isEqualToString:[object uniqueIdentifier]];
}

- (void)notifyOriginalDeviceDidBecomeAvailable
{
    [[NSNotificationCenter defaultCenter] postNotificationName:OEDeviceHandlerPlaceholderOriginalDeviceDidBecomeAvailableNotification object:self];
}

@end

NS_ASSUME_NONNULL_END
