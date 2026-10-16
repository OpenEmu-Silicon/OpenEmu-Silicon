// Copyright (c) 2025, OpenEmu Team
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

// Rename macOS Carbon's RGBColor to avoid clash with Flycast's RGBColor
#define RGBColor __macOS_RGBColor
#import <Cocoa/Cocoa.h>
#undef RGBColor

#import "FlycastGameCore.h"
#import <OpenEmuBase/OERingBuffer.h>
#import <OpenEmuBase/OEGameCore.h>

#include "emulator.h"
#include "types.h"
#include "cfg/option.h"
#include "stdclass.h"
#include "hw/maple/maple_cfg.h"
#include "hw/maple/maple_devs.h"
#include "hw/pvr/Renderer_if.h"
#include "input/gamepad.h"
#include "input/gamepad_device.h"
#include "audio/audiostream.h"
#include "ui/gui.h"
#include "rend/gles/gles.h"
#include "hw/mem/addrspace.h"
#include "hw/sh4/sh4_mem.h"
#include "oslib/oslib.h"
#include "wsi/osx.h"

#define RC_CLIENT_SUPPORTS_HASH 1
#include <rc_client.h>
#include <rc_consoles.h>
#import "OERetroAchievementsTransport.h"
#import "OERetroAchievementsBridge.h"

#include <OpenGL/gl3.h>
#include <mach/mach_time.h>
#include <sys/stat.h>

#define SAMPLERATE 44100
#define SIZESOUNDBUFFER (44100 / 60 * 4)

#pragma mark - OpenEmu Audio Backend

// Custom AudioBackend that writes samples to OpenEmu's ring buffer
class OpenEmuAudioBackend : public AudioBackend
{
    mach_timebase_info_data_t _tb;
    uint64_t _nextPushTime = 0;
    uint64_t _frameAheadTicks = 0; // one NTSC frame of lookahead in mach ticks

public:
    OpenEmuAudioBackend() : AudioBackend("openemu", "OpenEmu") {}

    bool init() override {
        mach_timebase_info(&_tb);
        _nextPushTime = 0;
        // Allow SH4 to run up to two NTSC frames (~33.4ms) ahead of real time
        // before sleeping. Two frames gives SH4 enough runway to complete a full
        // PVR render cycle and signal the render thread before the 60ms timeout
        // fires, fixing video slowdown and maple-bus polling gaps (#202).
        _frameAheadTicks = (uint64_t)NSEC_PER_SEC / 60 * 2 * _tb.denom / _tb.numer;
        return true;
    }

    u32 push(const void *data, u32 frames, bool wait) override
    {
        if (!_current) return frames;

        if (wait) {
            // Wall-clock throttle: pace the SH4 thread to real time using
            // mach_absolute_time rather than ring-buffer drain rate. The
            // previous ring-buffer approach (#203) ran ~8.8% fast on 48 kHz
            // hosts because CoreAudio drained the buffer faster than the
            // 44100 Hz math assumed (#202).
            //
            // Advance the deadline first, then sleep only if SH4 is more than
            // one NTSC frame ahead of real time. This gives VBlank a full
            // ~16.7ms window to fire before we block the SH4 thread.
            uint64_t batchNanos = (uint64_t)frames * NSEC_PER_SEC / SAMPLERATE;
            uint64_t batchTicks = batchNanos * _tb.denom / _tb.numer;

            uint64_t now = mach_absolute_time();

            // Reset after pauses, save-state loads, or the very first push.
            // 60ms slack = three PAL frames; matches the wider 2-frame lookahead
            // window so a brief CPU hiccup doesn't trigger a spurious clock reset.
            uint64_t maxSlipTicks = (uint64_t)(60 * NSEC_PER_MSEC) * _tb.denom / _tb.numer;
            if (_nextPushTime == 0 || now > _nextPushTime + maxSlipTicks)
                _nextPushTime = now;

            _nextPushTime += batchTicks;

            // Only sleep when SH4 is more than one NTSC frame ahead.
            if (_nextPushTime > now + _frameAheadTicks) {
                uint64_t sleepTicks = _nextPushTime - (now + _frameAheadTicks);
                uint64_t sleepNanos = sleepTicks * _tb.numer / _tb.denom;
                usleep((useconds_t)(sleepNanos / 1000));
            }
        }

        OERingBuffer *buf = [_current audioBufferAtIndex:0];
        [buf write:(const uint8_t *)data maxLength:(NSUInteger)(frames * 4)];
        return frames;
    }

    void term() override { _nextPushTime = 0; }
};

static OpenEmuAudioBackend openEmuAudioBackend;

#pragma mark -

@interface FlycastGameCore () <OEDCSystemResponderClient>
{
    NSString *_romPath;
    int _videoWidth;
    int _videoHeight;
    BOOL _isInitialized;
    BOOL _emuInitialized;
    double _frameInterval;
    OERetroAchievementsBridge *_raBridge;
}
@end

__weak FlycastGameCore *_current;

// Mirrors Flycast's own RA reader (Achievements::clientReadMemory): rcheevos addresses the
// 16 MB Dreamcast system RAM from 0; it lives at SH4 0x0C000000. Read through the SH4 bus.
static uint32_t flycast_rc_read_memory(uint32_t address, uint8_t *buffer,
                                       uint32_t num_bytes, rc_client_t *client)
{
    if (address + num_bytes > RAM_SIZE)
        return 0;
    address += 0x0C000000;
    switch (num_bytes)
    {
        case 1: *buffer = ReadMem8_nommu(address); break;
        case 2: *(u16 *)buffer = ReadMem16_nommu(address); break;
        case 4: *(u32 *)buffer = ReadMem32_nommu(address); break;
        default: return 0;
    }
    return num_bytes;
}

@implementation FlycastGameCore

#pragma mark - Lifecycle

- (id)init
{
    if (self = [super init]) {
        _videoWidth = 640;
        _videoHeight = 480;
        _isInitialized = NO;
        _frameInterval = 59.94;
    }
    _current = self;
    return self;
}

- (void)dealloc
{
    [_raBridge shutdown];
    _raBridge = nil;

    _current = nil;
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    _romPath = [path copy];

    // Start the RA bridge now (login + disc hashing run off the ROM path, independent of
    // emulation state). markROMReady is deferred to -executeFrame, once the game has loaded
    // and Dreamcast RAM is mapped.
    _raBridge = [[OERetroAchievementsBridge alloc] initWithGameCore:self
                                                       memoryReader:flycast_rc_read_memory
                                                          consoleID:(uint32_t)RC_CONSOLE_DREAMCAST];
    [_raBridge startWithROMPath:path];

    return YES;
}

- (void)setupEmulation
{
    NSString *supportPath = [self supportDirectoryPath];
    NSString *savesPath   = [self batterySavesDirectoryPath];
    NSString *biosPath    = [self biosDirectoryPath];

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[supportPath stringByAppendingPathComponent:@"data"]
  withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:savesPath
  withIntermediateDirectories:YES attributes:nil error:nil];

    set_user_config_dir(supportPath.fileSystemRepresentation);
    set_user_data_dir(savesPath.fileSystemRepresentation);
    add_system_data_dir(supportPath.fileSystemRepresentation);
    add_system_data_dir(biosPath.fileSystemRepresentation);

    config::RendererType = RenderType::OpenGL;
    config::AudioBackend.set("openemu");
    // JIT was previously disabled due to a race under non-threaded rendering (#46cdc996).
    // Threaded rendering is always active in this build so that race does not apply.
    config::DynarecEnabled.override(true);

    if (!addrspace::reserve()) {
        NSLog(@"[Flycast] Failed to reserve Dreamcast address space");
    }
    os_InstallFaultHandler();

    emu.init();
    _emuInitialized = YES;
}

- (void)startEmulation
{
    [super startEmulation];
}

- (void)stopEmulationWithCompletionHandler:(void(^)(void))completionHandler
{
    // In threaded rendering mode, the OE game loop thread is blocked inside
    // rend_single_frame() waiting for the next frame from the SH4 thread.
    // emu.stop() calls rend_cancel_emu_wait() which unblocks it, freeing the
    // thread to execute the completion handler. Safe to call twice — emu.stop()
    // checks state != Running and returns immediately on the second call.
    if (_isInitialized)
        emu.stop();
    [super stopEmulationWithCompletionHandler:completionHandler];
}

- (void)stopEmulation
{
    [_raBridge shutdown];
    _raBridge = nil;

    if (_isInitialized) {
        emu.stop();
        emu.unloadGame();
        rend_term_renderer();
        theGLContext.term();
        _isInitialized = NO;
    }
    os_UninstallFaultHandler();
    if (_emuInitialized) {
        emu.term();
        _emuInitialized = NO;
    }
    [super stopEmulation];
}

- (void)resetEmulation
{
    if (_isInitialized) {
        emu.requestReset();
    }
    [_raBridge reset];
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

#pragma mark - Frame Execution

- (void)executeFrame
{
    if (!_isInitialized) {
        try {
            gui_init();
            theGLContext.init();
            emu.loadGame(_romPath.fileSystemRepresentation);
            // loadGame calls reset()+load() which clears all settings — re-apply after it returns.
            config::DynarecEnabled.override(true);  // JIT race was non-threaded-rendering only; threaded is always active
            config::AudioBackend.set("openemu");    // reset() clears this to "auto"; restore before InitAudio()
            // loadGameSpecificSettings() runs load(true) which can flip UseReios=false from a per-game
            // config. Without HLE BIOS the VBL-driven GD-ROM server is inert and games freeze on a
            // black screen. Force HLE on for any user without a real Dreamcast BIOS installed.
            config::UseReios.override(true);
            rend_init_renderer();
            emu.start();
            gui_setState(GuiState::Closed);
            _isInitialized = YES;

            // Dreamcast RAM is mapped now; let rcheevos read it during -doFrame.
            [_raBridge markROMReady];
        } catch (const std::exception &e) {
            NSLog(@"[Flycast] Error loading game: %s", e.what());
            return;
        } catch (...) {
            NSLog(@"[Flycast] Unknown error loading game");
            return;
        }
    }

    emu.render();

    [_raBridge doFrame];
}

#pragma mark - Video

- (OEGameCoreRendering)gameCoreRendering
{
    return OEGameCoreRenderingOpenGL3Video;
}

- (BOOL)needsDoubleBufferedFBO
{
    return NO;
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(_videoWidth, _videoHeight);
}

- (OEIntSize)aspectSize
{
    return OEIntSizeMake(4, 3);
}

- (NSTimeInterval)frameInterval
{
    return _frameInterval;
}

#pragma mark - Audio

- (NSUInteger)channelCount
{
    return 2;
}

- (double)audioSampleRate
{
    return SAMPLERATE;
}

#pragma mark - Save States

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    if (!_isInitialized) { block(NO, nil); return; }

    @try {
        dc_savestate(0);
        std::string srcPath = hostfs::getSavestatePath(0, false);
        NSString *src = [NSString stringWithUTF8String:srcPath.c_str()];
        NSError *err = nil;
        [[NSFileManager defaultManager] removeItemAtPath:fileName error:nil];
        [[NSFileManager defaultManager] copyItemAtPath:src toPath:fileName error:&err];
        block(err == nil, err);
    } @catch (NSException *e) {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                             code:OEGameCoreCouldNotSaveStateError
                                         userInfo:@{NSLocalizedDescriptionKey: e.reason ?: @"Failed to save state"}];
        block(NO, error);
    }
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    if (!_isInitialized) { block(NO, nil); return; }

    @try {
        std::string dstPath = hostfs::getSavestatePath(0, true);
        NSString *dst = [NSString stringWithUTF8String:dstPath.c_str()];
        NSError *err = nil;
        [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
        [[NSFileManager defaultManager] copyItemAtPath:fileName toPath:dst error:&err];
        if (!err) dc_loadstate(0);
        block(err == nil, err);
    } @catch (NSException *e) {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                             code:OEGameCoreCouldNotLoadStateError
                                         userInfo:@{NSLocalizedDescriptionKey: e.reason ?: @"Failed to load state"}];
        block(NO, error);
    }
}

#pragma mark - Input

- (oneway void)didMoveDCJoystickDirection:(OEDCButton)button withValue:(CGFloat)value forPlayer:(NSUInteger)player
{
    NSUInteger p = player - 1;
    if (p > 3) return;

    switch (button) {
        case OEDCAnalogUp:    joyy[p] = (s16)(value * -32768); break;
        case OEDCAnalogDown:  joyy[p] = (s16)(value *  32767); break;
        case OEDCAnalogLeft:  joyx[p] = (s16)(value * -32768); break;
        case OEDCAnalogRight: joyx[p] = (s16)(value *  32767); break;
        case OEDCAnalogL:     lt[p]   = (u16)(value * 65535);  break;
        case OEDCAnalogR:     rt[p]   = (u16)(value * 65535);  break;
        default: break;
    }
}

- (oneway void)didPushDCButton:(OEDCButton)button forPlayer:(NSUInteger)player
{
    NSUInteger p = player - 1;
    if (p > 3) return;

    switch (button) {
        case OEDCButtonUp:    kcode[p] &= ~DC_DPAD_UP;    break;
        case OEDCButtonDown:  kcode[p] &= ~DC_DPAD_DOWN;  break;
        case OEDCButtonLeft:  kcode[p] &= ~DC_DPAD_LEFT;  break;
        case OEDCButtonRight: kcode[p] &= ~DC_DPAD_RIGHT; break;
        case OEDCButtonA:     kcode[p] &= ~DC_BTN_A;      break;
        case OEDCButtonB:     kcode[p] &= ~DC_BTN_B;      break;
        case OEDCButtonX:     kcode[p] &= ~DC_BTN_X;      break;
        case OEDCButtonY:     kcode[p] &= ~DC_BTN_Y;      break;
        case OEDCButtonStart: kcode[p] &= ~DC_BTN_START;  break;
        default: break;
    }
}

- (oneway void)didReleaseDCButton:(OEDCButton)button forPlayer:(NSUInteger)player
{
    NSUInteger p = player - 1;
    if (p > 3) return;

    switch (button) {
        case OEDCButtonUp:    kcode[p] |= DC_DPAD_UP;    break;
        case OEDCButtonDown:  kcode[p] |= DC_DPAD_DOWN;  break;
        case OEDCButtonLeft:  kcode[p] |= DC_DPAD_LEFT;  break;
        case OEDCButtonRight: kcode[p] |= DC_DPAD_RIGHT; break;
        case OEDCButtonA:     kcode[p] |= DC_BTN_A;      break;
        case OEDCButtonB:     kcode[p] |= DC_BTN_B;      break;
        case OEDCButtonX:     kcode[p] |= DC_BTN_X;      break;
        case OEDCButtonY:     kcode[p] |= DC_BTN_Y;      break;
        case OEDCButtonStart: kcode[p] |= DC_BTN_START;  break;
        default: break;
    }
}

@end
