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

#import <Cocoa/Cocoa.h>
#import <OpenEmuSystem/OEDeviceHandler.h>
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/hid/IOHIDUsageTables.h>
#import <ForceFeedback/ForceFeedback.h>

NS_ASSUME_NONNULL_BEGIN

@protocol OEHIDDeviceParser;

@interface OEHIDDeviceHandler : OEDeviceHandler

+ (id<OEHIDDeviceParser>)deviceParser;

+ (BOOL)canHandleDevice:(IOHIDDeviceRef)device;

/** Whether a device is keyboard-only, i.e. conforms to the Keyboard usage
 *  and does not also conform to GamePad or Joystick. A HID conforming to
 *  Keyboard as well as GamePad/Joystick (e.g. some Bluetooth Xbox
 *  controllers) is not keyboard-only, and must be routed through the
 *  controller parser rather than treated as a keyboard. */
+ (BOOL)deviceIsKeyboardOnly:(IOHIDDeviceRef)device;

- (instancetype)initWithDeviceDescription:(nullable OEDeviceDescription *)deviceDescription NS_UNAVAILABLE;
- (instancetype)initWithIOHIDDevice:(IOHIDDeviceRef)aDevice deviceDescription:(nullable OEDeviceDescription *)deviceDescription NS_DESIGNATED_INITIALIZER;

@property(readonly) IOHIDDeviceRef device;
@property(readonly) BOOL isUSBDevice;
@property(readonly) NSNumber *interfaceNumber;

- (void)dispatchEvent:(OEHIDEvent *)event;

- (OEHIDEvent *)eventWithHIDValue:(IOHIDValueRef)aValue;
- (void)dispatchEventWithHIDValue:(IOHIDValueRef)aValue;
- (void)dispatchFunctionKeyEventWithHIDValue:(IOHIDValueRef)aValue;
- (io_service_t)serviceRef;

- (void)forceFeedbackWithStrongIntensity:(CGFloat)strongIntensity weakIntensity:(CGFloat)weakIntensity;
@property(readonly) BOOL supportsForceFeedback;
- (void)enableForceFeedback;
- (void)disableForceFeedback;

/** The CFRunLoop where the HID report callbacks are called.
 *  @discussion The default RunLoop is the main RunLoop.
 *  @note If a custom device handler needs events to be dispatched to a
 *     different runloop, it shall override: (1) this property (2) the
 *     -setUpCallbacks method (3) the -dispatchEvent: method or,
 *     alternatively, the -dispatchEventWithHIDValue: and the
 *     -dispatchFunctionKeyEventWithHIDValue: methods (for keyboards).
 *  @warning This reference to eventRunLoop *must absolutely be kept alive as
 *     long as the device exists*. Otherwise, the HID Manager will eventually
 *     crash, *even if the device is unscheduled from the runloop*.
 *     Practically, this means that you must retain the eventRunLoop, and
 *     release it in the -dealloc method. */
@property(readonly) CFRunLoopRef eventRunLoop;

/** The input value matching properties used to whitelist the HID elements
 *  that deliver reports for this device.
 *  @discussion Override this method to add usage pages that a specific device
 *     needs. The default list covers the standard game controller pages. */
- (NSArray<NSDictionary<NSString *, id> *> *)inputValueMatchingProperties;

/** Registers the callbacks used for receiving HID reports from the device.
 *  @note If you override eventRunLoop, override this method to create
 *     the thread which will receive the events to ensure that the
 *     newly created CFRunLoop doesn't terminate immediately due to a
 *     lack of registered event sources. */
- (void)setUpCallbacks;

@end

@protocol OEHIDDeviceParser <NSObject>
- (OEHIDDeviceHandler *)deviceHandlerForIOHIDDevice:(IOHIDDeviceRef)aDevice;
@end

NS_ASSUME_NONNULL_END
