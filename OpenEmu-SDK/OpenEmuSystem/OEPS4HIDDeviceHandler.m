/*
 Copyright (c) 2018, OpenEmu Team

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

#import "OEPS4HIDDeviceHandler.h"

NS_ASSUME_NONNULL_BEGIN

static const NSUInteger OEPS4VendorID = 0x054C;

static const uint32_t OEPS4BluetoothInputReportID = 0x11;
static const uint32_t OEPS4BluetoothInputUsagePage = 0xFF00;
static const uint32_t OEPS4BluetoothInputUsage = 0x20;

static const NSUInteger OEPS4StandardReportID = 0x01;

/* Byte offsets inside the Bluetooth report 0x11 payload. The payload arrives
 * without the report ID byte, so the layout starts with the two header bytes. */
static const size_t OEPS4BluetoothLeftStickXOffset   = 2;
static const size_t OEPS4BluetoothLeftStickYOffset   = 3;
static const size_t OEPS4BluetoothRightStickXOffset  = 4;
static const size_t OEPS4BluetoothRightStickYOffset  = 5;
static const size_t OEPS4BluetoothButtonsOffset      = 6;
static const size_t OEPS4BluetoothButtonsHighOffset  = 7;
static const size_t OEPS4BluetoothSystemOffset       = 8;
static const size_t OEPS4BluetoothLeftTriggerOffset  = 9;
static const size_t OEPS4BluetoothRightTriggerOffset = 10;

static const size_t OEPS4BluetoothMinimumLength = OEPS4BluetoothRightTriggerOffset + 1;

@interface OEDeviceHandler ()
@property(readwrite) NSUInteger deviceNumber;
@end

@interface OEPS4HIDDeviceHandler ()
@end

@implementation OEPS4HIDDeviceHandler {
    NSArray *_deviceElements;
    NSDictionary<NSNumber *, NSValue *> *_controlElements;
    uint8_t _lastBluetoothState[16];
}

+ (BOOL)canHandleDevice:(IOHIDDeviceRef)device
{
    /* macOS 27 names the controller "DUALSHOCK 4 Wireless Controller" over
     * Bluetooth and "Wireless Controller" over USB. Match the identifiers
     * too, so the name never decides whether this handler is used. */
    NSNumber *vendorID  = (__bridge NSNumber *)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDVendorIDKey));
    NSNumber *productID = (__bridge NSNumber *)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductIDKey));
    NSUInteger product  = productID.unsignedIntegerValue;

    if(vendorID.unsignedIntegerValue == OEPS4VendorID && (product == 0x05C4 || product == 0x09CC))
        return YES;

    NSString *deviceName = (__bridge id)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
    return [deviceName hasPrefix:@"Wireless Controller"];
}

- (NSArray<NSDictionary<NSString *, id> *> *)inputValueMatchingProperties
{
    NSArray *properties = [super inputValueMatchingProperties];

    if(![self OE_isBluetoothDevice])
        return properties;

    /* Over Bluetooth, macOS 27 delivers report 0x11 as a vendor-defined value
     * instead of separate control elements. Whitelist it to decode it. */
    return [properties arrayByAddingObject:@{
        @kIOHIDElementUsagePageKey : @(OEPS4BluetoothInputUsagePage),
        @kIOHIDElementUsageKey     : @(OEPS4BluetoothInputUsage),
    }];
}

- (void)dispatchEventWithHIDValue:(IOHIDValueRef)aValue
{
    IOHIDElementRef element = IOHIDValueGetElement(aValue);

    if(IOHIDElementGetUsagePage(element) == OEPS4BluetoothInputUsagePage &&
       IOHIDElementGetUsage(element) == OEPS4BluetoothInputUsage &&
       IOHIDElementGetReportID(element) == OEPS4BluetoothInputReportID)
    {
        [self OE_dispatchBluetoothInputReport:aValue];
        return;
    }

    [super dispatchEventWithHIDValue:aValue];
}

- (BOOL)OE_isBluetoothDevice
{
    CFTypeRef transport = IOHIDDeviceGetProperty(self.device, CFSTR(kIOHIDTransportKey));
    if(transport == NULL)
        return NO;

    return CFStringCompare(transport, CFSTR(kIOHIDTransportBluetoothValue), 0) == kCFCompareEqualTo;
}

- (void)OE_dispatchBluetoothInputReport:(IOHIDValueRef)aValue
{
    const uint8_t *report = IOHIDValueGetBytePtr(aValue);
    CFIndex length = IOHIDValueGetLength(aValue);

    if(report == NULL || length < (CFIndex)OEPS4BluetoothMinimumLength)
        return;

    /* The left stick is the first control, so the compared block covers the
     * sticks, the buttons and the triggers, and no other report byte. */
    const uint8_t *state = report + OEPS4BluetoothLeftStickXOffset;
    size_t stateLength = OEPS4BluetoothMinimumLength - OEPS4BluetoothLeftStickXOffset;
    if(memcmp(state, _lastBluetoothState, stateLength) == 0)
        return;

    memcpy(_lastBluetoothState, state, stateLength);

    uint64_t timestamp = IOHIDValueGetTimeStamp(aValue);
    uint8_t buttons    = report[OEPS4BluetoothButtonsOffset];
    uint8_t buttonsHigh = report[OEPS4BluetoothButtonsHighOffset];
    uint8_t system     = report[OEPS4BluetoothSystemOffset];

    [self OE_dispatchValue:report[OEPS4BluetoothLeftStickXOffset]
              usagePage:kHIDPage_GenericDesktop
                  usage:kHIDUsage_GD_X
              timestamp:timestamp];
    [self OE_dispatchValue:report[OEPS4BluetoothLeftStickYOffset]
              usagePage:kHIDPage_GenericDesktop
                  usage:kHIDUsage_GD_Y
              timestamp:timestamp];
    [self OE_dispatchValue:report[OEPS4BluetoothRightStickXOffset]
              usagePage:kHIDPage_GenericDesktop
                  usage:kHIDUsage_GD_Z
              timestamp:timestamp];
    [self OE_dispatchValue:report[OEPS4BluetoothRightStickYOffset]
              usagePage:kHIDPage_GenericDesktop
                  usage:kHIDUsage_GD_Rz
              timestamp:timestamp];
    [self OE_dispatchValue:report[OEPS4BluetoothLeftTriggerOffset]
              usagePage:kHIDPage_GenericDesktop
                  usage:kHIDUsage_GD_Rx
              timestamp:timestamp];
    [self OE_dispatchValue:report[OEPS4BluetoothRightTriggerOffset]
              usagePage:kHIDPage_GenericDesktop
                  usage:kHIDUsage_GD_Ry
              timestamp:timestamp];

    [self OE_dispatchValue:(buttons & 0x0F)
              usagePage:kHIDPage_GenericDesktop
                  usage:kHIDUsage_GD_Hatswitch
              timestamp:timestamp];

    for(NSUInteger usage = 1; usage <= 14; usage++)
    {
        BOOL pressed = [self OE_isButtonPressedWithUsage:usage buttons:buttons buttonsHigh:buttonsHigh system:system];
        [self OE_dispatchValue:pressed
                  usagePage:kHIDPage_Button
                      usage:(uint32_t)usage
                  timestamp:timestamp];
    }
}

- (BOOL)OE_isButtonPressedWithUsage:(NSUInteger)usage buttons:(uint8_t)buttons buttonsHigh:(uint8_t)buttonsHigh system:(uint8_t)system
{
    switch(usage)
    {
        case 1  : return (buttons >> 4) & 1; // Square
        case 2  : return (buttons >> 5) & 1; // Cross
        case 3  : return (buttons >> 6) & 1; // Circle
        case 4  : return (buttons >> 7) & 1; // Triangle
        case 5  : return buttonsHigh & 1;
        case 6  : return (buttonsHigh >> 1) & 1;
        case 7  : return (buttonsHigh >> 2) & 1;
        case 8  : return (buttonsHigh >> 3) & 1;
        case 9  : return (buttonsHigh >> 4) & 1;
        case 10 : return (buttonsHigh >> 5) & 1;
        case 11 : return (buttonsHigh >> 6) & 1;
        case 12 : return (buttonsHigh >> 7) & 1;
        case 13 : return system & 1;
        case 14 : return (system >> 1) & 1;
        default : return NO;
    }
}

- (void)OE_dispatchValue:(CFIndex)value usagePage:(uint32_t)usagePage usage:(uint32_t)usage timestamp:(uint64_t)timestamp
{
    IOHIDElementRef element = [self OE_elementForUsagePage:usagePage usage:usage];
    if(element == NULL)
        return;

    IOHIDValueRef syntheticValue = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, timestamp, value);
    if(syntheticValue == NULL)
        return;

    [super dispatchEventWithHIDValue:syntheticValue];
    CFRelease(syntheticValue);
}

- (IOHIDElementRef)OE_elementForUsagePage:(uint32_t)usagePage usage:(uint32_t)usage
{
    if(_controlElements == nil)
        [self OE_setUpControlElements];

    NSNumber *key = @((((uint64_t)usagePage) << 16) | usage);
    return [_controlElements[key] pointerValue];
}

- (void)OE_setUpControlElements
{
    NSMutableDictionary *elements = [NSMutableDictionary dictionary];

    _deviceElements = (__bridge_transfer NSArray *)IOHIDDeviceCopyMatchingElements(self.device, NULL, 0);

    for(id value in _deviceElements)
    {
        IOHIDElementRef element = (__bridge IOHIDElementRef)value;
        IOHIDElementType type = IOHIDElementGetType(element);

        if(IOHIDElementGetReportID(element) != OEPS4StandardReportID)
            continue;

        if(type != kIOHIDElementTypeInput_Misc && type != kIOHIDElementTypeInput_Button)
            continue;

        NSNumber *key = @((((uint64_t)IOHIDElementGetUsagePage(element)) << 16) | IOHIDElementGetUsage(element));
        if(elements[key] == nil)
            elements[key] = [NSValue valueWithPointer:element];
    }

    _controlElements = [elements copy];
}

- (BOOL)connect
{
    // Unfortunately, HID stops responding after sending an output report.
    // https://stackoverflow.com/questions/30793753/iokit-not-receiving-hid-interrupt-reports-from-dualshock-4-controller-connected
    // https://stackoverflow.com/questions/43852993/macos-hid-usb-control-transfer-hid-api-libusb-macos
#if 0
    CFTypeRef transportType = IOHIDDeviceGetProperty([self device], CFSTR(kIOHIDTransportKey));
    BOOL isBluetooth = CFStringCompare(transportType, CFSTR(kIOHIDTransportBluetoothValue), 0) == kCFCompareEqualTo;

    if (isBluetooth)
    {
        // Turn off lightbar
        // https://github.com/torvalds/linux/blob/a3818841bd5e9b4a7e0e732c19cf3a632fcb525e/drivers/hid/hid-sony.c#L2179
        // http://www.psdevwiki.com/ps4/DS4-BT#0x11_2
        uint8_t data[79];
        memset(data, 0, sizeof(data));
        data[0]  = 0xA2; // Bluetooth header, transaction type DATA (0x0a), report type OUTPUT (0x02).
        data[1]  = 0x11; // protocol code/ID or encoded packet size?
        data[2]  = 0xC0 | 4; // Poll interval 4ms
        data[4]  = 0x07; // Enable LEDs, flash, rumble
        data[7]  = 0x00; // Rumble (right / weak)
        data[8]  = 0x00; // Rumble (left / strong)
        data[9]  = 0x00; // LED Red
        data[10] = 0x00; // LED Green
        data[11] = 0x00; // LED Blue
        data[12] = 0x00; // Duration LED flash bright
        data[13] = 0x00; // Duration LED flash dark

        // Calculate little-endian CRC32, then add the 4 bytes to end of data
        uint32_t crc = rc_crc32(0, data, sizeof(data) - 4);
        data[75] = crc & 0xff;
        data[76] = (crc >> 8) & 0xff;
        data[77] = (crc >> 16) & 0xff;
        data[78] = crc >> 24;

        IOHIDDeviceSetReport([self device],
                             kIOHIDReportTypeOutput,
                             data[0], // Matters?
                             data + 1,
                             sizeof(data) - 1);
    }
#endif
    return YES;
}

- (void)disconnect
{
    [super disconnect];
}

// https://rosettacode.org/wiki/CRC-32#C
// Alternative: use zlib
uint32_t rc_crc32(uint32_t crc, unsigned char const *buf, size_t len)
{
    static uint32_t table[256];
    static int have_table = 0;
    uint32_t rem;
    uint8_t octet;
    int i, j;
    unsigned char const *p, *q;

    /* This check is not thread safe; there is no mutex. */
    if (have_table == 0) {
        /* Calculate CRC table. */
        for (i = 0; i < 256; i++) {
            rem = i;  /* remainder from polynomial division */
            for (j = 0; j < 8; j++) {
                if (rem & 1) {
                    rem >>= 1;
                    rem ^= 0xedb88320;
                } else
                    rem >>= 1;
            }
            table[i] = rem;
        }
        have_table = 1;
    }

    crc = ~crc;
    q = buf + len;
    for (p = buf; p < q; p++) {
        octet = *p;  /* Cast to unsigned octet. */
        crc = (crc >> 8) ^ table[(crc & 0xff) ^ octet];
    }
    return ~crc;
}

@end

NS_ASSUME_NONNULL_END
