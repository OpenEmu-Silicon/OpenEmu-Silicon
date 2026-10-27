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

#import "OEDeviceManager.h"
#import "OEDeviceManager_Internal.h"
#import "OEDeviceHandler.h"
#import "OEControllerDescription.h"
#import "OEHIDDeviceHandler.h"
#import "OEMultiHIDDeviceHandler.h"
#import "OEWiimoteHIDDeviceHandler.h"
#import "OEPS3HIDDeviceHandler.h"
#import "OEPS4HIDDeviceHandler.h"
#import "OEXBox360HIDDeviceHander.h"
#import "OETouchbarHIDDeviceHandler.h"
#import "OEHIDEvent_Internal.h"

#import <objc/runtime.h>

#import <IOBluetooth/IOBluetooth.h>
#import <IOBluetooth/objc/IOBluetoothDeviceInquiry.h>
#import <IOBluetooth/objc/IOBluetoothDevice.h>

NS_ASSUME_NONNULL_BEGIN

NSNotificationName const OEDeviceManagerDidAddDeviceHandlerNotification    = @"OEDeviceManagerDidAddDeviceHandlerNotification";
NSNotificationName const OEDeviceManagerDidRemoveDeviceHandlerNotification = @"OEDeviceManagerDidRemoveDeviceHandlerNotification";

NSNotificationName const OEDeviceManagerDidAddGlobalEventMonitorHandlerNotification = @"OEDeviceManagerDidAddGlobalEventMonitorHandlerNotification";
NSNotificationName const OEDeviceManagerDidRemoveGlobalEventMonitorHandlerNotification = @"OEDeviceManagerDidRemoveGlobalEventMonitorHandlerNotification";

NSString *const OEDeviceManagerDeviceHandlerUserInfoKey           = @"OEDeviceManagerDeviceHandlerUserInfoKey";

@interface _OEDeviceManagerEventMonitor : NSObject
+ (instancetype)monitorWithGlobalMonitorHandler:(BOOL(^)(OEDeviceHandler *handler, OEHIDEvent *event))handler;
+ (instancetype)monitorWithEventMonitorHandler:(void(^)(OEDeviceHandler *handler, OEHIDEvent *event))handler;
@property(copy) BOOL(^globalMonitor)(OEDeviceHandler *handler, OEHIDEvent *event);
@property(copy) void(^eventMonitor)(OEDeviceHandler *handler, OEHIDEvent *event);
@end

static void OEHandle_DeviceMatchingCallback(void *inContext, IOReturn inResult, void *inSender, IOHIDDeviceRef inIOHIDDeviceRef);

static const void * kOEBluetoothDevicePairSyncStyleKey = &kOEBluetoothDevicePairSyncStyleKey;

@interface IOBluetoothDevicePair (SyncStyle)
@property(nonatomic, assign) BOOL attemptedHostToDevice;
@end

@implementation IOBluetoothDevicePair (SyncStyle)

- (BOOL)attemptedHostToDevice
{
    return [objc_getAssociatedObject(self, kOEBluetoothDevicePairSyncStyleKey) boolValue];
}

- (void)setAttemptedHostToDevice:(BOOL)attemptedHostToDevice
{
    objc_setAssociatedObject(self, kOEBluetoothDevicePairSyncStyleKey, @(attemptedHostToDevice), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

@interface OEDeviceManager () <IOBluetoothDeviceInquiryDelegate>
@end

@interface OEDeviceHandler ()
@property(readwrite) NSUInteger deviceNumber;
@property(readwrite) NSUInteger deviceIdentifier;
@end

@implementation OEDeviceManager {
    dispatch_queue_t _uniqueIdentifiersToDeviceHandlersQueue;
    NSMutableDictionary<NSString *, __kindof OEDeviceHandler *> *_uniqueIdentifiersToDeviceHandlers;

    NSMutableSet<OEDeviceHandler *> *_keyboardHandlers;
    NSMutableSet<OEDeviceHandler *> *_deviceHandlers;
    NSMutableSet<OEMultiHIDDeviceHandler *> *_multiDeviceHandlers;
    IOHIDManagerRef _hidManager;

    id _keyEventMonitor;
    id _modifierMaskMonitor;

    IOBluetoothDeviceInquiry *_inquiry;

    NSUInteger _lastAttributedDeviceIdentifier;
    NSUInteger _lastAttributedMultiDeviceIdentifier;
    NSUInteger _lastAttributedKeyboardIdentifier;

    NSHashTable<_OEDeviceManagerEventMonitor *> *_globalEventListeners;
    NSHashTable<_OEDeviceManagerEventMonitor *> *_unhandledEventListeners;
    NSMutableDictionary<OEDeviceHandler *, NSHashTable<_OEDeviceManagerEventMonitor *> *> *_deviceHandlersToEventListeners;
}

+ (OEDeviceManager *)sharedDeviceManager;
{
    static OEDeviceManager *sharedHIDManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedHIDManager = [[self alloc] init];
    });

    return sharedHIDManager;
}

- (instancetype)init
{
    if((self = [super init]))
    {
        _uniqueIdentifiersToDeviceHandlersQueue = dispatch_queue_create("org.openemu.uniqueIdentifiersToDeviceHandlersQueue", DISPATCH_QUEUE_CONCURRENT);
        _uniqueIdentifiersToDeviceHandlers = [[NSMutableDictionary alloc] init];

        _keyboardHandlers    = [[NSMutableSet alloc] init];
        _deviceHandlers      = [[NSMutableSet alloc] init];
        _multiDeviceHandlers = [[NSMutableSet alloc] init];
        _hidManager          = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);

        _globalEventListeners = [NSHashTable weakObjectsHashTable];
        _unhandledEventListeners = [NSHashTable weakObjectsHashTable];
        _deviceHandlersToEventListeners = [NSMutableDictionary dictionary];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self OE_setUpCallbacks];
        });
    }
    return self;
}

- (OEDeviceAccessType)accessType
{
    IOHIDAccessType accessType = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent);
    switch (accessType)
    {
        case kIOHIDAccessTypeGranted:
            return OEDeviceAccessTypeGranted;
        
        case kIOHIDAccessTypeDenied:
            return OEDeviceAccessTypeDenied;
        
        case kIOHIDAccessTypeUnknown:
        default:
            return OEDeviceAccessTypeUnknown;
    }
}

- (BOOL)requestAccess
{
    // Ask for approval
    return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
}

- (void)rescanKeyboardDevices
{
    if (@available(macOS 10.15, *)) {
        // Only skip if the user has explicitly denied access. "Unknown" means TCC
        // couldn't confirm the grant (common on ad-hoc/dev-signed builds and on
        // some macOS beta releases), but the permission is typically still in effect.
        // Letting IOKit attempt the match is safe: if permission truly isn't present,
        // no keyboard devices will appear in the matching callback.
        if (self.accessType == OEDeviceAccessTypeDenied) return;
        if (_keyboardHandlers.count > 0) return;  // already enumerated

        // Rebuild the matching array with keyboards included and re-apply it.
        // IOKit fires the existing matching callback immediately for any already-
        // connected keyboards, effectively enumerating them without restarting.
        NSArray *matchingTypes = @[
            @{ @ kIOHIDDeviceUsagePageKey : @(kHIDPage_GenericDesktop),
               @ kIOHIDDeviceUsageKey     : @(kHIDUsage_GD_Joystick) },
            @{ @ kIOHIDDeviceUsagePageKey : @(kHIDPage_GenericDesktop),
               @ kIOHIDDeviceUsageKey     : @(kHIDUsage_GD_GamePad) },
            @{ @ kIOHIDDeviceUsagePageKey : @(kHIDPage_GenericDesktop),
               @ kIOHIDDeviceUsageKey     : @(kHIDUsage_GD_Keyboard) },
        ];
        IOHIDManagerSetDeviceMatchingMultiple(_hidManager, (__bridge CFArrayRef)matchingTypes);
    }
}

- (void)OE_setUpCallbacks
{
    IOHIDManagerRegisterDeviceMatchingCallback(_hidManager, OEHandle_DeviceMatchingCallback, (__bridge void *)self);

    IOHIDManagerScheduleWithRunLoop(_hidManager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);

    [self OE_addKeyboardEventMonitor];

    NSArray *matchingTypes = @[ @{
        @ kIOHIDDeviceUsagePageKey : @(kHIDPage_GenericDesktop),
        @ kIOHIDDeviceUsageKey     : @(kHIDUsage_GD_Joystick)
    },
    @{
        @ kIOHIDDeviceUsagePageKey : @(kHIDPage_GenericDesktop),
        @ kIOHIDDeviceUsageKey     : @(kHIDUsage_GD_GamePad)
    }];
    
    BOOL addKeyboard = YES;
    if (@available(macOS 10.15, *))
    {
        addKeyboard = self.accessType == OEDeviceAccessTypeGranted;
    }
    
    if (addKeyboard)
    {
        matchingTypes = [matchingTypes arrayByAddingObject:@{
            @ kIOHIDDeviceUsagePageKey : @(kHIDPage_GenericDesktop),
            @ kIOHIDDeviceUsageKey     : @(kHIDUsage_GD_Keyboard)
        }];
    }

    IOHIDManagerSetDeviceMatchingMultiple(_hidManager, (__bridge CFArrayRef)matchingTypes);

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(OE_wiimoteDeviceDidDisconnect:) name:OEWiimoteDeviceHandlerDidDisconnectNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(OE_applicationWillTerminate:) name:NSApplicationWillTerminateNotification object:nil];
}

- (void)OE_applicationWillTerminate:(NSNotification *)notification;
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    // Ensure that we've properly cleaned up our HIDManager references and
    // removed our devices from the runloop.
    
    // Unschedule the HID manager from the main runloop. This propagates to all
    // device handlers that are scheduled there as well.
    //   We do this before deallocating the device handlers because, in the case
    // where a device handler is not scheduled to the main runloop, the
    // following call can crash because of a bug in the HID manager.
    //   Specifically, the HID manager stores pointers to CFRunLoops without
    // retaining them. Thus, when a device manager gets released, its run loop
    // can be deallocated even though IOHIDManager still has a reference to it.
    // The crash happens as soon as the HIDManager attempts to check if the
    // runloop of that device is equal to the main runloop, when deciding
    // whether to unschedule that device or not.
    if (_hidManager)
        IOHIDManagerUnscheduleFromRunLoop(_hidManager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    
    for(OEDeviceHandler *handler in [_deviceHandlers copy])
        [self OE_removeDeviceHandler:handler];

    [NSEvent removeMonitor:_keyEventMonitor];
    [NSEvent removeMonitor:_modifierMaskMonitor];
    _keyEventMonitor = nil;
    _modifierMaskMonitor = nil;

    if(_hidManager)
        CFRelease(_hidManager);
}

- (NSArray<OEDeviceHandler *> *)deviceHandlers
{
    return [_deviceHandlers copy];
}

- (NSArray<OEDeviceHandler *> *)controllerDeviceHandlers
{
    return [[_deviceHandlers allObjects] sortedArrayUsingComparator:^ NSComparisonResult (OEDeviceHandler *obj1, OEDeviceHandler *obj2) {
        return [@([obj1 deviceIdentifier]) compare:@([obj2 deviceIdentifier])];
    }];
}

- (NSArray<OEDeviceHandler *> *)keyboardDeviceHandlers
{
    return [[_keyboardHandlers allObjects] sortedArrayUsingComparator:^ NSComparisonResult (OEDeviceHandler *obj1, OEDeviceHandler *obj2) {
        return [@([obj1 deviceIdentifier]) compare:@([obj2 deviceIdentifier])];
    }];
}

- (OEDeviceHandler *)deviceHandlerForUniqueIdentifier:(NSString *)uniqueIdentifier
{
    __block OEDeviceHandler *handler;

    dispatch_sync(_uniqueIdentifiersToDeviceHandlersQueue, ^{
        handler = self->_uniqueIdentifiersToDeviceHandlers[uniqueIdentifier];

        if (handler)
            return;

        handler = [[OEDeviceHandlerPlaceholder alloc] initWithUniqueIdentifier:uniqueIdentifier];
        self->_uniqueIdentifiersToDeviceHandlers[uniqueIdentifier] = handler;
    });

    return handler;
}

- (void)deviceHandler:(nullable OEDeviceHandler *)device didReceiveEvent:(OEHIDEvent *)event
{
    BOOL continuePosting = YES;
    for(_OEDeviceManagerEventMonitor *monitor in _globalEventListeners) {
        if(![monitor globalMonitor](device, event))
            continuePosting = NO;
    }

    if(!continuePosting)
        return;

    if(device != nil) {
        NSHashTable<_OEDeviceManagerEventMonitor *> *monitors = _deviceHandlersToEventListeners[device];
        for(_OEDeviceManagerEventMonitor *monitor in monitors) {
            [monitor eventMonitor](device, event);
            continuePosting = NO;
        }

        if(!continuePosting)
            return;
    }

    for(_OEDeviceManagerEventMonitor *monitor in _unhandledEventListeners)
        [monitor eventMonitor](device, event);
}

- (BOOL)hasEventMonitor
{
    return _globalEventListeners.count > 0;
}

- (id)addGlobalEventMonitorHandler:(BOOL(^)(OEDeviceHandler *handler, OEHIDEvent *event))handler;
{
    _OEDeviceManagerEventMonitor *monitor = [_OEDeviceManagerEventMonitor monitorWithGlobalMonitorHandler:handler];
    [_globalEventListeners addObject:monitor];

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:OEDeviceManagerDidAddGlobalEventMonitorHandlerNotification object:self];
    });

    return monitor;
}

- (id)addEventMonitorForDeviceHandler:(OEDeviceHandler *)device handler:(void(^)(OEDeviceHandler *handler, OEHIDEvent *event))handler;
{
    NSAssert(device != nil, @"You must provide a device handler, use addUnhandledEventMonitorHandler: instead.");
    NSHashTable<_OEDeviceManagerEventMonitor *> *monitors = _deviceHandlersToEventListeners[device];
    if(monitors == nil)  {
        monitors = [NSHashTable weakObjectsHashTable];
        _deviceHandlersToEventListeners[device] = monitors;
    }

    _OEDeviceManagerEventMonitor *monitor = [_OEDeviceManagerEventMonitor monitorWithEventMonitorHandler:handler];
    [monitors addObject:monitor];
    return monitor;
}

- (id)addUnhandledEventMonitorHandler:(void(^)(OEDeviceHandler *handler, OEHIDEvent *event))handler;
{
    _OEDeviceManagerEventMonitor *monitor = [_OEDeviceManagerEventMonitor monitorWithEventMonitorHandler:handler];
    [_unhandledEventListeners addObject:monitor];
    return monitor;
}

- (void)removeMonitor:(id)monitor;
{
    if ([_globalEventListeners containsObject:monitor]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:OEDeviceManagerDidRemoveGlobalEventMonitorHandlerNotification object:self];
        });
    }

    [_globalEventListeners removeObject:monitor];
    [_unhandledEventListeners removeObject:monitor];

    NSMutableArray<OEDeviceHandler *> *keysToRemove = [NSMutableArray array];
    [_deviceHandlersToEventListeners enumerateKeysAndObjectsUsingBlock:^(OEDeviceHandler *key, NSHashTable *monitors, BOOL *stop) {
        [monitors removeObject:monitor];

        if([monitors count] == 0)
            [keysToRemove addObject:key];
    }];

    [_deviceHandlersToEventListeners removeObjectsForKeys:keysToRemove];
}

#pragma mark - Keyboard management

- (void)sendKeyboardKeyWithUsage:(NSUInteger)usage pressed:(BOOL)pressed
{
    OEHIDEvent *event = [OEHIDEvent keyEventWithTimestamp:[[NSProcessInfo processInfo] systemUptime] keyCode:usage state:pressed cookie:OEUndefinedCookie];
    [self deviceHandler:nil didReceiveEvent:event];
}

- (void)OE_addKeyboardEventMonitor;
{
    _keyEventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp handler:^ NSEvent * (NSEvent *anEvent) {
        /* Events with a process ID of 0 comes from the system, that is from the physical keyboard.
         * These events are already managed by their own device handler.
         * The events managed through this monitor are events coming from different applications.
         */
        if(CGEventGetIntegerValueField([anEvent CGEvent], kCGEventSourceUnixProcessID) == 0)
            return anEvent;

        OEHIDEvent *event = [OEHIDEvent keyEventWithTimestamp:[anEvent timestamp] keyCode:[OEHIDEvent keyCodeForVirtualKey:[anEvent keyCode]] state:[anEvent type] == NSEventTypeKeyDown cookie:OEUndefinedCookie];
        [[OEDeviceManager sharedDeviceManager] deviceHandler:nil didReceiveEvent:event];

        return anEvent;
    }];

    _modifierMaskMonitor =
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged handler:^ NSEvent * (NSEvent *anEvent) {
        /* Events with a process ID of 0 comes from the system, that is from the physical keyboard.
         * These events are already managed by their own device handler.
         * The events managed through this monitor are events coming from different applications.
         */
        if(CGEventGetIntegerValueField([anEvent CGEvent], kCGEventSourceUnixProcessID) == 0)
            return anEvent;

        NSUInteger keyCode = [OEHIDEvent keyCodeForVirtualKey:[anEvent keyCode]];
        NSUInteger keyMask = 0;

        switch(keyCode) {
            case kHIDUsage_KeyboardCapsLock : keyMask = NSEventModifierFlagCapsLock; break;

            case kHIDUsage_KeyboardLeftControl : keyMask = 0x0001; break;
            case kHIDUsage_KeyboardLeftShift : keyMask = 0x0002; break;
            case kHIDUsage_KeyboardRightShift : keyMask = 0x0004; break;
            case kHIDUsage_KeyboardLeftGUI : keyMask = 0x0008; break;
            case kHIDUsage_KeyboardRightGUI : keyMask = 0x0010; break;
            case kHIDUsage_KeyboardLeftAlt : keyMask = 0x0020; break;
            case kHIDUsage_KeyboardRightAlt : keyMask = 0x0040; break;
            case kHIDUsage_KeyboardRightControl : keyMask = 0x2000; break;
        }

        OEHIDEvent *event = [OEHIDEvent keyEventWithTimestamp:[anEvent timestamp] keyCode:keyCode state:!!([anEvent modifierFlags] & keyMask) cookie:OEUndefinedCookie];
        [[OEDeviceManager sharedDeviceManager] deviceHandler:nil didReceiveEvent:event];

        return anEvent;
    }];
}

#pragma mark - IOHIDDevice management

- (void)OE_enumerateDevicesUsingBlock:(void(^)(OEDeviceHandler *device, BOOL *stop))block
{
    BOOL stop = NO;
    for(OEDeviceHandler *handler in _multiDeviceHandlers) {
        block(handler, &stop);
        if(stop)
            return;
    }

    for(OEDeviceHandler *handler in _keyboardHandlers) {
        block(handler, &stop);
        if(stop)
            return;
    }

    for(OEDeviceHandler *handler in _deviceHandlers) {
        block(handler, &stop);
        if(stop)
            return;
    }
}

- (void)OE_addDeviceHandlerForDeviceRef:(IOHIDDeviceRef)device couldBeTheTouchbar:(BOOL)istouchbar
{
    NSAssert(device != NULL, @"Passing NULL device.");

    OEHIDDeviceHandler *handler = nil;
    if([OEHIDDeviceHandler deviceIsKeyboardOnly:device]) {
        if (!istouchbar)
            handler = [[OEHIDDeviceHandler alloc] initWithIOHIDDevice:device deviceDescription:nil];
        else
            handler = [[OETouchbarHIDDeviceHandler alloc] initWithIOHIDDevice:device deviceDescription:nil];
    } else
        handler = [[OEHIDDeviceHandler deviceParser] deviceHandlerForIOHIDDevice:device];

    if([handler connect])
        [self OE_addDeviceHandler:handler];
}

- (void)OE_addDeviceHandler:(__kindof OEDeviceHandler *)handler
{
    if(![handler isKindOfClass:[OEMultiHIDDeviceHandler class]]
       && ![handler isKeyboardDevice]
       && [[handler controllerDescription] numberOfControls] == 0) {
        NSLog(@"OEDeviceManager: ignoring device handler %@, no controls could be read from it.", handler);
        return;
    }

    dispatch_barrier_async(_uniqueIdentifiersToDeviceHandlersQueue, ^{
        OEDeviceHandlerPlaceholder *placeholder = self->_uniqueIdentifiersToDeviceHandlers[handler.uniqueIdentifier];
        self->_uniqueIdentifiersToDeviceHandlers[handler.uniqueIdentifier] = handler;

        if (![placeholder isKindOfClass:[OEDeviceHandlerPlaceholder class]])
            return;

        dispatch_async(dispatch_get_main_queue(), ^{
            [placeholder notifyOriginalDeviceDidBecomeAvailable];
        });
    });

    if([handler isKindOfClass:[OEMultiHIDDeviceHandler class]]) {
        [handler setDeviceIdentifier:++_lastAttributedMultiDeviceIdentifier];
        [_multiDeviceHandlers addObject:handler];

        for(OEDeviceHandler *subhandler in [(OEMultiHIDDeviceHandler *)handler subdeviceHandlers])
            [self OE_addDeviceHandler:subhandler];

        return;
    }

    if([handler isKeyboardDevice]) {
        [handler setDeviceIdentifier:++_lastAttributedKeyboardIdentifier];
        [self willChangeValueForKey:@"keyboardDeviceHandlers"];
        [_keyboardHandlers addObject:handler];
        [self didChangeValueForKey:@"keyboardDeviceHandlers"];
    } else {
        [handler setDeviceIdentifier:++_lastAttributedDeviceIdentifier];
        [self willChangeValueForKey:@"controllerDeviceHandlers"];
        [_deviceHandlers addObject:handler];
        [self didChangeValueForKey:@"controllerDeviceHandlers"];
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:OEDeviceManagerDidAddDeviceHandlerNotification object:self userInfo:@{ OEDeviceManagerDeviceHandlerUserInfoKey : handler }];
}

- (BOOL)OE_hasDeviceHandlerForDeviceRef:(IOHIDDeviceRef)deviceRef
{
    __block BOOL didFoundDevice = NO;
    [self OE_enumerateDevicesUsingBlock:^(OEDeviceHandler *handler, BOOL *stop) {
        if(![handler isKindOfClass:[OEHIDDeviceHandler class]] || [(OEHIDDeviceHandler *)handler device] != deviceRef)
            return;

        didFoundDevice = YES;
        *stop = YES;
    }];

    return didFoundDevice;
}

- (void)OE_removeDeviceHandler:(__kindof OEDeviceHandler *)handler
{
    dispatch_barrier_async(_uniqueIdentifiersToDeviceHandlersQueue, ^{
        [self->_uniqueIdentifiersToDeviceHandlers removeObjectForKey:handler.uniqueIdentifier];
    });

    if([handler isKindOfClass:[OEMultiHIDDeviceHandler class]]) {
        if(![_multiDeviceHandlers containsObject:handler])
            return;

        for(OEDeviceHandler *subhandler in [(OEMultiHIDDeviceHandler *)handler subdeviceHandlers])
            [self OE_addDeviceHandler:subhandler];

        [_multiDeviceHandlers removeObject:handler];

        [(OEMultiHIDDeviceHandler *)handler disconnect];

        return;
    }

    if([handler isKeyboardDevice]) {
        if(![_keyboardHandlers containsObject:handler])
            return;

        [self willChangeValueForKey:@"keyboardDeviceHandlers"];
        [_keyboardHandlers removeObject:handler];
        [self didChangeValueForKey:@"keyboardDeviceHandlers"];
    } else {
        if(![_deviceHandlers containsObject:handler])
            return;

        [self willChangeValueForKey:@"controllerDeviceHandlers"];
        [_deviceHandlers removeObject:handler];
        [self didChangeValueForKey:@"controllerDeviceHandlers"];
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:OEDeviceManagerDidRemoveDeviceHandlerNotification object:self userInfo:@{ OEDeviceManagerDeviceHandlerUserInfoKey : handler }];

    [(OEDeviceHandler *)handler disconnect];
}

- (void)OE_wiimoteDeviceDidDisconnect:(NSNotification *)notification
{
    [self OE_removeDeviceHandler:[notification object]];
}

#pragma mark - Wiimote methods

- (BOOL)isBluetoothEnabled
{
    BOOL powered = NO;
    IOBluetoothHostController *controller = [IOBluetoothHostController defaultController];
    
    if (controller != nil)
        powered = ([controller powerState] == kBluetoothHCIPowerStateON);

    return powered;
}

- (void)startWiimoteSearch;
{
    @synchronized(self) {
        //NSLog(@"Searching for Wiimotes");

        _inquiry = [IOBluetoothDeviceInquiry inquiryWithDelegate:self];
        [_inquiry setInquiryLength:3];
        [_inquiry setUpdateNewDeviceNames:YES];

        IOReturn status = [_inquiry start];
        if(status == kIOReturnSuccess)
            return;

        [_inquiry setDelegate:nil];
        _inquiry = nil;
        NSLog(@"Error: Inquiry did not start, error %d", status);
    }
}

- (void)stopWiimoteSearch;
{
    @synchronized(self) {
        [_inquiry stop];
        [_inquiry setDelegate:nil];
        _inquiry = nil;
    }
}

#pragma mark - IOBluetoothDeviceInquiry Delegates

- (void)deviceInquiryDeviceFound:(IOBluetoothDeviceInquiry *)sender device:(IOBluetoothDevice *)device
{
    //NSLog(@"%@ %@", NSStringFromSelector(_cmd), device);
    // We do not stop the inquiry here because we want to find multiple Wii Remotes, and also because
    // our search criteria is wide, and we may find non-Wiimotes.
}

- (void)deviceInquiryComplete:(IOBluetoothDeviceInquiry *)sender error:(IOReturn)error aborted:(BOOL)aborted
{
    //NSLog(@"Devices: %@ Error: %d, Aborted: %s", [sender foundDevices], error, BOOL_STR(aborted));

    [[sender foundDevices] enumerateObjectsUsingBlock:^(IOBluetoothDevice *obj, NSUInteger idx, BOOL *stop) {
        // Check to make sure BT device name has Wiimote prefix. Note that there are multiple
        // possible device names ("Nintendo RVL-CNT-01" and "Nintendo RVL-CNT-01-TR" at the
        // time of writing), so we don't do an exact string match.
        if(![OEWiimoteHIDDeviceHandler canHandleDeviceWithName:[obj name]])
            return;

        [obj openConnection];
        if([obj isPaired])
            return;
        
        IOBluetoothDevicePair *pair = [IOBluetoothDevicePair pairWithDevice:obj];
        [pair setDelegate:self];
        [pair start];
    }];
}

#pragma mark - IOBluetoothPairDelegate

- (void)devicePairingPINCodeRequest:(IOBluetoothDevicePair*)sender
{
    NSLog(@"Attempting pair");
    NSString *localAddress = [[[IOBluetoothHostController defaultController] addressAsString] uppercaseString];
    NSString *remoteAddress = [[[sender device] addressString] uppercaseString];

    BluetoothPINCode code;
    NSScanner *scanner = [NSScanner scannerWithString:[sender attemptedHostToDevice]?localAddress:remoteAddress];
    int byte = 5;
    while(![scanner isAtEnd]) {
        unsigned int data;
        [scanner scanHexInt:&data];
        code.data[byte] = data;
        [scanner scanUpToCharactersFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"] intoString:nil];
        byte--;
    }

    [sender replyPINCode:6 PINCode:&code];
}

- (void)devicePairingFinished:(IOBluetoothDevicePair*)sender error:(IOReturn)error
{
    if(error == kIOReturnSuccess)
        return;

    if(![sender attemptedHostToDevice]) {
        NSLog(@"Pairing failed, attempting inverse");
        IOBluetoothDevicePair *pair = [IOBluetoothDevicePair pairWithDevice:[sender device]];
        [[sender device] openConnection];
        [pair setAttemptedHostToDevice:YES];
        [pair setDelegate:self];
        [pair start];
    } else
        NSLog(@"Couldn't pair, what gives?");

    NSLog(@"Pairing finished %@: %x", sender, error);
}

@end

@implementation _OEDeviceManagerEventMonitor

+ (instancetype)monitorWithGlobalMonitorHandler:(BOOL(^)(OEDeviceHandler *handler, OEHIDEvent *event))handler
{
    _OEDeviceManagerEventMonitor *monitor = [[self alloc] init];
    [monitor setGlobalMonitor:handler];
    return monitor;
}

+ (instancetype)monitorWithEventMonitorHandler:(void(^)(OEDeviceHandler *handler, OEHIDEvent *event))handler
{
    _OEDeviceManagerEventMonitor *monitor = [[self alloc] init];
    [monitor setEventMonitor:handler];
    return monitor;
}

- (void)dealloc
{
    [[OEDeviceManager sharedDeviceManager] removeMonitor:self];
}

@end

#pragma mark - HIDManager Callbacks

static void OEHandle_DeviceMatchingCallback(void *inContext, IOReturn inResult, void *inSender, IOHIDDeviceRef inIOHIDDeviceRef)
{
    //NSLog(@"Found device: %s( context: %p, result: %#x, sender: %p, device: %p ).\n", __PRETTY_FUNCTION__, inContext, inResult, inSender, inIOHIDDeviceRef);

    if([(__bridge OEDeviceManager *)inContext OE_hasDeviceHandlerForDeviceRef:inIOHIDDeviceRef]) {
        NSLog(@"Device %@ is already being handled", inIOHIDDeviceRef);
        return;
    }
    
    CFTypeRef locid = IOHIDDeviceGetProperty(inIOHIDDeviceRef, CFSTR(kIOHIDLocationIDKey));
    CFTypeRef prodkey = IOHIDDeviceGetProperty(inIOHIDDeviceRef, CFSTR(kIOHIDProductKey));
    CFTypeRef vid = IOHIDDeviceGetProperty(inIOHIDDeviceRef, CFSTR(kIOHIDVendorIDKey));
    CFTypeRef pid = IOHIDDeviceGetProperty(inIOHIDDeviceRef, CFSTR(kIOHIDProductIDKey));
    BOOL touchbar = NO;
    
    if(locid == NULL) {
        NSLog(@"Device %p does not have a location ID", inIOHIDDeviceRef);
        if (prodkey == NULL) {
            NSLog(@"Device %p does not have a product name.", inIOHIDDeviceRef);
            if ([@(OETouchbarHIDDeviceVID) isEqual:(__bridge id)(vid)] &&
                [@(OETouchbarHIDDevicePID) isEqual:(__bridge id)(pid)]) {
                touchbar = YES;
                prodkey = @"Touchbar (probably)";
            } else {
                NSLog(@"Device does not look like a touchbar; discarding %@", inIOHIDDeviceRef);
                return;
            }
        }
    }

    if(IOHIDDeviceOpen(inIOHIDDeviceRef, kIOHIDOptionsTypeNone) != kIOReturnSuccess) {
        NSLog(@"%s: failed to open device at %p", __FUNCTION__, inIOHIDDeviceRef);
        return;
    }

    NSLog(@"Found Device %p: %@", inIOHIDDeviceRef, prodkey);

    //add a OEHIDDeviceHandler for our HID device
    [(__bridge OEDeviceManager *)inContext OE_addDeviceHandlerForDeviceRef:inIOHIDDeviceRef couldBeTheTouchbar:touchbar];
}

NS_ASSUME_NONNULL_END
