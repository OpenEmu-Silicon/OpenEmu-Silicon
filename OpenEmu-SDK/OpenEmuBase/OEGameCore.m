/*
 Copyright (c) 2009, OpenEmu Team

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

#import <TargetConditionals.h>

#import "OEGameCore.h"
#import "OEGameCoreController.h"
#import "OEMemoryRegionDescriptor.h"
#import "OEAbstractAdditions.h"
#import "OEAudioBuffer.h"
#import "OERingBuffer.h"
#import "OETimingUtils.h"
#import "OELogging.h"

#import <os/signpost.h>
#import <os/lock.h>

#ifndef BOOL_STR
#define BOOL_STR(b) ((b) ? "YES" : "NO")
#endif

NSString *const OEGameCoreErrorDomain = @"org.openemu.GameCore.ErrorDomain";

/// The most time, in seconds, the game loop will try to win back after running late (about six frames at 60 Hz).
static const NSTimeInterval OEGameCoreMaxCatchUp = 0.1;

@implementation OEGameCore
{
    uint64_t _statsWindowStart, _statsLastFrame;
    NSUInteger _statsFrames;
    double _statsWorstGapMs;
    NSUInteger _statsAudioCapacity, _statsAudioFillMin, _statsAudioFillMax, _statsAudioWrittenAtStart, _statsAudioWrittenNow;
    BOOL _statsAudioWrittenAtStartSet;
    NSThread *_gameCoreThread;
    CFRunLoopRef _gameCoreRunLoop;

    void (^_stopEmulationHandler)(void);
    void (^_frameCallback)(NSTimeInterval frameInterval);

    OERingBuffer __strong **ringBuffers;

    OEDiffQueue            *rewindQueue;
    NSUInteger              rewindCounter;

    BOOL                    shouldStop;
    BOOL                    singleFrameStep;
    BOOL                    isRewinding;
    BOOL                    isPausedExecution;
    BOOL                    _hardcoreEnabled;

    NSTimeInterval          lastRate;

    os_unfair_lock          _ringBufferLock;

    NSUInteger frameCounter;
}

@synthesize nextFrameTime;

static Class GameCoreClass = Nil;

- (BOOL)hardcoreEnabled
{
    return _hardcoreEnabled;
}

- (void)setHardcoreEnabled:(BOOL)hardcoreEnabled
{
    _hardcoreEnabled = hardcoreEnabled;
    if (hardcoreEnabled) {
        isRewinding = NO;
        singleFrameStep = NO;
        // Clear an active slow-motion rate (slowdown stays blocked in hardcore)
        // while preserving fast-forward (permitted per RA's hardcore spec).
        // Normalize both the live rate and the stored resume rate used when paused.
        if (lastRate > 0.0 && lastRate < 1.0) {
            lastRate = 1.0;
        }
        if (_rate > 0.0 && _rate < 1.0) {
            self.rate = 1.0;
        }
    }
}

+ (void)initialize
{
    if(self == [OEGameCore class])
    {
        GameCoreClass = [OEGameCore class];
    }
}

- (instancetype)init
{
    self = [super init];
    if(self != nil)
    {
        _ringBufferLock = OS_UNFAIR_LOCK_INIT;
        NSUInteger count = [self audioBufferCount];
        ringBuffers = (__strong OERingBuffer **)calloc(count, sizeof(OERingBuffer *));
    }
    return self;
}

- (void)dealloc
{
    for(NSUInteger i = 0, count = [self audioBufferCount]; i < count; i++)
        ringBuffers[i] = nil;

    free(ringBuffers);
    _stopEmulationHandler = nil; // Break retain cycles
    _frameCallback = nil;
}

- (NSString *)pluginName
{
    return [[self owner] pluginName];
}

- (NSString *)biosDirectoryPath
{
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [[self owner] biosDirectoryPath];
    #pragma clang diagnostic pop
}

- (NSString *)supportDirectoryPath
{
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [[self owner] supportDirectoryPath];
    #pragma clang diagnostic pop
}

- (NSString *)batterySavesDirectoryPath
{
    return [[self supportDirectoryPath] stringByAppendingPathComponent:@"Battery Saves"];
}

- (BOOL)supportsRewinding
{
    return [[self owner] supportsRewindingForSystemIdentifier:[self systemIdentifier]];
}

- (NSUInteger)rewindInterval
{
    return [[self owner] rewindIntervalForSystemIdentifier:[self systemIdentifier]];
}

- (NSUInteger)rewindBufferSeconds
{
    return [[self owner] rewindBufferSecondsForSystemIdentifier:[self systemIdentifier]];
}

- (OEDiffQueue *)rewindQueue
{
    if(rewindQueue == nil) {
        NSUInteger capacity = ceil(([self frameInterval]*[self rewindBufferSeconds]) / ([self rewindInterval]+1));
        rewindQueue = [[OEDiffQueue alloc] initWithCapacity:capacity];
    }
    return rewindQueue;
}

#pragma mark - Execution

- (void)setFrameCallback:(void (^)(NSTimeInterval frameInterval))block
{
    _frameCallback = block;
}

- (void)performBlock:(void(^)(void))block
{
    if (_gameCoreRunLoop == nil) {
        block();
        return;
    }

    CFRunLoopPerformBlock(_gameCoreRunLoop, kCFRunLoopCommonModes, block);
    CFRunLoopWakeUp(_gameCoreRunLoop);
}

- (void)_gameCoreThreadWithStartEmulationCompletionHandler:(void (^)(void))startCompletionHandler
{
    @autoreleasepool {
        _gameCoreRunLoop = CFRunLoopGetCurrent();

        [self startEmulation];

        if (startCompletionHandler != nil)
            dispatch_async(dispatch_get_main_queue(), startCompletionHandler);

        [self runGameLoop:nil];

        _gameCoreRunLoop = nil;
    }
}

// GameCores that render direct to OpenGL rather than a buffer should override this and return YES
// If the GameCore subclass returns YES, the renderDelegate will set the appropriate GL Context
// So the GameCore subclass can just draw to OpenGL
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (BOOL)rendersToOpenGL
{
    return NO;
}
#pragma clang diagnostic pop

- (void)setupEmulationWithCompletionHandler:(void (^)(void))completionHandler
{
    [self setupEmulation];

    if (completionHandler != nil)
        completionHandler();
}

- (void)setupEmulation
{
}

- (void)startEmulationWithCompletionHandler:(void (^)(void))completionHandler
{
    _gameCoreThread = [[NSThread alloc] initWithTarget:self selector:@selector(_gameCoreThreadWithStartEmulationCompletionHandler:) object:completionHandler];
    _gameCoreThread.name = @"org.openemu.core-thread";
    _gameCoreThread.qualityOfService = NSQualityOfServiceUserInteractive;

    [_gameCoreThread start];
}

- (void)resetEmulationWithCompletionHandler:(void (^)(void))completionHandler
{
    [self performBlock:^{
        [self resetEmulation];

        if (completionHandler)
            dispatch_async(dispatch_get_main_queue(), completionHandler);
    }];
}

- (void)runStartUpFrameWithCompletionHandler:(void(^)(void))handler
{
    [self OE_executeFrame];
    handler();
}

- (void)runGameLoop:(id)anArgument
{
#if 0
    __block NSTimeInterval gameTime = 0;
    __block int wasZero=1;
#endif

    OESetThreadRealtime(1. / (_rate * [self frameInterval]), OEGameCoreDefaultRealtimeConstraint, OEGameCoreDefaultRealtimeLimit); // guessed from bsnes
    nextFrameTime = OEMonotonicTime();

    while(!shouldStop)
    {
    @autoreleasepool
    {
#if 0
        gameTime += 1. / [self frameInterval];
        if(wasZero && gameTime >= 1)
        {
            NSUInteger audioBytesGenerated = ringBuffers[0].bytesWritten;
            double expectedRate = [self audioSampleRateForBuffer:0];
            NSUInteger audioSamplesGenerated = audioBytesGenerated/(2*[self channelCount]);
            double realRate = audioSamplesGenerated/gameTime;

            wasZero = 0;
        }
#endif
        
        BOOL executing = _rate > 0 || singleFrameStep || isPausedExecution;

        [_delegate gameCoreWillBeginFrame: executing];

        if(executing && isRewinding)
        {
            if (singleFrameStep) {
                singleFrameStep = isRewinding = NO;
            }

            os_signpost_interval_begin(OE_LOG_CORE_REWIND, OS_SIGNPOST_ID_EXCLUSIVE, "pop");
            NSData *state = [[self rewindQueue] pop];
            os_signpost_interval_end(OE_LOG_CORE_REWIND, OS_SIGNPOST_ID_EXCLUSIVE, "pop");
            if(state)
            {
                os_signpost_interval_begin(OE_LOG_CORE_REWIND, OS_SIGNPOST_ID_EXCLUSIVE, "deserializeState");
                [self deserializeState:state withError:nil];
                os_signpost_interval_end(OE_LOG_CORE_REWIND, OS_SIGNPOST_ID_EXCLUSIVE, "deserializeState");

                [self OE_executeFrame]; // Core callout — render the restored state
            }
            
        }
        else if(executing)
        {
            singleFrameStep = NO;

            if([self supportsRewinding] && rewindCounter == 0)
            {
                os_signpost_interval_begin(OE_LOG_CORE_REWIND, OS_SIGNPOST_ID_EXCLUSIVE, "serializeState");
                NSData *state = [self serializeStateWithError:nil];
                os_signpost_interval_end(OE_LOG_CORE_REWIND, OS_SIGNPOST_ID_EXCLUSIVE, "serializeState");
                if(state)
                {
                    os_signpost_interval_begin(OE_LOG_CORE_REWIND, OS_SIGNPOST_ID_EXCLUSIVE, "push");
                    [[self rewindQueue] push:state];
                    os_signpost_interval_end(OE_LOG_CORE_REWIND, OS_SIGNPOST_ID_EXCLUSIVE, "push");
                }
                rewindCounter = [self rewindInterval];
            }
            else
            {
                rewindCounter--;
            }

            [self OE_executeFrame]; // Core callout
        }
        
        [_delegate gameCoreWillEndFrame: executing];

        NSTimeInterval frameRate = self.frameInterval; // the frameInterval property is incorrectly named
        NSTimeInterval adjustedRate = _rate ?: 1;
        NSTimeInterval advance = 1.0 / (frameRate * adjustedRate);
        nextFrameTime += advance;
        frameCounter++;

        // Sleep till next time.
        NSTimeInterval realTime = OEMonotonicTime();

        // If we have fallen behind by more than a few frames, give up the lost time instead of catching up.
        // Catching up runs frames back to back, which also produces their audio back to back: the audio buffer
        // (about 125 ms) overflows and the dropped samples are heard as a crackle, and the game visibly rushes.
        // Measured on Mario 64: the first 3 seconds ran 194 frames instead of 180 and overflowed the buffer 14 to 29
        // times, while every later 3-second window was exactly 180 frames with no overflow.
        NSTimeInterval timeOver = realTime - nextFrameTime;
        if(timeOver >= OEGameCoreMaxCatchUp)
        {

            nextFrameTime = realTime;
        }

        OEWaitUntil(nextFrameTime);
        
        if (_frameCallback)
            _frameCallback(1.0 / frameRate);

        if (!executing) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, true);
            nextFrameTime = OEMonotonicTime() + advance;
        }
        
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.001, true);
    }
    }

    [[self delegate] gameCoreDidFinishFrameRefreshThread:self];
}

- (void)stopEmulation
{
    [_renderDelegate suspendFPSLimiting];
    shouldStop = YES;

    [self didStopEmulation];
}

- (void)stopEmulationWithCompletionHandler:(void(^)(void))completionHandler;
{
    [self performBlock:^{
        self->_stopEmulationHandler = [completionHandler copy];

        if (self.hasAlternateRenderingThread)
            [self->_renderDelegate willRenderFrameOnAlternateThread];
        else
            [self->_renderDelegate willExecute];

        [self stopEmulation];
    }];
}

- (void)didStopEmulation
{
    if(_stopEmulationHandler != nil)
        dispatch_async(dispatch_get_main_queue(), _stopEmulationHandler);

    _stopEmulationHandler = nil;
}

- (void)startEmulation
{
    if ([self class] == GameCoreClass) return;
    if (_rate != 0) return;

    [_renderDelegate resumeFPSLimiting];
    self.rate = 1;
}

#pragma mark - ABSTRACT METHODS

- (void)resetEmulation
{
    [self doesNotImplementSelector:_cmd];
}

- (void)OE_executeFrame
{
    os_signpost_interval_begin(OE_LOG_CORE_RUN, OS_SIGNPOST_ID_EXCLUSIVE, "OE_executeFrame");
    [_renderDelegate willExecute];
    
    os_signpost_interval_begin(OE_LOG_CORE_RUN, OS_SIGNPOST_ID_EXCLUSIVE, "executeFrame");
    [self executeFrame];
    os_signpost_interval_end(OE_LOG_CORE_RUN, OS_SIGNPOST_ID_EXCLUSIVE, "executeFrame");
    
    [_renderDelegate didExecute];
    os_signpost_interval_end(OE_LOG_CORE_RUN, OS_SIGNPOST_ID_EXCLUSIVE, "OE_executeFrame");
    [self OE_recordFrameForStats];
}

/// Logs one line every few seconds with how many frames ran and how long the slowest gap between frames was,
/// so a play test can read frame pacing from the log without anyone watching. Cheap: a clock read per frame.
- (void)OE_recordFrameForStats
{
    static const double kReportInterval = 3.0;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (_statsWindowStart == 0) {
        _statsWindowStart = _statsLastFrame = now;
        return;
    }
    double gapMs = (now - _statsLastFrame) / 1e6;
    if (gapMs > _statsWorstGapMs) _statsWorstGapMs = gapMs;
    _statsLastFrame = now;
    _statsFrames++;

    // How full the first audio buffer is, sampled once per frame, and how many bytes the core wrote.
    NSUInteger fill = 0, written = 0;
    id<OEAudioBuffer> buffer = self.audioBufferCount > 0 ? [self audioBufferAtIndex:0] : nil;
    if ([buffer isKindOfClass:[OERingBuffer class]]) {
        OERingBuffer *ring = (OERingBuffer *)buffer;
        fill = ring.availableBytes;
        written = ring.bytesWritten;
        _statsAudioCapacity = ring.length;
        if (_statsFrames == 1 || fill < _statsAudioFillMin) _statsAudioFillMin = fill;
        if (fill > _statsAudioFillMax) _statsAudioFillMax = fill;
        if (_statsAudioWrittenAtStart == 0 && _statsAudioWrittenAtStartSet == NO) { _statsAudioWrittenAtStart = written; _statsAudioWrittenAtStartSet = YES; }
        _statsAudioWrittenNow = written;
    }

    double elapsed = (now - _statsWindowStart) / 1e9;
    if (elapsed >= kReportInterval) {
        os_log(OE_LOG_CORE_RUN, "frame stats: %lu frames in %.1fs (%.1f fps), worst gap %.1f ms",
               (unsigned long)_statsFrames, elapsed, _statsFrames / elapsed, _statsWorstGapMs);
        if (_statsAudioCapacity > 0) {
            double bytesPerSecond = (_statsAudioWrittenNow - _statsAudioWrittenAtStart) / elapsed;
            os_log(OE_LOG_CORE_RUN, "audio stats: core wrote %.0f bytes/s, buffer fill min %lu max %lu of %lu bytes",
                   bytesPerSecond, (unsigned long)_statsAudioFillMin, (unsigned long)_statsAudioFillMax, (unsigned long)_statsAudioCapacity);
        }
        _statsWindowStart = now;
        _statsFrames = 0;
        _statsWorstGapMs = 0;
        _statsAudioFillMax = 0;
        _statsAudioWrittenAtStartSet = NO;
        _statsAudioWrittenAtStart = 0;
    }
}

- (void)executeFrame
{
    [self doesNotImplementSelector:_cmd];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (BOOL)loadFileAtPath:(NSString *)path
{
    [self doesNotImplementSelector:_cmd];
    return NO;
}
#pragma clang diagostic pop

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [self loadFileAtPath:path];
#pragma clang diagnostic pop
}

#pragma mark - Video

- (OEIntRect)screenRect
{
    return (OEIntRect){ {}, [self bufferSize]};
}

- (OEIntSize)bufferSize
{
    [self doesNotImplementSelector:_cmd];
    return (OEIntSize){};
}

- (OEIntSize)aspectSize
{
    return (OEIntSize){ 1, 1 };
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (const void *)videoBuffer
{
    [self doesNotImplementSelector:_cmd];
    return NULL;
}
#pragma clang diagnostic pop

- (uint32_t)pixelFormat
{
    [self doesNotImplementSelector:_cmd];
    return 0;
}

- (uint32_t)pixelType
{
    [self doesNotImplementSelector:_cmd];
    return 0;
}

- (NSInteger)bytesPerRow
{
    // This default implementation returns bufferSize.width * bytesPerPixel
    // Calculating bytes per pixel from the OpenGL enums needs a lot of entries.

    uint32_t pixelFormat = self.pixelFormat;
    uint32_t pixelType = self.pixelType;
    int nComponents = 0, bytesPerComponent = 0, bytesPerPixel = 0;

    switch (pixelFormat) {
        case OEPixelFormat_LUMINANCE:
            nComponents = 1;
            break;
        case OEPixelFormat_RGB:
        case OEPixelFormat_BGR:
            nComponents = 3;
            break;
        case OEPixelFormat_RGBA:
        case OEPixelFormat_BGRA:
            nComponents = 4;
            break;
    }

    switch (pixelType) {
        case OEPixelType_UNSIGNED_BYTE:
            bytesPerComponent = 1;
            break;
        case OEPixelType_UNSIGNED_SHORT_5_6_5:
        case OEPixelType_UNSIGNED_SHORT_5_6_5_REV:
        case OEPixelType_UNSIGNED_SHORT_4_4_4_4:
        case OEPixelType_UNSIGNED_SHORT_4_4_4_4_REV:
        case OEPixelType_UNSIGNED_SHORT_5_5_5_1:
        case OEPixelType_UNSIGNED_SHORT_1_5_5_5_REV:
            bytesPerPixel = 2;
            break;
        case OEPixelType_UNSIGNED_INT_8_8_8_8:
        case OEPixelType_UNSIGNED_INT_8_8_8_8_REV:
        case OEPixelType_UNSIGNED_INT_10_10_10_2:
        case OEPixelType_UNSIGNED_INT_2_10_10_10_REV:
            bytesPerPixel = 4;
            break;
    }

    if (!bytesPerPixel) bytesPerPixel = nComponents * bytesPerComponent;
    NSAssert(bytesPerPixel, @"Couldn't calculate bytesPerRow: %#x %#x", pixelFormat, pixelType);

    return bytesPerPixel * self.bufferSize.width;
}

- (BOOL)hasAlternateRenderingThread
{
    return NO;
}

- (BOOL)needsDoubleBufferedFBO
{
    return NO;
}
- (OEGameCoreRendering)gameCoreRendering {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if ([self respondsToSelector:@selector(rendersToOpenGL)]) {
        return [self rendersToOpenGL] ? OEGameCoreRenderingOpenGL2 : OEGameCoreRenderingBitmap;
    }
    #pragma clang diagnostic pop

    return OEGameCoreRenderingBitmap;
}

- (void)createMetalTextureWithDevice:(id<MTLDevice>)device
{
    _metalDevice = device;
    OEIntSize size = self.bufferSize;
    MTLTextureDescriptor* desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:size.width
                                    height:size.height
                                 mipmapped:false];
    [desc setUsage:MTLTextureUsageShaderRead];
    [desc setStorageMode:MTLStorageModePrivate];
    _metalTexture = [device newTextureWithDescriptor:desc];
}

- (const void*)getVideoBufferWithHint:(void *)hint
{
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [self videoBuffer];
    #pragma clang diagnostic pop
}


- (BOOL)tryToResizeVideoTo:(OEIntSize)size
{
    if (self.gameCoreRendering == OEGameCoreRenderingBitmap)
        return NO;

    return YES;
}

- (NSTimeInterval)frameInterval
{
    return 60.0;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (void)fastForward:(BOOL)flag
{
    // Fast-forward is permitted in hardcore mode per RA's hardcore-compliance
    // spec (only slowdown and frame advance are restricted, not speed-up).
    float newrate = flag ? 5.0 : 1.0;

    if (self.isEmulationPaused) {
        lastRate = newrate;
    } else {
        self.rate = newrate;
    }
}
#pragma clang diagnostic pop

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (void)rewind:(BOOL)flag
{
    if (self.hardcoreEnabled) { isRewinding = NO; return; }
    if(flag && [self supportsRewinding] && ![[self rewindQueue] isEmpty])
    {
        isRewinding = YES;
    }
    else
    {
        isRewinding = NO;
    }
}
#pragma clang diagnostic pop

- (void)setPauseEmulation:(BOOL)paused
{
    if (self.rate == 0 && paused)  return;
    if (self.rate != 0 && !paused) return;

    // Set rate to 0 and store the previous rate.
    if (paused) {
        lastRate = self.rate;
        self.rate = 0;
        [_audioDelegate pauseAudio];
    } else {
        self.rate = lastRate;
        [_audioDelegate resumeAudio];
    }
}

- (BOOL)isEmulationPaused
{
    return _rate == 0;
}

- (void)retroAchievementsIdle
{
}

- (NSData *)retroAchievementsSerializedProgress
{
    return nil;
}

- (void)retroAchievementsDeserializeProgress:(NSData *)data
{
}

- (BOOL)canPauseRetroAchievementsHardcoreWithFramesRemaining:(uint32_t *)framesRemaining
{
    if (framesRemaining != NULL) {
        *framesRemaining = 0;
    }
    return YES;
}

- (void)fastForwardAtSpeed:(CGFloat)fastForwardSpeed;
{
    // Fast-forward is permitted in hardcore mode per RA's hardcore-compliance
    // spec (only slowdown and frame advance are restricted, not speed-up).
    [self setRate:fastForwardSpeed];
}

- (void)rewindAtSpeed:(CGFloat)rewindSpeed;
{
    if (self.hardcoreEnabled) { isRewinding = NO; return; }
    isRewinding = (rewindSpeed > 0);
    [self setRate:rewindSpeed];
}

- (void)slowMotionAtSpeed:(CGFloat)slowMotionSpeed;
{
    if (self.hardcoreEnabled) return;
    [self setRate:slowMotionSpeed];
}

- (void)stepFrameForward
{
    if (self.hardcoreEnabled) return;
    singleFrameStep = YES;
}

- (void)stepFrameBackward
{
    if (self.hardcoreEnabled) return;
    singleFrameStep = isRewinding = YES;
}

- (void)setRate:(float)rate
{


    _rate = rate;
    if (_rate > 0.001)
      OESetThreadRealtime(1./(_rate * [self frameInterval]), OEGameCoreDefaultRealtimeConstraint, OEGameCoreDefaultRealtimeLimit);
}

- (void)beginPausedExecution
{
    if (isPausedExecution == YES) return;

    isPausedExecution = YES;
    [_renderDelegate suspendFPSLimiting];
    [_audioDelegate pauseAudio];
}

- (void)endPausedExecution
{
    if (isPausedExecution == NO) return;

    isPausedExecution = NO;
    [_renderDelegate resumeFPSLimiting];
    [_audioDelegate resumeAudio];
}

#pragma mark - Audio

- (id<OEAudioBuffer>)audioBufferAtIndex:(NSUInteger)index
{
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [self ringBufferAtIndex:index];
    #pragma clang diagnostic pop
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (OERingBuffer *)ringBufferAtIndex:(NSUInteger)index
{
    NSAssert1(index < [self audioBufferCount], @"The index %lu is too high", index);
    
    os_unfair_lock_lock(&_ringBufferLock);
    OERingBuffer *result = ringBuffers[index];
    if(result == nil) {
        /* ring buffer is 0.075 seconds (75ms).
         * 50ms was prone to crackling on high-load cores; 100ms added too much lag.
         * 75ms is the "Goldilocks" zone for stability vs. latency. */
        double sampleRate = [self audioSampleRateForBuffer:index];
        NSAssert(sampleRate > 0, @"Sample rate must be greater than 0 for buffer %lu", index);

        double frameSampleCount = sampleRate * 0.075;
        NSUInteger channelCount = [self channelCountForBuffer:index];
        NSUInteger bytesPerSample = [self audioBitDepth] / 8;
        NSAssert(frameSampleCount, @"frameSampleCount is 0");
        NSUInteger len = channelCount * bytesPerSample * frameSampleCount;
        NSUInteger coreRequestedLen = [self audioBufferSizeForBuffer:index] * 2;
        len = MAX(coreRequestedLen, len);
        
        result = [[OERingBuffer alloc] initWithLength:len];
        [result setDiscardPolicy:OERingBufferDiscardPolicyOldest];
        [result setAnticipatesUnderflow:YES];
        ringBuffers[index] = result;
    }
    os_unfair_lock_unlock(&_ringBufferLock);

    return result;
}
#pragma clang diagnostic pop

- (NSUInteger)audioBufferCount
{
    return 1;
}

- (void)getAudioBuffer:(void *)buffer frameCount:(NSUInteger)frameCount bufferIndex:(NSUInteger)index
{
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [[self ringBufferAtIndex:index] read:buffer maxLength:frameCount * [self channelCountForBuffer:index] * sizeof(UInt16)];
    #pragma clang diagnostic pop
}

- (NSUInteger)channelCount
{
    [self doesNotImplementSelector:_cmd];
    return 0;
}

- (double)audioSampleRate
{
    [self doesNotImplementSelector:_cmd];
    return 0;
}

- (NSUInteger)audioBitDepth
{
    return 16;
}

- (NSUInteger)channelCountForBuffer:(NSUInteger)buffer
{
    if(buffer == 0) return [self channelCount];

#if DEBUG
    os_log_error(OE_LOG_DEFAULT, "Buffer count is greater than 1, must implement %{public}@", NSStringFromSelector(_cmd));
#endif

    [self doesNotImplementSelector:_cmd];
    return 0;
}

- (NSUInteger)audioBufferSizeForBuffer:(NSUInteger)buffer
{
    double frameSampleCount = [self audioSampleRateForBuffer:buffer] / [self frameInterval];
    NSUInteger channelCount = [self channelCountForBuffer:buffer];
    NSUInteger bytesPerSample = [self audioBitDepth] / 8;
    NSAssert(frameSampleCount, @"frameSampleCount is 0");
    return channelCount * bytesPerSample * frameSampleCount;
}

- (double)audioSampleRateForBuffer:(NSUInteger)buffer
{
    if(buffer == 0) return [self audioSampleRate];

#if DEBUG
    os_log_error(OE_LOG_DEFAULT, "Buffer count is greater than 1, must implement %{public}@", NSStringFromSelector(_cmd));
#endif

    [self doesNotImplementSelector:_cmd];
    return 0;
}

#pragma mark - Save state

- (NSData *)serializeStateWithError:(NSError **)outError
{
    return nil;
}

- (BOOL)deserializeState:(NSData *)state withError:(NSError **)outError
{
    return NO;
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void(^)(BOOL success, NSError *error))block
{
    block(NO, [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreDoesNotSupportSaveStatesError userInfo:nil]);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void(^)(BOOL success, NSError *error))block
{
    block(NO, [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreDoesNotSupportSaveStatesError userInfo:nil]);
}

#pragma mark - Cheats

- (void)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled
{
}

- (NSArray<OEMemoryRegionDescriptor *> *)readableMemoryRegions
{
    return @[];
}

#pragma mark - Misc

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (void)changeDisplayMode;
{
}
#pragma clang diagnostic pop

#pragma mark - Discs

- (NSUInteger)discCount
{
    return 1;
}

- (void)setDisc:(NSUInteger)discNumber
{
}

#pragma mark - File Insertion

- (void)insertFileAtURL:(NSURL *)url completionHandler:(void(^)(BOOL success, NSError *error))block
{
    block(NO, [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadROMError userInfo:nil]);
}

#pragma mark - Display Mode

- (NSArray<NSDictionary<NSString *, id> *> *)displayModes
{
    return nil;
}

- (void)changeDisplayWithMode:(NSString *)displayMode
{
}

@end

#pragma mark - NSURL

@implementation OEGameCore (NSURL)

- (NSURL *)biosDirectory
{
    return self.owner.biosDirectory;
}

- (NSURL *)supportDirectory
{
    return self.owner.supportDirectory;
}

- (NSURL *)batterySavesDirectory
{
    return [self.supportDirectory URLByAppendingPathComponent:@"Battery Saves"];
}

- (BOOL)loadFileAtURL:(NSURL *)url error:(NSError **)error
{
    return [self loadFileAtPath:url.path error:error];
}

- (void)saveStateToFileAtURL:(NSURL *)url completionHandler:(void(^)(BOOL success, NSError *error))block
{
    [self saveStateToFileAtPath:url.path completionHandler:block];
}

- (void)loadStateFromFileAtURL:(NSURL *)url completionHandler:(void(^)(BOOL success, NSError *error))block
{
    [self loadStateFromFileAtPath:url.path completionHandler:block];
}

@end
