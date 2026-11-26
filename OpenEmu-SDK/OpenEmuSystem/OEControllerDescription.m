/*
 Copyright (c) 2013, OpenEmu Team

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

#import "OEControllerDescription.h"
#import "OEControllerDescription_Internal.h"
#import "OEDeviceHandler.h"
#import "OEHIDDeviceHandler.h"
#import "OEHIDEvent.h"
#import "OEHIDEvent_Internal.h"
#import <IOKit/hid/IOHIDUsageTables.h>

NS_ASSUME_NONNULL_BEGIN

@interface OEControllerDescription ()
{
    NSString *_identifier;
    NSString *_name;

    NSMutableDictionary<NSString *, OEControlDescription *> *_controls;
    NSMutableDictionary<NSString *, OEControlValueDescription *> *_identifierToControlValue;
    NSMutableDictionary<NSNumber *, OEControlValueDescription *> *_valueIdentifierToControlValue;
}

- (instancetype)OE_initWithVendorID:(NSUInteger)vendorID productID:(NSUInteger)productID name:(NSString *)name __attribute__((objc_method_family(init)));
- (instancetype)OE_initWithIdentifier:(NSString *)identifier representation:(NSDictionary *)representation __attribute__((objc_method_family(init)));

@end

// Device representations stay in there for as long as no actual device of their type were plugged in.
static NSDictionary<NSString *, NSDictionary *> *_mappingRepresentations;
static NSArray<OEControllerDescription *> *_knownControllerDescriptions;

@implementation OEControllerDescription

+ (void)initialize
{
    if(self == [OEControllerDescription class])
    {
        NSURL *identifierURL = [[NSBundle mainBundle] URLForResource:@"Controller-Database" withExtension:@"plist"];
        if (identifierURL == nil)
        {
            // Fallback to framework bundled version
            identifierURL = [[NSBundle bundleForClass:OEControllerDescription.class] URLForResource:@"Controller-Database" withExtension:@"plist"];
        }
        NSDictionary *representations = [NSPropertyListSerialization propertyListWithData:[NSData dataWithContentsOfURL:identifierURL options:NSDataReadingMappedIfSafe error:NULL] options:0 format:NULL error:NULL];

        NSMutableDictionary<NSString *, NSDictionary *> *mappingReps = [NSMutableDictionary dictionaryWithCapacity:[representations count]];
        NSMutableArray<OEControllerDescription *> *knownControllerDescriptions = [NSMutableArray array];

        [representations enumerateKeysAndObjectsUsingBlock:^(NSString *identifier, NSDictionary *rep, BOOL *stop) {
            OEControllerDescription *description = [[OEControllerDescription alloc] OE_initWithIdentifier:identifier representation:rep];
            [knownControllerDescriptions addObject:description];

            mappingReps[identifier] = rep[@"OEControllerMappings"] ? : @{};
        }];

        _knownControllerDescriptions = [knownControllerDescriptions copy];
        _mappingRepresentations = [mappingReps copy];
    }
}

+ (OEControllerDescription *)OE_controllerDescriptionForVendorID:(NSUInteger)vendorID productID:(NSUInteger)productID product:(NSString *)product
{
    // Some devices have no HID Product string descriptor
    if(product == nil) product = @"Unknown USB Gamepad";

    for (OEControllerDescription *controllerDescription in _knownControllerDescriptions) {
        for (OEDeviceDescription *deviceDescription in [controllerDescription deviceDescriptions]) {
            if (deviceDescription.vendorID != vendorID || deviceDescription.productID != productID)
                continue;

            if (!deviceDescription.requiresNameMatch || [deviceDescription.product isEqualToString:product])
                return [controllerDescription OE_controllerDescription];
        }
    }

    return [[OEControllerDescription alloc] OE_initWithVendorID:vendorID productID:productID name:product];
}

+ (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)OE_representationForControllerDescription:(OEControllerDescription *)controllerDescription
{
    return _mappingRepresentations[controllerDescription.identifier];
}

- (instancetype)OE_initWithIdentifier:(NSString *)identifier representation:(NSDictionary *)representation
{
    if((self = [super init]))
    {
        _identifier = [identifier copy];
        _name = representation[@"OEControllerName"];
        _wantsCalibration = ![representation[@"OEDisableCalibration"] boolValue];
        _controls = [NSMutableDictionary dictionary];
        _identifierToControlValue = [NSMutableDictionary dictionary];
        _valueIdentifierToControlValue = [NSMutableDictionary dictionary];

        [self OE_setUpDevicesWithRepresentations:[representation objectForKey:@"OEControllerDevices"]];
    }

    return self;
}

- (instancetype)OE_initWithVendorID:(NSUInteger)vendorID productID:(NSUInteger)productID name:(NSString *)name
{
    if((self = [super init]))
    {
        _isGeneric = YES;
        _name = name;
        _wantsCalibration = YES;
        _controls = [NSMutableDictionary dictionary];
        _identifierToControlValue = [NSMutableDictionary dictionary];
        _valueIdentifierToControlValue = [NSMutableDictionary dictionary];

        OEDeviceDescription *desc = [[OEDeviceDescription alloc] OE_initWithRepresentation:@{
            @"OEControllerDeviceName"    : _name,
            @"OEControllerProductName"   : _name,
            @"OEControllerVendorID"      : @(vendorID),
            @"OEControllerProductID"     : @(productID),
        } controllerDescription:self];

        _identifier = [desc genericDeviceIdentifier];
        _deviceDescriptions = @[ desc ];
    }

    return self;
}

- (id)copyWithZone:(nullable NSZone *)zone
{
    return self;
}

- (instancetype)OE_controllerDescription
{
    OEControllerDescription *ret = [[[self class] alloc] init];
    ret->_isGeneric = _isGeneric;
    ret->_identifier = [_identifier copy];
    ret->_name = [_name copy];
    ret->_wantsCalibration = _wantsCalibration;
    ret->_controls = [NSMutableDictionary dictionary];
    ret->_identifierToControlValue = [NSMutableDictionary dictionary];
    ret->_valueIdentifierToControlValue = [NSMutableDictionary dictionary];

    NSMutableArray<OEDeviceDescription *> *deviceDescriptions = [NSMutableArray array];
    [_deviceDescriptions enumerateObjectsUsingBlock:^(OEDeviceDescription *obj, NSUInteger index, BOOL *stop) {
        [deviceDescriptions addObject:[obj OE_deviceDescriptionWithControllerDescription:ret]];
    }];
    ret->_deviceDescriptions = [deviceDescriptions copy];

    return ret;
}

- (OEDeviceDescription *)deviceDescriptionForVendorID:(NSUInteger)vendorID productID:(NSUInteger)productID cookie:(uint32_t)cookie
{
    for (OEDeviceDescription *deviceDescription in _deviceDescriptions) {
        if (deviceDescription.vendorID == vendorID && deviceDescription.productID == productID && (cookie == 0 || deviceDescription.cookie == cookie)) {
            return deviceDescription;
        }
    }

    NSAssert(NO, @"No product found for a device with VendorID %zu, ProductID: %zu, Cookie: %u, despite this description being generated from this device.", vendorID, productID, cookie);
    return nil;
}

- (OEDeviceDescription *)OE_addDeviceDescriptionWithVendorID:(NSUInteger)vendorID productID:(NSUInteger)productID product:(NSString *)product cookie:(uint32_t)cookie
{
    OEDeviceDescription *desc = [[OEDeviceDescription alloc] OE_initWithRepresentation:@{
        @"OEControllerDeviceName"    : product,
        @"OEControllerProductName"   : product,
        @"OEControllerVendorID"      : @(vendorID),
        @"OEControllerProductID"     : @(productID),
        @"OEControllerCookie"        : @(cookie),
    } controllerDescription:self];

    _deviceDescriptions = [_deviceDescriptions arrayByAddingObject:desc];

    return desc;
}

- (void)OE_setUpDevicesWithRepresentations:(NSArray *)representations
{
    NSMutableArray<OEDeviceDescription *> *deviceDescriptions = [NSMutableArray array];
    for(NSDictionary *rep in representations) {
        [deviceDescriptions addObject:[[OEDeviceDescription alloc] OE_initWithRepresentation:rep controllerDescription:self]];
    }

    _deviceDescriptions = [deviceDescriptions copy];
}

- (NSUInteger)numberOfControls
{
    return [_controls count];
}

- (NSArray<OEControlDescription *> *)controls
{
    return [_controls allValues];
}

- (nullable OEControlValueDescription *)controlValueDescriptionForEvent:(OEHIDEvent *)event;
{
    return _valueIdentifierToControlValue[@([event controlValueIdentifier])];
}

- (OEControlValueDescription *)controlValueDescriptionForIdentifier:(NSString *)controlIdentifier;
{
    return _identifierToControlValue[controlIdentifier];
}

- (nullable OEControlValueDescription *)controlValueDescriptionForRepresentation:(id)representation
{
    if ([representation isKindOfClass:[NSDictionary class]])
        return [self controlValueDescriptionForEvent:[OEHIDEvent eventWithDictionaryRepresentation:representation]];

    if ([representation isKindOfClass:[NSString class]])
        return [self controlValueDescriptionForIdentifier:representation];

    return nil;
}

- (OEControlDescription *)addControlWithIdentifier:(nullable NSString *)identifier name:(nullable NSString *)name event:(OEHIDEvent *)event;
{
    OEControlDescription *desc = [[OEControlDescription alloc] OE_initWithIdentifier:identifier name:name genericEvent:event controllerDescription:self];
    NSAssert(_controls[[desc identifier]] == nil, @"There is already a control %@ with the identifier %@", _controls[[desc identifier]], identifier);

    _controls[[desc identifier]] = desc;

    if(_isGeneric) [desc setUpControlValuesUsingRepresentations:nil];

    return desc;
}

- (OEControlDescription *)addControlWithIdentifier:(NSString *)identifier name:(NSString *)name event:(OEHIDEvent *)event valueRepresentations:(NSDictionary *)valueRepresentations;
{
    OEControlDescription *desc = [self addControlWithIdentifier:identifier name:name event:event];
    [desc setUpControlValuesUsingRepresentations:valueRepresentations];

    return desc;
}


- (void)OE_controlDescription:(OEControlDescription *)control didAddControlValue:(OEControlValueDescription *)valueDesc;
{
    _identifierToControlValue[[valueDesc identifier]] = valueDesc;
    _valueIdentifierToControlValue[[valueDesc valueIdentifier]] = valueDesc;
}

@end

OEHIDEventType OEHIDEventTypeFromNSString(NSString *string)
{
    static NSDictionary *namesToValue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        namesToValue = @{
            @"Axis"      : @(OEHIDEventTypeAxis),
            @"Button"    : @(OEHIDEventTypeButton),
            @"HatSwitch" : @(OEHIDEventTypeHatSwitch),
            @"Trigger"   : @(OEHIDEventTypeTrigger),
        };
    });

    return [[namesToValue objectForKey:string] integerValue];
}

NSUInteger OEUsageFromUsageStringWithType(NSString *usageString, OEHIDEventType type)
{
    switch(type)
    {
        case OEHIDEventTypeButton :
            return [usageString integerValue];
        case OEHIDEventTypeAxis :
        case OEHIDEventTypeTrigger :
            return OEHIDEventAxisFromNSString(usageString);
        case OEHIDEventTypeHatSwitch :
            return kHIDUsage_GD_Hatswitch;
        default :
            break;
    }

    return 0;
}

NS_ASSUME_NONNULL_END
