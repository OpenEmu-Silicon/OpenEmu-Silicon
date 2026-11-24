// Copyright (c) 2026. Wii System Plugin integration.
// Extends only the Wii responder; preserves the original Wii plugin source
// and existing Dolphin core binary untouched.
#import "OEWiiOrientationGameplay.h"
#import "OEWiiSystemResponderClient.h"
#import <CoreFoundation/CoreFoundation.h>

// OpenEmu's Controls UI runs in the app; the responder runs in HelperApp.
// Do not rely on [NSUserDefaults standardUserDefaults] crossing processes.
static CFStringRef const kOrientationDomain = CFSTR("org.openemu.WiiOrientation");
static CFStringRef const kOrientationKey = CFSTR("sideways");

@interface OEWiiOrientationGameplayResponder () {
    // Dolphin starts with its sideways toggle OFF for each new game core.
    BOOL _appliedSideways[4];
    BOOL _hasSeenGameplayInput[4];
    BOOL _desiredSideways;
    NSTimeInterval _lastRead;
}
@property(nonatomic, strong) NSTimer *orientationTimer;
@end

@implementation OEWiiOrientationGameplayResponder

- (instancetype)initWithController:(OESystemController *)controller
{
    if((self = [super initWithController:controller])) {
        _lastRead = 0;
        _desiredSideways = NO;
        NSLog(@"[WiiOrientation v16] Wii gameplay responder initialized");
    }
    return self;
}

- (void)dealloc
{
    [self.orientationTimer invalidate];
}

- (BOOL)readSidewaysPreferenceForced:(BOOL)forced
{
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    // Throttle disk synchronization on heavily repeated analog events.
    if(forced || now - _lastRead > 0.18) {
        CFPreferencesAppSynchronize(kOrientationDomain);
        CFTypeRef v = CFPreferencesCopyAppValue(kOrientationKey, kOrientationDomain);
        if(v) {
            _desiredSideways = CFGetTypeID(v) == CFBooleanGetTypeID() &&
                                CFBooleanGetValue((CFBooleanRef)v);
            CFRelease(v);
        }
        _lastRead = now;
    }
    return _desiredSideways;
}

// IMPORTANT: Dolphin's existing DolHost::processSpecialKeys increments the
// incoming enum before checking the orientation commands. Consequently, in
// this specific shipped bridge OEWiimoteChangeExtension is interpreted as the
// OEWiimoteSideways TOGGLE. This synthetic call deliberately preserves that
// bridge's existing behavior rather than modifying core code. It is only sent
// when a per-player state transition is required; repeated polling cannot
// toggle sideways back accidentally.
- (void)sendSidewaysToggleToPlayer:(NSUInteger)player onCoreThread:(BOOL)onCoreThread
{
    id<OEWiiSystemResponderClient> client = self.client;
    if(!client) return;
    if(onCoreThread) {
        [client didPushWiiButton:OEWiimoteChangeExtension forPlayer:player];
    } else {
        [client performBlock:^{
            [client didPushWiiButton:OEWiimoteChangeExtension forPlayer:player];
        }];
    }
    NSLog(@"[WiiOrientation v16] Requested Dolphin sideways toggle for player %lu",
          (unsigned long)player);
}

- (void)synchronizePlayer:(NSUInteger)player onCoreThread:(BOOL)onCoreThread
{
    if(player < 1 || player > 4 || !self.client) return;
    @synchronized(self) {
        // The first actual input indicates a running game. Don't issue a
        // toggle during -setClient:, since Dolphin ignores it until its
        // -startEmulation setup finishes. Future UI changes are then polled.
        _hasSeenGameplayInput[player-1] = YES;
        BOOL want = [self readSidewaysPreferenceForced:NO];
        if(want == _appliedSideways[player-1]) return;
        _appliedSideways[player-1] = want;
        [self sendSidewaysToggleToPlayer:player onCoreThread:onCoreThread];
    }
}

- (void)checkOrientation:(NSTimer *)timer
{
    if(!self.client) {
        [timer invalidate];
        self.orientationTimer = nil;
        return;
    }
    @synchronized(self) {
        BOOL want = [self readSidewaysPreferenceForced:YES];
        for(NSUInteger i = 0; i < 4; i++) {
            if(!_hasSeenGameplayInput[i] || want == _appliedSideways[i]) continue;
            _appliedSideways[i] = want;
            [self sendSidewaysToggleToPlayer:i+1 onCoreThread:NO];
        }
    }
}

- (void)setClient:(id<OESystemResponderClient>)client
{
    [super setClient:client];
    [self.orientationTimer invalidate];
    self.orientationTimer = nil;
    if(!client) return;

    // The helper links the game core to the responder before starting Dolphin.
    // Poll preference changes without sending toggles until gameplay input
    // confirms the core has actually started.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        OEWiiOrientationGameplayResponder *strongSelf = weakSelf;
        if(!strongSelf || strongSelf.client != client) return;
        strongSelf.orientationTimer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                                       repeats:YES
                                                                         block:^(NSTimer *timer) {
            OEWiiOrientationGameplayResponder *target = weakSelf;
            if(target) [target checkOrientation:timer];
            else [timer invalidate];
        }];
    });
}

- (void)pressEmulatorKey:(OESystemKey *)key
{
    [self synchronizePlayer:key.player onCoreThread:YES];
    [super pressEmulatorKey:key];
}

- (void)releaseEmulatorKey:(OESystemKey *)key
{
    [self synchronizePlayer:key.player onCoreThread:YES];
    [super releaseEmulatorKey:key];
}

- (void)changeAnalogEmulatorKey:(OESystemKey *)key value:(CGFloat)value
{
    [self synchronizePlayer:key.player onCoreThread:YES];
    [super changeAnalogEmulatorKey:key value:value];
}

@end
