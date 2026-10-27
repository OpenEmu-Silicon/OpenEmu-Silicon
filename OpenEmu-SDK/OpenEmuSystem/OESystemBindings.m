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

#import "OESystemBindings.h"

#import "OEBindingsController_Internal.h"
#import "OEControlDescription.h"
#import "OEControllerDescription.h"
#import "OEDeviceDescription.h"
#import "OEDeviceHandler.h"
#import "OEHIDDeviceHandler.h"
#import "OEHIDEvent.h"
#import "OEHIDEvent_Internal.h"
#import "OEKeyBindingDescription.h"
#import "OESystemController.h"

NS_ASSUME_NONNULL_BEGIN

static NSString *const _OEKeyboardPlayerBindingRepresentationsKey = @"keyboardPlayerBindings";
static NSString *const _OEControllerBindingRepresentationsKey = @"controllerBindings";

NSString *const OEGlobalButtonSaveState         = @"OEGlobalButtonSaveState";
NSString *const OEGlobalButtonLoadState         = @"OEGlobalButtonLoadState";
NSString *const OEGlobalButtonQuickSave         = @"OEGlobalButtonQuickSave";
NSString *const OEGlobalButtonQuickLoad         = @"OEGlobalButtonQuickLoad";
NSString *const OEGlobalButtonFullScreen        = @"OEGlobalButtonFullScreen";
NSString *const OEGlobalButtonMute              = @"OEGlobalButtonMute";
NSString *const OEGlobalButtonVolumeDown        = @"OEGlobalButtonVolumeDown";
NSString *const OEGlobalButtonVolumeUp          = @"OEGlobalButtonVolumeUp";
NSString *const OEGlobalButtonStop              = @"OEGlobalButtonStop";
NSString *const OEGlobalButtonReset             = @"OEGlobalButtonReset";
NSString *const OEGlobalButtonPause             = @"OEGlobalButtonPause";
NSString *const OEGlobalButtonRewind            = @"OEGlobalButtonRewind";
NSString *const OEGlobalButtonFastForward       = @"OEGlobalButtonFastForward";
NSString *const OEGlobalButtonSlowMotion        = @"OEGlobalButtonSlowMotion";
NSString *const OEGlobalButtonStepFrameBackward = @"OEGlobalButtonStepFrameBackward";
NSString *const OEGlobalButtonStepFrameForward  = @"OEGlobalButtonStepFrameForward";
NSString *const OEGlobalButtonNextDisplayMode   = @"OEGlobalButtonNextDisplayMode";
NSString *const OEGlobalButtonLastDisplayMode   = @"OEGlobalButtonLastDisplayMode";
NSString *const OEGlobalButtonScreenshot        = @"OEGlobalButtonScreenshot";
NSString *const OEGlobalButtonRapidFireToggle   = @"OEGlobalButtonRapidFireToggle";
NSString *const OEGlobalButtonRapidFireClear    = @"OEGlobalButtonRapidFireClear";
NSString *const OEGlobalButtonRapidFireReset    = @"OEGlobalButtonRapidFireReset";

@interface OEHIDEvent ()
- (OEHIDEvent *)OE_eventWithDeviceHandler:(OEDeviceHandler *)aDeviceHandler;
@end

@interface OESystemBindings ()
{
    NSMutableSet<id<OESystemBindingsObserver>> *_bindingsObservers;

    NSMutableDictionary<NSNumber *, OEKeyboardPlayerBindings *> *_keyboardPlayerBindings;

    // Map devices identifiers to an array of saved bindings
    // Each object in the array represent settings in the order they were added to the app
    // When a new device with the same manufacturer is plugged in, it inherits the settings
    // of the player they were first setup or the first player if the device doesn't exists
    NSMutableDictionary<id, NSMutableArray *> *_parsedManufacturerBindings;
    NSMutableDictionary<NSString *, NSArray<NSDictionary<NSString *, id> *> *> *_unparsedManufactuerBindings;
    NSMutableDictionary<OEDeviceHandler *, OEDevicePlayerBindings *> *_deviceHandlersToBindings;

    NSMutableDictionary<NSNumber *, OEDevicePlayerBindings *> *_devicePlayerBindings;

    NSMutableDictionary<NSString *, OEDevicePlayerBindings *> *_defaultDeviceBindings;

    OEDevicePlayerBindings *_emptyConfiguration;

    BOOL _needsDevicePlayerCompaction;
    NSMutableSet<OEDevicePlayerBindings *> *_manuallyAssignedBindings;
}

- (void)OE_notifyObserversDidSetEvent:(OEHIDEvent *)anEvent forBindingKey:(id)bindingKey playerNumber:(NSUInteger)playerNumber  __attribute__((nonnull));
- (void)OE_notifyObserversDidUnsetEvent:(OEHIDEvent *)anEvent forBindingKey:(id)bindingKey playerNumber:(NSUInteger)playerNumber  __attribute__((nonnull));
- (id)OE_playerBindings:(OEKeyboardPlayerBindings *)sender didSetKeyboardEvent:(OEHIDEvent *)anEvent forKey:(NSString *)keyName  __attribute__((nonnull));
- (id)OE_playerBindings:(OEDevicePlayerBindings *)sender didSetDeviceEvent:(OEHIDEvent *)anEvent forKey:(NSString *)keyName  __attribute__((nonnull));

@end

@implementation OESystemBindings

- (instancetype)OE_initWithBindingsController:(nullable OEBindingsController *)parentController systemController:(OESystemController *)aController dictionaryRepresentation:(NSDictionary *)aDictionary
{
    if(aController == nil) return nil;

    if((self = [super init]))
    {
        _parsedManufacturerBindings = [NSMutableDictionary dictionary];
        _defaultDeviceBindings      = [NSMutableDictionary dictionary];
        _deviceHandlersToBindings   = [NSMutableDictionary dictionary];

        _keyboardPlayerBindings     = [NSMutableDictionary dictionary];
        _devicePlayerBindings       = [NSMutableDictionary dictionary];
        _manuallyAssignedBindings   = [NSMutableSet        set];

        _bindingsObservers          = [NSMutableSet        set];

        _bindingsController         = parentController;
        _systemController           = aController;

        if(aDictionary != nil) [self OE_setUpKeyboardBindingsWithRepresentations:aDictionary[_OEKeyboardPlayerBindingRepresentationsKey]];
        else                   [self OE_registerDefaultControls:[_systemController defaultKeyboardControls]];

        _unparsedManufactuerBindings = [aDictionary[_OEControllerBindingRepresentationsKey] mutableCopy];

        _emptyConfiguration = [[OEDevicePlayerBindings alloc] OE_initWithSystemBindings:self playerNumber:0 deviceHandler:nil];
        [_emptyConfiguration OE_setBindingEvents:@{ }];
        [_emptyConfiguration OE_setBindingDescriptions:[self OE_stringValuesForBindings:nil possibleKeys:_systemController.allKeyBindingsDescriptions]];
    }

    return self;
}

#pragma mark - System Bindings general use methods

- (NSUInteger)numberOfPlayers
{
    return [_systemController numberOfPlayers];
}

#pragma mark - Parse the receiver's representation dictionaries

- (void)OE_registerDefaultControls:(NSDictionary<NSString *, NSNumber *> *)defaultControls
{
    if([defaultControls count] == 0) return;

    // We always assume player 1, if we want to have multiple players, we will have to use an NSArray instead
    OEKeyboardPlayerBindings *bindings = [self keyboardPlayerBindingsForPlayer:1];

    [defaultControls enumerateKeysAndObjectsUsingBlock:
     ^(NSString *key, NSNumber *obj, BOOL *stop)
     {
         OEHIDEvent *theEvent = [OEHIDEvent keyEventWithTimestamp:0
                                                          keyCode:[obj unsignedIntValue]
                                                            state:NSControlStateValueOn
                                                           cookie:OEUndefinedCookie];

         [bindings assignEvent:theEvent toKeyWithName:key];
     }];
}

- (void)OE_setUpKeyboardBindingsWithRepresentations:(NSArray *)representations;
{
    if(representations == nil) return;

    // Convert keyboard bindings
    _keyboardPlayerBindings = [[NSMutableDictionary alloc] initWithCapacity:[representations count]];

    [representations enumerateObjectsUsingBlock:^(NSDictionary *encoded, NSUInteger idx, BOOL *stop) {
        NSMutableDictionary *decodedBindings = [NSMutableDictionary dictionaryWithCapacity:[encoded count]];

        [encoded enumerateKeysAndObjectsUsingBlock:^(NSString *keyName, id value, BOOL *stop) {
            OEKeyBindingDescription *desc = self->_systemController.allKeyBindingsDescriptions[keyName];

            if(desc)
                decodedBindings[desc] = [OEHIDEvent eventWithDictionaryRepresentation:value];
        }];

        OEKeyboardPlayerBindings *controller = [[OEKeyboardPlayerBindings alloc] OE_initWithSystemBindings:self playerNumber:idx + 1];

        [controller OE_setBindingEvents:decodedBindings];
        [controller OE_setBindingDescriptions:[self OE_stringValuesForBindings:decodedBindings possibleKeys:self->_systemController.keyBindingsDescriptions]];

        self->_keyboardPlayerBindings[@([controller playerNumber])] = controller;
    }];
}

- (void)OE_parseDefaultControlValuesForControllerDescription:(OEControllerDescription *)controllerDescription
{
    if(_defaultDeviceBindings[[controllerDescription identifier]] != nil) return;

    NSDictionary *representation = [_systemController defaultDeviceControls][[controllerDescription identifier]];
    if(representation == nil) return;
    
    OEDevicePlayerBindings *dpb = [self OE_parsedDevicePlayerBindingsForRepresentation:representation withControllerDescription:controllerDescription];
    if (!dpb) {
        NSLog(@"Failed to parse default bindings for %@!", controllerDescription);
        return;
    }
    
    _defaultDeviceBindings[[controllerDescription identifier]] = dpb;
}

/* Returns YES if all the bindings were successfully parsed; NO if some bindings were reset because of a
 * parsing error. */
- (BOOL)OE_parseManufacturerControlValuesForDeviceDescription:(OEDeviceDescription *)deviceDescription
{
    if(_parsedManufacturerBindings[deviceDescription] != nil) return YES;

    OEControllerDescription *controllerDescription = [deviceDescription controllerDescription];
    NSString *genericDeviceIdentifier = [deviceDescription genericDeviceIdentifier];
    NSArray<NSDictionary *> *genericDeviceBindingsToParse = _unparsedManufactuerBindings[genericDeviceIdentifier];
    [_unparsedManufactuerBindings removeObjectForKey:genericDeviceIdentifier];

    if(genericDeviceBindingsToParse == nil && _parsedManufacturerBindings[controllerDescription] != nil) return YES;
    
    BOOL noErrors = YES;

    NSMutableArray<OEDevicePlayerBindings *> *parsedBindings = _parsedManufacturerBindings[controllerDescription] ? : [NSMutableArray array];

    for(NSDictionary<NSString *, id> *representation in genericDeviceBindingsToParse) {
        OEDevicePlayerBindings *dpb = [self OE_parsedDevicePlayerBindingsForRepresentation:representation withControllerDescription:controllerDescription];
        if (dpb)
            [parsedBindings addObject:dpb];
        else
            noErrors = NO;
    }

    if(![controllerDescription isGeneric])
    {
        [self OE_parseDefaultControlValuesForControllerDescription:controllerDescription];

        for(NSDictionary<NSString *, id> *representation in _unparsedManufactuerBindings[[controllerDescription identifier]]) {
            OEDevicePlayerBindings *dpb = [self OE_parsedDevicePlayerBindingsForRepresentation:representation withControllerDescription:controllerDescription];
            if (dpb)
                [parsedBindings addObject:dpb];
            else
                noErrors = NO;
        }
        [_unparsedManufactuerBindings removeObjectForKey:[controllerDescription identifier]];
        _parsedManufacturerBindings[controllerDescription] = parsedBindings;
    }

    _parsedManufacturerBindings[deviceDescription] = parsedBindings;
    return noErrors;
}

- (nullable OEDevicePlayerBindings *)OE_parsedDevicePlayerBindingsForRepresentation:(NSDictionary<NSString *, id> *)representation withControllerDescription:(OEControllerDescription *)controllerDescription
{
    __block BOOL corrupted = NO;
    
    NSMutableDictionary<OEBindingDescription *, OEControlValueDescription *> *rawBindings = [NSMutableDictionary dictionaryWithCapacity:[_systemController.allKeyBindingsDescriptions count]];
    [_systemController.allKeyBindingsDescriptions enumerateKeysAndObjectsUsingBlock:^(NSString *keyName, OEKeyBindingDescription *keyDesc, BOOL *stop) {
        id controlIdentifier = representation[keyName];
        if(controlIdentifier == nil)
            return;

        NSAssert(![controlIdentifier isKindOfClass:[NSNumber class]], @"Default for key %@ in System %@ was not converted to the new system.", keyName, [self->_systemController systemName]);

        OEControlValueDescription *controlValue = [controllerDescription controlValueDescriptionForRepresentation:controlIdentifier];
        OEHIDEvent *event = [controlValue event];

        if (controlValue == nil) {
            NSLog(@"Unknown control value for identifier: '%@' associated with key name: '%@'", controlIdentifier, keyName);
            corrupted = YES;
            *stop = YES;
            return;
        }

        if([event type] == OEHIDEventTypeHatSwitch && [keyDesc hatSwitchGroup] != nil)
        {
            // Sync the key direction with the hat switch direction, in case they're different.
            enum { NORTH, EAST, SOUTH, WEST, HAT_COUNT };
            
            OEHIDEventHatDirection direction  = [event hatDirection];
            NSUInteger     currentDir = NORTH;
            
            if(direction & OEHIDEventHatDirectionNorth) currentDir = NORTH;
            if(direction & OEHIDEventHatDirectionEast)  currentDir = EAST;
            if(direction & OEHIDEventHatDirectionSouth) currentDir = SOUTH;
            if(direction & OEHIDEventHatDirectionWest)  currentDir = WEST;
            
            keyDesc = [[keyDesc hatSwitchGroup] keys][currentDir];
        }
        
        rawBindings[[self OE_keyIdentifierForKeyDescription:keyDesc event:event]] = controlValue;
    }];
    
    if (corrupted)
        return nil;

    OEDevicePlayerBindings *controller = [[OEDevicePlayerBindings alloc] OE_initWithSystemBindings:self playerNumber:0 deviceHandler:nil];
    [controller OE_setBindingEvents:rawBindings];
    [controller OE_setBindingDescriptions:[self OE_stringValuesForBindings:rawBindings possibleKeys:_systemController.allKeyBindingsDescriptions]];

    return controller;
}

- (nullable OEDevicePlayerBindings *)OE_duplicateDevicePlayerBindings:(OEDevicePlayerBindings *)originalDevicePlayerBindings forHandler:(OEDeviceHandler *)deviceHandler
{
    if (!originalDevicePlayerBindings)
        return nil;

    NSDictionary *representation = [self OE_controllerRepresentationForDevicePlayerBindings:originalDevicePlayerBindings];
    OEDevicePlayerBindings *devicePlayerBindings = [self OE_parsedDevicePlayerBindingsForRepresentation:representation withControllerDescription:deviceHandler.deviceDescription.controllerDescription];
    if (devicePlayerBindings)
        [devicePlayerBindings OE_setDeviceHandler:deviceHandler];

    return devicePlayerBindings;
}

- (OEBindingDescription *)OE_keyIdentifierForKeyDescription:(OEKeyBindingDescription *)keyDescription event:(OEHIDEvent *)event;
{
    OEBindingDescription *insertedKey = keyDescription;
    OEHIDEventType eventType = [event type];
    if(eventType == OEHIDEventTypeAxis || eventType == OEHIDEventTypeHatSwitch)
    {
        OEKeyBindingGroupDescription *keyGroup = (eventType == OEHIDEventTypeAxis ? keyDescription.axisGroup : keyDescription.hatSwitchGroup);
        if(keyGroup != nil)
            insertedKey = [keyGroup orientedKeyGroupWithBaseKey:keyDescription];
    }

    return insertedKey;
}

#pragma mark - Construct the receiver's representation dictionaries

- (NSDictionary<NSString *, __kindof id<OEPropertyList>> *)OE_dictionaryRepresentation;
{
    NSMutableDictionary<NSString *, __kindof id<OEPropertyList>> *dictionary = [NSMutableDictionary dictionaryWithCapacity:2];

    void (^addToDictionary)(NSString *key, id value) =
    ^(NSString *key, __kindof id<OEPropertyList> value)
    {
        if(value)
            dictionary[key] = value;
    };

    addToDictionary(_OEControllerBindingRepresentationsKey, [self OE_dictionaryRepresentationForControllerBindings]);
    addToDictionary(_OEKeyboardPlayerBindingRepresentationsKey, [self OE_arrayRepresentationForKeyboardBindings]);

    return [dictionary copy];
}

- (NSDictionary<NSString *, __kindof id<OEPropertyList>> *)OE_dictionaryRepresentationForControllerBindings;
{
    NSMutableDictionary<NSString *, NSArray *> *ret = [_unparsedManufactuerBindings mutableCopy] ? : [NSMutableDictionary dictionaryWithCapacity:[_parsedManufacturerBindings count]];

    [_parsedManufacturerBindings enumerateKeysAndObjectsUsingBlock:
     ^(id description, NSArray *controllers, BOOL *stop)
     {
         BOOL isDeviceDescription = [description isKindOfClass:[OEDeviceDescription class]];
         if(   ( isDeviceDescription && ![[description controllerDescription] isGeneric])
            || (!isDeviceDescription &&   [description isGeneric]))
             return;

         NSMutableArray<NSDictionary<NSString *, id> *> *controllerRepresentations = [NSMutableArray arrayWithCapacity:[controllers count]];
         for(OEDevicePlayerBindings *controller in controllers) {
             [controllerRepresentations addObject:[self OE_controllerRepresentationForDevicePlayerBindings:controller]];
         }

         ret[[description identifier]] = controllerRepresentations;
     }];

    return ret;
}

- (NSDictionary<NSString *, id> *)OE_controllerRepresentationForDevicePlayerBindings:(OEDevicePlayerBindings *)controller
{
    NSMutableDictionary<NSString *, id> *bindingRepresentations = [NSMutableDictionary dictionary];
    [[controller bindingEvents] enumerateKeysAndObjectsUsingBlock:^(__kindof OEBindingDescription *key, OEControlValueDescription *obj, BOOL *stop) {
        NSString *saveKey = nil;
        if([key isKindOfClass:[OEKeyBindingDescription class]]) {
            saveKey = [key name];
        } else if([key isKindOfClass:[OEOrientedKeyGroupBindingDescription class]]) {
            saveKey = [[key baseKey] name];
        } else {
            NSLog(@"WARNING: Unknown Bindings key");
            NSLog(@"%@", key);
            saveKey = @"";
        }

        bindingRepresentations[saveKey] = obj.representation;
    }];

    return [bindingRepresentations copy];
}

- (NSMutableArray<NSDictionary<NSString *, __kindof id<OEPropertyList>> *> *)OE_arrayRepresentationForKeyboardBindings
{
    NSMutableArray<NSDictionary<NSString *, __kindof id<OEPropertyList>> *> *ret = [NSMutableArray arrayWithCapacity:[_keyboardPlayerBindings count]];
    NSUInteger numberOfPlayers = [self numberOfPlayers];
    NSUInteger lastValidPlayerNumber = 1;

    for(NSUInteger i = 1; i <= numberOfPlayers; i++)
    {
        NSDictionary *rawBindings = [_keyboardPlayerBindings[@(i)] bindingEvents];
        NSMutableDictionary<NSString *, __kindof id<OEPropertyList>> *bindingRepresentations = [NSMutableDictionary dictionaryWithCapacity:[rawBindings count]];
        [rawBindings enumerateKeysAndObjectsUsingBlock:
         ^(OEKeyBindingDescription *key, OEHIDEvent *event, BOOL *stop)
         {
             bindingRepresentations[[key name]] = event.dictionaryRepresentation;
         }];

        ret[[ret count]] = bindingRepresentations;

        if(rawBindings != nil) lastValidPlayerNumber = i;
    }

    if(lastValidPlayerNumber < numberOfPlayers)
        [ret removeObjectsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(lastValidPlayerNumber, numberOfPlayers - lastValidPlayerNumber)]];

    return ret;
}

#pragma mark -
#pragma mark Player Bindings Controller Representation

- (NSUInteger)playerNumberForEvent:(OEHIDEvent *)anEvent;
{
    if([anEvent type] == OEHIDEventTypeKeyboard || [anEvent deviceHandler] == nil) return 0;

    OEDeviceHandler *handler = [anEvent deviceHandler];

    return [[[_devicePlayerBindings keysOfEntriesPassingTest:
              ^ BOOL (NSNumber *key, OEDevicePlayerBindings *obj, BOOL *stop)
              {
                  if([obj deviceHandler] == handler)
                  {
                      *stop = YES;
                      return YES;
                  }

                  return NO;
              }] anyObject] integerValue];
}

- (nullable OEDevicePlayerBindings *)devicePlayerBindingsForPlayer:(NSUInteger)playerNumber;
{
    if(playerNumber == 0 || playerNumber > [self numberOfPlayers]) return nil;

    return _devicePlayerBindings[@(playerNumber)];
}

- (nullable OEKeyboardPlayerBindings *)keyboardPlayerBindingsForPlayer:(NSUInteger)playerNumber;
{
    if(playerNumber == 0 || playerNumber > [self numberOfPlayers]) return nil;

    OEKeyboardPlayerBindings *ret = _keyboardPlayerBindings[@(playerNumber)];

    if(ret == nil)
    {
        [self willChangeValueForKey:@"keyboardPlayerBindings"];
        ret = [[OEKeyboardPlayerBindings alloc] OE_initWithSystemBindings:self playerNumber:playerNumber];

        // At this point, if a keyboard bindings doesn't exist, it means none were saved for this player
        [ret OE_setBindingDescriptions:[self OE_stringValuesForBindings:nil possibleKeys:_systemController.keyBindingsDescriptions]];
        [ret OE_setBindingEvents:@{ }];

        _keyboardPlayerBindings[@(playerNumber)] = ret;

        [self didChangeValueForKey:@"keyboardPlayerBindings"];
    }

    return ret;
}

- (NSUInteger)playerForDeviceHandler:(OEDeviceHandler *)deviceHandler;
{
    return [[self devicePlayerBindingsForDeviceHandler:deviceHandler] playerNumber];
}

- (nullable OEDeviceHandler *)deviceHandlerForPlayer:(NSUInteger)playerNumber;
{
    if(playerNumber == 0 || playerNumber > [self numberOfPlayers]) return nil;

    OEDevicePlayerBindings *bindings = _devicePlayerBindings[@(playerNumber)];

    NSAssert([bindings playerNumber] == playerNumber, @"Expected player number for bindings: %ld, got: %ld.", playerNumber, [bindings playerNumber]);

    return [bindings deviceHandler];
}

- (OEDevicePlayerBindings *)devicePlayerBindingsForDeviceHandler:(OEDeviceHandler *)deviceHandler;
{
    return _deviceHandlersToBindings[deviceHandler];
}

- (void)setDeviceHandler:(OEDeviceHandler *)deviceHandler forPlayer:(NSUInteger)playerNumber;
{
    // Find the two bindings to switch.
    OEDevicePlayerBindings *newBindings = [self devicePlayerBindingsForDeviceHandler:deviceHandler];
    NSAssert(newBindings != nil, @"A device handler without device player bindings?!");
    if([newBindings playerNumber] == playerNumber) return;

    // The user chose this layout by hand, so a pending compaction must not undo it.
    _needsDevicePlayerCompaction = NO;

    OEDevicePlayerBindings *oldBindings = [self devicePlayerBindingsForPlayer:playerNumber];

    // Notify observers to remove all bindings to the old player number of each devices.
    if(oldBindings != nil) [self OE_notifyObserversForRemovedDeviceBindings:oldBindings];
    [self OE_notifyObserversForRemovedDeviceBindings:newBindings];

    // Clean up the keys for each player keys so there's no confusion.
    if(oldBindings != nil) [_devicePlayerBindings removeObjectForKey:@([oldBindings playerNumber])];
    [_devicePlayerBindings removeObjectForKey:@([newBindings playerNumber])];

    // Change the player numbers.
    if(oldBindings != nil) [oldBindings OE_setPlayerNumber:[newBindings playerNumber]];
    [newBindings OE_setPlayerNumber:playerNumber];

    // Move the bindings in the array.
    if(oldBindings != nil) _devicePlayerBindings[@([oldBindings playerNumber])] = oldBindings;
    _devicePlayerBindings[@(playerNumber)] = newBindings;

    // Notify observers to add all bindings for the new player layout.
    if(oldBindings != nil) [self OE_notifyObserversForAddedDeviceBindings:oldBindings];
    [self OE_notifyObserversForAddedDeviceBindings:newBindings];

    // Both bindings now sit where the user put them; keep them there.
    [_manuallyAssignedBindings addObject:newBindings];
    if(oldBindings != nil) [_manuallyAssignedBindings addObject:oldBindings];
}

#pragma mark -
#pragma mark Preference Panel Representation Helper Methods

- (NSString *)OE_descriptionForEvent:(id)anEvent;
{
    if(anEvent == nil) return nil;

    // Handle device events.
    if([anEvent isKindOfClass:[OEControlValueDescription class]])
        return [anEvent name];

    // Handle keyboard events.
    return ([anEvent respondsToSelector:@selector(displayDescription)]
            ? [anEvent displayDescription]
            : [anEvent description]);
}

- (NSDictionary<NSString *, NSString *> *)OE_stringValuesForBindings:(nullable NSDictionary<__kindof OEBindingDescription *, OEControlValueDescription *> *)bindingsToConvert possibleKeys:(NSDictionary<NSString *, OEKeyBindingDescription *> *)nameToKeyMap;
{
    NSMutableDictionary<NSString *, NSString *> *ret = [NSMutableDictionary dictionaryWithCapacity:[nameToKeyMap count]];

    [bindingsToConvert enumerateKeysAndObjectsUsingBlock:
     ^(__kindof OEBindingDescription *key, OEControlValueDescription *obj, BOOL *stop)
     {
         NSAssert(![obj isKindOfClass:[OEControlDescription class]], @"A OEControlDescription object was wrongfully associated to the key '%@'.", key);

         if([key isKindOfClass:[OEKeyBindingDescription class]])
             // General case - the event value is attached to the key-name for bindings
             [ret setObject:[self OE_descriptionForEvent:obj] forKey:[key name]];
         else if([key isKindOfClass:[OEOrientedKeyGroupBindingDescription class]])
         {
             OEOrientedKeyGroupBindingDescription *group = key;
             OEControlValueDescription *controlValue = obj;
             OEHIDEvent *event = [controlValue event];

             // In case of key-group, we need to create multiple key-strings for each cases of the key, usually 2 for axis type and 4 for hat switch type
             NSAssert([controlValue isKindOfClass:[OEControlValueDescription class]], @"Only OEControlValueDescription can be associated with binding groups, got: %@ %@", [event class], event);

             switch([group type])
             {
                 case OEKeyGroupTypeAxis :
                 {
                     NSAssert([event type] == OEHIDEventTypeAxis, @"Excepting OEHIDEventTypeAxis event type for Axis key group, got: %@", NSStringFromOEHIDEventType([event type]));

                     ret[[[group baseKey] name]] = [controlValue name];
                     ret[[[group oppositeKey] name]] = [[controlValue associatedControlValueDescriptionForEvent:[event axisEventWithOppositeDirection]] name];
                 }
                     break;
                 case OEKeyGroupTypeHatSwitch :
                 {
                     NSAssert([event type] == OEHIDEventTypeHatSwitch, @"Excepting OEHIDEventTypeHatSwitch event type for Axis key group, got: %@", NSStringFromOEHIDEventType([event type]));

                     enum { NORTH, EAST, SOUTH, WEST, HAT_COUNT };

                     OEHIDEventHatDirection direction  = [event hatDirection];
                     __block NSUInteger     currentDir = NORTH;

                     if(direction & OEHIDEventHatDirectionNorth) currentDir = NORTH;
                     if(direction & OEHIDEventHatDirectionEast)  currentDir = EAST;
                     if(direction & OEHIDEventHatDirectionSouth) currentDir = SOUTH;
                     if(direction & OEHIDEventHatDirectionWest)  currentDir = WEST;

                     static OEHIDEventHatDirection dirs[HAT_COUNT] = { OEHIDEventHatDirectionNorth, OEHIDEventHatDirectionEast, OEHIDEventHatDirectionSouth, OEHIDEventHatDirectionWest };

                     [group enumerateKeysFromBaseKeyUsingBlock:
                      ^(OEKeyBindingDescription *key, BOOL *stop)
                      {
                          ret[[key name]] = [[controlValue associatedControlValueDescriptionForEvent:[event hatSwitchEventWithDirection:dirs[currentDir % HAT_COUNT]]] name];

                          currentDir++;
                      }];
                 }
                     break;
                 default :
                     NSAssert(NO, @"Unknown Key Group Type");
                     break;
             }
         }
     }];

    return ret;
}

- (__kindof OEBindingDescription *)OE_playerBindings:(__kindof OEPlayerBindings *)sender didAssignEvent:(OEHIDEvent *)anEvent toKeyWithName:(NSString *)keyName;
{
    NSAssert([anEvent isKindOfClass:[OEHIDEvent class]], @"Can only set OEHIDEvents for bindings.");

    // Make a copy because events are reused to remember the previous state/timestamp
    anEvent = [anEvent copy];

    __kindof OEBindingDescription *ret = ([anEvent type] == OEHIDEventTypeKeyboard
        ? [self OE_playerBindings:sender didSetKeyboardEvent:anEvent forKey:keyName]
        : [self OE_playerBindings:sender didSetDeviceEvent:anEvent forKey:keyName]);

    return ret;
}

- (void)OE_playerBindings:(__kindof OEPlayerBindings *)sender didRemoveEventForKeyWithName:(NSString *)aKey;
{
    if([sender isKindOfClass:[OEKeyboardPlayerBindings class]])
        [self OE_playerBindings:sender didUnsetKeyboardEventForKey:aKey];
    else if([sender isKindOfClass:[OEDevicePlayerBindings class]])
        [self OE_playerBindings:sender didUnsetDeviceEventForKey:aKey];
}

- (__kindof OEBindingDescription *)OE_playerBindings:(OEKeyboardPlayerBindings *)sender didSetKeyboardEvent:(OEHIDEvent *)anEvent forKey:(NSString *)keyName;
{
    NSAssert([sender isKindOfClass:[OEKeyboardPlayerBindings class]], @"Invalid sender: OEKeyboardPlayerBindings expected, got: %@ %@", [sender class], sender);

    OEKeyBindingDescription *keyDesc = _systemController.allKeyBindingsDescriptions[keyName];
    NSAssert(keyDesc != nil, @"Could not find Key Binding Description for key with name \"%@\" in system \"%@\"", keyName, [[self systemController] systemIdentifier]);

    // Trying to set the same event to the same key, ignore it
    if([[[sender bindingEvents] objectForKey:keyDesc] isEqual:anEvent]) return keyDesc;

    [_keyboardPlayerBindings enumerateKeysAndObjectsUsingBlock:
     ^(NSNumber *key, OEKeyboardPlayerBindings *playerBindings, BOOL *stop)
     {
         NSArray *keys = [[playerBindings bindingEvents] allKeysForObject:anEvent];
         NSAssert([keys count] <= 1, @"More than one key is attached to the same event: %@ -> %@", anEvent, keys);

         OEKeyBindingDescription *desc = [keys lastObject];
         if(desc != nil)
         {
             [playerBindings OE_setBindingDescription:nil forKey:[desc name]];
             [playerBindings OE_setBindingEvent:nil forKey:desc];

             [self OE_notifyObserversDidUnsetEvent:anEvent forBindingKey:desc playerNumber:[desc isSystemWide] ? 0 : [playerBindings playerNumber]];
         }
     }];

    id previousBinding = [sender OE_bindingEventForKey:keyDesc];
    if(previousBinding != nil) [self OE_notifyObserversDidUnsetEvent:previousBinding forBindingKey:keyDesc playerNumber:[sender playerNumber]];

    NSString *eventString = [self OE_descriptionForEvent:anEvent];

    [sender OE_setBindingDescription:eventString forKey:keyName];
    [sender OE_setBindingEvent:anEvent forKey:keyDesc];

    [self OE_notifyObserversDidSetEvent:anEvent forBindingKey:keyDesc playerNumber:[sender playerNumber]];
    [[self bindingsController] OE_setRequiresSynchronization];

    return keyDesc;
}

- (void)OE_playerBindings:(OEKeyboardPlayerBindings *)sender didUnsetKeyboardEventForKey:(NSString *)keyName;
{
    NSAssert([sender isKindOfClass:[OEKeyboardPlayerBindings class]], @"Invalid sender: OEKeyboardPlayerBindings expected, got: %@ %@", [sender class], sender);

    OEKeyBindingDescription *keyDesc = _systemController.allKeyBindingsDescriptions[keyName];
    NSAssert(keyDesc != nil, @"Could not find Key Binding Description for key with name \"%@\" in system \"%@\"", keyName, [[self systemController] systemIdentifier]);

    OEHIDEvent *event = [sender bindingEvents][keyDesc];
    if(event == nil) return;

    [sender OE_setBindingDescription:nil forKey:[keyDesc name]];
    [sender OE_setBindingEvent:nil forKey:keyDesc];

    [self OE_notifyObserversDidUnsetEvent:event forBindingKey:keyDesc playerNumber:[keyDesc isSystemWide] ? 0 : [sender playerNumber]];
    [[self bindingsController] OE_setRequiresSynchronization];
}

- (__kindof OEBindingDescription *)OE_playerBindings:(OEDevicePlayerBindings *)sender didSetDeviceEvent:(OEHIDEvent *)anEvent forKey:(NSString *)keyName;
{
    NSAssert([sender isKindOfClass:[OEDevicePlayerBindings class]], @"Invalid sender: OEDevicePlayerBindings expected, got: %@ %@", [sender class], sender);

    NSAssert(_systemController.allKeyBindingsDescriptions[keyName] != nil, @"Could not find Key Binding Description for key with name \"%@\" in system \"%@\"", keyName, [[self systemController] systemIdentifier]);

    OEControlValueDescription *valueDesc = [[[sender deviceHandler] controllerDescription] controlValueDescriptionForEvent:anEvent];
    NSAssert(valueDesc != nil, @"Controller type '%@' does not recognize the event '%@', when attempting to set the key with name: '%@'.", [[[sender deviceHandler] controllerDescription] identifier], anEvent, keyName);

    // Sender is a duplicate configuration of an existing configuration,
    // save it as a new configuration now that it is being modified.
    NSMutableArray *manufactureBindings = _parsedManufacturerBindings[[[sender deviceHandler] deviceDescription]];
    if (![manufactureBindings containsObject:sender]) {
        [manufactureBindings addObject:sender];
    }

    // Search for keys bound to the same event.
    NSArray<__kindof OEBindingDescription *> *keys = [[sender bindingEvents] allKeysForObject:valueDesc];
    if([keys count] == 0)
    {
        keys = [[[sender bindingEvents] keysOfEntriesPassingTest:
                 ^ BOOL (OEOrientedKeyGroupBindingDescription *key, OEControlValueDescription *obj, BOOL *stop)
                 {
                     if(![key isKindOfClass:[OEOrientedKeyGroupBindingDescription class]]) return NO;

                     return [obj controlDescription] == [valueDesc controlDescription];
                 }] allObjects];
    }

    // Remove bindings for these keys
    NSAssert([keys count] <= 1, @"More than one key is attached to the same event: %@ -> %@", anEvent, keys);
    __kindof OEBindingDescription *keyDesc = [keys lastObject];

    if(keyDesc != nil)
    {
        NSArray<NSString *> *keys = nil;
        if([keyDesc isKindOfClass:[OEKeyBindingDescription class]])
            keys = @[ [keyDesc name] ];
        else if([keyDesc isKindOfClass:[OEKeyBindingGroupDescription class]])
            keys = [keyDesc keyNames];

        for(NSString *key in keys) [sender OE_setBindingDescription:nil forKey:key];

        [sender OE_setBindingEvent:nil forKey:keyDesc];
        [self OE_notifyObserversDidUnsetEvent:anEvent forBindingKey:keyDesc playerNumber:[sender playerNumber]];
    }

    // Find the appropriate key for the event
    keyDesc = _systemController.allKeyBindingsDescriptions[keyName];
    [self OE_removeConcurrentBindings:sender ofKey:keyDesc withEvent:anEvent];

    switch([anEvent type])
    {
        case OEHIDEventTypeAxis :
            if([keyDesc axisGroup] != nil)
                keyDesc = [[keyDesc axisGroup] orientedKeyGroupWithBaseKey:keyDesc];
            break;
        case OEHIDEventTypeHatSwitch :
            if([keyDesc hatSwitchGroup] != nil)
            {
                OEKeyBindingGroupDescription *hatSwitchGroup = [keyDesc hatSwitchGroup];
                
                // Sync the key direction with the hat switch direction, in case they're different.
                enum { NORTH, EAST, SOUTH, WEST, HAT_COUNT };
                OEHIDEventHatDirection direction  = [anEvent hatDirection];
                NSUInteger     currentDir = NORTH;
                
                if(direction & OEHIDEventHatDirectionNorth) currentDir = NORTH;
                if(direction & OEHIDEventHatDirectionEast)  currentDir = EAST;
                if(direction & OEHIDEventHatDirectionSouth) currentDir = SOUTH;
                if(direction & OEHIDEventHatDirectionWest)  currentDir = WEST;
                
                keyDesc = [hatSwitchGroup orientedKeyGroupWithBaseKey:hatSwitchGroup.keys[currentDir]];
            }
            break;
        default :
            break;
    }

    [self OE_notifyObserversDidUnsetDeviceEventsOfPlayerBindings:sender forBindingKey:keyDesc];

    // Update the bindings for the event
    NSDictionary<NSString *, NSString *> *eventStrings = [self OE_stringValuesForBindings:@{ keyDesc : valueDesc } possibleKeys:_systemController.allKeyBindingsDescriptions];

    [eventStrings enumerateKeysAndObjectsUsingBlock:
     ^(NSString *key, NSString *obj, BOOL *stop)
     {
         [sender OE_setBindingDescription:obj forKey:key];
     }];

    [sender OE_setBindingEvent:valueDesc forKey:keyDesc];
    [self OE_notifyObserversDidSetEvent:anEvent forBindingKey:keyDesc playerNumber:[sender playerNumber]];
    [[self bindingsController] OE_setRequiresSynchronization];

    return keyDesc;
}

- (void)OE_notifyObserversDidUnsetDeviceEventsOfPlayerBindings:(OEDevicePlayerBindings *)sender forBindingKey:(id)bindingKey
{
    OEDeviceHandler *deviceHandler = [sender deviceHandler];
    OEHIDEvent *previousEventBinding = [[[sender OE_bindingEventForKey:bindingKey] event] eventWithDeviceHandler:deviceHandler];
    if(previousEventBinding != nil) [self OE_notifyObserversDidUnsetEvent:previousEventBinding forBindingKey:bindingKey playerNumber:[sender playerNumber]];

    if(![bindingKey isKindOfClass:[OEKeyBindingGroupDescription class]])
        return;

    for(OEKeyBindingDescription *keyDesc in [bindingKey keys])
    {
        OEHIDEvent *previousEventBinding = [[[sender OE_bindingEventForKey:keyDesc] event] eventWithDeviceHandler:deviceHandler];
        if(previousEventBinding != nil) [self OE_notifyObserversDidUnsetEvent:previousEventBinding forBindingKey:keyDesc playerNumber:[sender playerNumber]];
    }
}

- (void)OE_playerBindings:(OEDevicePlayerBindings *)sender didUnsetDeviceEventForKey:(NSString *)keyName;
{
    NSAssert([sender isKindOfClass:[OEDevicePlayerBindings class]], @"Invalid sender: OEKeyboardPlayerBindings expected, got: %@ %@", [sender class], sender);

    __block __kindof OEBindingDescription *keyDesc = _systemController.allKeyBindingsDescriptions[keyName];
    NSAssert(keyDesc != nil, @"Could not find Key Binding Description for key with name \"%@\" in system \"%@\"", keyName, [[self systemController] systemIdentifier]);

    // Sender is a duplicate configuration of an existing configuration,
    // save it as a new configuration now that it is being modified.
    NSMutableArray *manufactureBindings = _parsedManufacturerBindings[[[sender deviceHandler] deviceDescription]];
    if (![manufactureBindings containsObject:sender]) {
        [manufactureBindings addObject:sender];
    }

    __block OEControlValueDescription *valueDescToRemove = [sender bindingEvents][keyDesc];
    if(valueDescToRemove == nil)
    {
        [[keyDesc axisGroup] enumerateOrientedKeyGroupsFromKey:keyDesc usingBlock:
         ^(OEOrientedKeyGroupBindingDescription *key, BOOL *stop)
         {
             OEControlValueDescription *valueDesc = [sender bindingEvents][key];
             if(valueDesc == nil) return;

             keyDesc = key;
             valueDescToRemove = valueDesc;
             *stop = YES;
         }];
    }

    if(valueDescToRemove == nil)
    {
        [[keyDesc hatSwitchGroup] enumerateOrientedKeyGroupsFromKey:keyDesc usingBlock:
         ^(OEOrientedKeyGroupBindingDescription *key, BOOL *stop)
         {
             OEControlValueDescription *valueDesc = [sender bindingEvents][key];
             if(valueDesc == nil) return;

             keyDesc = key;
             valueDescToRemove = valueDesc;
             *stop = YES;
         }];
    }

    if(valueDescToRemove == nil) return;

    OEHIDEvent *eventToRemove = [[valueDescToRemove event] eventWithDeviceHandler:[sender deviceHandler]];

    NSArray<NSString *> *keys = nil;
    if([keyDesc isKindOfClass:[OEKeyBindingDescription class]])
        keys = @[ [keyDesc name] ];
    else if([keyDesc isKindOfClass:[OEKeyBindingGroupDescription class]])
        keys = [keyDesc keyNames];

    for(NSString *key in keys) [sender OE_setBindingDescription:nil forKey:key];

    [sender OE_setBindingEvent:nil forKey:keyDesc];
    [self OE_notifyObserversDidUnsetEvent:eventToRemove forBindingKey:keyDesc playerNumber:[sender playerNumber]];
    [[self bindingsController] OE_setRequiresSynchronization];
}

- (void)OE_removeConcurrentBindings:(OEDevicePlayerBindings *)sender ofKey:(OEKeyBindingDescription *)keyDesc withEvent:(OEHIDEvent *)anEvent;
{
    NSDictionary<__kindof OEBindingDescription *, OEControlValueDescription *> *rawBindings = [[sender bindingEvents] copy];
    OEKeyBindingGroupDescription *axisGroup = keyDesc.axisGroup;
    OEKeyBindingGroupDescription *hatGroup = keyDesc.hatSwitchGroup;

    if(axisGroup == nil && hatGroup == nil) return;

    OEDeviceHandler *handler = [sender deviceHandler];

    switch([anEvent type])
    {
        case OEHIDEventTypeButton :
        case OEHIDEventTypeTrigger :
        {
            [rawBindings enumerateKeysAndObjectsUsingBlock:
             ^ void (OEOrientedKeyGroupBindingDescription *keyDesc, OEControlValueDescription *valueDesc, BOOL *stop)
             {
                 if(![keyDesc isKindOfClass:[OEOrientedKeyGroupBindingDescription class]]) return;

                 OEKeyBindingGroupDescription *keyGroup = [keyDesc parentKeyGroup];
                 if(keyGroup != axisGroup && keyGroup != hatGroup) return;

                 [[keyGroup keyNames] enumerateObjectsUsingBlock:
                  ^(NSString *key, NSUInteger idx, BOOL *stop)
                  {
                      [sender OE_setBindingDescription:nil forKey:key];
                  }];

                 [sender OE_setBindingEvent:nil forKey:keyDesc];
                 [self OE_notifyObserversDidUnsetEvent:[[valueDesc event] OE_eventWithDeviceHandler:handler] forBindingKey:keyDesc playerNumber:[sender playerNumber]];
             }];
        }
            break;
        case OEHIDEventTypeAxis :
        {
            for(OEKeyBindingDescription *keyDesc in [axisGroup keys])
            {
                OEControlValueDescription *valueDesc = [rawBindings objectForKey:keyDesc];
                if(valueDesc != nil)
                {
                    [sender OE_setBindingDescription:nil forKey:[keyDesc name]];
                    [sender OE_setBindingEvent:nil forKey:keyDesc];
                    [self OE_notifyObserversDidUnsetEvent:[[valueDesc event] OE_eventWithDeviceHandler:handler] forBindingKey:keyDesc playerNumber:[sender playerNumber]];
                }
            }

            [rawBindings enumerateKeysAndObjectsUsingBlock:
             ^ void (OEOrientedKeyGroupBindingDescription *keyDesc, OEControlValueDescription *valueDesc, BOOL *stop)
             {
                 if(![keyDesc isKindOfClass:[OEOrientedKeyGroupBindingDescription class]]) return;

                 OEKeyBindingGroupDescription *keyGroup = [keyDesc parentKeyGroup];
                 if(keyGroup != axisGroup && keyGroup != hatGroup) return;

                 [[keyDesc keyNames] enumerateObjectsUsingBlock:
                  ^(NSString *key, NSUInteger idx, BOOL *stop)
                  {
                      [sender OE_setBindingDescription:nil forKey:key];
                  }];

                 [sender OE_setBindingEvent:nil forKey:keyDesc];
                 [self OE_notifyObserversDidUnsetEvent:[[valueDesc event] OE_eventWithDeviceHandler:handler] forBindingKey:keyDesc playerNumber:[sender playerNumber]];
             }];
        }
            break;
        case OEHIDEventTypeHatSwitch :
        {
            NSMutableSet<OEKeyBindingGroupDescription *> *visitedAxisGroups = [NSMutableSet set];
            if (axisGroup) [visitedAxisGroups addObject:axisGroup];
            if (hatGroup) [visitedAxisGroups addObject:hatGroup];
            for(OEKeyBindingDescription *keyDesc in [hatGroup keys])
            {
                OEControlValueDescription *valueDesc = [rawBindings objectForKey:keyDesc];
                if(valueDesc != nil)
                {
                    [sender OE_setBindingDescription:nil forKey:[keyDesc name]];
                    [sender OE_setBindingEvent:nil forKey:keyDesc];
                    [self OE_notifyObserversDidUnsetEvent:[[valueDesc event] OE_eventWithDeviceHandler:handler] forBindingKey:keyDesc playerNumber:[sender playerNumber]];
                }

                OEKeyBindingGroupDescription *temp = keyDesc.axisGroup;
                if(temp != nil) [visitedAxisGroups addObject:temp];
            }

            [rawBindings enumerateKeysAndObjectsUsingBlock:
             ^(OEOrientedKeyGroupBindingDescription *keyDesc, OEControlValueDescription *valueDesc, BOOL *stop)
             {
                 if(![visitedAxisGroups containsObject:keyDesc]) return;

                 [[keyDesc keyNames] enumerateObjectsUsingBlock:
                  ^(NSString *key, NSUInteger idx, BOOL *stop)
                  {
                      [sender OE_setBindingDescription:nil forKey:key];
                  }];

                 [sender OE_setBindingEvent:nil forKey:keyDesc];
                 [self OE_notifyObserversDidUnsetEvent:[[valueDesc event] OE_eventWithDeviceHandler:handler] forBindingKey:keyDesc playerNumber:[sender playerNumber]];
             }];
        }
            break;
        default :
            break;
    }
}

#pragma mark -
#pragma mark Device Handlers Management

- (BOOL)OE_didAddDeviceHandler:(OEDeviceHandler *)aHandler
{
    BOOL corrupted = NO;
    
    // Ignore extra keyboards for now
    if([aHandler isKeyboardDevice])
        return YES;

    [self OE_notifyObserversForAddedDeviceBindings:[self OE_deviceBindingsForDeviceHandler:aHandler corruptBindingsDetected:&corrupted]];
    return !corrupted;
}

- (void)OE_didRemoveDeviceHandler:(OEDeviceHandler *)aHandler;
{
    // Ignore extra keyboards for now
    if([aHandler isKeyboardDevice]) return;

    OEDevicePlayerBindings *controller = [_deviceHandlersToBindings objectForKey:aHandler];

    if(controller == nil)
    {
        NSLog(@"WARNING: Trying to remove device %@ that was not registered with %@", aHandler, self);
        return;
    }

    NSUInteger playerNumber = [controller playerNumber];

    [self willChangeValueForKey:@"devicePlayerBindings"];
    [_devicePlayerBindings removeObjectForKey:@(playerNumber)];
    [self didChangeValueForKey:@"devicePlayerBindings"];

    [self OE_notifyObserversForRemovedDeviceBindings:controller];

    [controller OE_setDeviceHandler:nil];
    [controller OE_setPlayerNumber:0];

    [_manuallyAssignedBindings removeObject:controller];

    [self OE_compactDevicePlayerBindings];
}

- (void)OE_compactDevicePlayerBindings
{
    // Moves are not announced to observers, so compaction only runs while there
    // are none. Today OEGameDocument is the only observer and it removes itself
    // when the game closes. A long-lived observer would defer compaction
    // forever; a future change that adds one must handle that case.
    if([_bindingsObservers count] > 0)
    {
        _needsDevicePlayerCompaction = YES;
        return;
    }

    _needsDevicePlayerCompaction = NO;

    NSUInteger count = [_devicePlayerBindings count];
    if(count == 0) return;

    NSArray<NSNumber *> *players = [[_devicePlayerBindings allKeys] sortedArrayUsingSelector:@selector(compare:)];
    // The players already fill 1..count, nothing to do.
    if([[players lastObject] unsignedIntegerValue] == count) return;

    // Manual bindings stay where the user put them. Only automatic bindings
    // move down to fill the first free players.
    NSMutableArray<OEDevicePlayerBindings *> *automaticBindings = [NSMutableArray array];
    NSMutableSet<NSNumber *> *manualPlayers = [NSMutableSet set];
    for(NSNumber *player in players)
    {
        OEDevicePlayerBindings *bindings = _devicePlayerBindings[player];
        if([_manuallyAssignedBindings containsObject:bindings]) [manualPlayers addObject:player];
        else [automaticBindings addObject:bindings];
    }

    if([automaticBindings count] == 0) return;

    BOOL didMove = NO;
    NSUInteger nextPlayerNumber = 1;
    for(OEDevicePlayerBindings *bindings in automaticBindings)
    {
        while([manualPlayers containsObject:@(nextPlayerNumber)])
            nextPlayerNumber++;

        NSUInteger playerNumber = [bindings playerNumber];
        if(playerNumber != nextPlayerNumber)
        {
            if(!didMove)
            {
                [self willChangeValueForKey:@"devicePlayerBindings"];
                didMove = YES;
            }

            [_devicePlayerBindings removeObjectForKey:@(playerNumber)];
            [bindings OE_setPlayerNumber:nextPlayerNumber];
            _devicePlayerBindings[@(nextPlayerNumber)] = bindings;
        }

        nextPlayerNumber++;
    }

    if(didMove) [self didChangeValueForKey:@"devicePlayerBindings"];
}

- (void)OE_notifyObserversForAddedDeviceBindings:(OEDevicePlayerBindings *)aHandler;
{
    NSUInteger playerNumber = [aHandler playerNumber];
    OEDeviceHandler *deviceHandler = [aHandler deviceHandler];

    [[aHandler bindingEvents] enumerateKeysAndObjectsUsingBlock:
     ^(id key, OEControlValueDescription *obj, BOOL *stop)
     {
         for(id<OESystemBindingsObserver> observer in self->_bindingsObservers)
             [observer systemBindings:self didSetEvent:[[obj event] OE_eventWithDeviceHandler:deviceHandler] forBinding:key playerNumber:playerNumber];
     }];
}

- (void)OE_notifyObserversForRemovedDeviceBindings:(OEDevicePlayerBindings *)aHandler;
{
    NSUInteger playerNumber = [aHandler playerNumber];
    OEDeviceHandler *deviceHandler = [aHandler deviceHandler];

    // Tell the controllers that the bindings are not used anymore
    [[aHandler bindingEvents] enumerateKeysAndObjectsUsingBlock:
     ^(id key, OEControlValueDescription *obj, BOOL *stop)
     {
         for(id<OESystemBindingsObserver> observer in self->_bindingsObservers)
             [observer systemBindings:self didUnsetEvent:[[obj event] OE_eventWithDeviceHandler:deviceHandler] forBinding:key playerNumber:playerNumber];
     }];
}

- (OEDevicePlayerBindings *)OE_deviceBindingsForDeviceHandler:(OEDeviceHandler *)aHandler corruptBindingsDetected:(BOOL *)outCorrupted
{
    __block OEDevicePlayerBindings *controller = [_deviceHandlersToBindings objectForKey:aHandler];

    // The device was already registered with the system controller
    if(controller != nil) return controller;

    OEDeviceDescription *deviceDescription         = [aHandler deviceDescription];
    OEControllerDescription *controllerDescription = [deviceDescription controllerDescription];
    NSMutableArray *manuBindings                   = _parsedManufacturerBindings[deviceDescription];

    // Allocate a new array to countain OEDevicePlayerBindings objects for the given device type
    if(manuBindings == nil)
    {
        BOOL ok = [self OE_parseManufacturerControlValuesForDeviceDescription:deviceDescription];
        manuBindings = _parsedManufacturerBindings[deviceDescription];
        
        if (outCorrupted) *outCorrupted = !ok;
        if (!ok) {
            /* request saving the bindings file to remove the corrupt bindings */
            [self.bindingsController OE_setRequiresSynchronization];
        }
    }

    [manuBindings enumerateObjectsUsingBlock:^(OEDevicePlayerBindings *devicePlayerBindings, NSUInteger idx, BOOL *stop) {
        if (devicePlayerBindings.deviceHandler == nil) {
            controller = [self OE_duplicateDevicePlayerBindings:devicePlayerBindings forHandler:aHandler];
            if (controller) {
                manuBindings[idx] = controller;
            } else {
                /* Fix bindings file in the specific case of two controllers with the same
                 * PID & VID and different HID profiles, when they are connected one after the
                 * other to the same instance of OpenEmu.
                 *   Known controllers with OEControllerRequiresNameMatch set to YES are not
                 * affected by this. */
                if (outCorrupted) *outCorrupted = YES;
                [self.bindingsController OE_setRequiresSynchronization];
                [manuBindings removeObjectAtIndex:idx];
            }
            *stop = YES;
        }
    }];

    // No available slots in the known configurations, look for defaults
    if(controller == nil)
    {
        OEDevicePlayerBindings *ctrl = _defaultDeviceBindings[[controllerDescription identifier]];
        controller = [self OE_duplicateDevicePlayerBindings:ctrl forHandler:aHandler];
    }

    // No defaults, duplicate the first manufacturer  device
    if(controller == nil && [manuBindings count] > 0)
        controller = [self OE_duplicateDevicePlayerBindings:manuBindings.firstObject forHandler:aHandler];

    // Still nothing, create a completely empty controller
    if(controller == nil)
    {
        // This handler is the first of its kind for the application
        controller = [self OE_duplicateDevicePlayerBindings:_emptyConfiguration forHandler:aHandler];
    }

    // Keep track of device handlers
    _deviceHandlersToBindings[aHandler] = controller;

    // Add it to the player list
    [self OE_addDeviceBindings:controller];

    return controller;
}

- (NSUInteger)OE_addDeviceBindings:(OEDevicePlayerBindings *)controller;
{
    // Find the first free slot.
    NSUInteger playerNumber = 1;
    while(_devicePlayerBindings[@(playerNumber)] != nil)
        playerNumber++;

    [self willChangeValueForKey:@"devicePlayerBindings"];
    _devicePlayerBindings[@(playerNumber)] = controller;
    [self didChangeValueForKey:@"devicePlayerBindings"];

    [controller OE_setPlayerNumber:playerNumber];

    return playerNumber;
}

#pragma mark -
#pragma mark Bindings Observers

- (void)OE_notifyObserversDidSetEvent:(OEHIDEvent *)anEvent forBindingKey:(__kindof OEBindingDescription *)bindingKey playerNumber:(NSUInteger)playerNumber;
{
    for(id<OESystemBindingsObserver> observer in _bindingsObservers)
        [observer systemBindings:self didSetEvent:anEvent forBinding:bindingKey playerNumber:playerNumber];
}

- (void)OE_notifyObserversDidUnsetEvent:(OEHIDEvent *)anEvent forBindingKey:(__kindof OEBindingDescription *)bindingKey playerNumber:(NSUInteger)playerNumber;
{
    for(id<OESystemBindingsObserver> observer in _bindingsObservers)
        [observer systemBindings:self didUnsetEvent:anEvent forBinding:bindingKey playerNumber:playerNumber];
}

- (void)OE_notifyExistingBindings:(OEPlayerBindings *)bindings toObserver:(id<OESystemBindingsObserver>)observer;
{
    if(bindings == nil) return;

    OEDevicePlayerBindings *deviceBindings = nil;
    if([bindings isKindOfClass:[OEDevicePlayerBindings class]])
        deviceBindings = (OEDevicePlayerBindings *)bindings;

    NSUInteger playerNumber = [bindings playerNumber];

    [[bindings bindingEvents] enumerateKeysAndObjectsUsingBlock:
     ^(id key, id event, BOOL *stop)
     {
         NSUInteger player = playerNumber;
         // playerNumber for system-wide keys should always be 0
         if(self->_systemController.systemKeyBindingsDescriptions != nil &&
            [key isKindOfClass:[OEKeyBindingDescription class]] &&
            [key isSystemWide])
             player = 0;

         if(deviceBindings != nil) event = [[(OEControlValueDescription *)event event] OE_eventWithDeviceHandler:[deviceBindings deviceHandler]];
         [observer systemBindings:self didSetEvent:event forBinding:key playerNumber:player];
     }];
}

- (void)OE_notifyExistingBindingsInArray:(NSArray *)bindingsArray toObserver:(id<OESystemBindingsObserver>)observer
{
    for(OEPlayerBindings *ctrl in bindingsArray)
        [self OE_notifyExistingBindings:ctrl toObserver:observer];
}

- (void)addBindingsObserver:(id<OESystemBindingsObserver>)observer
{
    if([_bindingsObservers containsObject:observer]) return;

    [self OE_notifyExistingBindingsInArray:[_keyboardPlayerBindings allValues] toObserver:observer];
    [self OE_notifyExistingBindingsInArray:[_devicePlayerBindings allValues]   toObserver:observer];

    [_bindingsObservers addObject:observer];
}

- (void)removeBindingsObserver:(id<OESystemBindingsObserver>)observer
{
    // No need to tell it to unset everything
    [_bindingsObservers removeObject:observer];

    if(_needsDevicePlayerCompaction) [self OE_compactDevicePlayerBindings];
}

@end

NS_ASSUME_NONNULL_END
