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

// OpenEmu wrapper for the Azahar Nintendo 3DS engine.
//
// Run model: frame-driven. OpenEmu's game loop calls executeFrame, and each call runs the
// engine until it has drawn one frame (AzaharHost::RunFrame). Azahar's own libretro frontend
// runs the engine the same way, and it keeps pause, reset, frame step and speed changes in
// OpenEmu's hands with no second thread to hand frames over from. OpenEmu paces the loop, so
// the engine's own frame limiter is off.
//
// This file includes no engine headers; AzaharHost.cpp is the only code that does.

#import "AzaharGameCore.h"
#import "AzaharHost.h"

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenEmuBase/OEAudioBuffer.h>
#import <OpenEmuBase/OERingBuffer.h>

#include <cmath>

static NSString *const kLayoutKey = @"azahar.layout";
static NSString *const kScaleKey = @"azahar.resolution";
static NSString *const kStereoKey = @"azahar.stereo";
static NSString *const kStereoDepthKey = @"azahar.stereo.depth";

static const NSUInteger kFrameWidth = 400;
static const NSUInteger kFrameHeight = 480;

@implementation AzaharGameCore {
    NSURL *_gameURL;
    NSView *_renderView;       // carries the CAMetalLayer the engine creates its Vulkan surface from
    id<MTLDevice> _device;
    id<MTLTexture> _texture;        // black, shown until the engine has drawn a frame
    id<MTLTexture> _frameTexture;   // the engine's newest finished frame (atomic via @synchronized)
    BOOL _loaded;
    BOOL _touching;
    NSString *_layoutName;
    NSUInteger _scale;
    NSString *_stereoName;
    NSUInteger _stereoDepthPercent;
    uint32_t *_videoBuffer;
    BOOL _ownsVideoBuffer;
    // Keep the click-free audio restart after brief ring-buffer starvation.
    CFAbsoluteTime _audioLastDeliveryAt;
    NSUInteger _audioFadeFramesRemaining;
    // Display Candidate 3: preserve OpenEmu's natural window geometry by letting
    // it settle on a native-size frame before publishing high-resolution frames.
    // This does NOT downsample the final frame: after the short geometry phase,
    // Metal textures and screenRect both use the engine's complete output size.
    NSUInteger _nativeStartupFrames;
    BOOL _nativeStartupComplete;
    NSUInteger _nativeLayoutFramesRemaining;
    AzaharHost::Layout _requestedLayoutOnCoreThread;
    unsigned _requestedScaleOnCoreThread;
    AzaharHost::StereoMode _requestedStereoOnCoreThread;
    unsigned _requestedDepthOnCoreThread;
    AzaharHost::Layout _appliedLayoutOnCoreThread;
    AzaharHost::StereoMode _appliedStereoOnCoreThread;
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    _gameURL = [NSURL fileURLWithPath:path];

    NSFileManager *fm = NSFileManager.defaultManager;
    // OpenEmu's support folder is already this core's (~/Library/Application Support/OpenEmu/Azahar).
    NSURL *userDir = self.supportDirectory;
    [fm createDirectoryAtURL:userDir withIntermediateDirectories:YES attributes:nil error:NULL];

    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    AzaharHost::Folders folders;
    folders.userDir = userDir.fileSystemRepresentation;
    folders.moltenVKPath = [bundle.privateFrameworksPath stringByAppendingPathComponent:@"libMoltenVK.dylib"].fileSystemRepresentation;

    std::string failure;
    if (!AzaharHost::Initialize(folders, &failure)) {
        return [self failLoad:error message:@(failure.c_str())];
    }
    [self ensureRenderView];
    AzaharHost::SetRenderSurface((__bridge void *)_renderView.layer);

    // Initialize starts with native geometry even if a previous session left
    // engine globals at 4x. Saved modes are restored below, but their high-res
    // scale is deferred until OpenEmu has established the first window size.
    _nativeStartupFrames = 0;
    _nativeStartupComplete = NO;
    _nativeLayoutFramesRemaining = 0;
    _requestedLayoutOnCoreThread = AzaharHost::Layout::Stacked;
    _appliedLayoutOnCoreThread = AzaharHost::Layout::Stacked;
    _requestedScaleOnCoreThread = 1;
    _requestedStereoOnCoreThread = AzaharHost::StereoMode::Off;
    _appliedStereoOnCoreThread = AzaharHost::StereoMode::Off;
    _requestedDepthOnCoreThread = 100;
    _stereoDepthPercent = 100; // Default full 3D depth; selectable in 10% steps.
    AzaharHost::SetDisplay(AzaharHost::Layout::Stacked, 1, AzaharHost::StereoMode::Off, 100);

    if (!AzaharHost::Load(path.fileSystemRepresentation, &failure)) {
        return [self failLoad:error message:@(failure.c_str())];
    }
    _loaded = YES;
    // Bring back the layout and resolution picked last time.
    for (NSString *key in @[kLayoutKey, kScaleKey, kStereoKey, kStereoDepthKey]) {
        NSString *saved = self.displayModeInfo[key];
        if ([saved isKindOfClass:NSString.class]) {
            [self changeDisplayWithMode:saved];
        }
    }

    _videoBuffer = (uint32_t *)calloc(kFrameWidth * kFrameHeight, sizeof(uint32_t));
    _ownsVideoBuffer = YES;
    return YES;
}

- (BOOL)failLoad:(NSError **)error message:(NSString *)message
{
    if (error) {
        *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                     code:OEGameCoreCouldNotLoadROMError
                                 userInfo:@{NSLocalizedDescriptionKey: message, NSURLErrorKey: _gameURL}];
    }
    return NO;
}

// The engine needs a layer to create its Vulkan surface from, even though the picture goes to
// OpenEmu's texture. Build it on the main thread.
- (void)ensureRenderView
{
    if (_renderView != nil) {
        return;
    }
    void (^make)(void) = ^{
        NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kFrameWidth, kFrameHeight)];
        view.wantsLayer = YES;
        view.layer = [CAMetalLayer layer];
        self->_renderView = view;
    };
    if (NSThread.isMainThread) {
        make();
    } else {
        dispatch_sync(dispatch_get_main_queue(), make);
    }
}

- (void)setupEmulation
{
}

- (void)startEmulation
{
    // OpenEmu's ring is 75 ms and normally refuses a read unless it has 2x the
    // requested audio. During 3DS loading spikes that can turn a brief shortage
    // into a full silent callback. For this core only, allow *partial* reads:
    // OpenEmu's unchanged audio renderer already zero-fills the missing tail.
    id<OEAudioBuffer> audio = [self audioBufferAtIndex:0];
    if ([audio isKindOfClass:[OERingBuffer class]]) {
        ((OERingBuffer *)audio).anticipatesUnderflow = NO;
    }
    [super startEmulation];
    // OpenEmu's Metal renderer makes the game loop wait after every frame for a signal that
    // only OpenGL cores send. We pace the engine ourselves, so turn that wait off.
    [self.renderDelegate suspendFPSLimiting];
}

- (void)stopEmulation
{
    if (_loaded) {
        _loaded = NO;
        AzaharHost::Shutdown();
    }
    [super stopEmulation];
}

- (void)resetEmulation
{
    if (_loaded) {
        AzaharHost::Reset();
    }
}

#pragma mark - Display modes

static NSArray<NSString *> *LayoutNames(void)
{
    return @[@"Stacked", @"Top Screen Only", @"Bottom Screen Only", @"Side-by-Side", @"Large Top Screen"];
}

static NSArray<NSString *> *StereoNames(void)
{
    return @[@"Off (2D)", @"Side-by-Side Half", @"Side-by-Side Full", @"Anaglyph (Red/Cyan)"];
}

// Legacy display-mode values may still be stored in OpenEmu preferences.
// Normalize them so existing users keep their selected layout and stereo mode.
static NSString *CanonicalDisplayModeName(NSString *name)
{
    if ([name isEqualToString:@"Top screen only"])    return @"Top Screen Only";
    if ([name isEqualToString:@"Bottom screen only"]) return @"Bottom Screen Only";
    if ([name isEqualToString:@"Side by side"])       return @"Side-by-Side";
    if ([name isEqualToString:@"Large top screen"])    return @"Large Top Screen";
    if ([name isEqualToString:@"Side-by-side Half"])  return @"Side-by-Side Half";
    if ([name isEqualToString:@"Side-by-side Full"])  return @"Side-by-Side Full";
    return name;
}

static AzaharHost::StereoMode StereoForName(NSString *name)
{
    switch ([StereoNames() indexOfObject:name]) {
        case 1: return AzaharHost::StereoMode::SideBySideHalf;
        case 2: return AzaharHost::StereoMode::SideBySideFull;
        case 3: return AzaharHost::StereoMode::Anaglyph;
        default: return AzaharHost::StereoMode::Off;
    }
}

static AzaharHost::Layout LayoutForName(NSString *name)
{
    const NSUInteger i = [LayoutNames() indexOfObject:name];
    switch (i) {
        case 1: return AzaharHost::Layout::TopOnly;
        case 2: return AzaharHost::Layout::BottomOnly;
        case 3: return AzaharHost::Layout::SideBySide;
        case 4: return AzaharHost::Layout::LargeTop;
        default: return AzaharHost::Layout::Stacked;
    }
}

- (NSArray<NSDictionary<NSString *, id> *> *)displayModes
{
    NSString *layout = _layoutName ?: LayoutNames()[0];
    const NSUInteger scale = _scale ?: 1;
    NSMutableArray *layouts = [NSMutableArray array];
    for (NSString *name in LayoutNames()) {
        [layouts addObject:OEDisplayMode_OptionWithStateValue(name, kLayoutKey, @([name isEqualToString:layout]), name)];
    }
    NSMutableArray *scales = [NSMutableArray array];
    for (NSUInteger s = 1; s <= 6; s++) {
        NSString *name = [NSString stringWithFormat:@"%lux", (unsigned long)s];
        [scales addObject:OEDisplayMode_OptionWithStateValue(name, kScaleKey, @(s == scale), name)];
    }
    // Stereo output is independent of how the two 3DS screens are arranged.
    NSString *stereo = _stereoName ?: StereoNames()[0];
    NSMutableArray *stereos = [NSMutableArray array];
    for (NSString *name in StereoNames()) {
        [stereos addObject:OEDisplayMode_OptionWithStateValue(name, kStereoKey,
                                                             @([name isEqualToString:stereo]), name)];
    }
    // Keep the menu ordered Resolution, Screen Layout, Stereoscopic Mode,
    // and (only while stereo is active) 3D Depth at the very bottom.
    NSMutableArray *groups = [NSMutableArray arrayWithArray:@[
        @{OEGameCoreDisplayModeGroupNameKey: @"Resolution", OEGameCoreDisplayModeGroupItemsKey: scales},
        @{OEGameCoreDisplayModeGroupNameKey: @"Screen Layout", OEGameCoreDisplayModeGroupItemsKey: layouts},
        @{OEGameCoreDisplayModeGroupNameKey: @"Stereoscopic Mode", OEGameCoreDisplayModeGroupItemsKey: stereos},
    ]];
    // OpenEmu re-requests displayModes after a selection. Hide depth while 2D
    // is active; retain the saved depth for the next time stereo is enabled.
    if (![stereo isEqualToString:StereoNames()[0]]) {
        NSMutableArray *depths = [NSMutableArray array];
        for (NSUInteger d = 10; d <= 100; d += 10) {
            NSString *name = [NSString stringWithFormat:@"%lu%%", (unsigned long)d];
            [depths addObject:OEDisplayMode_OptionWithStateValue(name, kStereoDepthKey,
                                                                 @(d == _stereoDepthPercent), name)];
        }
        [groups addObject:@{OEGameCoreDisplayModeGroupNameKey: @"3D Depth", OEGameCoreDisplayModeGroupItemsKey: depths}];
    }
    return groups;
}

- (void)changeDisplayWithMode:(NSString *)displayMode
{
    // Accept values saved by previous builds, but use the new labels going forward.
    displayMode = CanonicalDisplayModeName(displayMode);
    if ([LayoutNames() containsObject:displayMode]) {
        _layoutName = displayMode;
    } else if (displayMode.length == 2 && [displayMode hasSuffix:@"x"] && [displayMode integerValue] >= 1 && [displayMode integerValue] <= 6) {
        _scale = (NSUInteger)[displayMode integerValue];
    } else if ([StereoNames() containsObject:displayMode]) {
        _stereoName = displayMode;
    } else if ([displayMode hasSuffix:@"%"] && displayMode.length >= 3) {
        NSString *numeric = [displayMode substringToIndex:displayMode.length - 1];
        const NSInteger amount = [numeric integerValue];
        if (amount < 10 || amount > 100 || amount % 10 != 0 ||
            ![numeric isEqualToString:[NSString stringWithFormat:@"%ld", (long)amount]]) return;
        _stereoDepthPercent = (NSUInteger)amount;
    } else {
        return;
    }
    NSString *layout = _layoutName ?: LayoutNames()[0];
    const NSUInteger scale = _scale ?: 1;
    NSString *stereo = _stereoName ?: StereoNames()[0];
    const NSUInteger depth = _stereoDepthPercent;
    const BOOL layoutModeChanged = [LayoutNames() containsObject:displayMode];
    [self performBlock:^{
        const AzaharHost::Layout requestedLayout = LayoutForName(layout);
        const unsigned requestedScale = (unsigned)scale;
        const AzaharHost::StereoMode requestedStereo = StereoForName(stereo);
        const unsigned requestedDepth = (unsigned)depth;
        const BOOL layoutActuallyChanged =
            layoutModeChanged && requestedLayout != self->_appliedLayoutOnCoreThread;
        const BOOL fullStereoWidthChanged =
            (requestedStereo == AzaharHost::StereoMode::SideBySideFull) !=
            (self->_appliedStereoOnCoreThread == AzaharHost::StereoMode::SideBySideFull);
        self->_requestedLayoutOnCoreThread = requestedLayout;
        self->_requestedScaleOnCoreThread = requestedScale;
        self->_requestedStereoOnCoreThread = requestedStereo;
        self->_requestedDepthOnCoreThread = requestedDepth;

        // Initial startup: give OpenEmu a correctly shaped native frame before
        // reporting the complete high-resolution texture and source rectangle.
        // When changing layouts later at >1x, similarly show a few native frames
        // so its existing one-shot aspect-change resize uses natural dimensions.
        // Resolution changes within the same layout do not change its aspect.
        if (!self->_nativeStartupComplete) {
            AzaharHost::SetDisplay(requestedLayout, 1, requestedStereo, requestedDepth);
            self->_appliedLayoutOnCoreThread = requestedLayout;
            self->_appliedStereoOnCoreThread = requestedStereo;
        } else if ((layoutActuallyChanged || fullStereoWidthChanged) && requestedScale > 1) {
            // Both the two-screen layout and SBS Full alter the image's natural
            // aspect. Stage one native-size image before restoring 2x-4x pixels.
            self->_nativeLayoutFramesRemaining = 12;
            AzaharHost::SetDisplay(requestedLayout, 1, requestedStereo, requestedDepth);
            self->_appliedLayoutOnCoreThread = requestedLayout;
            self->_appliedStereoOnCoreThread = requestedStereo;
        } else if (self->_nativeLayoutFramesRemaining > 0) {
            AzaharHost::SetDisplay(requestedLayout, 1, requestedStereo, requestedDepth);
            self->_appliedLayoutOnCoreThread = requestedLayout;
            self->_appliedStereoOnCoreThread = requestedStereo;
        } else {
            AzaharHost::SetDisplay(requestedLayout, requestedScale, requestedStereo, requestedDepth);
            self->_appliedLayoutOnCoreThread = requestedLayout;
            self->_appliedStereoOnCoreThread = requestedStereo;
        }
    }];
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    // OpenEmuHelperApp already dispatches saveStateToFile to OEGameCore's run loop.
    // Re-enqueueing it from the emulation thread can strand the close-time autosave:
    // the callback requesting the save runs, but the nested CFRunLoopPerformBlock may
    // never execute. Preserve the emulation-thread requirement without the extra hop.
    void (^saveOnCoreThread)(void) = ^{
        std::string failure;
        const BOOL ok = self->_loaded && AzaharHost::SaveState(fileName.fileSystemRepresentation, &failure);
        block(ok, ok ? nil : [NSError errorWithDomain:OEGameCoreErrorDomain
                                                 code:OEGameCoreCouldNotSaveStateError
                                             userInfo:@{NSLocalizedDescriptionKey: @(failure.c_str())}]);
    };

    if ([[[NSThread currentThread] name] isEqualToString:@"org.openemu.core-thread"]) {
        saveOnCoreThread();
    } else {
        // Other callers may invoke this method from an arbitrary thread.
        [self performBlock:saveOnCoreThread];
    }
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    [self performBlock:^{
        std::string failure;
        const BOOL ok = self->_loaded && AzaharHost::LoadState(fileName.fileSystemRepresentation, &failure);
        block(ok, ok ? nil : [NSError errorWithDomain:OEGameCoreErrorDomain
                                                 code:OEGameCoreCouldNotLoadStateError
                                             userInfo:@{NSLocalizedDescriptionKey: @(failure.c_str())}]);
    }];
}

- (void)executeFrame
{
    if (!_loaded) {
        return;
    }
    std::string failure;
    const bool frameOK = AzaharHost::RunFrame(&failure);
    if (!frameOK) {
        NSLog(@"[Azahar] %s", failure.c_str());
        _loaded = NO;
        return;
    }
    // The sound the engine made this frame goes into OpenEmu's ring. At any speed but normal it
    // would only crackle and overflow the ring, so drain it and drop it. (A rate of 0 means the
    // host has not set one, which is normal speed.)
    const BOOL silent = self.rate > 0.0f && self.rate != 1.0f;
    id<OEAudioBuffer> ring = [self audioBufferAtIndex:0];
    int16_t pcm[2048 * 2];
    size_t frames;
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    // If the core has supplied no audio for >80 ms, OpenEmu's 75-ms ring may
    // have emptied. Restart gently instead of jumping from silence directly
    // to an arbitrary non-zero sample. Only the first 8 ms are attenuated.
    if (_audioLastDeliveryAt > 0 && now - _audioLastDeliveryAt > 0.080) {
        _audioFadeFramesRemaining = 384; // 8 ms at 48 kHz
    }
    size_t framesDeliveredThisCall = 0;
    while ((frames = AzaharHost::PullAudio(pcm, 2048)) > 0) {
        if (!silent) {
            const NSUInteger requested = frames * 2 * sizeof(int16_t);
            for (size_t i = 0; i < frames && _audioFadeFramesRemaining != 0; ++i) {
                const double gain = (384.0 - _audioFadeFramesRemaining) / 384.0;
                pcm[i * 2] = static_cast<int16_t>(std::lround(pcm[i * 2] * gain));
                pcm[i * 2 + 1] = static_cast<int16_t>(std::lround(pcm[i * 2 + 1] * gain));
                --_audioFadeFramesRemaining;
            }
            [ring write:pcm maxLength:requested];
            framesDeliveredThisCall += frames;
        }
    }
    if (framesDeliveredThisCall > 0) _audioLastDeliveryAt = now;
    // The engine's texture is its own frame; keep a reference to the newest one for OpenEmu to show.
    id<MTLTexture> frame = (__bridge id<MTLTexture>)AzaharHost::FrameTexture();
    @synchronized (self) {
        _frameTexture = frame;
    }
    // Defer scale activation until AFTER this frame's Metal texture has been
    // handed to OpenEmu. The next engine frame then carries the entire high-res
    // texture, while the initial window-size calculation already used 1x.
    // A frame countdown schedules transitions without timers or thread waits.
    if (!_nativeStartupComplete) {
        ++_nativeStartupFrames;
        if (_nativeStartupFrames >= 180) {
            _nativeStartupComplete = YES;
            if (_requestedScaleOnCoreThread > 1) {
                AzaharHost::SetDisplay(_requestedLayoutOnCoreThread, _requestedScaleOnCoreThread,
                                       _requestedStereoOnCoreThread, _requestedDepthOnCoreThread);
            }
        }
    } else if (_nativeLayoutFramesRemaining > 0) {
        --_nativeLayoutFramesRemaining;
        if (_nativeLayoutFramesRemaining == 0) {
            AzaharHost::SetDisplay(_requestedLayoutOnCoreThread, _requestedScaleOnCoreThread,
                                   _requestedStereoOnCoreThread, _requestedDepthOnCoreThread);
        }
    }
}

- (void)dealloc
{
    if (_ownsVideoBuffer) {
        free(_videoBuffer);
    }
}

#pragma mark - Video

- (OEGameCoreRendering)gameCoreRendering
{
    return OEGameCoreRenderingMetal2;
}

// A black texture is shown until the engine has drawn its first frame.
- (void)createMetalTextureWithDevice:(id<MTLDevice>)device
{
    _device = device;
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                    width:kFrameWidth
                                                                                   height:kFrameHeight
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModePrivate;
    _texture = [device newTextureWithDescriptor:desc];

    id<MTLCommandBuffer> clear = [[device newCommandQueue] commandBuffer];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = _texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    [[clear renderCommandEncoderWithDescriptor:pass] endEncoding];
    [clear commit];
    [clear waitUntilCompleted];
}

- (id<MTLDevice>)metalDevice
{
    return _device;
}

- (id<MTLTexture>)metalTexture
{
    @synchronized (self) {
        return _frameTexture ?: _texture;
    }
}

- (const void *)getVideoBufferWithHint:(void *)hint
{
    if (hint != NULL) {
        if (_ownsVideoBuffer) {
            free(_videoBuffer);
            _ownsVideoBuffer = NO;
        }
        _videoBuffer = (uint32_t *)hint;
    }
    return _videoBuffer;
}

// The picture is the size of the engine's last frame (both screens, in its current layout),
// or 400 by 480 until it has drawn one.
- (OEIntSize)bufferSize
{
    const int w = (int)AzaharHost::FrameWidth(), h = (int)AzaharHost::FrameHeight();
    if (w > 0 && h > 0) return OEIntSizeMake(w, h);
    // No frame yet: use the size the chosen layout will draw, so the window opens the right shape.
    uint32_t ew = 0, eh = 0;
    AzaharHost::ExpectedFrameSize(&ew, &eh);
    return ew > 0 && eh > 0 ? OEIntSizeMake((int)ew, (int)eh) : OEIntSizeMake((int)kFrameWidth, (int)kFrameHeight);
}

- (OEIntRect)screenRect
{
    const OEIntSize size = [self bufferSize];
    return OEIntRectMake(0, 0, size.width, size.height);
}

- (OEIntSize)aspectSize
{
    return [self bufferSize];
}

- (NSTimeInterval)frameInterval
{
    return 59.83;
}

- (GLenum)pixelFormat
{
    return 0x80E1; // GL_BGRA
}

- (GLenum)pixelType
{
    return 0x8367; // GL_UNSIGNED_INT_8_8_8_8_REV
}

#pragma mark - Audio

- (NSUInteger)channelCount
{
    return 2;
}

- (double)audioSampleRate
{
    // Output at a standard device-friendly rate; the host resamples.
    return 48000;
}

#pragma mark - Input

// OpenEmu's buttons, as the engine's.
static BOOL EngineButtonForButton(OE3DSButton button, AzaharHost::Button *out)
{
    switch (button) {
        case OE3DSButtonUp:     *out = AzaharHost::Button::Up; return YES;
        case OE3DSButtonDown:   *out = AzaharHost::Button::Down; return YES;
        case OE3DSButtonLeft:   *out = AzaharHost::Button::Left; return YES;
        case OE3DSButtonRight:  *out = AzaharHost::Button::Right; return YES;
        case OE3DSButtonA:      *out = AzaharHost::Button::A; return YES;
        case OE3DSButtonB:      *out = AzaharHost::Button::B; return YES;
        case OE3DSButtonX:      *out = AzaharHost::Button::X; return YES;
        case OE3DSButtonY:      *out = AzaharHost::Button::Y; return YES;
        case OE3DSButtonL:      *out = AzaharHost::Button::L; return YES;
        case OE3DSButtonR:      *out = AzaharHost::Button::R; return YES;
        case OE3DSButtonZL:     *out = AzaharHost::Button::ZL; return YES;
        case OE3DSButtonZR:     *out = AzaharHost::Button::ZR; return YES;
        case OE3DSButtonStart:  *out = AzaharHost::Button::Start; return YES;
        case OE3DSButtonSelect: *out = AzaharHost::Button::Select; return YES;
        default: return NO;
    }
}

- (oneway void)didPush3DSButton:(OE3DSButton)button forPlayer:(NSUInteger)player
{
    AzaharHost::Button engine;
    if (EngineButtonForButton(button, &engine)) AzaharHost::SetButton(engine, true);
}

- (oneway void)didRelease3DSButton:(OE3DSButton)button forPlayer:(NSUInteger)player
{
    AzaharHost::Button engine;
    if (EngineButtonForButton(button, &engine)) AzaharHost::SetButton(engine, false);
}

- (oneway void)didChange3DSAxis:(OE3DSAxis)axis value:(float)value forPlayer:(NSUInteger)player
{
    switch (axis) {
        case OE3DSAxisCirclePadX: AzaharHost::SetAxis(AzaharHost::Axis::CirclePadX, value); break;
        case OE3DSAxisCirclePadY: AzaharHost::SetAxis(AzaharHost::Axis::CirclePadY, value); break;
        case OE3DSAxisCStickX:    AzaharHost::SetAxis(AzaharHost::Axis::CStickX, value); break;
        case OE3DSAxisCStickY:    AzaharHost::SetAxis(AzaharHost::Axis::CStickY, value); break;
        default: break;
    }
}

// OpenEmu sends touch points in the displayed picture, whose size is aspectSize, which is the
// engine's frame. The engine finds the bottom screen in its layout itself and ignores a touch
// that lands elsewhere.
- (oneway void)didTouchScreenPoint:(OEIntPoint)point
{
    const unsigned x = point.x < 0 ? 0 : (unsigned)point.x, y = point.y < 0 ? 0 : (unsigned)point.y;
    if (_touching) {
        AzaharHost::TouchMoved(x, y);
    } else {
        _touching = YES;
        AzaharHost::TouchPressed(x, y);
    }
}

- (oneway void)didReleaseTouch
{
    _touching = NO;
    AzaharHost::TouchReleased();
}

@end
