/*
 Copyright (c) 2020, OpenEmu Team

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
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#if TARGET_OS_OSX
#import <Cocoa/Cocoa.h>
#endif
#import <OpenEmuBase/OESystemResponderClient.h>
#import <OpenEmuBase/OEGeometry.h>
#import <OpenEmuBase/OEDiffQueue.h>
#import <OpenEmuBase/OEGameCoreDisplayModes.h>

@class OEGameCoreController, OEGameCore, OEMemoryRegionDescriptor;

#ifndef DLog

#ifdef DEBUG_PRINT
/*!
 * @function DLog
 * @abstract NSLogs when the source is built in Debug, otherwise does nothing.
 */
#define DLog(format, ...) NSLog(@"%@:%d: %s: " format, [[NSString stringWithUTF8String:__FILE__] lastPathComponent], __LINE__, __FUNCTION__, ##__VA_ARGS__)
#else
#define DLog(format, ...) do {} while(0)
#endif
#endif

/*!
 * @function GET_CURRENT_OR_RETURN
 * @abstract Fetch the current game core, or fail with given return code if there is none.
 */
#define GET_CURRENT_OR_RETURN(...) __strong __typeof__(_current) current = _current; if(current == nil) return __VA_ARGS__;

/*!
 * @macro OE_EXPORTED_CLASS
 * @abstract Define "Symbols Hidden By Default" on core projects and declare the core class with this
 * for the optimizations. Especially effective for dead code stripping and LTO.
 */
#define OE_EXPORTED_CLASS     __attribute__((visibility("default")))

#define OE_DEPRECATED(reason) __attribute__((deprecated(reason)))
#define OE_DEPRECATED_WITH_REPLACEMENT(reason, replacement) __attribute__((deprecated(reason, replacement)))

#define OEGameCoreDefaultRealtimeConstraint 0.007
#define OEGameCoreDefaultRealtimeLimit      0.03

#pragma mark -

// Return values for -pixelFormat
#define OEPixelFormat_LUMINANCE   0x1909 // GL_LUMINANCE
#define OEPixelFormat_RGB         0x1907 // GL_RGB
#define OEPixelFormat_BGR         0x80E0 // GL_BGR
#define OEPixelFormat_RGBA        0x1908 // GL_RGBA
#define OEPixelFormat_BGRA        0x80E1 // GL_BGRA

// Return values for -pixelType
#define OEPixelType_UNSIGNED_BYTE                 0x1401 // GL_UNSIGNED_BYTE
#define OEPixelType_UNSIGNED_SHORT_5_6_5          0x8363 // GL_UNSIGNED_SHORT_5_6_5
#define OEPixelType_UNSIGNED_SHORT_5_6_5_REV      0x8364 // GL_UNSIGNED_SHORT_5_6_5_REV
#define OEPixelType_UNSIGNED_SHORT_4_4_4_4        0x8033 // GL_UNSIGNED_SHORT_4_4_4_4
#define OEPixelType_UNSIGNED_SHORT_4_4_4_4_REV    0x8365 // GL_UNSIGNED_SHORT_4_4_4_4_REV
#define OEPixelType_UNSIGNED_SHORT_5_5_5_1        0x8034 // GL_UNSIGNED_SHORT_5_5_5_1
#define OEPixelType_UNSIGNED_SHORT_1_5_5_5_REV    0x8366 // GL_UNSIGNED_SHORT_1_5_5_5_REV
#define OEPixelType_UNSIGNED_INT_8_8_8_8          0x8035 // GL_UNSIGNED_INT_8_8_8_8
#define OEPixelType_UNSIGNED_INT_8_8_8_8_REV      0x8367 // GL_UNSIGNED_INT_8_8_8_8_REV
#define OEPixelType_UNSIGNED_INT_10_10_10_2       0x8036 // GL_UNSIGNED_INT_10_10_10_2
#define OEPixelType_UNSIGNED_INT_2_10_10_10_REV   0x8368 // GL_UNSIGNED_INT_2_10_10_10_REV
 
#pragma mark -

NS_ASSUME_NONNULL_BEGIN

extern NSString *const OEGameCoreErrorDomain;

typedef NS_ERROR_ENUM(OEGameCoreErrorDomain, OEGameCoreErrorCodes) {
    OEGameCoreCouldNotStartCoreError = -1,
    OEGameCoreCouldNotLoadROMError   = -2,
    OEGameCoreCouldNotLoadStateError = -3,
    OEGameCoreStateHasWrongSizeError = -4,
    OEGameCoreCouldNotSaveStateError = -5,
    OEGameCoreDoesNotSupportSaveStatesError = -6,
};

/*!
 * @enum OEGameCoreRendering
 * @abstract Which renderer will be set up for the game core.
 */
typedef NS_ENUM(NSUInteger, OEGameCoreRendering) {
    OEGameCoreRenderingBitmap,      //!< The game bitmap will be put directly into an IOSurface.
    OEGameCoreRenderingOpenGL2,     //!< The core will be provided a CGL OpenGL 2.1 (Compatibility) context.
    OEGameCoreRenderingOpenGL3,     //!< The core will be provided a CGL OpenGL 3.2+ Core/OpenGLES3 context.
    OEGameCoreRenderingMetal2,      //!< Not yet implemented.
    
    OEGameCoreRendering2DVideo      NS_SWIFT_UNAVAILABLE("Use .bitmap instead")  NS_DEPRECATED_WITH_REPLACEMENT_MAC("OEGameCoreRenderingBitmap",  10.7, 10.14.4) = OEGameCoreRenderingBitmap,
    OEGameCoreRenderingOpenGL2Video NS_SWIFT_UNAVAILABLE("Use .openGL2 instead") NS_DEPRECATED_WITH_REPLACEMENT_MAC("OEGameCoreRenderingOpenGL2", 10.7, 10.14.4) = OEGameCoreRenderingOpenGL2,
    OEGameCoreRenderingOpenGL3Video NS_SWIFT_UNAVAILABLE("Use .openGL3 instead") NS_DEPRECATED_WITH_REPLACEMENT_MAC("OEGameCoreRenderingOpenGL3", 10.7, 10.14.4) = OEGameCoreRenderingOpenGL3,
    OEGameCoreRenderingMetal2Video  NS_SWIFT_UNAVAILABLE("Use .metal2 instead")  NS_DEPRECATED_WITH_REPLACEMENT_MAC("OEGameCoreRenderingMetal2",  10.7, 10.14.4) = OEGameCoreRenderingMetal2 ,
};

@protocol OERenderDelegate <NSObject>
@required

/*!
 * @method presentDoubleBufferedFBO
 * @discussion
 * If the core returns YES from needsDoubleBufferedFBO,
 * call this method when you wish to swap buffers.
 */
- (void)presentDoubleBufferedFBO;

/*!
 * @method willRenderFrameOnAlternateThread
 * @discussion
 * 2D - Not used.
 * 3D -
 * If rendering video on a secondary thread, call this method before every frame rendered.
 */
- (void)willRenderFrameOnAlternateThread;

/*!
 * @method didRenderFrameOnAlternateThread
 * @discussion
 * 2D - Not used.
 * 3D -
 * If rendering video on a secondary thread, call this method after every frame rendered.
 */
- (void)didRenderFrameOnAlternateThread;

/*!
 * @property presentationFramebuffer
 * @discussion
 * 2D - Not used.
 * 3D - For cores which can directly render to a GL FBO or equivalent,
 * this will return the FBO which game pixels eventually go to. This
 * allows porting of cores that overwrite GL_DRAW_FRAMEBUFFER.
 */
@property (nonatomic, readonly, nullable) id presentationFramebuffer;

// For internal use only.
- (void)willExecute;
- (void)didExecute;
- (void)suspendFPSLimiting;
- (void)resumeFPSLimiting;
@end

@protocol OEGameCoreDelegate <NSObject>
@required

#pragma mark - Internal APIs

- (void)gameCoreDidFinishFrameRefreshThread:(OEGameCore *)gameCore;

/// Called prior to any core execution or rendering of the next frame.
///
/// This method is called unconditionally, even when execution is paused.
/// - Parameter isExecuting: ``YES`` if the core will execute the next frame.
- (void)gameCoreWillBeginFrame:(BOOL)isExecuting;

/// Called after the core has executed a frame and the display is rendered.
///
/// This method is called unconditionally, even when execution is paused.
/// This may be used to continue to render display effects.
///
/// - Parameter isExecuting: ``YES`` if the core will execute the next frame.
- (void)gameCoreWillEndFrame:(BOOL)isExecuting;
@end

#pragma mark -

@protocol OEAudioDelegate <NSObject>
@required
- (void)audioSampleRateDidChange;

// If you expect no audio for an extended period of time, stop the playback thread.
- (void)pauseAudio;
- (void)resumeAudio;
@end

@class OERingBuffer;
@protocol OEAudioBuffer;

#pragma mark -

OE_EXPORTED_CLASS
#if TARGET_OS_OSX
@interface OEGameCore : NSResponder <OESystemResponderClient>
#else
@interface OEGameCore : NSObject <OESystemResponderClient>
#endif

// TODO: Move all ivars/properties that don't need overriding to a category?
@property(weak)     id<OEGameCoreDelegate> delegate;
@property(weak)     id<OERenderDelegate>   renderDelegate;
@property(weak)     id<OEAudioDelegate>    audioDelegate;

@property(nonatomic, weak)     OEGameCoreController          *owner;
@property(nonatomic, readonly) NSString                      *pluginName;

@property(nonatomic, readonly) NSString                      *biosDirectoryPath;
@property(nonatomic, readonly) NSString                      *supportDirectoryPath;
@property(nonatomic, readonly) NSString                      *batterySavesDirectoryPath;

@property(nonatomic, readonly) BOOL                           supportsRewinding;
@property(nonatomic, readonly) NSUInteger                     rewindInterval;
@property(nonatomic, readonly) NSUInteger                     rewindBufferSeconds;
@property(nonatomic, readonly) OEDiffQueue                   *rewindQueue;

/// When YES, the base implementations of rewind, fast-forward, and frame-step
/// become no-ops. Set by the helper when RetroAchievements hardcore mode is on.
@property(nonatomic)           BOOL                           hardcoreEnabled;

@property(nonatomic, copy)     NSString                      *systemIdentifier;
@property(nonatomic, copy)     NSString                      *systemRegion;
@property(nonatomic, copy)     NSString                      *ROMMD5 NS_SWIFT_NAME(romMD5);
@property(nonatomic, copy)     NSString                      *ROMHeader;
@property(nonatomic, copy)     NSString                      *ROMSerial;
@property(nonatomic, copy, nullable) NSURL                    *lockOnRomURL;
@property(nonatomic, copy, nullable) NSURL                    *lockOnUpmemURL;

/** The current value for each display mode preference key. Used to fetch the
 *  initial display mode state after the core is initialized.
 *  @note This property is set to the current state of all display modes --
 *    as fetched from the saved application preferences -- before
 *    -loadFileAtPath:error: is invoked. The SDK does not access it anymore
 *    after that. Therefore, it is not strictly necessary for the core to keep
 *    this property updated. */
@property(nonatomic, copy)     NSDictionary<NSString *, id> *displayModeInfo;

#pragma mark - Starting

/*!
 * @method loadFileAtPath:error
 * @discussion
 * Try to load a ROM and return NO if it fails, or YES if it succeeds.
 * You can do any setup you want here.
 */
- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error;

- (void)setupEmulationWithCompletionHandler:(void(^)(void))completionHandler;
- (void)startEmulationWithCompletionHandler:(void(^)(void))completionHandler;
- (void)resetEmulationWithCompletionHandler:(void(^)(void))completionHandler;

#pragma mark - Stopping

/*!
 * @method stopEmulation
 * @discussion
 * Shut down the core. In non-debugging modes of core execution,
 * the process will be exit immediately after, so you don't need to
 * free any CPU or OpenGL resources.
 *
 * The OpenGL context is available in this method.
 */
- (void)stopEmulation;
- (void)stopEmulationWithCompletionHandler:(void(^)(void))completionHandler;

#pragma mark - Execution

/*!
 * @property frameInterval
 * @abstract The ideal *frequency* (in Hz) of -executeFrame calls when rate=1.0.
 * This property is only read at the start and cannot be changed.
 * @discussion Even though the property name and type indicate that
 * a *period* in seconds should be returned (i.e. 1/60.0 ~= 0.01667 for 60 FPS execution),
 * this method shall return a frequency in Hz instead (the inverse of that period).
 * This naming mistake must be mantained for backwards compatibility.
 */
@property (nonatomic, readonly) NSTimeInterval frameInterval;

/*!
 * @property rate
 * @discussion
 * The rate the game is currently running at. Generally 1.0.
 * If 0, the core is paused.
 * If >1.0, the core is fast-forwarding and -executeFrame will be called more often.
 * Values <1.0 are not expected.
 *
 * There is no need to check this property if your core does all work inside -executeFrame.
 */
@property (nonatomic, assign) float rate;

/*!
 * @method executeFrame
 * @discussion
 * Called every 1/(rate*frameInterval) seconds by -runGameLoop:.
 * The core should produce 1 frameInterval worth of audio and can output 1 frame of video.
 */
- (void)executeFrame;

/*!
 * @method resetEmulation
 * @abstract Presses the reset button on the console.
 */
- (void)resetEmulation;

/*!
 * @method beginPausedExecution
 * @abstract Run the thread without appearing to execute the game.
 * @discussion OpenEmu may ask the core to save the game, etc. even though it is paused.
 * Some cores need to run their -executeFrame to process the save message (e.g. Mupen).
 * Call this method from inside the save method to handle this case without disturbing the UI.
 */
- (void)beginPausedExecution;
- (void)endPausedExecution;

#pragma mark - Video

/*!
 * @method getVideoBufferWithHint:
 * @param hint If possible, use 'hint' as the video buffer for this frame.
 * @discussion
 * Called before each -executeFrame call. The method should return 
 * a video buffer containing 'bufferSize' packed pixels, and -executeFrame
 * should draw into this buffer. If 'hint' is set, using that as the video
 * buffer may be faster. Besides that, returning the same buffer each time
 * may be faster.
 */
- (const void *)getVideoBufferWithHint:(void *)hint;

/*!
 * @method tryToResizeVideoTo:
 * @discussion
 * If the core can natively draw at any resolution, change the resolution
 * to 'size' and return YES. Otherwise, return NO. If YES, the next call to
 * -executeFrame will have a newly sized framebuffer.
 * It is assumed that only 3D cores can do this.
 */
- (BOOL)tryToResizeVideoTo:(OEIntSize)size;

/*!
 * @property gameCoreRendering
 * @discussion
 * What kind of 3D API the core requires, or none.
 * Defaults to OEGameCoreRenderingBitmap.
 */
@property (nonatomic, readonly) OEGameCoreRendering gameCoreRendering;

/*!
 * @property hasAlternateRenderingThread
 * @abstract If the core starts another thread to do 3D operations on.
 * @discussion
 * 3D -
 * OE will provide one extra GL context for this thread to avoid corruption
 * of the main context. More than one rendering thread is not supported.
 */
@property (nonatomic, readonly) BOOL hasAlternateRenderingThread;

/*!
 * @property needsDoubleBufferedFBO
 * @abstract If the game flickers when rendering directly to IOSurface.
 * @discussion
 * 3D -
 * Some cores' OpenGL renderers accidentally cause the IOSurface to update early,
 * either by calling glFlush() or through GL driver bugs. This implements a workaround.
 * Used by Mupen64Plus.
 */
@property (nonatomic, readonly) BOOL needsDoubleBufferedFBO;

/*!
 * @property bufferSize
 * @discussion
 * 2D -
 * The size in pixels to allocate the framebuffer at.
 * Cores should output at their largest native size, including overdraw, without aspect ratio correction.
 * 3D -
 * The initial size to allocate the framebuffer at.
 * The user may decide to resize it later, but OE will try to request new sizes at the same aspect ratio as bufferSize.
 */
@property(readonly) OEIntSize   bufferSize;

/*!
 * @property screenRect
 * @discussion
 * The rect inside the framebuffer showing the currently displayed picture,
 * not including overdraw, but without aspect ratio correction.
 * Aspect ratio correction is not used for 3D.
 */
@property(readonly) OEIntRect   screenRect;

/*!
 * @property aspectSize
 * @discussion
 * The size at the display aspect ratio (DAR) of the picture.
 * The actual pixel values are not used; only the ratio is used.
 * Aspect ratio correction is not used for 3D.
 */
@property(readonly) OEIntSize   aspectSize;

/*!
 * @property pixelFormat
 * @discussion
 * The 'type' parameter to glTexImage2D, used to create the framebuffer.
 * GL_BGRA is preferred, but avoid doing any conversions inside the core.
 * Ignored for 3D cores.
 */
@property(readonly) uint32_t    pixelType;

/*!
 * @property pixelFormat
 * @discussion
 * The 'format' parameter to glTexImage2D, used to create the framebuffer.
 * GL_UNSIGNED_SHORT_1_5_5_5_REV or GL_UNSIGNED_INT_8_8_8_8_REV are preferred, but
 * avoid doing any conversions inside the core.
 * Ignored for 3D cores.
 */
@property(readonly) uint32_t    pixelFormat;

/*!
 * @property bytesPerRow
 * @discussion
 * If the core outputs pixels with custom padding, and that padding cannot be expressed
 * as overscan with bufferSize, you can implement this to return the distance between
 * the first two rows in bytes.
 * Ignored for 3D cores.
 */
@property(readonly) NSInteger   bytesPerRow;

#pragma mark - Metal 3D

// The methods and properties in this section require OpenEmu 2.4.
@property (readonly, nullable) id<MTLDevice> metalDevice;
@property (readonly, nullable) id<MTLTexture> metalTexture;
- (void)createMetalTextureWithDevice:(id<MTLDevice>)device NS_SWIFT_NAME(createMetalTexture(device:));

#pragma mark - Audio

// TODO: Should this return void? What does it do?
- (void)getAudioBuffer:(void *)buffer frameCount:(NSUInteger)frameCount bufferIndex:(NSUInteger)index;

/**
 * Returns the OEAudioBuffer associated to the specified audio track.
 * @discussion A concrete game core can override this method to customize
 *      its audio buffering system. OpenEmu never calls the -write:maxLength: method
 *      of a buffer returned by this method.
 * @param index The audio track index.
 * @returns The audio buffer from which to read audio samples.
 */
- (id<OEAudioBuffer>)audioBufferAtIndex:(NSUInteger)index;

/*!
 * @property audioBufferCount
 * @discussion
 * Defaults to 1. Return a value other than 1 if the core can export
 * multiple audio tracks. There is currently not much need for this.
 */
@property(readonly) NSUInteger  audioBufferCount;

// Used when audioBufferCount == 1
@property(readonly) NSUInteger  channelCount;
@property(readonly) NSUInteger  audioBitDepth;
@property(readonly) double      audioSampleRate;

// Used when audioBufferCount > 1
- (NSUInteger)channelCountForBuffer:(NSUInteger)buffer;
- (double)audioSampleRateForBuffer:(NSUInteger)buffer;

/*!
 * @method audioBufferSizeForBuffer:
 * Returns the number of audio frames that are enquequed by the game core into
 * the ring buffer every video frame.
 * @param buffer The index of the buffer.
 * @note If this method is not overridden by a concrete game core, it
 * returns a very conservative frame count.
 */
- (NSUInteger)audioBufferSizeForBuffer:(NSUInteger)buffer;

#pragma mark - Save States

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void(^)(BOOL success, NSError *_Nullable error))block NS_SWIFT_ASYNC_THROWS_ON_FALSE(1);

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void(^)(BOOL success, NSError *_Nullable error))block NS_SWIFT_ASYNC_THROWS_ON_FALSE(1);

@end

#pragma mark - Optional

@interface OEGameCore (OptionalMethods)

#pragma mark - Save state - Optional

- (NSData * _Nullable)serializeStateWithError:(NSError **)outError;
- (BOOL)deserializeState:(NSData *)state withError:(NSError **)outError;

#pragma mark - Cheats - Optional

- (void)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled;

#pragma mark - Readable Memory - Optional

/// Returns an array of memory region descriptors with their current data.
/// Override this in cores that support cheat search / memory inspection.
- (NSArray<OEMemoryRegionDescriptor *> *)readableMemoryRegions;

#pragma mark - Live Memory - Optional

// Live memory lets an outside tool (such as an Archipelago client) read and write the
// running game's memory. Call these only from inside -performLiveMemoryTransaction:,
// so no frame runs in the middle of a set of reads and writes.

/// The platform of the loaded game ("GB", "GBC", "GBA", ...), or nil if the core does not support live memory.
- (NSString * _Nullable)liveMemoryPlatform;

/// The names of the memory areas that can be read and written while the game runs. Empty if unsupported.
- (NSArray<NSString *> *)liveMemoryAreaNames;

/// The size in bytes of a memory area, or 0 for an unknown area.
- (NSUInteger)sizeOfLiveMemoryArea:(NSString *)area;

/// Copies bytes from a memory area. Bytes past the end of the area read as 0.
/// Returns NO only when the area is unknown.
- (BOOL)readLiveMemoryArea:(NSString *)area offset:(uint64_t)offset length:(NSUInteger)length into:(uint8_t *)buffer;

/// Writes bytes into a memory area. Bytes past the end of the area are ignored.
/// Returns NO only when the area is unknown.
- (BOOL)writeLiveMemoryArea:(NSString *)area offset:(uint64_t)offset bytes:(const uint8_t *)bytes length:(NSUInteger)length;

/// Runs the block on the emulation thread while no frame is running. The default uses -performBlock:.
/// Cores that run the emulated CPU on a thread of their own must override this before listing any areas.
- (void)performLiveMemoryTransaction:(void (^)(void))block;

#pragma mark - Discs - Optional

@property(readonly) NSUInteger discCount;
- (void)setDisc:(NSUInteger)discNumber;

#pragma mark - File Insertion - Optional

- (void)insertFileAtURL:(NSURL *)file completionHandler:(void(^)(BOOL success, NSError *_Nullable error))block NS_SWIFT_ASYNC_THROWS_ON_FALSE(1);

#pragma mark - Display Mode - Optional

/** An array describing the available display mode options and the
 *  appearance of the menu used to select them.
 *  @discussion Each NSDictionary in the array corresponds to an item
 *    in the Display Modes menu.
 *    Each item can represent one of these things, depending on the keys
 *    contained in the dictionary:
 *     - A label
 *     - A separator
 *     - A binary (toggleable) option
 *     - An option mutually exclusive with other options
 *     - A nested group of options (which appears as a submenu)
 *    See OEGameCoreController.h for a detailed discussion of the keys contained
 *    in each item dictionary. */
@property(readonly, nullable) NSArray<NSDictionary<NSString *, id> *> *displayModes;

/** Change display mode.
 *  @param displayMode The name of the display mode to enable or disable, as
 *    specified in its OEGameCoreDisplayModeNameKey key. */
- (void)changeDisplayWithMode:(NSString *)displayMode;

@end

#pragma mark - Internal

// There should be no need to override these methods.
@interface OEGameCore ()
/*!
 * @method runGameLoop:
 * @discussion
 * Cores may implement this if they wish to control their entire event loop.
 * This is not recommended.
 */
- (void)runGameLoop:(id _Nullable)anArgument;

/*!
 * @method startEmulation
 * @discussion
 * A method called on OEGameCore after -setupEmulation and
 * before -executeFrame. You may implement it for organizational
 * purposes but it is not necessary.
 *
 * The OpenGL context is available in this method.
 */
- (void)startEmulation;

/*!
 * @method setupEmulation
 * @discussion
 * Try to setup emulation as much as possible before the UI appears.
 * Audio/video properties don't need to be valid before this method, but
 * do need to be valid after.
 *
 * It's not necessary to implement this, all setup can be done in loadFileAtPath
 * or in the first executeFrame. But you're more likely to run into OE bugs that way.
 */
- (void)setupEmulation;

- (void)didStopEmulation;
- (void)runStartUpFrameWithCompletionHandler:(void(^)(void))handler;

- (void)stopEmulationWithCompletionHandler:(void(^)(void))completionHandler;

/*!
 * @property pauseEmulation
 * @discussion Pauses the emulator "nicely".
 * When set to YES, pauses emulation. When set to NO,
 * resets the rate to whatever it previously was.
 * The FPS limiter will stop, causing your rendering thread to pause.
 * You should probably not override this.
 */
@property(nonatomic, getter=isEmulationPaused) BOOL pauseEmulation;
- (void)setPauseEmulation:(BOOL)pauseEmulation NS_REQUIRES_SUPER;

/// Called while emulation is paused so RetroAchievements can continue routine server communication.
- (void)retroAchievementsIdle;

/// Returns whether a RetroAchievements hardcore session may pause right now.
- (BOOL)canPauseRetroAchievementsHardcoreWithFramesRemaining:(uint32_t *_Nullable)framesRemaining;

/// Returns a serialized rcheevos progress blob for the current session, or nil if not supported.
/// Used to write a sidecar file alongside softcore save states so measured progress survives
/// across save/load cycles.
- (nullable NSData *)retroAchievementsSerializedProgress;

/// Restores rcheevos measured progress from a previously serialized blob.
/// Pass nil to reset progress cleanly — correct behavior for old save states with no sidecar.
- (void)retroAchievementsDeserializeProgress:(nullable NSData *)data;

/// When didExecute is called, will be the next wakeup time.
@property (nonatomic, readonly) NSTimeInterval nextFrameTime;

@end

#pragma mark - NSURL

// The methods and properties in this category require OpenEmu 2.4.
@interface OEGameCore (NSURL)

@property(nonatomic, readonly) NSURL *biosDirectory;
@property(nonatomic, readonly) NSURL *supportDirectory;
@property(nonatomic, readonly) NSURL *batterySavesDirectory;

/*!
 * @method loadFileAtURL:error
 * @discussion
 * Try to load a ROM and return NO if it fails, or YES if it succeeds.
 * You can do any setup you want here.
 */
- (BOOL)loadFileAtURL:(NSURL *)url error:(NSError **)error;

- (void)saveStateToFileAtURL:(NSURL *)url completionHandler:(void(^)(BOOL success, NSError *_Nullable error))block NS_SWIFT_ASYNC_THROWS_ON_FALSE(1);
- (void)loadStateFromFileAtURL:(NSURL *)url completionHandler:(void(^)(BOOL success, NSError *_Nullable error))block NS_SWIFT_ASYNC_THROWS_ON_FALSE(1);

@end

#pragma mark - Deprecated

// These methods will be removed after some time.
@interface OEGameCore (Deprecated)

- (BOOL)loadFileAtPath:(NSString *)path DEPRECATED_ATTRIBUTE NS_SWIFT_UNAVAILABLE("use loadFileAtPath:error:");

- (void)fastForward:(BOOL)flag OE_DEPRECATED("use -rate");
- (void)rewind:(BOOL)flag OE_DEPRECATED("use -rate");

- (BOOL)rendersToOpenGL OE_DEPRECATED("use -gameCoreRendering");
@property(readonly) const void *videoBuffer OE_DEPRECATED("use -getVideoBufferWithHint:");

- (OERingBuffer *)ringBufferAtIndex:(NSUInteger)index OE_DEPRECATED_WITH_REPLACEMENT("", "-audioBufferAtIndex:");

- (void)changeDisplayMode OE_DEPRECATED("use -changeDisplayWithMode:, -displayModes with OEGameCoreDisplayMode* constants, and self.displayModeInfo");

@property(assign) BOOL shouldSkipFrame OE_DEPRECATED("Not used by OpenEmu 2.0.9 and later.");

@property(readonly) uint32_t internalPixelFormat OE_DEPRECATED("Not used by OpenEmu 2.1 and later.");

@end

NS_ASSUME_NONNULL_END
