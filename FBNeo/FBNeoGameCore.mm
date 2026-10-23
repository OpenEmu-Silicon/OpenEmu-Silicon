// Copyright (c) 2026, OpenEmu Team
// Author: Leonardo Kasperavičius
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

#import "FBNeoGameCore.h"

#import <OpenEmuBase/OEAudioBuffer.h>
#import <OpenEmuBase/OEMemoryRegionDescriptor.h>
#import <OpenGL/gl.h>
#import <os/log.h>

#include "fbheadless.h"

#define RC_CLIENT_SUPPORTS_HASH 1
#include <rc_client.h>
#include <rc_consoles.h>
#import "OERetroAchievementsTransport.h"
#import "OERetroAchievementsBridge.h"

static os_log_t OE_CORE_LOG;

// FBNeo arcade achievement sets are authored against the flat main-RAM buffer
// (CpsRamFF for CPS, "68K RAM" for Neo Geo, etc.) that FBHeadlessReadAchievementMemory
// exposes — not the CPU hardware address space. The bridge gates this for
// ROM-readiness and shutdown.
static uint32_t fbneo_rc_read_memory(uint32_t address, uint8_t *buffer, uint32_t num_bytes, rc_client_t *client)
{
    return FBHeadlessReadAchievementMemory(address, buffer, num_bytes);
}

@implementation FBNeoGameCore
{
    uint32_t *_videoBuffer; // OpenEmu-provided frame buffer (the "hint")
    int _width;
    int _height;
    int _aspectX;
    int _aspectY;
    double _frameInterval;
    OERetroAchievementsBridge *_raBridge;
    NSMutableDictionary<NSString *, NSNumber *> *_cheatList; // code -> enabled
    int _cheatsBigEndian;                                    // main CPU multibyte order
}

+ (void)initialize
{
    OE_CORE_LOG = os_log_create("org.openemu.FBNeo", "");
}

- (instancetype)init
{
    if (self = [super init]) {
        _width = 384;
        _height = 224;
        _aspectX = 4;
        _aspectY = 3;
        _frameInterval = 60.0;
    }
    return self;
}

#pragma mark - Lifecycle

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    FBHeadlessInit();

    NSString *romDir = [path stringByDeletingLastPathComponent];
    FBHeadlessSetRomPath(romDir.fileSystemRepresentation);

    // FBNeo identifies a set by its short name (the zip filename without extension).
    NSString *shortName = [[path lastPathComponent] stringByDeletingPathExtension];
    os_log_info(OE_CORE_LOG, "loading FBNeo driver %{public}@ from %{public}@", shortName, romDir);

    if (FBHeadlessLoadDriver(shortName.UTF8String) != 0) {
        os_log_error(OE_CORE_LOG, "failed to load FBNeo driver %{public}@", shortName);
        if (error) {
            *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadROMError userInfo:@{
                NSLocalizedDescriptionKey: @"Unable to load ROM.",
                NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:@"\"%@\" is not a recognized FinalBurn Neo set, or required ROM files are missing. The ROMs must be from an FBNeo-compatible set.", shortName],
            }];
        }
        // Undo FBHeadlessInit so global state doesn't leak and a retry starts clean.
        FBHeadlessExit();
        return NO;
    }

    _width = FBHeadlessGetVideoWidth();
    _height = FBHeadlessGetVideoHeight();

    int fps = FBHeadlessGetFrameRate(); // frames * 100
    _frameInterval = fps > 0 ? fps / 100.0 : 60.0;

    _aspectX = FBHeadlessGetAspectX();
    _aspectY = FBHeadlessGetAspectY();
    if (_aspectX <= 0 || _aspectY <= 0) {
        _aspectX = _width;
        _aspectY = _height;
    }

    // Cache the main-CPU multibyte order for cheat writes (from the first RAM region).
    _cheatsBigEndian = 0;
    if (FBHeadlessGetMemoryRegionCount() > 0) {
        unsigned int rs = 0, rl = 0;
        int be = 0;
        FBHeadlessGetMemoryRegion(0, &rs, &rl, &be);
        _cheatsBigEndian = be;
    }

    // RAM is valid once the driver is initialized; arcade hashing uses the file name.
    _raBridge = [[OERetroAchievementsBridge alloc] initWithGameCore:self
                                                       memoryReader:fbneo_rc_read_memory
                                                          consoleID:RC_CONSOLE_ARCADE];
    [_raBridge startWithROMPath:path];
    [_raBridge markROMReady];

    return YES;
}

- (void)resetEmulation
{
    [_raBridge reset];
    FBHeadlessReset();
}

- (void)stopEmulation
{
    [_raBridge shutdown];
    _raBridge = nil;
    FBHeadlessExit();
    [super stopEmulation];
}

- (void)dealloc
{
    [_raBridge shutdown];
    _raBridge = nil;
}

- (void)executeFrame
{
    FBHeadlessRunFrame(1);

    [self applyCheats];

    const unsigned char *src = FBHeadlessGetVideoBuffer();
    if (src != NULL && _videoBuffer != NULL) {
        // Safe: OpenEmu allocates _videoBuffer via bufferSize/getVideoBufferWithHint in
        // setupEmulation, which runs only after loadFileAtPath has set _width/_height to the
        // driver's real size, so the destination is always sized for this copy.
        memcpy(_videoBuffer, src, (size_t)_width * (size_t)_height * 4);
    }

    int frames = FBHeadlessGetAudioFrames();
    const short *abuf = FBHeadlessGetAudioBuffer();
    if (frames > 0 && abuf != NULL) {
        id<OEAudioBuffer> buf = [self audioBufferAtIndex:0];
        [buf write:abuf maxLength:(NSUInteger)frames * 2 * sizeof(int16_t)];
    }

    [_raBridge doFrame];
}

- (NSTimeInterval)frameInterval
{
    return _frameInterval;
}

#pragma mark - Video

- (const void *)getVideoBufferWithHint:(void *)hint
{
    _videoBuffer = (uint32_t *)hint;
    return _videoBuffer;
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(_width, _height);
}

- (OEIntRect)screenRect
{
    return OEIntRectMake(0, 0, _width, _height);
}

- (OEIntSize)aspectSize
{
    return OEIntSizeMake(_aspectX, _aspectY);
}

- (GLenum)pixelFormat
{
    return GL_BGRA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_INT_8_8_8_8_REV;
}

#pragma mark - Audio

- (double)audioSampleRate
{
    return FBHeadlessGetAudioSampleRate();
}

- (NSUInteger)channelCount
{
    return 2;
}

#pragma mark - Save States

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    BOOL success = FBHeadlessSaveState(fileName.fileSystemRepresentation) == 0;
    if (success) {
        block(YES, nil);
    } else {
        block(NO, [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotSaveStateError userInfo:@{
            NSLocalizedDescriptionKey: @"Save state failed.",
            NSLocalizedRecoverySuggestionErrorKey: @"FinalBurn Neo could not write a save state for this game.",
        }]);
    }
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    BOOL success = FBHeadlessLoadState(fileName.fileSystemRepresentation) == 0;
    if (success) {
        block(YES, nil);
    } else {
        block(NO, [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadStateError userInfo:@{
            NSLocalizedDescriptionKey: @"Load state failed.",
            NSLocalizedRecoverySuggestionErrorKey: @"This save state could not be loaded, possibly because it was made with a different game or core version.",
        }]);
    }
}

#pragma mark - Input

// OEArcadeButton values (Up..Service) align with FBHeadlessButton; the fork maps
// them to the active driver's inputs.
- (void)setState:(BOOL)pressed ofButton:(OEArcadeButton)button forPlayer:(NSUInteger)player
{
    if (player == 0 || player > 4) {
        return;
    }
    if (button >= OEArcadeUIConfigure) {
        return; // UI command, not a game input
    }
    FBHeadlessSetInput((int)(player - 1), (int)button, pressed ? 1 : 0);
}

- (oneway void)didPushArcadeButton:(OEArcadeButton)button forPlayer:(NSUInteger)player
{
    [self setState:YES ofButton:button forPlayer:player];
}

- (oneway void)didReleaseArcadeButton:(OEArcadeButton)button forPlayer:(NSUInteger)player
{
    [self setState:NO ofButton:button forPlayer:player];
}

#pragma mark - Cheats

// Cheats operate on the same flat RAM map as achievements/search, so a value found
// in the search window can be written back by address. Codes are ADDRESS:VALUE hex
// (multi-part joined with '+'); the game overwrites RAM, so enabled codes are
// re-applied every frame.
- (void)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled
{
    if (_cheatList == nil) {
        _cheatList = [NSMutableDictionary dictionary];
    }
    code = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    code = [code stringByReplacingOccurrencesOfString:@" " withString:@""];
    code = [code stringByReplacingOccurrencesOfString:@"=" withString:@":"];
    if (enabled) {
        _cheatList[code] = @YES;
    } else {
        [_cheatList removeObjectForKey:code];
    }
}

- (void)applyCheats
{
    if (_cheatList.count == 0) {
        return;
    }
    int littleEndian = _cheatsBigEndian ? 0 : 1;
    for (NSString *key in _cheatList) {
        if (![_cheatList[key] boolValue]) {
            continue;
        }
        for (NSString *single in [key componentsSeparatedByString:@"+"]) {
            NSRange colon = [single rangeOfString:@":"];
            if (colon.location == NSNotFound) {
                continue;
            }
            unsigned int addr = 0, value = 0;
            if (![[NSScanner scannerWithString:[single substringToIndex:colon.location]] scanHexInt:&addr]) {
                continue;
            }
            NSString *valueStr = [single substringFromIndex:colon.location + 1];
            if (![[NSScanner scannerWithString:valueStr] scanHexInt:&value]) {
                continue;
            }
            int size = (int)((valueStr.length + 1) / 2);
            if (size < 1) size = 1;
            if (size > 4) size = 4;
            FBHeadlessWriteAchievementMemory(addr, value, size, littleEndian);
        }
    }
}

- (NSArray<OEMemoryRegionDescriptor *> *)readableMemoryRegions
{
    int count = FBHeadlessGetMemoryRegionCount();
    if (count <= 0) {
        return @[];
    }
    NSMutableArray<OEMemoryRegionDescriptor *> *result = [NSMutableArray arrayWithCapacity:count];
    for (int i = 0; i < count; i++) {
        unsigned int start = 0, length = 0;
        int bigEndian = 0;
        if (!FBHeadlessGetMemoryRegion(i, &start, &length, &bigEndian) || length == 0) {
            continue;
        }
        void *bytes = malloc(length);
        if (bytes == NULL) {
            continue;
        }
        FBHeadlessReadAchievementMemory(start, (unsigned char *)bytes, length);
        NSData *data = [NSData dataWithBytesNoCopy:bytes length:length freeWhenDone:YES];

        unsigned int maxAddress = start + length - 1;
        uint8_t addrBytes = (maxAddress > 0xFFFF) ? 4 : (maxAddress > 0xFF) ? 3 : 2;
        uint8_t minDataBytes = bigEndian ? 2 : 1;
        [result addObject:[OEMemoryRegionDescriptor descriptorWithName:@"RAM"
                                                               address:start
                                                          addressBytes:addrBytes
                                                          minDataBytes:minDataBytes
                                                                  data:data]];
    }
    return result;
}

#pragma mark - RetroAchievements

- (void)retroAchievementsIdle
{
    [_raBridge idle];
}

- (BOOL)canPauseRetroAchievementsHardcoreWithFramesRemaining:(uint32_t *)framesRemaining
{
    return _raBridge ? [_raBridge canPauseWithFramesRemaining:framesRemaining] : YES;
}

- (NSData *)retroAchievementsSerializedProgress
{
    return [_raBridge serializeProgress];
}

- (void)retroAchievementsDeserializeProgress:(NSData *)data
{
    [_raBridge deserializeProgress:data];
}

@end
