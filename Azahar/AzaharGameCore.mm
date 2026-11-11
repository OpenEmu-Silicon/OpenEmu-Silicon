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
    id<MTLTexture> _texture;
    BOOL _loaded;
    uint32_t *_videoBuffer;
    BOOL _ownsVideoBuffer;
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    _gameURL = [NSURL fileURLWithPath:path];

    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *userDir = [self.supportDirectory URLByAppendingPathComponent:@"Azahar" isDirectory:YES];
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

- (void)executeFrame
{
    if (!_loaded) {
        return;
    }
    std::string failure;
    if (!AzaharHost::RunFrame(&failure)) {
        NSLog(@"[Azahar] %s", failure.c_str());
        _loaded = NO;
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

// Until the engine's picture reaches OpenEmu (a later step), show a black texture.
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
    return _texture;
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

- (OEIntSize)bufferSize
{
    return OEIntSizeMake((int)kFrameWidth, (int)kFrameHeight);
}

- (OEIntRect)screenRect
{
    return OEIntRectMake(0, 0, (int)kFrameWidth, (int)kFrameHeight);
}

- (OEIntSize)aspectSize
{
    return OEIntSizeMake((int)kFrameWidth, (int)kFrameHeight);
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

#pragma mark - Input (wired in a later step)

- (oneway void)didPush3DSButton:(OE3DSButton)button forPlayer:(NSUInteger)player {}
- (oneway void)didRelease3DSButton:(OE3DSButton)button forPlayer:(NSUInteger)player {}
- (oneway void)didChange3DSAxis:(OE3DSAxis)axis value:(float)value forPlayer:(NSUInteger)player {}
- (oneway void)didTouchScreenPoint:(OEIntPoint)point {}
- (oneway void)didReleaseTouch {}

@end
