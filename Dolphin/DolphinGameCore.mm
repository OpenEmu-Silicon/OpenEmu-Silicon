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
#include "Core/Core.h"
#include "Core/State.h"
#include "Core/System.h"
#include "Core/HW/Memmap.h"
#include "OpenEmuAudioStream.h"
#include "UICommon/UICommon.h"
#include <stdatomic.h>

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#import "OERetroAchievementsTransport.h"
#import "OERetroAchievementsBridge.h"
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

      [_raBridge doFrame];
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
    return _dolMetalTexture;
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
    return _dolphinCoreScreen;
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
    if (!_isInitialized)
    {
        // Core not yet running — defer until initialization completes.
        autoLoadStatefileName = fileName;
        [NSThread detachNewThreadSelector:@selector(autoloadWaitThread) toTarget:self withObject:nil];
        block(YES, nil);
    }
    else
    {
        // State::LoadAs runs synchronously on the CPU thread via RunOnCPUThread,
        // so by the time LoadState returns the state has been applied.
        dol_host->LoadState([fileName UTF8String]);
        block(YES, nil);
    }
}

- (void)autoloadWaitThread
{
    @autoreleasepool
    {
        while (!_isInitialized)
            usleep(100);

        dol_host->LoadState([autoLoadStatefileName UTF8String]);
    }
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
@end
