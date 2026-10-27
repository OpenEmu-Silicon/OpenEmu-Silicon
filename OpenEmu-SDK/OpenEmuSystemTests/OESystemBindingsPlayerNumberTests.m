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

@interface OETestKeyboardHandler : OEDeviceHandler
@end

@implementation OETestKeyboardHandler

- (BOOL)isKeyboardDevice
{
    return YES;
}

@end

@interface OETestPlayerBindingsChangeCounter : NSObject
@property NSUInteger count;
@end

@implementation OETestPlayerBindingsChangeCounter

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context
{
    self.count++;
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

- (void)assertPlayers:(NSArray<OEDeviceHandler *> *)handlers
{
    [handlers enumerateObjectsUsingBlock:^(OEDeviceHandler *handler, NSUInteger idx, BOOL *stop) {
        NSUInteger player = idx + 1;
        XCTAssertEqual([self->_bindings playerForDeviceHandler:handler], player);
        if(player <= [self->_bindings numberOfPlayers])
            XCTAssertEqual([[self->_bindings devicePlayerBindingsForPlayer:player] deviceHandler], handler);
    }];

    for(NSUInteger player = [handlers count] + 1; player <= [_bindings numberOfPlayers]; player++)
        XCTAssertNil([_bindings devicePlayerBindingsForPlayer:player]);
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

- (void)testDisconnectingLastControllerKeepsOtherPlayers
{
    OEDeviceHandler *first = [self connectController];
    OEDeviceHandler *second = [self connectController];
    OEDeviceHandler *third = [self connectController];

    [_bindings OE_didRemoveDeviceHandler:third];

    [self assertPlayers:@[first, second]];
    XCTAssertEqual([_bindings playerForDeviceHandler:third], 0);
}

- (void)testDisconnectingMiddleControllerMovesOnlyLaterPlayers
{
    OEDeviceHandler *first = [self connectController];
    OEDeviceHandler *second = [self connectController];
    OEDeviceHandler *third = [self connectController];

    [_bindings OE_didRemoveDeviceHandler:second];

    [self assertPlayers:@[first, third]];
    XCTAssertEqual([_bindings playerForDeviceHandler:second], 0);
}

- (void)testDisconnectingAllControllersLeavesNoPlayers
{
    OEDeviceHandler *first = [self connectController];
    OEDeviceHandler *second = [self connectController];

    [_bindings OE_didRemoveDeviceHandler:first];
    [_bindings OE_didRemoveDeviceHandler:second];

    [self assertPlayers:@[]];

    OEDeviceHandler *third = [self connectController];
    [self assertPlayers:@[third]];
}

- (void)testReconnectedControllerTakesNextPlayer
{
    OEDeviceHandler *first = [self connectController];
    OEDeviceHandler *second = [self connectController];

    [_bindings OE_didRemoveDeviceHandler:first];
    OEDeviceHandler *reconnected = [self connectController];

    [self assertPlayers:@[second, reconnected]];
}

- (void)testSeveralDisconnectsDuringGameAreFilledWhenGameEnds
{
    OEDeviceHandler *first = [self connectController];
    OEDeviceHandler *second = [self connectController];
    OEDeviceHandler *third = [self connectController];
    OEDeviceHandler *fourth = [self connectController];

    OETestBindingsObserver *game = [[OETestBindingsObserver alloc] init];
    [_bindings addBindingsObserver:game];

    [_bindings OE_didRemoveDeviceHandler:first];
    [_bindings OE_didRemoveDeviceHandler:third];

    XCTAssertNil([_bindings devicePlayerBindingsForPlayer:1]);
    XCTAssertEqual([_bindings playerForDeviceHandler:second], 2);
    XCTAssertNil([_bindings devicePlayerBindingsForPlayer:3]);
    XCTAssertEqual([_bindings playerForDeviceHandler:fourth], 4);

    [_bindings removeBindingsObserver:game];

    [self assertPlayers:@[second, fourth]];
}

- (void)testControllerConnectedDuringGameFillsEmptyPlayer
{
    OEDeviceHandler *first = [self connectController];
    OEDeviceHandler *second = [self connectController];

    OETestBindingsObserver *game = [[OETestBindingsObserver alloc] init];
    [_bindings addBindingsObserver:game];

    [_bindings OE_didRemoveDeviceHandler:first];
    OEDeviceHandler *third = [self connectController];

    [self assertPlayers:@[third, second]];

    [_bindings removeBindingsObserver:game];

    [self assertPlayers:@[third, second]];
}

- (void)testPlayersMoveOnlyWhenLastGameOfSystemEnds
{
    OEDeviceHandler *first = [self connectController];
    OEDeviceHandler *second = [self connectController];

    OETestBindingsObserver *firstGame = [[OETestBindingsObserver alloc] init];
    OETestBindingsObserver *secondGame = [[OETestBindingsObserver alloc] init];
    [_bindings addBindingsObserver:firstGame];
    [_bindings addBindingsObserver:secondGame];

    [_bindings OE_didRemoveDeviceHandler:first];

    [_bindings removeBindingsObserver:firstGame];
    XCTAssertEqual([_bindings playerForDeviceHandler:second], 2);
    XCTAssertNil([_bindings devicePlayerBindingsForPlayer:1]);

    [_bindings removeBindingsObserver:secondGame];
    [self assertPlayers:@[second]];
}

- (void)testDisconnectWhileIdleAfterGameDoesNotNeedGameToEndAgain
{
    OEDeviceHandler *first = [self connectController];
    OEDeviceHandler *second = [self connectController];
    OEDeviceHandler *third = [self connectController];

    OETestBindingsObserver *game = [[OETestBindingsObserver alloc] init];
    [_bindings addBindingsObserver:game];
    [_bindings OE_didRemoveDeviceHandler:first];
    [_bindings removeBindingsObserver:game];

    [self assertPlayers:@[second, third]];

    [_bindings OE_didRemoveDeviceHandler:second];

    [self assertPlayers:@[third]];
}

- (void)testManualPlayerAssignmentSurvivesDisconnect
{
    OEDeviceHandler *first = [self connectController];
    OEDeviceHandler *second = [self connectController];
    OEDeviceHandler *third = [self connectController];

    [_bindings setDeviceHandler:second forPlayer:4];
    XCTAssertEqual([_bindings playerForDeviceHandler:second], 4);
    XCTAssertNil([_bindings devicePlayerBindingsForPlayer:2]);

    [_bindings OE_didRemoveDeviceHandler:first];

    XCTAssertEqual([_bindings playerForDeviceHandler:second], 4);
    XCTAssertEqual([_bindings playerForDeviceHandler:third], 1);
    XCTAssertEqualObjects([_bindings deviceHandlerForPlayer:1], third);
    XCTAssertNil([_bindings devicePlayerBindingsForPlayer:2]);
    XCTAssertNil([_bindings devicePlayerBindingsForPlayer:3]);
    XCTAssertEqualObjects([_bindings deviceHandlerForPlayer:4], second);
}

- (void)testManualReassignmentDuringGameIsNotUndoneWhenGameEnds
{
    OEDeviceHandler *first = [self connectController];
    OEDeviceHandler *second = [self connectController];
    OEDeviceHandler *third = [self connectController];

    OETestBindingsObserver *game = [[OETestBindingsObserver alloc] init];
    [_bindings addBindingsObserver:game];

    [_bindings OE_didRemoveDeviceHandler:first];

    XCTAssertNil([_bindings devicePlayerBindingsForPlayer:1]);
    XCTAssertEqual([_bindings playerForDeviceHandler:second], 2);
    XCTAssertEqual([_bindings playerForDeviceHandler:third], 3);

    [_bindings setDeviceHandler:third forPlayer:4];
    XCTAssertEqual([_bindings playerForDeviceHandler:third], 4);

    [_bindings removeBindingsObserver:game];

    XCTAssertEqual([_bindings playerForDeviceHandler:second], 2);
    XCTAssertEqual([_bindings playerForDeviceHandler:third], 4);
    XCTAssertNil([_bindings devicePlayerBindingsForPlayer:1]);
}

- (void)testDisconnectingManuallyAssignedControllerFreesItsPlayer
{
    OEDeviceHandler *first = [self connectController];
    OEDeviceHandler *second = [self connectController];
    OEDeviceHandler *third = [self connectController];

    [_bindings setDeviceHandler:second forPlayer:4];
    XCTAssertEqual([_bindings playerForDeviceHandler:second], 4);

    [_bindings OE_didRemoveDeviceHandler:second];

    [self assertPlayers:@[first, third]];
    XCTAssertNil([_bindings devicePlayerBindingsForPlayer:4]);
}

- (void)testDisconnectingOneOfTwoManuallyAssignedControllersKeepsTheOther
{
    OEDeviceHandler *first = [self connectController];
    OEDeviceHandler *second = [self connectController];

    [_bindings setDeviceHandler:first forPlayer:2];
    XCTAssertEqual([_bindings playerForDeviceHandler:first], 2);
    XCTAssertEqual([_bindings playerForDeviceHandler:second], 1);

    [_bindings OE_didRemoveDeviceHandler:second];

    XCTAssertEqual([_bindings playerForDeviceHandler:first], 2);
    XCTAssertNil([_bindings devicePlayerBindingsForPlayer:1]);
}

- (void)testControllersAbovePlayerLimitMoveIntoFreedPlayers
{
    NSMutableArray<OEDeviceHandler *> *handlers = [NSMutableArray array];
    for(NSUInteger i = 0; i < [_bindings numberOfPlayers] + 1; i++)
        [handlers addObject:[self connectController]];

    OEDeviceHandler *extra = [handlers lastObject];
    XCTAssertEqual([_bindings playerForDeviceHandler:extra], [_bindings numberOfPlayers] + 1);
    XCTAssertNil([_bindings devicePlayerBindingsForPlayer:[_bindings numberOfPlayers] + 1]);

    [_bindings OE_didRemoveDeviceHandler:handlers[0]];
    [handlers removeObjectAtIndex:0];

    [self assertPlayers:handlers];
    XCTAssertEqual([[_bindings devicePlayerBindingsForPlayer:[_bindings numberOfPlayers]] deviceHandler], extra);
}

- (void)testKeyboardDevicesDoNotChangePlayers
{
    OEDeviceHandler *first = [self connectController];
    OEDeviceHandler *second = [self connectController];

    OETestKeyboardHandler *keyboard = [[OETestKeyboardHandler alloc] initWithDeviceDescription:nil];
    XCTAssertTrue([_bindings OE_didAddDeviceHandler:keyboard]);
    XCTAssertEqual([_bindings playerForDeviceHandler:keyboard], 0);
    [self assertPlayers:@[first, second]];

    [_bindings OE_didRemoveDeviceHandler:keyboard];
    [self assertPlayers:@[first, second]];
}

- (void)testPlayerChangeIsSentToObserversOfDevicePlayerBindings
{
    OEDeviceHandler *first = [self connectController];
    OEDeviceHandler *second = [self connectController];
    OEDeviceHandler *third = [self connectController];

    OETestPlayerBindingsChangeCounter *counter = [[OETestPlayerBindingsChangeCounter alloc] init];
    [_bindings addObserver:counter forKeyPath:@"devicePlayerBindings" options:0 context:NULL];

    [_bindings OE_didRemoveDeviceHandler:third];
    NSUInteger changesWithoutMove = counter.count;

    counter.count = 0;
    [_bindings OE_didRemoveDeviceHandler:first];
    NSUInteger changesWithMove = counter.count;

    [_bindings removeObserver:counter forKeyPath:@"devicePlayerBindings"];

    XCTAssertEqual(changesWithoutMove, 1);
    XCTAssertEqual(changesWithMove, 2);
    [self assertPlayers:@[second]];
}

@end
