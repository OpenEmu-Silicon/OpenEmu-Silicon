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
    uint32_t *_videoBuffer;
    BOOL _ownsVideoBuffer;
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

    if (!AzaharHost::Load(path.fileSystemRepresentation, &failure)) {
        return [self failLoad:error message:@(failure.c_str())];
    }
    _loaded = YES;

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

static NSString *const kLayoutKey = @"azahar.layout";
static NSString *const kScaleKey = @"azahar.resolution";

static NSArray<NSString *> *LayoutNames(void)
{
    return @[@"Stacked", @"Top screen only", @"Bottom screen only", @"Side by side", @"Large top screen"];
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
    for (NSUInteger s = 1; s <= 4; s++) {
        NSString *name = [NSString stringWithFormat:@"%lux", (unsigned long)s];
        [scales addObject:OEDisplayMode_OptionWithStateValue(name, kScaleKey, @(s == scale), name)];
    }
    return @[
        @{OEGameCoreDisplayModeGroupNameKey: @"Screen Layout", OEGameCoreDisplayModeGroupItemsKey: layouts},
        @{OEGameCoreDisplayModeGroupNameKey: @"Resolution", OEGameCoreDisplayModeGroupItemsKey: scales},
    ];
}

- (void)changeDisplayWithMode:(NSString *)displayMode
{
    if ([LayoutNames() containsObject:displayMode]) {
        _layoutName = displayMode;
    } else if (displayMode.length == 2 && [displayMode hasSuffix:@"x"] && [displayMode integerValue] >= 1 && [displayMode integerValue] <= 4) {
        _scale = (NSUInteger)[displayMode integerValue];
    } else {
        return;
    }
    NSString *layout = _layoutName ?: LayoutNames()[0];
    const NSUInteger scale = _scale ?: 1;
    [self performBlock:^{
        AzaharHost::SetDisplay(LayoutForName(layout), (unsigned)scale);
    }];
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    // The engine is not thread safe: run on the thread that runs frames.
    [self performBlock:^{
        std::string failure;
        const BOOL ok = self->_loaded && AzaharHost::SaveState(fileName.fileSystemRepresentation, &failure);
        block(ok, ok ? nil : [NSError errorWithDomain:OEGameCoreErrorDomain
                                                 code:OEGameCoreCouldNotSaveStateError
                                             userInfo:@{NSLocalizedDescriptionKey: @(failure.c_str())}]);
    }];
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
    if (!AzaharHost::RunFrame(&failure)) {
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
    while ((frames = AzaharHost::PullAudio(pcm, 2048)) > 0) {
        if (!silent) {
            [ring write:pcm maxLength:frames * 2 * sizeof(int16_t)];
        }
    }

    // The engine's texture is its own frame; keep a reference to the newest one for OpenEmu to show.
    id<MTLTexture> frame = (__bridge id<MTLTexture>)AzaharHost::FrameTexture();
    @synchronized (self) {
        _frameTexture = frame;
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
    return w > 0 && h > 0 ? OEIntSizeMake(w, h) : OEIntSizeMake((int)kFrameWidth, (int)kFrameHeight);
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
    return 32728;
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
