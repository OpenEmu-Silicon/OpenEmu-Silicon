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

/*
    What doesn't work:
          I got everything in GC working

 */

//  Changed <al*> includes to <OpenAL/al*>
//  Added iRenderFBO to Videoconfig, OGL postprocessing and renderer
//  Added SetState to device.h for input and FullAnalogControl
//  Added Render on alternate thread in Core.cpp in EmuThread() Video Thread
//  Added Render on alternate thread in Cope.cpp in CPUThread() to support single thread mode CPU/GPU

#import "DolphinGameCore.h"
#include "DolHost.h"
#include "AudioCommon/SoundStream.h"
#include "Common/Config/Config.h"
#include "Core/Config/GraphicsSettings.h"
#include "Core/Core.h"
#include "Core/State.h"
#include "Core/System.h"
#include "Core/HW/Memmap.h"
// Dolphin owns the emulation GPU; the presenter lets us resize only its output
// surface, independently of OpenEmu's game window and without editing OpenEmu.
#include "VideoCommon/Fifo.h"
#include "VideoCommon/Present.h"
#include "OpenEmuAudioStream.h"
#include "UICommon/UICommon.h"
#include <stdatomic.h>

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#import "OERetroAchievementsTransport.h"
#import "OERetroAchievementsBridge.h"
#import <OpenEmuBase/OEMemoryRegionDescriptor.h>
#import <OpenEmuBase/OEGameCoreDisplayModes.h>
#include <rc_consoles.h>
#include <rc_hash.h>

#include "DiscIO/Blob.h"
#include <memory>

#define OpenEmu 1

@interface DolphinGameCore () <OEGCSystemResponderClient>
@property (copy) NSString *filePath;
@end

DolphinGameCore *_current = 0;

// g_sound_stream was removed in Dolphin 26.03; access via Core::System::GetInstance().GetSoundStream()

// rcheevos addresses GameCube/Wii RAM from a flat space; Dolphin maps MEM1 at 0x80000000 and
// (Wii only) MEM2 at 0x90000000. GetPointerForRange validates the range and returns nullptr
// outside mapped memory (so a GameCube game never resolves a MEM2 address), and the Running-state
// gate keeps reads from touching memory before boot or during teardown.
static uint32_t dolphin_rc_read_memory(uint32_t address, uint8_t *buffer,
                                       uint32_t num_bytes, rc_client_t *client)
{
    auto &system = Core::System::GetInstance();
    if (Core::GetState(system) != Core::State::Running)
        return 0;

    // Translate the rcheevos address to a real GC/Wii bus address (see consoleinfo.c):
    //   MEM1 (GC + Wii): RA 0x00000000-0x017FFFFF -> 0x80000000
    //   MEM2 (Wii only): RA 0x10000000-0x13FFFFFF -> 0x90000000
    u32 realAddress;
    if (address < 0x01800000u)
        realAddress = 0x80000000u + address;
    else if (address >= 0x10000000u && address < 0x14000000u)
        realAddress = 0x90000000u + (address - 0x10000000u);
    else
        return 0;

    const u8 *ptr = system.GetMemory().GetPointerForRange(realAddress, num_bytes);
    if (ptr == nullptr)
        return 0;

    memcpy(buffer, ptr, num_bytes);
    return num_bytes;
}

#pragma mark - Disc hash file reader (RetroAchievements identification)

// rcheevos identifies a GameCube/Wii game by reading the raw disc image (or, for WiiWare, the raw
// .wad). Its default file reader only understands a plain .iso, so compressed disc formats
// (.rvz/.gcz/.wia/.ciso/.wbfs) fail with "hash generation failed". Dolphin's DiscIO blob reader
// decompresses any supported disc format on demand, so we route identification through it and
// present the decompressed disc image — producing the same hash a plain .iso would. A .wad is not
// a disc blob (CreateBlobReader returns null), so fall back to raw file I/O for those.
namespace {
struct DolphinHashFile {
    std::unique_ptr<DiscIO::BlobReader> blob;  // disc images; null in raw mode
    FILE *fp;                                  // raw mode (e.g. WiiWare .wad)
    uint64_t pos;
    uint64_t size;
};
}

static void *dolphin_hash_open(const char *path)
{
    DolphinHashFile *f = new DolphinHashFile{nullptr, nullptr, 0, 0};

    std::unique_ptr<DiscIO::BlobReader> blob = DiscIO::CreateBlobReader(path);
    if (blob) {
        f->size = blob->GetDataSize();
        f->blob = std::move(blob);
        return f;
    }

    FILE *fp = fopen(path, "rb");
    if (!fp) {
        delete f;
        return nullptr;
    }
    fseeko(fp, 0, SEEK_END);
    const off_t end = ftello(fp);
    fseeko(fp, 0, SEEK_SET);
    f->fp = fp;
    f->size = (end > 0) ? (uint64_t)end : 0;
    return f;
}

static void dolphin_hash_seek(void *handle, int64_t offset, int origin)
{
    DolphinHashFile *f = static_cast<DolphinHashFile *>(handle);
    if (!f)
        return;

    int64_t base = 0;
    switch (origin) {
        case SEEK_SET: base = 0; break;
        case SEEK_CUR: base = (int64_t)f->pos; break;
        case SEEK_END: base = (int64_t)f->size; break;
        default: return;
    }
    int64_t newPos = base + offset;
    f->pos = (newPos < 0) ? 0 : (uint64_t)newPos;
}

static int64_t dolphin_hash_tell(void *handle)
{
    DolphinHashFile *f = static_cast<DolphinHashFile *>(handle);
    return f ? (int64_t)f->pos : -1;
}

static size_t dolphin_hash_read(void *handle, void *buffer, size_t requested)
{
    DolphinHashFile *f = static_cast<DolphinHashFile *>(handle);
    if (!f || f->pos >= f->size)
        return 0;

    const uint64_t remain = f->size - f->pos;
    if (requested > remain)
        requested = (size_t)remain;
    if (requested == 0)
        return 0;

    if (f->blob) {
        if (!f->blob->Read(f->pos, requested, (uint8_t *)buffer))
            return 0;
    } else {
        if (fseeko(f->fp, (off_t)f->pos, SEEK_SET) != 0)
            return 0;
        requested = fread(buffer, 1, requested, f->fp);
    }

    f->pos += requested;
    return requested;
}

static void dolphin_hash_close(void *handle)
{
    DolphinHashFile *f = static_cast<DolphinHashFile *>(handle);
    if (f && f->fp)
        fclose(f->fp);
    delete f;
}

@implementation DolphinGameCore
{
    DolHost *dol_host;

    uint16_t *_soundBuffer;
    bool _isWii;
    atomic_bool _isInitialized;
    float _frameInterval;
    int _internalResolution;       // menu / saved choice (1-6)
    BOOL _wiimoteSideways;        // saved orientation choice (Wii only)
    int _activeOutputScale;       // actual Metal output texture dimensions
    int _pendingStartupScale;     // apply saved 2-6x only after the window is established
    NSUInteger _startupFrameCount;

    NSString *autoLoadStatefileName;
    NSString *_dolphinCoreModule;
    OEIntSize _dolphinCoreAspect;
    OEIntSize _dolphinCoreScreen;

    id<MTLTexture> _dolMetalTexture;
    CAMetalLayer  *_dolMetalLayer;

    OERetroAchievementsBridge *_raBridge;
}

- (instancetype)init
{
    if(self = [super init]){
        dol_host = DolHost::GetInstance();
        _internalResolution = 1;
        _activeOutputScale = 1;
        _pendingStartupScale = 0;
        _startupFrameCount = 0;
    }

    _current = self;

    return self;
}

- (void)dealloc
{
    [_raBridge shutdown];
    _raBridge = nil;

    delete dol_host;
    free(_soundBuffer);
}

# pragma mark - RetroAchievements
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

# pragma mark - Display modes

// OpenEmu remembers this mode per game. Internal EFB scale and the Metal output
// both increase, so OpenEmu receives REAL high-resolution frames. The window's
// size remains under the host app's control; the output aspect ratio is unchanged.
static NSString *const kDolphinResolutionPrefKey = @"dolphin.resolution";

// How a Wii remote is held. "Upright" is Dolphin's normal pointing position; "Sideways" is the NES-style
// two-hand grip. The same saved value is shown as a choice in Preferences > Controls (the Wii plugin's
// plist names the same key and values), so change them in both places together.
static NSString *const kDolphinOrientationPrefKey = @"dolphin.orientation";
static NSString *const kDolphinOrientationUpright = @"Upright";
static NSString *const kDolphinOrientationSideways = @"Sideways";

// 1 = sideways, 0 = upright, -1 = not an orientation name.
static int DolphinSidewaysForOrientationName(NSString *name)
{
    if ([name isEqualToString:kDolphinOrientationSideways]) return 1;
    if ([name isEqualToString:kDolphinOrientationUpright]) return 0;
    return -1;
}

static int DolphinResolutionForName(NSString *name)
{
    if (![name isKindOfClass:[NSString class]] || name.length != 2 ||
        [name characterAtIndex:1] != 'x')
        return 0;
    const unichar digit = [name characterAtIndex:0];
    return digit >= '1' && digit <= '6' ? (int)(digit - '0') : 0;
}

- (NSArray<NSDictionary<NSString *, id> *> *)displayModes
{
    NSMutableArray *resolutions = [NSMutableArray arrayWithCapacity:6];
    for (int scale = 1; scale <= 6; ++scale) {
        NSString *name = [NSString stringWithFormat:@"%dx", scale];
        [resolutions addObject:OEDisplayMode_OptionWithStateValue(
            name, kDolphinResolutionPrefKey, @(scale == _internalResolution), name)];
    }
    NSMutableArray *groups = [NSMutableArray arrayWithObject:
        @{OEGameCoreDisplayModeGroupNameKey: @"Resolution",
          OEGameCoreDisplayModeGroupItemsKey: resolutions}];

    // Only the Wii has a Wiimote to hold.
    if (_isWii) {
        // Menu only: the "next display mode" hotkey steps through every mode that is not marked manual, and
        // it must not flip how the remote is held.
        NSMutableArray *orientations = [NSMutableArray arrayWithCapacity:2];
        for (NSString *name in @[kDolphinOrientationUpright, kDolphinOrientationSideways]) {
            const BOOL selected = [name isEqualToString:kDolphinOrientationSideways] == _wiimoteSideways;
            NSMutableDictionary *item = [OEDisplayMode_OptionWithStateValue(
                name, kDolphinOrientationPrefKey, @(selected), name) mutableCopy];
            item[OEGameCoreDisplayModeManualOnlyKey] = @YES;
            [orientations addObject:item];
        }
        [groups addObject:@{OEGameCoreDisplayModeGroupNameKey: @"Wiimote Orientation",
                            OEGameCoreDisplayModeGroupItemsKey: orientations}];
    }
    return groups;
}

// Set both Dolphin's high-resolution internal EFB and its high-resolution Metal
// output. The output surface and OpenEmu texture must agree in pixel dimensions.
// Crucially, we do not touch OpenEmu's NSWindow, which retains its user-selected
// size through in-game display-mode changes.
- (BOOL)applyResolutionScale:(int)scale
{
    if (scale < 1 || scale > 6)
        return NO;

    if (_activeOutputScale != scale) {
        id<MTLTexture> oldTexture = nil;
        @synchronized (self) { oldTexture = _dolMetalTexture; }
        if (!oldTexture || !_dolMetalLayer)
            return NO;

        const NSUInteger width = (NSUInteger)_dolphinCoreScreen.width * scale;
        const NSUInteger height = (NSUInteger)_dolphinCoreScreen.height * scale;
        id<MTLDevice> device = oldTexture.device;
        MTLTextureDescriptor *desc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                         width:width height:height mipmapped:NO];
        desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModePrivate;
        id<MTLTexture> newTexture = [device newTextureWithDescriptor:desc];
        if (!newTexture) {
            NSLog(@"[DolphinResolution] Unable to allocate %lux%lu output texture",
                  (unsigned long)width, (unsigned long)height);
            return NO;
        }

        // Clear newly allocated texture before allowing OpenEmu to composite it.
        id<MTLCommandBuffer> cb = [[device newCommandQueue] commandBuffer];
        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = newTexture;
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        [[cb renderCommandEncoderWithDescriptor:rpd] endEncoding];
        [cb commit];
        [cb waitUntilCompleted];

        // The Dolphin GPU thread must not read the target pointer or recreate the
        // backbuffer while these dimensions change. PauseAndLock is also used by
        // Dolphin's normal live graphics-configuration refresh.
        auto& system = Core::System::GetInstance();
        const bool lockGPU = Core::IsRunning(system);
        if (lockGPU)
            system.GetFifo().PauseAndLock();

        @synchronized (self) {
            _dolMetalTexture = newTexture;
            _dolMetalLayer.bounds = CGRectMake(0, 0, width, height);
            _activeOutputScale = scale;
            dol_host->SetMetalTexture(newTexture);
            if (g_presenter)
                g_presenter->ResizeSurface();
        }

        if (lockGPU)
            system.GetFifo().RestoreState(true);
    }

    // Dolphin rebuilds its scaled EFB through its existing config callback.
    Config::SetCurrent(Config::GFX_EFB_SCALE, scale);
    NSLog(@"[DolphinResolution] Active %dx, output %dx%d, logical window unchanged",
          scale, _dolphinCoreScreen.width * scale, _dolphinCoreScreen.height * scale);
    return YES;
}

- (void)changeDisplayWithMode:(NSString *)displayMode
{
    const int orientation = DolphinSidewaysForOrientationName(displayMode);
    if (orientation >= 0) {
        _wiimoteSideways = orientation == 1;
        if (_isInitialized && _isWii)
            [self applyWiimoteOrientation];
        return;
    }

    const int scale = DolphinResolutionForName(displayMode);
    if (scale == 0)
        return;

    if (_isInitialized) {
        if (![self applyResolutionScale:scale])
            return; // Keep the previously selected mode if allocation failed.
        _pendingStartupScale = 0; // Manual choice overrides pending restore.
    } else {
        // Before the Metal texture exists, remember the request for startup.
        _pendingStartupScale = scale > 1 ? scale : 0;
    }

    _internalResolution = scale;
}

// Tell Dolphin how every Wiimote is held. Dolphin only has its Wiimotes once the game has booted, so this is
// called after boot and again whenever the choice changes.
- (void)applyWiimoteOrientation
{
    dol_host->SetWiimoteOrientation(_wiimoteSideways);
    NSLog(@"[DolphinOrientation] %@", _wiimoteSideways ? kDolphinOrientationSideways : kDolphinOrientationUpright);
}

# pragma mark - Execution
- (BOOL)loadFileAtPath:(NSString *)path
{
    self.filePath = path;

    if([[self systemIdentifier] isEqualToString:@"openemu.system.gc"])
    {
        _dolphinCoreModule = @"gc";
        _isWii = false;
        _dolphinCoreAspect = OEIntSizeMake(4, 3);
        _dolphinCoreScreen = OEIntSizeMake(640, 480);
    }
    else
    {
        _dolphinCoreModule = @"Wii";
        _isWii = true;
        _dolphinCoreAspect = OEIntSizeMake(16,9);
        _dolphinCoreScreen = OEIntSizeMake(854, 480);
    }

    dol_host->Init([[self supportDirectoryPath] fileSystemRepresentation], [path fileSystemRepresentation] );

    // Start at native resolution while the window and Metal surface are being
    // established. A remembered higher scale is restored after initial frames,
    // avoiding oversized startup windows and unnecessary high-res boot work.
    const int savedScale = DolphinResolutionForName(self.displayModeInfo[kDolphinResolutionPrefKey]);
    _internalResolution = savedScale ?: 1;
    _wiimoteSideways = DolphinSidewaysForOrientationName(self.displayModeInfo[kDolphinOrientationPrefKey]) == 1;
    _activeOutputScale = 1;
    _pendingStartupScale = _internalResolution > 1 ? _internalResolution : 0;
    _startupFrameCount = 0;
    Config::SetCurrent(Config::GFX_EFB_SCALE, 1);

    // The RA bridge logs in and hashes off the ROM path here; markROMReady is deferred to
    // -startEmulation, once Dolphin has booted and RAM is mapped.
    _raBridge = [[OERetroAchievementsBridge alloc] initWithGameCore:self
                                                       memoryReader:dolphin_rc_read_memory
                                                          consoleID:(uint32_t)(_isWii ? RC_CONSOLE_WII : RC_CONSOLE_GAMECUBE)];
    [_raBridge startWithROMPath:path];

    // Let rcheevos hash compressed disc images (.rvz/.gcz/.wia/.ciso/.wbfs) by reading them
    // through DiscIO, which presents the decompressed disc the hasher expects; WiiWare .wad
    // files fall through to raw file I/O inside the reader.
    static const rc_hash_filereader_t dolphinHashFileReader = {
        dolphin_hash_open,
        dolphin_hash_seek,
        dolphin_hash_tell,
        dolphin_hash_read,
        dolphin_hash_close,
    };
    [_raBridge setHashFileReader:&dolphinHashFileReader];

    usleep(5000);
    return YES;
}

- (void)setPauseEmulation:(BOOL)flag
{
    dol_host->Pause(flag);
    
    [super setPauseEmulation:flag];
}

- (void)stopEmulation
{
    [_raBridge shutdown];
    _raBridge = nil;

    _isInitialized = false;
    
    dol_host->RequestStop();

    [super stopEmulation];
}

- (void)startEmulation
{
    if (!_isInitialized)
    {
        dol_host->SetMetalLayer(_dolMetalLayer);
        dol_host->SetMetalTexture(_dolMetalTexture);

        if(dol_host->LoadFileAtPath())
            _isInitialized = true;
        
        _frameInterval = dol_host->GetFrameInterval();

        if (_isInitialized && _isWii)
            [self applyWiimoteOrientation];

        // Dolphin has booted and GameCube RAM is mapped; let rcheevos read it during -doFrame.
        [_raBridge markROMReady];
    }
    [super startEmulation];

    //Disable the OE framelimiting
    [self.renderDelegate suspendFPSLimiting];
}

- (void)resetEmulation
{
     dol_host->Reset();
     [_raBridge reset];
}

- (void)executeFrame
{
   if (![self isEmulationPaused])
    {
        if(!dol_host->CoreRunning()) {
        dol_host->Pause(false);
        }
    
      dol_host->UpdateFrame();

      // Apply a deferred auto-load once the CPU thread is up; LoadState returns false (a no-op)
      // while the core is still booting, so retry each frame until it takes.
      if (autoLoadStatefileName && dol_host->LoadState([autoLoadStatefileName UTF8String]))
          autoLoadStatefileName = nil;

      [_raBridge doFrame];

      // Do not enlarge the output during Dolphin's boot or OpenEmu's initial
      // window layout. Restore the saved resolution after 90 host frames.
      // Changing it here uses exactly the same live path as the menu choice.
      if (_pendingStartupScale > 1 && ++_startupFrameCount >= 90) {
          const int wanted = _pendingStartupScale;
          _pendingStartupScale = 0;
          if (![self applyResolutionScale:wanted]) {
              _internalResolution = 1;
              NSLog(@"[DolphinResolution] Saved %dx restore failed; staying at 1x", wanted);
          }
      }
    }
}

# pragma mark - Nand directory Callback
- (const char *)getBundlePath
{
    NSBundle *coreBundle = [NSBundle bundleForClass:[self class]];
    const char *dataPath;
    dataPath = [[coreBundle resourcePath] fileSystemRepresentation];

    return dataPath;
}

# pragma mark - Video
- (OEGameCoreRendering)gameCoreRendering
{
    return OEGameCoreRenderingMetal2;
}

- (BOOL)hasAlternateRenderingThread
{
    return YES;
}

- (void)createMetalTextureWithDevice:(id<MTLDevice>)device
{
    // Texture OE composites from — needs RenderTarget so Dolphin can write into it.
    MTLTextureDescriptor *desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:_dolphinCoreScreen.width
                                    height:_dolphinCoreScreen.height
                                 mipmapped:NO];
    desc.usage       = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModePrivate;
    _dolMetalTexture = [device newTextureWithDescriptor:desc];

    // Clear to black so frame 0 composites black instead of uninitialized magenta.
    id<MTLCommandQueue> q = [device newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture    = _dolMetalTexture;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    [[cb renderCommandEncoderWithDescriptor:rpd] endEncoding];
    [cb commit];
    [cb waitUntilCompleted];

    // Sizing layer: gives Dolphin's Metal backend real surface dimensions for SetupSurface().
    // BindBackbuffer bypasses this layer's drawables and uses _dolMetalTexture directly.
    _dolMetalLayer              = [CAMetalLayer layer];
    _dolMetalLayer.device       = device;
    _dolMetalLayer.pixelFormat  = MTLPixelFormatBGRA8Unorm;
    _dolMetalLayer.framebufferOnly = NO;
    _dolMetalLayer.bounds       = CGRectMake(0, 0, _dolphinCoreScreen.width, _dolphinCoreScreen.height);
    _dolMetalLayer.contentsScale = 1.0;
}

- (id<MTLTexture>)metalTexture
{
    // Metal renderer can ask from a different thread during a live mode change.
    @synchronized (self) { return _dolMetalTexture; }
}

// MTL3DGameRenderer.update() reads these to resolve OEMTLPixelFormat even in Metal2 mode.
// GL_BGRA (0x80E1) + GL_UNSIGNED_INT_8_8_8_8_REV (0x8367) → OEMTLPixelFormat.BGRA8Unorm,
// matching the MTLPixelFormatBGRA8Unorm texture we create above.
- (GLenum)pixelFormat  { return 0x80E1; } // GL_BGRA
- (GLenum)pixelType    { return 0x8367; } // GL_UNSIGNED_INT_8_8_8_8_REV

- (const void *)videoBuffer
{
    return NULL;
}

- (NSTimeInterval)frameInterval
{
    return _frameInterval ?: 60;
}

- (OEIntSize)bufferSize
{
    // Physical source resolution follows the Metal output. This ensures
    // OpenEmu shaders see *all* pixels instead of cropping a high-resolution texture to 1x.
    // OpenEmu's window controller controls the onscreen size separately.
    @synchronized (self) {
        const int scale = _activeOutputScale > 0 ? _activeOutputScale : 1;
        return OEIntSizeMake(_dolphinCoreScreen.width * scale,
                             _dolphinCoreScreen.height * scale);
    }
}

- (OEIntSize)aspectSize
{
    return _dolphinCoreAspect;
}

- (void) SetScreenSize:(int)width :(int)height
{
}

# pragma mark - Audio
- (NSUInteger)channelCount
{
    return 2;
}

- (double)audioSampleRate
{
    return OE_SAMPLERATE;
}

- (id<OEAudioBuffer>)audioBufferAtIndex:(NSUInteger)index
{
    return self;
}

- (NSUInteger)length
{
    return OE_SIZESOUNDBUFFER;
}

- (NSUInteger)read:(void *)buffer maxLength:(NSUInteger)len
{
    SoundStream* sound_stream = Core::System::GetInstance().GetSoundStream();
    OpenEmuAudioStream* oe_stream = dynamic_cast<OpenEmuAudioStream*>(sound_stream);
    if (_isInitialized && oe_stream) {
        // Always consume the full requested length. Mixer::Mix() zeroes the output
        // buffer before mixing and always returns num_samples, so any frames Dolphin
        // hasn't produced yet come back as silence. Returning len (not the Mix()
        // return value) prevents AVAudioSourceNode from setting mDataByteSize to a
        // short count, which would cause CoreAudio to output a click for the gap.
        oe_stream->readAudio(buffer, (int)len);
    } else {
        memset(buffer, 0, len);
    }
    return len;
}

- (NSUInteger)write:(const void *)buffer maxLength:(NSUInteger)length
{
    return 0;
}

# pragma mark - Save States
- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    // Wait for full initialization before saving.
    while (!_isInitialized)
        usleep(1000);

    // State::SaveAs dispatches the file write to a background thread and returns immediately.
    // UICommon::FlushUnsavedData() acquires the exclusive save-in-progress lock, which blocks
    // until the background thread releases its shared lock — i.e. until the file is fully written.
    // If SaveToBuffer fails internally (DoState error), Dolphin never emplaces the work item and
    // the file is never written. Check existence so OE gets an accurate success/failure signal.
    dol_host->SaveState([fileName UTF8String]);
    UICommon::FlushUnsavedData();

    BOOL success = [[NSFileManager defaultManager] fileExistsAtPath:fileName];
    if (success) {
        block(YES, nil);
    } else {
        NSError *err = [NSError errorWithDomain:OEGameCoreErrorDomain
                                          code:OEGameCoreCouldNotSaveStateError
                                      userInfo:@{NSLocalizedDescriptionKey: @"Dolphin failed to write the save state file. Check that the game is fully loaded before saving."}];
        block(NO, err);
    }
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    if (!_isInitialized || !dol_host->LoadState([fileName UTF8String]))
    {
        // CPU thread isn't servicing jobs yet (boot still in the Starting phase). Queue the load
        // for -executeFrame, which retries it every frame until the core reaches Running.
        autoLoadStatefileName = [fileName copy];
    }
    block(YES, nil);
}

# pragma mark - Input GC
- (oneway void)didMoveGCJoystickDirection:(OEGCButton)button withValue:(CGFloat)value forPlayer:(NSUInteger)player
{
    if(_isInitialized)
    {
        dol_host->SetAxis(button, value, (int)player);
    }
}

- (oneway void)didPushGCButton:(OEGCButton)button forPlayer:(NSUInteger)player
{
    if(_isInitialized)
    {
        dol_host->setButtonState(button, 1, (int)player);
    }
}

- (oneway void)didReleaseGCButton:(OEGCButton)button forPlayer:(NSUInteger)player
{
    if(_isInitialized)
    {
        dol_host->setButtonState(button, 0, (int)player);
    }
}

# pragma mark - Input Wii
- (oneway void)didMoveWiiJoystickDirection:(OEWiiButton)button withValue:(CGFloat)value forPlayer:(NSUInteger)player
{
    if(_isInitialized)
    {
        dol_host->SetAxis(button, value, (int)player);
    }
}

- (oneway void)didPushWiiButton:(OEWiiButton)button forPlayer:(NSUInteger)player
{
    if(_isInitialized)
    {
        if (button > OEWiiButtonCount) {
            dol_host->processSpecialKeys(button , (int)player);
        } else {
            dol_host->setButtonState(button, 1, (int)player);
        }
    }
}

- (oneway void)didReleaseWiiButton:(OEWiiButton)button forPlayer:(NSUInteger)player
{
    if(_isInitialized && button != OEWiimoteSideways && button != OEWiimoteUpright)
    {
        dol_host->setButtonState(button, 0, (int)player);
    }
}

//- (oneway void) didMoveWiiAccelerometer:(OEWiiAccelerometer)accelerometer withValue:(CGFloat)X withValue:(CGFloat)Y withValue:(CGFloat)Z forPlayer:(NSUInteger)player
//{
//    if(_isInitialized)
//    {
//        if (accelerometer == OEWiiNunchuk)
//        {
//            dol_host->setNunchukAccel(X,Y,Z,(int)player);
//        }
//        else
//        {
//            dol_host->setWiimoteAccel(X,Y,Z,(int)player);
//        }
//    }
//}

//- (oneway void)didMoveWiiIR:(OEWiiButton)button IRinfo:(OEwiimoteIRinfo)IRinfo forPlayer:(NSUInteger)player
//{
//    if(_isInitialized)
//    {
//        dol_host->setIRdata(IRinfo ,(int)player);
//    }
//}

- (oneway void)didChangeWiiExtension:(OEWiimoteExtension)extension forPlayer:(NSUInteger)player
{
    if(_isInitialized)
    {
        dol_host->changeWiimoteExtension(extension, (int)player);
    }
}

- (oneway void)IRMovedAtPoint:(int)X withValue:(int)Y
{
//    if (_isInitialized)
//    {
//        int dX = (1023.0 / 854.0) * X;
//        int dY =  (767.0 / 480.0) * Y;
//
////        dol_host->DisplayMessage([[NSString stringWithFormat:@"X: %d, Y: %d",dX,dY ] UTF8String]);
//
//       dol_host->SetIR(0, dX,dY);
//    }
}

# pragma mark - Cheats
- (void)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled
{
    dol_host->SetCheat([code UTF8String], [type UTF8String], enabled);
}

// Cheat search reads a snapshot of MEM1, the 24 MB main RAM mapped at 0x80000000 (GameCube and
// Wii alike). The buffer is stored big-endian (PowerPC), which the app-side search reads
// big-endian when converting a found value into an Action Replay write code. Only MEM1 is exposed:
// an Action Replay address is a 25-bit offset from 0x80000000, so it can't reach the Wii's MEM2.
- (NSArray<OEMemoryRegionDescriptor *> *)readableMemoryRegions
{
    if (!_isInitialized)
        return @[];

    auto &system = Core::System::GetInstance();
    if (Core::GetState(system) == Core::State::Uninitialized)
        return @[];

    auto &memory = system.GetMemory();
    const uint32_t size = memory.GetRamSizeReal();
    if (size == 0)
        return @[];

    const uint8_t *ram = memory.GetPointerForRange(0x80000000u, size);
    if (ram == nullptr)
        return @[];

    NSData *data = [NSData dataWithBytes:ram length:size];
    OEMemoryRegionDescriptor *mem1 =
        [OEMemoryRegionDescriptor descriptorWithName:@"MEM1"
                                             address:0x80000000u
                                        addressBytes:4
                                                data:data];
    return @[mem1];
}
@end
