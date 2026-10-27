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

#import "MAMEGameCore.h"

#import <OpenEmuBase/OERingBuffer.h>
#import <OpenEmuBase/OEMemoryRegionDescriptor.h>
#import <OpenGL/gl.h>
#import <os/log.h>

@interface MAMEAuditResult: NSObject

/*! Returns the unique identifier of this result
 *
 * @remarks
 *
 * Identifier which groups resources by their driver, parent or CHD name
 */
@property (nonatomic, readonly) NSString *identifier;
@property (nonatomic, readonly) NSString *fileName;

- (instancetype)initWithDriver:(NSString *)driver auditRecord:(AuditRecord *)record;
- (BOOL)checkSetExistsInDir:(NSURL *)dir;

@end

@interface MAMEGameCore () <OEArcadeSystemResponderClient>
{
    uint32_t _buttons[8][OEArcadeButtonCount];
    uint32_t _axes[8][InputMaxAxis];
    
    uint32_t *_buffer;
    OEIntSize _bufferSize;
    OEIntRect _screenRect;
    OEIntSize _aspectSize;
    
    NSTimeInterval _frameInterval;
    

    // dylib
    void *_handle;
    OSD *_osd;
    BOOL _supportsRewinding;
    
    NSMutableDictionary<NSString *, NSDictionary *> *_cheatList;
}

@end

static int32_t joystick_get_state(void *device_internal, void *item_internal)
{
    return *(int32_t *)item_internal;
}

static os_log_t OE_CORE_LOG, OE_CORE_AUDIT_LOG;

@implementation MAMEGameCore

#pragma mark - Lifecycle

+ (void)initialize
{
    OE_CORE_LOG         = os_log_create("org.openemu.MAME", "");
    OE_CORE_AUDIT_LOG   = os_log_create("org.openemu.MAME", "audit");
}

- (id)init
{
    self = [super init];
    if(!self)
    {
        return nil;
    }

    // Sensible defaults
    _bufferSize    = OEIntSizeMake(1024, 1024);
    _frameInterval = 60;
    _screenRect = { {0,0}, _bufferSize };
    _aspectSize = { 4, 3 };

    _osd = [OSD shared];
    _osd.delegate = self;

    return self;
}

#pragma mark - OSDDelegate

- (void)didInitialize
{
    // initialize joysticks
    for (int i = 0; i < 8; i++) {
        NSString *name = [NSString stringWithFormat:@"OpenEmu Player %d", i];
        InputDevice *dev = [_osd.joystick addDeviceNamed:name];
        [dev addItemNamed:@"X Axis" id:InputItemID_XAXIS getter:joystick_get_state context:&_axes[i][0]];
        [dev addItemNamed:@"Y Axis" id:InputItemID_YAXIS getter:joystick_get_state context:&_axes[i][1]];
        [dev addItemNamed:@"Start" id:InputItemID_START getter:joystick_get_state context:&_buttons[i][OEArcadeButtonP1Start]];
        [dev addItemNamed:@"Insert Coin" id:InputItemID_SELECT getter:joystick_get_state context:&_buttons[i][OEArcadeButtonInsertCoin]];
        [dev addItemNamed:@"Button 1" id:InputItemID_BUTTON1 getter:joystick_get_state context:&_buttons[i][OEArcadeButton1]];
        [dev addItemNamed:@"Button 2" id:InputItemID_BUTTON2 getter:joystick_get_state context:&_buttons[i][OEArcadeButton2]];
        [dev addItemNamed:@"Button 3" id:InputItemID_BUTTON3 getter:joystick_get_state context:&_buttons[i][OEArcadeButton3]];
        [dev addItemNamed:@"Button 4" id:InputItemID_BUTTON4 getter:joystick_get_state context:&_buttons[i][OEArcadeButton4]];
        [dev addItemNamed:@"Button 5" id:InputItemID_BUTTON5 getter:joystick_get_state context:&_buttons[i][OEArcadeButton5]];
        [dev addItemNamed:@"Button 6" id:InputItemID_BUTTON6 getter:joystick_get_state context:&_buttons[i][OEArcadeButton6]];
    }
    
    // Special keys
    InputDevice *kb = [_osd.keyboard addDeviceNamed:@"OpenEmu Keyboard"];
    [kb addItemNamed:@"Service" id:InputItemID_F2 getter:joystick_get_state context:&_buttons[0][OEArcadeButtonService]];
    [kb addItemNamed:@"UI Configure" id:InputItemID_TAB getter:joystick_get_state context:&_buttons[0][OEArcadeUIConfigure]];
}

- (void)didChangeDisplayBounds:(NSSize)bounds fps:(double)fps aspect:(NSSize)aspect
{
    _screenRect = {{0, 0}, OEIntSizeMake(bounds.width, bounds.height)};
    
    // for single screen games:
    BOOL singleScreen = YES;
    if (singleScreen)
    {
        CGFloat newHeight = (aspect.height / aspect.width) * bounds.width;
        _aspectSize = OEIntSizeMake(bounds.width, newHeight);
    }
    else
    {
        _aspectSize = OEIntSizeMake(bounds.width, bounds.height);
    }
    
    _frameInterval = fps;
}

- (void)updateAudioBuffer:(const int16_t *)buffer samples:(NSInteger)samples
{
    id<OEAudioBuffer> buf = [self audioBufferAtIndex:0];
    [buf write:buffer maxLength:samples * 2 * sizeof(int16_t)];
}

- (void)logLevel:(OSDLogLevel)level message:(NSString *)msg
{
    switch (level) {
        case OSDLogLevelError:
            os_log_error(OE_CORE_LOG, "%{public}s", msg.UTF8String);
            break;
            
        case OSDLogLevelVerbose:
            os_log_debug(OE_CORE_LOG, "%{public}s", msg.UTF8String);
            break;
            
        default:
            os_log_info(OE_CORE_LOG, "%{public}s", msg.UTF8String);
            break;
    }
}

#pragma mark - Execution

BOOL driverIsNotWorking(GameDriverOptions o)
{
    if ((o & GameDriverMachineNotWorking) == GameDriverMachineNotWorking) {
        return YES;
    }
    
    if ((o & GameDriverMachineIsSkeleton) == GameDriverMachineIsSkeleton) {
        return YES;
    }
    
    return NO;
}

- (BOOL)validateGameDriver:(GameDriver *)driver error:(NSError **)error
{
    GameDriverOptions o = driver.flags;
    
    if (o & (GameDriverMachineClickableArtwork | GameDriverMachineRequiresArtwork | GameDriverMachineMechanical))
    {
        if (error != nil)
        {
            *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadROMError userInfo:@{
                NSLocalizedDescriptionKey : @"Unable to load ROM.",
                NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:@"\"%@\" (%@).\n\nMechanical systems or systems which require artwork to operate are not supported.", driver.fullName, driver.name],
            }];
        }
        return NO;
    }
    
    if (driverIsNotWorking(o)) {
        if (error != nil)
        {
            *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadROMError userInfo:@{
                NSLocalizedDescriptionKey : @"Unable to load ROM.",
                NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:@"\"%@\" (%@).\n\nThis machine does not work and the emulation is not yet complete. There is nothing you can do to fix this problem except wait for the MAME developers to improve the emulation.", driver.fullName, driver.name],
            }];
        }
        return NO;
    }
    
    return YES;
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    NSString *romDir = [path stringByDeletingLastPathComponent];
    Options *opts = _osd.options;
    [opts setBasePath:self.supportDirectoryPath];

    // Keep MAME's internal cheat menu off; OpenEmu provides its own cheat search.
    opts.cheat = NO;

    opts.romsPath = romDir;
    BOOL prev;
    prev = opts.autoStretchXY;
    opts.autoStretchXY = NO;
    prev = opts.unevenStretchX;
    opts.unevenStretchX = NO;
    prev = opts.unevenStretchY;
    opts.unevenStretchY = NO;
    prev = opts.unevenStretch;
    opts.unevenStretch = NO;
    opts.keepAspect = YES;
    
    _osd.verboseOutput = NO;

    NSString *rom = [[path lastPathComponent] stringByDeletingPathExtension];
    os_log_info(OE_CORE_LOG, "loading MAME driver %{public}@ from %{public}@", rom, romDir);

    AuditResult *ar;
    BOOL success = [_osd setDriver:rom withAuditResult:&ar error:error];
    if (!success)
    {
        os_log_error(OE_CORE_LOG, "failed to select MAME driver %{public}@", rom);
        return NO;
    }
    
    if (![self validateGameDriver:_osd.driver error:error])
    {
        os_log_error(OE_CORE_LOG, "MAME driver validation failed for %{public}@", rom);
        return NO;
    }
    
    os_log_info(OE_CORE_AUDIT_LOG, "audit summary for %{public}@ is %ld", rom, (long)ar.summary);
    if (ar.summary == AuditSummaryIncorrect || ar.summary == AuditSummaryNotFound)
    {
        os_log_error(OE_CORE_AUDIT_LOG, "audit failed for %{public}@", rom);
        if (error != nil)
        {
            *error = [self processAuditResult:ar forRomDir:romDir];
        }
        return NO;
    }
    
    if (![_osd initializeWithError:error])
    {
        os_log_error(OE_CORE_LOG, "MAME initialization failed for %{public}@", rom);
        return NO;
    }
    
    _supportsRewinding = _osd.supportsSave && _osd.stateSize < 1e6;
    if (_osd.supportsSave && !_supportsRewinding)
    {
        os_log_info(OE_CORE_LOG, "disabling rewind support, save state size too big %{iec-bytes}ld", _osd.stateSize);
    }

    return YES;
}

- (NSError *)processAuditResult:(AuditResult *)ar forRomDir:(NSString *)romDir
{
    GameDriver *driver = _osd.driver;
    NSString *gameDriverName = driver.name;
    NSMutableOrderedSet<MAMEAuditResult *> *results = [NSMutableOrderedSet new];
    
    for (AuditRecord *rec in ar.records) {
        
        switch (rec.substatus) {
            case AuditSubstatusGood:
                continue;
                
            case AuditSubstatusFoundNodump:
            case AuditSubstatusGoodNeedsRedump:
            case AuditSubstatusNotFoundNoDump:
            case AuditSubstatusNotFoundOptional:
                // acceptable conditions, based on audit.cpp:media_auditor::summarize method,
                // which all result in a BEST_AVAILABLE status
                continue;

            // bad conditions
                
            case AuditSubstatusFoundWrongLength: {
                os_log_error(OE_CORE_AUDIT_LOG, "wrong length: %{public}@, media type %ld", rec.name, rec.mediaType);
                [results addObject:[[MAMEAuditResult alloc] initWithDriver:gameDriverName auditRecord:rec]];
                break;
            }
                
            case AuditSubstatusFoundBadChecksum: {
                os_log_error(OE_CORE_AUDIT_LOG, "bad checksum: %{public}@, media type %ld", rec.name, rec.mediaType);
                [results addObject:[[MAMEAuditResult alloc] initWithDriver:gameDriverName auditRecord:rec]];
                break;
            }
                
            case AuditSubstatusNotFound: {
                os_log_error(OE_CORE_AUDIT_LOG, "not found: %{public}@, media type %ld", rec.name, rec.mediaType);
                [results addObject:[[MAMEAuditResult alloc] initWithDriver:gameDriverName auditRecord:rec]];
                break;
            }
                
            case AuditSubstatusUnverified:
            default:
                continue;
        }
    }
    
    // Sort missing files by ascending order
    NSSortDescriptor *sortDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"self"
                                                                     ascending:YES];
    [results sortUsingDescriptors:@[sortDescriptor]];
    
    // Determine if ROMs exist with missing files, or are not found
    NSURL *romDirURL = [NSURL fileURLWithPath:romDir isDirectory:YES];
    NSMutableString *missingFilesList = [NSMutableString string];
    for(MAMEAuditResult *result in results)
    {
        if ([result checkSetExistsInDir:romDirURL])
        {
            [missingFilesList appendString:[NSString stringWithFormat:@"%@  \t- INCORRECT SET\n", result.fileName]];
        }
        else
        {
            [missingFilesList appendString:[NSString stringWithFormat:@"%@  \t- NOT FOUND\n", result.fileName]];
        }
    }
    
    // Give an audit report to the user
    NSString *game = [NSString stringWithFormat:@"%@ (%@.zip)", driver.fullName, gameDriverName];
    NSString *versionRequired = [[[[NSBundle bundleForClass:[self class]] infoDictionary] objectForKey:@"CFBundleVersion"] substringToIndex:5];

    NSError *outErr = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadROMError userInfo:@{
        NSLocalizedDescriptionKey : @"Required files are missing.",
        NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:@"%@ requires:\n\n%@\nThese ROMs must be from a MAME %@ ROM set. Some of these files can be parent/device/BIOS ROMs, which are not part of the game, but are still required. Delete files already imported and reimport with correct files.", game, missingFilesList, versionRequired],
        }];

    return outErr;
}

- (void)resetEmulation
{
    [_osd scheduleHardReset];
}

#pragma mark - Video

- (const void *)getVideoBufferWithHint:(void *)hint
{
    _buffer = (uint32_t *)hint;
    [_osd setBuffer:hint size:NSSizeFromOEIntSize(_bufferSize)];
    return _buffer;
}

- (OEIntSize)bufferSize
{
    return _bufferSize;
}

- (OEIntRect)screenRect {
    return _screenRect;
}

- (OEIntSize)aspectSize
{
    return _aspectSize;
}

- (GLenum)pixelFormat
{
    return GL_BGRA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_INT_8_8_8_8_REV;
}

#pragma mark - execution

- (void)executeFrame
{
    [_osd execute];
}

- (void)stopEmulation
{
    _osd.delegate = nil;
    [_osd unload];
    [super stopEmulation];
}

- (NSTimeInterval)frameInterval
{
    return _frameInterval;
}

#pragma mark - Audio

- (double)audioSampleRate
{
    return 48000;
}

- (NSUInteger)channelCount
{
    return 2;
}

#pragma mark - Input

- (void)setState:(BOOL)pressed ofButton:(OEArcadeButton)button forPlayer:(NSUInteger)player
{
    if (player == 0 || player > 8 || button < 0 || button >= OEArcadeButtonCount)
    {
        os_log_error(OE_CORE_LOG, "ignoring invalid arcade input player %lu button %lu", (unsigned long)player, (unsigned long)button);
        return;
    }

    NSUInteger playerIndex = player - 1;
    _buttons[playerIndex][button] = pressed ? 1 : 0;
    _axes[playerIndex][0] = _buttons[playerIndex][OEArcadeButtonLeft] ? InputAbsoluteMin : (_buttons[playerIndex][OEArcadeButtonRight] ? InputAbsoluteMax : 0);
    _axes[playerIndex][1] = _buttons[playerIndex][OEArcadeButtonUp] ? InputAbsoluteMin : (_buttons[playerIndex][OEArcadeButtonDown] ? InputAbsoluteMax : 0);
}

- (oneway void)didPushArcadeButton:(OEArcadeButton)button forPlayer:(NSUInteger)player
{
    [self setState:YES ofButton:button forPlayer:player];
}

- (oneway void)didReleaseArcadeButton:(OEArcadeButton)button forPlayer:(NSUInteger)player
{
    [self setState:NO ofButton:button forPlayer:player];
}

#pragma mark - Save State

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    BOOL res     = NO;
    NSError *err = nil;
    
    if (_osd.supportsSave)
    {
        res = [_osd saveStateFromFileAtPath:fileName error:&err];
    }
    else
    {
        err = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotSaveStateError userInfo:@{
            NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Game \"%@\" does not not support save states.", _osd.driver.fullName],
        }];
    }
    
    block(res, err);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    BOOL res     = NO;
    NSError *err = nil;
    
    if (_osd.supportsSave)
    {
        res = [_osd loadStateFromFileAtPath:fileName error:&err];
    }
    else
    {
        err = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotSaveStateError userInfo:@{
            NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Game \"%@\" does not not support save states.", _osd.driver.fullName],
        }];
    }
    
    block(res, err);
}

- (BOOL)supportsRewinding
{
    return _supportsRewinding;
}

#pragma mark - Cheats

- (void)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled
{
    if (!_cheatList)
        _cheatList = [NSMutableDictionary dictionary];

    code = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    code = [code stringByReplacingOccurrencesOfString:@" " withString:@""];
    code = [code stringByReplacingOccurrencesOfString:@"=" withString:@":"];

    if (enabled)
        _cheatList[code] = @{@"enabled": @YES};
    else
        [_cheatList removeObjectForKey:code];

    // Disable all cheats first
    for (uint32_t i = 0; i < 256; i++) {
        [_osd setCheat:i address:0 value:0 size:1 enabled:NO];
    }

    // Re-apply all enabled cheats
    uint32_t idx = 0;
    for (NSString *key in _cheatList) {
        if (![_cheatList[key][@"enabled"] boolValue]) continue;
        if (idx >= 256) break;

        NSArray<NSString *> *parts = [key componentsSeparatedByString:@"+"];
        for (NSString *singleCode in parts) {
            if (idx >= 256) break;
            NSRange colonRange = [singleCode rangeOfString:@":"];
            if (colonRange.location == NSNotFound) continue;

            unsigned int addr = 0, val = 0;
            if (![[NSScanner scannerWithString:[singleCode substringToIndex:colonRange.location]] scanHexInt:&addr]) continue;
            if (![[NSScanner scannerWithString:[singleCode substringFromIndex:colonRange.location + 1]] scanHexInt:&val]) continue;

            NSUInteger valueHexLen = singleCode.length - colonRange.location - 1;
            uint8_t size = (uint8_t)((valueHexLen + 1) / 2);
            if (size == 0) size = 1;
            if (size > 4) size = 4;

            [_osd setCheat:idx address:addr value:val size:size enabled:YES];
            idx++;
        }
    }
}

- (NSArray<OEMemoryRegionDescriptor *> *)readableMemoryRegions
{
    NSArray<NSDictionary *> *regions = [_osd readableMemoryRegions];
    if (!regions || regions.count == 0) return @[];

    NSMutableArray<OEMemoryRegionDescriptor *> *result = [NSMutableArray arrayWithCapacity:regions.count];
    for (NSDictionary *dict in regions) {
        NSString *name = dict[@"name"] ?: @"RAM";
        uint32_t address = [dict[@"address"] unsignedIntValue];
        NSData *bytes = dict[@"bytes"];
        BOOL bigEndian = [dict[@"bigEndian"] boolValue];
        int8_t addressShift = (int8_t)[dict[@"addressShift"] intValue];
        if (!bytes) continue;

        // Size the address width to the region's highest address, not its base.
        uint64_t lastOffset = bytes.length - 1;
        uint32_t maxAddress = address + (uint32_t)(addressShift >= 0 ? lastOffset << addressShift : lastOffset >> -addressShift);
        uint8_t addrBytes = (maxAddress > 0xFFFF) ? 4 : (maxAddress > 0xFF) ? 3 : 2;
        uint8_t minDataBytes = bigEndian ? 2 : 1;

        [result addObject:[OEMemoryRegionDescriptor descriptorWithName:name
                                                              address:address
                                                         addressBytes:addrBytes
                                                         minDataBytes:minDataBytes
                                                         addressShift:addressShift
                                                                 data:bytes]];
    }
    return result;
}

- (NSData *)serializeStateWithError:(NSError *__autoreleasing *)outError
{
    return [_osd serializeState];
}

- (BOOL)deserializeState:(NSData *)state withError:(NSError *__autoreleasing *)outError
{
    return [_osd deserializeState:state];
}

@end

@implementation MAMEAuditResult
{
    NSString    *_driver;
    AuditRecord *_record;
}

- (instancetype)initWithDriver:(NSString *)driver auditRecord:(AuditRecord *)record
{
    if ((self = [super init]))
    {
        _driver = driver;
        _record = record;
    }
    return self;
}

- (NSString *)identifier
{
    if (_record.mediaType == AuditMediaTypeDisk)
    {
        // a CHD
        return _record.name;
    }
    
    Device *parent = _record.sharedDevice;
    if (parent)
    {
        return parent.shortName;
    }
    
    return _driver;
}

- (NSArray<NSString *> *)extensions
{
    if (_record.mediaType == AuditMediaTypeDisk)
    {
        return @[@".chd"];
    }
    
    return @[@".zip", @".7z"];
}

- (BOOL)isEqual:(id)object
{
    if (object == nil || ![object isKindOfClass:self.class])
    {
        return NO;
    }
    
    MAMEAuditResult *other = (MAMEAuditResult *)object;
    return [self.identifier isEqualToString:other.identifier];
}

- (NSComparisonResult)compare:(MAMEAuditResult *)other
{
    return [self.identifier compare:other.identifier];
}

/*! Returns the first valid file name for this result
 */
- (NSString *)fileName
{
    return [self.identifier stringByAppendingString:[[self extensions] firstObject]];
}

/*! Determines if the ROM set exists
 */
- (BOOL)checkSetExistsInDir:(NSURL *)dir
{
    for (NSString *ext in [self extensions])
    {
        NSURL *missingFileURL = [dir URLByAppendingPathComponent:[self.identifier stringByAppendingString:ext]];
    
        if([missingFileURL checkResourceIsReachableAndReturnError:nil])
        {
            return YES;
        }
    }
    return NO;
}

- (NSUInteger)hash
{
    return self.identifier.hash;
}

@end
