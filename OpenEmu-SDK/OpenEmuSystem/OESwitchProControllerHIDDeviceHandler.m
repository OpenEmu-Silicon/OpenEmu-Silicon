// Copyright (c) 2019, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

/*
 * Most of this code has been written based on the reverse-engineered documentation
 * which can be found at https://github.com/dekuNukem/Nintendo_Switch_Reverse_Engineering
 *
 * As an additional reference, another implementation of a driver for this controller
 * can be found at https://github.com/Davidobot/BetterJoyForCemu
 */

#import "OEDeviceDescription.h"
#import "OEDeviceManager_Internal.h"
#import "OEControllerDescription_Internal.h"
#import "OESwitchProControllerHIDDeviceHandler.h"


#pragma mark - Device Handler Parameters


#define MAX_INPUT_REPORT_SIZE (256)
#define MAX_RESPONSE_ATTEMPTS (10)
#define MAX_RESPONSE_WAIT_SECONDS (10.0)
#define PING_INTERVAL_SECONDS (60.0)

#define NINTENDO_VENDOR_ID (0x57E)
#define PRO_CONTROLLER_PRODUCT_ID (0x2009)
#define N64_CONTROLLER_PRODUCT_ID (0x2019)

//#define LOG_COMMUNICATION


#pragma mark - Input / Output Report Structures


typedef NS_ENUM(uint8_t, OEHACInputReportID) {
    OEHACInputReportIDSubcommandReply = 0x21,
    OEHACInputReportIDNFCIRFirmwareUpdateReply = 0x23,
    OEHACInputReportIDFullReport = 0x30,
    OEHACInputReportIDNFCIRReport = 0x31,
    OEHACInputReportIDSimpleHIDReport = 0x3F,
    OEHACInputReportIDUSBSubcommandReply = 0x81
};

typedef NS_ENUM(uint8_t, OEHACOuputReportID) {
    OEHACOutputReportIDRumbleAndSubcommand = 0x01,
    OEHACOutputReportIDNFCIRFirmwareUpdatePacket = 0x03,
    OEHACOutputReportIDRumble = 0x10,
    OEHACOutputReportIDNFCIR = 0x11,
    OEHACOutputReportIDUSBSubcommand = 0x80
};


typedef NS_ENUM(uint8_t, OEHACUSBSubcommandID) {
    OEHACUSBSubcommandIDGetStatus = 0x01,
    OEHACUSBSubcommandIDRequestHandshake,
    OEHACUSBSubcommandIDRequestHighDataRate,
    OEHACUSBSubcommandIDDisableUSBHIDTimeout,
    OEHACUSBSubcommandIDEnableUSBHIDTimeout,
    OEHACUSBSubcommandIDReset,
};

typedef struct __attribute__((packed)) {
    OEHACOuputReportID reportID;
    OEHACUSBSubcommandID subcommand;
} OEHACUSBSubcommandOutputReport;

typedef struct __attribute__((packed)) {
    OEHACInputReportID reportID;
    OEHACUSBSubcommandID subcommand;
    uint8_t data[0];
} OEHACUSBAcknowledgmentOutputReport;


typedef NS_ENUM(uint8_t, OEHACSubcommandID) {
    OEHACSubcmdNoop = 0,
    OEHACSubcmdManualPairing,
    OEHACSubcmdRequestDeviceInfo,
    OEHACSubcmdSetInputReportMode,
    OEHACSubcmdRequestTriggerButtonHeldTime,
    OEHACSubcmdRequestPageListState,
    OEHACSubcmdSetPowerState,
    OEHACSubcmdResetPairing,
    OEHACSubcmdSetFactoryLowPowerState,
    OEHACSubcmdRequestSPIFlashRead = 0x10,
    OEHACSubcmdRequestSPIFlashWrite,
    OEHACSubcmdRequestSPIFlashErase,
    OEHACSubcmdResetNFCIR = 0x20,
    OEHACSubcmdSetNFCIRConfig,
    OEHACSubcmdSetNFCIRState,
    OEHACSubcmdSetPlayerLights = 0x30,
    OEHACSubcmdRequestPlayerLights,
    OEHACSubcmdSetHomeLight = 0x38
};


typedef NS_ENUM(uint8_t, OEHACPowerState) {
    OEHACPowerStateSleep = 0,
    OEHACPowerStateResetAndReconnect = 1,
    OEHACPowerStateResetToPairMode = 2,
    OEHACPowerStateResetToHOMEMode = 4
};


typedef uint8_t OEHAC12BitPackedPair[3];

typedef struct {
    uint16_t x;
    uint16_t y;
} OEHAC16BitUnsignedPair;


typedef struct __attribute__((packed)) {
    OEHACOuputReportID reportID;
    uint8_t seqNumber;
    uint8_t rumbleData[8];
    OEHACSubcommandID subcmdID;
    uint8_t subcmdParam[0x35];
} OEHACRumbleAndSubcommandOutputReport;


typedef NS_OPTIONS(uint8_t, OEHACButtonState0) {
    OEHACButtonState0Y  = 0b00000001,
    OEHACButtonState0X  = 0b00000010,
    OEHACButtonState0B  = 0b00000100,
    OEHACButtonState0A  = 0b00001000,
    OEHACButtonState0SR = 0b00010000,
    OEHACButtonState0SL = 0b00100000,
    OEHACButtonState0R  = 0b01000000,
    OEHACButtonState0ZR = 0b10000000
};

typedef NS_OPTIONS(uint8_t, OEHACButtonState1) {
    OEHACButtonState1Minus      = 0b00000001,
    OEHACButtonState1Plus       = 0b00000010,
    OEHACButtonState1RStick     = 0b00000100,
    OEHACButtonState1LStick     = 0b00001000,
    OEHACButtonState1Home       = 0b00010000,
    OEHACButtonState1Capture    = 0b00100000,
    OEHACButtonState1ChargeGrip = 0b10000000
};

typedef NS_OPTIONS(uint8_t, OEHACButtonState2) {
    OEHACButtonState2Down  = 0b00000001,
    OEHACButtonState2Up    = 0b00000010,
    OEHACButtonState2Right = 0b00000100,
    OEHACButtonState2Left  = 0b00001000,
    OEHACButtonState2SR    = 0b00010000,
    OEHACButtonState2SL    = 0b00100000,
    OEHACButtonState2L     = 0b01000000,
    OEHACButtonState2ZL    = 0b10000000
};

typedef struct __attribute__((packed)) {
    OEHACInputReportID reportID;
    uint8_t seqNumber;
    uint8_t chargingStatus;
    OEHACButtonState0 buttons0;
    OEHACButtonState1 buttons1;
    OEHACButtonState2 buttons2;
    OEHAC12BitPackedPair leftStick;
    OEHAC12BitPackedPair rightStick;
    uint8_t rumbleStatus;
} OEHACStandardHIDInputReport;


typedef struct __attribute__((packed)) {
    OEHACStandardHIDInputReport parent;
    uint8_t ackStatus;
    OEHACSubcommandID repliedSubcmdId;
    uint8_t reply[34];
} OEHACAcknowledgmentHIDInputReport;


typedef struct __attribute__((packed)) {
    uint8_t fwVersion[2];
    uint8_t deviceType;
    uint8_t unk0;
    uint8_t btMacAddress[6];
} OEHACDeviceStatusSubcommandReply;


typedef struct __attribute__((packed)) {
    OEHAC12BitPackedPair maxDelta;
    OEHAC12BitPackedPair center;
    OEHAC12BitPackedPair minDelta;
} OEHACStickCalibrationData;

typedef struct __attribute__((packed)) {
    OEHAC12BitPackedPair left_maxDelta;
    OEHAC12BitPackedPair left_zero;
    OEHAC12BitPackedPair left_minDelta;
    // the following 3 lines of code are correct
    // anything suspicious is 100% nintendo's fault
    OEHAC12BitPackedPair right_zero;
    OEHAC12BitPackedPair right_minDelta;
    OEHAC12BitPackedPair right_maxDelta;
} OEHACFactoryStickCalibrationData;

typedef struct __attribute__((packed)) {
    uint16_t leftDataAvailable;
    OEHACStickCalibrationData leftStick;
    uint16_t rightDataAvailable;
    OEHACStickCalibrationData rightStick;
} OEHACUserStickCalibrationData;

enum {
    OEHACFactoryStickCalibrationDataAddress = 0x603D,
    OEHACUserStickCalibrationDataAddress = 0x8010,
    OEHACUserStickDataAvailableMagic = 0xA1B2
};


static void OEHACProControllerHIDReportCallback(
    void * _Nullable        context,
    IOReturn                result,
    void * _Nullable        sender,
    IOHIDReportType         type,
    uint32_t                reportID,
    uint8_t *               report,
    CFIndex                 reportLength);

static OEHAC16BitUnsignedPair OEHACUnpackPair(const OEHAC12BitPackedPair packed)
{
    OEHAC16BitUnsignedPair res;
    res.x = packed[0] | ((packed[1] & 0x0F) << 8);
    res.y = ((packed[1] & 0xF0) >> 4) | (packed[2] << 4);
    return res;
}


typedef struct {
    NSInteger min;
    NSInteger zero;
    NSInteger max;
} OEHACProControllerAxisCalibration;

typedef struct {
    OEHACProControllerAxisCalibration x;
    OEHACProControllerAxisCalibration y;
} OEHACProControllerStickCalibration;

static OEHACProControllerStickCalibration OEHACConvertCalibration(
    const OEHAC12BitPackedPair packed_maxdelta,
    const OEHAC12BitPackedPair packed_zero,
    const OEHAC12BitPackedPair packed_mindelta)
{
    OEHAC16BitUnsignedPair maxdelta, zero, mindelta;
    OEHACProControllerStickCalibration res;
    
    maxdelta = OEHACUnpackPair(packed_maxdelta);
    zero = OEHACUnpackPair(packed_zero);
    mindelta = OEHACUnpackPair(packed_mindelta);
    
    /* The calibration data is specified in the reference system used by
     * Nintendo's proprietary button status reports. Nintendo's reference
     * system flips the Y axis with respect to the HID specification. */
    res.x.max = (zero.x + maxdelta.x) << 4;
    res.x.zero = zero.x << 4;
    res.x.min = (zero.x - mindelta.x) << 4;
    res.y.max = 0x10000 - (NSInteger)((zero.y - mindelta.y) << 4);
    res.y.zero = 0x10000 - (NSInteger)(zero.y << 4);
    res.y.min = 0x10000 - (NSInteger)((zero.y + maxdelta.y) << 4);
    
    return res;
}

static CGFloat OEHACScaleValueWithCalibration(
    const OEHACProControllerAxisCalibration *selectedCalibration,
    NSInteger rawValue)
{
    CGFloat res = rawValue - selectedCalibration->zero;
    if (res < 0.0) {
        res /= (CGFloat)(selectedCalibration->zero - selectedCalibration->min);
    } else {
        res /= (CGFloat)(selectedCalibration->max - selectedCalibration->zero);
    }
    
    /* the factory calibration is a bit generous at the edges; compensate for that */
    res /= 0.90;
    
    return MAX(-1, MIN(res, 1));
}


#pragma mark -


@interface OESwitchProControllerHIDDeviceParser ()

+ (OESwitchProControllerHIDDeviceParser *)sharedInstance;
+ (NSUInteger)_cookieFromUsage:(NSUInteger)usage;

- (void)registerDeviceHandler:(OESwitchProControllerHIDDeviceHandler *)dh;

@end


#pragma mark - Device Handler


@implementation OESwitchProControllerHIDDeviceHandler
{
    NSThread *_thread;
    NSTimer *_pingTimer;
    
    uint8_t _reportBuffer[MAX_INPUT_REPORT_SIZE];
    uint8_t _packetCounter;
    
    NSCondition *_responseAvailable;
    NSData *_currentResponse;
    
    OEHACProControllerStickCalibration _leftStickCalibration;
    OEHACProControllerStickCalibration _rightStickCalibration;

    /* The Nintendo Switch Online N64 controller speaks the same protocol as
     * the Pro Controller, with the same button bits, but has no right stick. */
    BOOL _isN64Controller;
}


@synthesize eventRunLoop = _eventRunLoop;


+ (BOOL)canHandleDevice:(IOHIDDeviceRef)aDevice
{
    NSString *deviceName = (__bridge id)IOHIDDeviceGetProperty(aDevice, CFSTR(kIOHIDProductKey));
    NSNumber *vid = (__bridge id)IOHIDDeviceGetProperty(aDevice, CFSTR(kIOHIDVendorIDKey));
    NSNumber *pid = (__bridge id)IOHIDDeviceGetProperty(aDevice, CFSTR(kIOHIDProductIDKey));

    if ([vid integerValue] != NINTENDO_VENDOR_ID)
        return NO;

    if ([deviceName isEqualToString:@"Pro Controller"] && [pid integerValue] == PRO_CONTROLLER_PRODUCT_ID)
        return YES;

    /* The N64 controller needs the same start-up handshake as the Pro Controller,
     * otherwise it never sends usable input. Match on the ID only, since the
     * name it reports differs between Bluetooth and USB. */
    if ([pid integerValue] == N64_CONTROLLER_PRODUCT_ID)
        return YES;

    return NO;
}


+ (OEHIDDeviceParser *)deviceParser
{
    return [OESwitchProControllerHIDDeviceParser sharedInstance];
}


- (instancetype)initWithIOHIDDevice:(IOHIDDeviceRef)aDevice deviceDescription:(nullable OEDeviceDescription *)deviceDescription
{
    self = [super initWithIOHIDDevice:aDevice deviceDescription:deviceDescription];

    NSNumber *pid = (__bridge id)IOHIDDeviceGetProperty(aDevice, CFSTR(kIOHIDProductIDKey));
    _isN64Controller = ([pid integerValue] == N64_CONTROLLER_PRODUCT_ID);

    /* plausible default calibration
     * if everything goes according to plan, it will be rewritten by values
     * read from the controller's internal flash memory at connection time */
    _leftStickCalibration = _rightStickCalibration =
        (OEHACProControllerStickCalibration){
            .x = {.min = 8192, .zero = 32768, .max = 57344},
            .y = {.min = 8192, .zero = 32768, .max = 57344},
        };
    
    return self;
}


- (void)setUpCallbacks
{
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    _thread = [[NSThread alloc] initWithBlock:^{
        self->_responseAvailable = [[NSCondition alloc] init];
        self->_eventRunLoop = (CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());
        
        IOHIDDeviceRegisterInputReportCallback(self.device, self->_reportBuffer, MAX_INPUT_REPORT_SIZE, OEHACProControllerHIDReportCallback, (__bridge void *)self);
        [super setUpCallbacks];
        
        dispatch_semaphore_signal(done);
        CFRunLoopRun();
    }];
    [_thread setQualityOfService:NSQualityOfServiceUserInteractive];
    [_thread setName:@"org.openemu.OpenEmuSystem.switchProControllerThread"];
    [_thread start];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
}


- (BOOL)connect
{
    NSString *transport = IOHIDDeviceGetProperty([self device], CFSTR(kIOHIDTransportKey));
    if ([transport isEqualToString:@kIOHIDTransportUSBValue]) {
        _isUSB = YES;
        [self _enableUSBmode];
    }
    
    NSData *info = [self _sendSubcommand:OEHACSubcmdRequestDeviceInfo withData:NULL length:0];
    if (info && info.length >= sizeof(OEHACAcknowledgmentHIDInputReport)) {
        const OEHACAcknowledgmentHIDInputReport *ack = info.bytes;
        const OEHACDeviceStatusSubcommandReply *status = (const OEHACDeviceStatusSubcommandReply *)&(ack->reply);
        NSLog(@"[dev %p] Firmware Version: %02x.%02x", self, status->fwVersion[0], status->fwVersion[1]);
        _internalSerialNumber = [NSData dataWithBytes:status->btMacAddress length:6];
    }
    
    [[OESwitchProControllerHIDDeviceParser sharedInstance] registerDeviceHandler:self];
    
    [self _setReportMode:OEHACInputReportIDFullReport];
    [self _setPlayerLights:0x0F];
    [self _requestCalibrationData];
    
    /* In BetterJoyForCemu there is a comment that says the controller wants to be
     * periodically pinged to keep its connection alive. Even though I've never seen
     * a spontaneous disconnection, it's better to be safe than sorry */
    _pingTimer = [NSTimer timerWithTimeInterval:PING_INTERVAL_SECONDS repeats:YES block:^(NSTimer * _Nonnull timer) {
        [self _sendOneWaySubcommand:OEHACSubcmdNoop withData:NULL length:0];
    }];
    [_pingTimer setTolerance:PING_INTERVAL_SECONDS * 0.1];
    [[NSRunLoop mainRunLoop] addTimer:_pingTimer forMode:NSDefaultRunLoopMode];
    
    return YES;
}


- (void)disconnect
{
    [super disconnect];
    
    [_pingTimer invalidate];
    
    /* we don't want to disconnect the controller every time the helper
     * app terminates, just when OpenEmu closes */
    if ([[[NSBundle mainBundle] bundleIdentifier] isEqual:@"org.openemu.OpenEmu"]) {
        [self _setPowerState:OEHACPowerStateSleep];
    }
    
    CFRunLoopStop(_eventRunLoop);
}


- (void)dealloc
{
    if (_eventRunLoop)
        CFRelease(_eventRunLoop);
}


#pragma mark - Calibration


- (void)_requestCalibrationData
{
    NSData *fact = [self _requestSPIFlashReadAtAddress:OEHACFactoryStickCalibrationDataAddress length:sizeof(OEHACFactoryStickCalibrationData)];
    if (!fact) {
        NSLog(@"[dev %p] cannot read stick calibration data from SPI flash!", self);
        return;
    }
    const OEHACFactoryStickCalibrationData *calibData = fact.bytes;
    
    self->_leftStickCalibration = OEHACConvertCalibration(calibData->left_maxDelta, calibData->left_zero, calibData->left_minDelta);
    self->_rightStickCalibration = OEHACConvertCalibration(calibData->right_maxDelta, calibData->right_zero, calibData->right_minDelta);
    
    NSLog(@"Loaded calibration successfully for %@ %@", _isN64Controller ? @"Switch N64 Controller" : @"Switch Pro Controller", self);
    NSLog(@"Left stick (x, y): [+] %d, %d; [0] %d %d; [-] %d %d",
        (int)self->_leftStickCalibration.x.max,
        (int)self->_leftStickCalibration.y.max,
        (int)self->_leftStickCalibration.x.zero,
        (int)self->_leftStickCalibration.y.zero,
        (int)self->_leftStickCalibration.x.min,
        (int)self->_leftStickCalibration.y.min);
    NSLog(@"Right stick (x, y): [+] %d, %d; [0] %d %d; [-] %d %d",
        (int)self->_rightStickCalibration.x.max,
        (int)self->_rightStickCalibration.y.max,
        (int)self->_rightStickCalibration.x.zero,
        (int)self->_rightStickCalibration.y.zero,
        (int)self->_rightStickCalibration.x.min,
        (int)self->_rightStickCalibration.y.min);
}


#pragma mark - Event Dispatching


- (void)dispatchEventWithHIDValue:(IOHIDValueRef)aValue
{
    /* Ignore the standard HID reports; over BlueTooth they would be usable,
     * but they're not via USB. Instead we parse Nintendo's proprietary input reports
     * manually instead. */
    return;
}


- (void)_dispatchEventsWithStandardInputReport:(OEHACStandardHIDInputReport *)report
{
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSInteger cookie;
    
    /* Buttons */
    const uint8_t button0Map[] = {
        OEHACButtonState0Y,  3,
        OEHACButtonState0X,  4,
        OEHACButtonState0B,  1,
        OEHACButtonState0A,  2,
        OEHACButtonState0R,  6,
        OEHACButtonState0ZR, 8,
        0};
    const uint8_t button1Map[] = {
        OEHACButtonState1Minus,    9,
        OEHACButtonState1Plus,    10,
        OEHACButtonState1RStick,  12,
        OEHACButtonState1LStick,  11,
        OEHACButtonState1Home,    13,
        OEHACButtonState1Capture, 14,
        0};
    const uint8_t button2Map[] = {
        OEHACButtonState2L,  5,
        OEHACButtonState2ZL, 7,
        0};
    [self _dispatchButtonEventsWithButtonMask:report->buttons0 buttonMap:button0Map timestamp:now];
    [self _dispatchButtonEventsWithButtonMask:report->buttons1 buttonMap:button1Map timestamp:now];
    [self _dispatchButtonEventsWithButtonMask:report->buttons2 buttonMap:button2Map timestamp:now];
    
    /* D-Pad */
    const OEHIDEventHatDirection buttonToHat[] = {
        /* ..ud                     ..uD                             ..Ud                             ..UD                                */
        OEHIDEventHatDirectionNull, OEHIDEventHatDirectionSouth,     OEHIDEventHatDirectionNorth,     OEHIDEventHatDirectionNull, /* lr.. */
        OEHIDEventHatDirectionEast, OEHIDEventHatDirectionSouthEast, OEHIDEventHatDirectionNorthEast, OEHIDEventHatDirectionNull, /* lR.. */
        OEHIDEventHatDirectionWest, OEHIDEventHatDirectionSouthWest, OEHIDEventHatDirectionNorthWest, OEHIDEventHatDirectionNull, /* Lr.. */
        OEHIDEventHatDirectionNull, OEHIDEventHatDirectionNull,      OEHIDEventHatDirectionNull,      OEHIDEventHatDirectionNull};/* LR.. */
    uint8_t direction = report->buttons2 & (OEHACButtonState2Up | OEHACButtonState2Down | OEHACButtonState2Left | OEHACButtonState2Right);
    NSAssert(direction < 0x10, @"Don't touch my enums! We are making assumptions here");
    OEHIDEventHatDirection hat = buttonToHat[direction];
    cookie = [OESwitchProControllerHIDDeviceParser _cookieFromUsage:0x39];
    OEHIDEvent *hatevt = [OEHIDEvent hatSwitchEventWithDeviceHandler:self timestamp:now type:OEHIDEventHatSwitchType8Ways direction:hat cookie:cookie];
    [self dispatchEvent:hatevt];
    
    /* Left stick */
    OEHAC16BitUnsignedPair leftStick = OEHACUnpackPair(report->leftStick);
    [self _dispatchEventsOfXAxis:OEHIDEventAxisX YAxis:OEHIDEventAxisY withData:leftStick calibration:&_leftStickCalibration timestamp:now];
    
    /* Right stick (the N64 controller has none; its unused bytes would
     * otherwise show up as a stuck axis while mapping buttons) */
    if (!_isN64Controller) {
        OEHAC16BitUnsignedPair rightStick = OEHACUnpackPair(report->rightStick);
        [self _dispatchEventsOfXAxis:OEHIDEventAxisRx YAxis:OEHIDEventAxisRy withData:rightStick calibration:&_rightStickCalibration timestamp:now];
    }
}


- (void)_dispatchButtonEventsWithButtonMask:(uint8_t)mask buttonMap:(const uint8_t[])map timestamp:(NSTimeInterval)ts
{
    int i=0;
    while (map[i] != 0) {
        uint8_t thisButtonMask = map[i++];
        uint8_t thisButtonNumber = map[i++];
        NSInteger cookie = [OESwitchProControllerHIDDeviceParser _cookieFromUsage:thisButtonNumber];
        OEHIDEventState state = (mask & thisButtonMask) ? OEHIDEventStateOn : OEHIDEventStateOff;
        OEHIDEvent *evt = [OEHIDEvent buttonEventWithDeviceHandler:self timestamp:ts buttonNumber:thisButtonNumber state:state cookie:cookie];
        [self dispatchEvent:evt];
    }
}


- (void)_dispatchEventsOfXAxis:(OEHIDEventAxis)xaxis YAxis:(OEHIDEventAxis)yaxis withData:(OEHAC16BitUnsignedPair)stickData calibration:(const OEHACProControllerStickCalibration *)calibration timestamp:(NSTimeInterval)now
{
    stickData.x <<= 4;
    stickData.y = ~(stickData.y << 4);
    
    NSInteger cookie;
    CGFloat value;
    OEHIDEvent *event;
    
    cookie = [OESwitchProControllerHIDDeviceParser _cookieFromUsage:xaxis];
    value = OEHACScaleValueWithCalibration(&(calibration->x), stickData.x);
    if (fabs(value) < [self deadZoneForControlCookie:cookie])
        value = 0;
    event = [OEHIDEvent axisEventWithDeviceHandler:self timestamp:now axis:xaxis value:value cookie:cookie];
    [self dispatchEvent:event];
    
    cookie = [OESwitchProControllerHIDDeviceParser _cookieFromUsage:yaxis];
    value = OEHACScaleValueWithCalibration(&(calibration->y), stickData.y);
    if (fabs(value) < [self deadZoneForControlCookie:cookie])
        value = 0;
    event = [OEHIDEvent axisEventWithDeviceHandler:self timestamp:now axis:yaxis value:value cookie:cookie];
    [self dispatchEvent:event];
}


#pragma mark - Controller-Specific functionality


- (void)_setPlayerLights:(uint8_t)mask
{
    [self _sendSubcommand:OEHACSubcmdSetPlayerLights withData:&mask length:1];
}


- (void)_setReportMode:(OEHACInputReportID)mode
{
    [self _sendSubcommand:OEHACSubcmdSetInputReportMode withData:&mode length:1];
}


- (void)_setPowerState:(OEHACPowerState)powerState
{
    [self _sendOneWaySubcommand:OEHACSubcmdSetPowerState withData:&powerState length:1];
}


- (void)_enableUSBmode
{
    [self _sendUSBSubcommand:OEHACUSBSubcommandIDRequestHandshake];
    [self _sendUSBSubcommand:OEHACUSBSubcommandIDRequestHighDataRate];
    [self _sendUSBSubcommand:OEHACUSBSubcommandIDRequestHandshake];
    [self _sendOneWayUSBSubcommand:OEHACUSBSubcommandIDDisableUSBHIDTimeout];
}


#pragma mark - Custom HID Reports Send/Receive Primitives


- (NSData *)_requestSPIFlashReadAtAddress:(uint32_t)in_base length:(uint8_t)in_len
{
    NSAssert(in_len <= 29, @"cannot read more than 29 bytes from SPI Flash at a time");
    
    struct __attribute__((packed)) {
        uint32_t base;
        uint8_t len;
    } spiReadSubcmdData = {in_base, in_len};
    
    __block NSData *result;
    [self _sendSubcommand:OEHACSubcmdRequestSPIFlashRead withData:&spiReadSubcmdData length:sizeof(spiReadSubcmdData) validationHandler:^BOOL(NSData *data) {
        const OEHACAcknowledgmentHIDInputReport *ack = data.bytes;
        const struct __attribute__((packed)) {
            uint32_t base;
            uint8_t len;
            uint8_t data[29];
        } *reply = (void *)ack->reply;

        if (reply->base != in_base || reply->len != in_len) {
            NSLog(@"[dev %p] Wrong ACK from controller (SPI Flash read wrong offset/length)", self);
            return NO;
        }
        
        result = [NSData dataWithBytes:reply->data length:in_len];
        return YES;
    }];
    
    if (!result)
        return nil;
    return result;
}


- (NSData *)_sendSubcommand:(OEHACSubcommandID)cmdid withData:(const void *)data length:(NSUInteger)length
{
    return [self _sendSubcommand:cmdid withData:data length:length validationHandler:nil];
}


- (NSData *)_sendSubcommand:(OEHACSubcommandID)cmdid withData:(const void *)data length:(NSUInteger)length validationHandler:(BOOL (^ __nullable)(NSData *))validator
{
    OEHACRumbleAndSubcommandOutputReport report = {0};
    NSAssert(length < sizeof(report.subcmdParam), @"too much data for a single report");
    
    report.reportID = OEHACOutputReportIDRumbleAndSubcommand;
    report.seqNumber = _packetCounter;
    _packetCounter = (_packetCounter + 1) & 0xF;
    report.subcmdID = cmdid;
    if (data)
        memcpy(report.subcmdParam, data, length);
    
    NSData *reportData = [NSData dataWithBytes:&report length:sizeof(OEHACRumbleAndSubcommandOutputReport)];
    return [self _attemptSendingOutputReport:reportData responseHandler:^BOOL(NSData *respData, int attempts) {
        if ([respData length] < sizeof(OEHACAcknowledgmentHIDInputReport)) {
            NSLog(@"[dev %p] Invalid ACK from controller (subcommand %02X)", self, cmdid);
            return NO;
        }
        const OEHACAcknowledgmentHIDInputReport *response = [respData bytes];
        if (!(response->ackStatus & 0x80)) {
            NSLog(@"[dev %p] NACK from controller (subcommand %02X)", self, cmdid);
            return NO;
        }
        if (response->repliedSubcmdId != cmdid) {
            NSLog(@"[dev %p] Wrong ACK from controller (subcommand %02X expected, %02X received) [attempt = %d]", self, cmdid, response->repliedSubcmdId, attempts);
            return NO;
        } else if (validator && !validator(respData)) {
            NSLog(@"[dev %p] Validation failed [attempt = %d]", self, attempts);
            return NO;
        }
        return YES;
    }];
}


- (BOOL)_sendOneWaySubcommand:(OEHACSubcommandID)cmdid withData:(const void *)data length:(NSUInteger)length
{
    OEHACRumbleAndSubcommandOutputReport report = {0};
    NSAssert(length < sizeof(report.subcmdParam), @"too much data for a single report");
    
    report.reportID = OEHACOutputReportIDRumbleAndSubcommand;
    report.seqNumber = _packetCounter;
    _packetCounter = (_packetCounter + 1) & 0xF;
    report.subcmdID = cmdid;
    if (data)
        memcpy(report.subcmdParam, data, length);
    
    #ifdef LOG_COMMUNICATION
    NSLog(@"[dev %p] sent output report %@", self, [NSData dataWithBytes:(uint8_t *)&report length:sizeof(OEHACRumbleAndSubcommandOutputReport)]);
    #endif
    IOReturn ret = IOHIDDeviceSetReport([self device], kIOHIDReportTypeOutput, report.reportID, (uint8_t *)&report, sizeof(OEHACRumbleAndSubcommandOutputReport));
    if (ret != kIOReturnSuccess) {
        NSLog(@"[dev %p] Could not send command, error: %x", self, ret);
        return NO;
    }
    
    return YES;
}


- (NSData *)_sendUSBSubcommand:(OEHACUSBSubcommandID)cmdid
{
    OEHACUSBSubcommandOutputReport report = {0};
    report.reportID = OEHACOutputReportIDUSBSubcommand;
    report.subcommand = cmdid;
    
    NSData *reportData = [NSData dataWithBytes:(void*)&report length:sizeof(OEHACUSBSubcommandOutputReport)];
    
    return [self _attemptSendingOutputReport:reportData responseHandler:^BOOL(NSData *respData, int attempts) {
        if ([respData length] < sizeof(OEHACUSBAcknowledgmentOutputReport)) {
            NSLog(@"[dev %p] Invalid ACK from controller (USB subcommand %02X)", self, cmdid);
            return NO;
        }
        const OEHACUSBAcknowledgmentOutputReport *response = respData.bytes;
        if (response->reportID != OEHACInputReportIDUSBSubcommandReply) {
            NSLog(@"[dev %p] Invalid ACK from controller (USB subcommand %02X)", self, cmdid);
            return NO;
        }
        if (response->subcommand != cmdid) {
            NSLog(@"[dev %p] Wrong USB ACK from controller (subcommand %02X expected, %02X received) [attempt = %d]", self, cmdid, response->subcommand, attempts);
           return NO;
        }
        return YES;
    }];
}


- (BOOL)_sendOneWayUSBSubcommand:(OEHACUSBSubcommandID)cmdid
{
    OEHACUSBSubcommandOutputReport report = {0};
    
    report.reportID = OEHACOutputReportIDUSBSubcommand;
    report.subcommand = cmdid;
    
    #ifdef LOG_COMMUNICATION
    NSLog(@"[dev %p] sent output report %@", self, [NSData dataWithBytes:(uint8_t *)&report length:sizeof(OEHACUSBSubcommandOutputReport)]);
    #endif
    IOReturn ret = IOHIDDeviceSetReport([self device], kIOHIDReportTypeOutput, report.reportID, (uint8_t *)&report, sizeof(OEHACUSBSubcommandOutputReport));
    if (ret != kIOReturnSuccess) {
        NSLog(@"[dev %p] Could not send command, error: %x", self, ret);
        return NO;
    }
    
    return YES;
}


- (NSData *)_attemptSendingOutputReport:(NSData *)report responseHandler:(BOOL (^)(NSData *respData, int attempts))respHandler
{
    NSAssert(report.length > 1, @"HID reports must be at least one byte long!");
    
    NSData *ack;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MAX_RESPONSE_WAIT_SECONDS];
    uint8_t reportID = ((uint8_t *)report.bytes)[0];
    
    [_responseAvailable lock];
    
    _currentResponse = nil;
    #ifdef LOG_COMMUNICATION
    NSLog(@"[dev %p] sent output report %@", self, report);
    #endif
    IOReturn ret = IOHIDDeviceSetReport([self device], kIOHIDReportTypeOutput, reportID, report.bytes, report.length);
    if (ret != kIOReturnSuccess) {
        NSLog(@"[dev %p] Could not send command, error: %x", self, ret);
        goto fail;
    }
    
    int attempts = 0;
    while (_currentResponse == nil && attempts < MAX_RESPONSE_ATTEMPTS) {
        BOOL notTimeout = YES;
        while (_currentResponse == nil && notTimeout)
            notTimeout = [_responseAvailable waitUntilDate:deadline];
        if (!notTimeout && _currentResponse == nil) {
            NSLog(@"[dev %p] Did not receive ACK from controller after %f s", self,  MAX_RESPONSE_WAIT_SECONDS);
            goto fail;
        }
        
        BOOL accepted = respHandler(_currentResponse, attempts);
        if (!accepted) {
            _currentResponse = nil;
            attempts++;
        }
    }
    ack = _currentResponse;
    
fail:
    [_responseAvailable unlock];
    
    return ack;
}


- (void)_didReceiveInputReportWithID:(uint8_t)rid data:(uint8_t *)data length:(NSUInteger)length
{
    if (data[0] == OEHACInputReportIDSubcommandReply || data[0] == OEHACInputReportIDUSBSubcommandReply) {
        [_responseAvailable lock];
        _currentResponse = [NSData dataWithBytes:data length:length];
        #ifdef LOG_COMMUNICATION
        NSLog(@"[dev %p] ack report %@", self, _currentResponse);
        #endif
        [_responseAvailable signal];
        [_responseAvailable unlock];
        
    } else if (data[0] == OEHACInputReportIDFullReport && length >= sizeof(OEHACStandardHIDInputReport)) {
        #ifdef LOG_COMMUNICATION
        NSLog(@"[dev %p] input report %@", self, [NSData dataWithBytes:data length:length]);
        #endif
        /* Latency of an event dispatch as measured on a MacBook Pro (13-inch, 2018,
         * Four Thunderbolt 3 Ports), via timestamp comparison with both the LOG_COMMUNICATION
         * define enalbed and the HID Event Log option enabled:
         * ~500 microseconds (0.030 frames at 60 FPS) */
        __block OEHACStandardHIDInputReport report = *((OEHACStandardHIDInputReport *)(data));
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _dispatchEventsWithStandardInputReport:&report];
        });
        
    } else {
        #ifdef LOG_COMMUNICATION
        NSLog(@"[dev %p] non-ack report %@", self, [NSData dataWithBytes:data length:length]);
        #endif
    }
}


@end


static void OEHACProControllerHIDReportCallback(
    void * _Nullable        context,
    IOReturn                result,
    void * _Nullable        sender,
    IOHIDReportType         type,
    uint32_t                reportID,
    uint8_t *               report,
    CFIndex                 reportLength)
{
    [(__bridge OESwitchProControllerHIDDeviceHandler *)context _didReceiveInputReportWithID:reportID data:report length:reportLength];
}


#pragma mark - Device Parser (mainly for USB support)


@implementation OESwitchProControllerHIDDeviceParser
{
    NSMapTable <NSData *, OESwitchProControllerHIDDeviceHandler *> *_serialToHandler;
}


- (instancetype)init
{
    self = [super init];
    _serialToHandler = [NSMapTable strongToWeakObjectsMapTable];
    return self;
}


+ (OESwitchProControllerHIDDeviceParser *)sharedInstance
{
    static OESwitchProControllerHIDDeviceParser *parser;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        parser = [[OESwitchProControllerHIDDeviceParser alloc] init];
    });
    return parser;
}


+ (NSUInteger)_cookieFromUsage:(NSUInteger)usage
{
    NSUInteger cookie;
    /* reproduce the same cookies seen over bluetooth
     * probably unnecessary */
    if (usage == 0x30 || usage == 0x31)
        cookie = usage - 0x30 + 0x4B3;
    else if (usage == 0x33 || usage == 0x34)
        cookie = usage - 0x33 + 0x4B5;
    else if (usage == 0x39)
        cookie = 0x4B2;
    else
        cookie = usage + 1;
    return cookie;
}


- (OEDeviceHandler *)deviceHandlerForIOHIDDevice:(IOHIDDeviceRef)device
{
    /* When connected via USB, the exposed HID elements are completely different.
     * To work around that, we build a custom device description which is compatible
     * with the HID elements that are exposed via bluetooth. */
    
    NSNumber *vid = (__bridge NSNumber *)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDVendorIDKey));
    NSNumber *pid = (__bridge NSNumber *)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductIDKey));
    NSString *pkey = (__bridge NSString *)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
    OEControllerDescription *controllerDesc = [OEControllerDescription OE_controllerDescriptionForVendorID:vid.integerValue productID:pid.integerValue product:pkey];
    if ([[controllerDesc controls] count] == 0) {
        NSDictionary *representations = [OEControllerDescription OE_representationForControllerDescription:controllerDesc];
        [representations enumerateKeysAndObjectsUsingBlock:^(NSString *identifier, NSDictionary *representation, BOOL *stop) {
            OEHIDEventType type = OEHIDEventTypeFromNSString(representation[@"Type"]);
            NSUInteger usage = OEUsageFromUsageStringWithType(representation[@"Usage"], type);
            NSUInteger cookie = [OESwitchProControllerHIDDeviceParser _cookieFromUsage:usage];

            OEHIDEvent *event;
            switch (type) {
                case OEHIDEventTypeAxis:
                    event = [OEHIDEvent axisEventWithDeviceHandler:nil timestamp:0 axis:usage direction:OEHIDEventAxisDirectionNull cookie:cookie];
                    break;
                case OEHIDEventTypeButton:
                    event = [OEHIDEvent buttonEventWithDeviceHandler:nil timestamp:0 buttonNumber:usage state:OEHIDEventStateOn cookie:cookie];
                    break;
                case OEHIDEventTypeHatSwitch:
                    event = [OEHIDEvent hatSwitchEventWithDeviceHandler:nil timestamp:0 type:OEHIDEventHatSwitchType8Ways direction:OEHIDEventHatDirectionNull cookie:cookie];
                    break;
                default:
                    NSLog(@"unexpected item in controller database for Switch Pro Controller");
                    return;
            }

            [controllerDesc addControlWithIdentifier:identifier name:representation[@"Name"] event:event valueRepresentations:representation[@"Values"]];
        }];
    }

    return [[OESwitchProControllerHIDDeviceHandler alloc] initWithIOHIDDevice:device deviceDescription:[controllerDesc deviceDescriptionForVendorID:vid.integerValue productID:pid.integerValue cookie:0]];
}


- (void)registerDeviceHandler:(OESwitchProControllerHIDDeviceHandler *)dh
{
    /* When connecting a Switch Pro Controller via USB, if that same controller
     * was already connected via BlueTooth, it can happen that for a brief instant
     * OpenEmu thinks that the controller is connected both via USB and BT
     * at the same time.
     *
     * Thus, we keep a registry of all the device handlers of each Switch Controller
     * so that we can check if we have to manually disconnect a device because
     * we are changing connection to USB. */
    
    NSData *serial = dh.internalSerialNumber;
    OESwitchProControllerHIDDeviceHandler *existing = [_serialToHandler objectForKey:serial];
    OEDeviceManager *devm = [OEDeviceManager sharedDeviceManager];
    
    if (![devm.deviceHandlers containsObject:existing]) {
        /* Device is not connected in any other way */
        [_serialToHandler setObject:dh forKey:serial];
        return;
    }
    
    NSLog(@"Switch Pro Controller %@ is connected both via bluetooth and USB; removing least recent connection", serial);
    [[OEDeviceManager sharedDeviceManager] OE_removeDeviceHandler:existing];
    [_serialToHandler setObject:dh forKey:serial];
}


@end

