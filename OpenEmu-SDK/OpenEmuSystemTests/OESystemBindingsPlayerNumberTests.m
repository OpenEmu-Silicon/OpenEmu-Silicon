// Copyright (c) 2026, OpenEmu Team
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

#import <XCTest/XCTest.h>
#import <OpenEmuSystem/OpenEmuSystem.h>

#import "../OpenEmuSystem/OEBindingsController_Internal.h"
#import "../OpenEmuSystem/OEControllerDescription_Internal.h"

@interface OESystemController ()
- (BOOL)OE_isBundleValid:(NSBundle *)aBundle forClass:(Class)aClass;
- (void)OE_setUpControllerPreferencesKeys;
@end

@interface OETestSystemController : OESystemController
@end

@implementation OETestSystemController

- (BOOL)OE_isBundleValid:(NSBundle *)aBundle forClass:(Class)aClass
{
    return YES;
}

- (void)OE_setUpControllerPreferencesKeys
{
}

- (NSUInteger)numberOfPlayers
{
    return 4;
}

@end

@interface OETestBindingsObserver : NSObject <OESystemBindingsObserver>
@end

@implementation OETestBindingsObserver

- (void)systemBindings:(OESystemBindings *)sender didSetEvent:(OEHIDEvent *)event forBinding:(__kindof OEBindingDescription *)bindingDescription playerNumber:(NSUInteger)playerNumber
{
}

- (void)systemBindings:(OESystemBindings *)sender didUnsetEvent:(OEHIDEvent *)event forBinding:(__kindof OEBindingDescription *)bindingDescription playerNumber:(NSUInteger)playerNumber
{
}

@end

@interface OESystemBindingsPlayerNumberTests : XCTestCase
@end

@implementation OESystemBindingsPlayerNumberTests
{
    OETestSystemController *_systemController;
    OESystemBindings *_bindings;
    OEDeviceDescription *_deviceDescription;
}

- (void)setUp
{
    _systemController = [[OETestSystemController alloc] initWithBundle:[NSBundle bundleForClass:[self class]]];
    XCTAssertNotNil(_systemController);

    _bindings = [[OESystemBindings alloc] OE_initWithBindingsController:nil systemController:_systemController dictionaryRepresentation:@{}];

    OEControllerDescription *controllerDescription =
        [OEControllerDescription OE_controllerDescriptionForVendorID:0xFFFE
                                                             productID:0xFFFE
                                                               product:@"Unit Test Player Controller"];
    _deviceDescription = [controllerDescription deviceDescriptionForVendorID:0xFFFE productID:0xFFFE cookie:0];
}

- (OEDeviceHandler *)connectController
{
    OEDeviceHandler *handler = [[OEDeviceHandler alloc] initWithDeviceDescription:_deviceDescription];
    XCTAssertTrue([_bindings OE_didAddDeviceHandler:handler]);
    return handler;
}

- (void)testControllersConnectedWhileIdleTakeTheFirstPlayers
{
    OEDeviceHandler *first = [self connectController];
    OEDeviceHandler *second = [self connectController];

    XCTAssertEqual([_bindings playerForDeviceHandler:first], 1);
    XCTAssertEqual([_bindings playerForDeviceHandler:second], 2);
}

- (void)testDisconnectingWhileIdleMovesRemainingControllersUp
{
    OEDeviceHandler *first = [self connectController];
    OEDeviceHandler *second = [self connectController];
    OEDeviceHandler *third = [self connectController];

    [_bindings OE_didRemoveDeviceHandler:first];

    XCTAssertEqual([_bindings playerForDeviceHandler:second], 1);
    XCTAssertEqual([_bindings playerForDeviceHandler:third], 2);
    XCTAssertEqualObjects([_bindings deviceHandlerForPlayer:1], second);
    XCTAssertEqualObjects([_bindings deviceHandlerForPlayer:2], third);
    XCTAssertNil([_bindings devicePlayerBindingsForPlayer:3]);

    OEDeviceHandler *fourth = [self connectController];
    XCTAssertEqual([_bindings playerForDeviceHandler:fourth], 3);
}

- (void)testDisconnectingDuringGameKeepsPlayersUntilGameEnds
{
    OEDeviceHandler *first = [self connectController];
    OEDeviceHandler *second = [self connectController];

    OETestBindingsObserver *game = [[OETestBindingsObserver alloc] init];
    [_bindings addBindingsObserver:game];

    [_bindings OE_didRemoveDeviceHandler:first];

    XCTAssertEqual([_bindings playerForDeviceHandler:second], 2);
    XCTAssertNil([_bindings devicePlayerBindingsForPlayer:1]);

    [_bindings removeBindingsObserver:game];

    XCTAssertEqual([_bindings playerForDeviceHandler:second], 1);
    XCTAssertNil([_bindings devicePlayerBindingsForPlayer:2]);
}

- (void)testManualPlayerAssignmentIsKeptWithoutDisconnect
{
    OEDeviceHandler *handler = [self connectController];

    [_bindings setDeviceHandler:handler forPlayer:2];
    XCTAssertEqual([_bindings playerForDeviceHandler:handler], 2);

    OETestBindingsObserver *game = [[OETestBindingsObserver alloc] init];
    [_bindings addBindingsObserver:game];
    [_bindings removeBindingsObserver:game];

    XCTAssertEqual([_bindings playerForDeviceHandler:handler], 2);
}

@end
