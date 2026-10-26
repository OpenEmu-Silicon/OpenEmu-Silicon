// Copyright (c) 2021, OpenEmu Team
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

// OpenEmu wrapper for the ARMSX2 PlayStation 2 engine.
//
// Item 2 of issue #769: the plugin loads a BIOS and boots a game or the BIOS menu.
// There is no picture yet (item 3), no audio (item 4), no input (item 5) and no
// save states or disc swap (item 6); those methods are present but empty so the
// host does not trip over them.

#import "PCSX2GameCore.h"

// The engine's headers use the name BOOL too. Rename Objective-C's for their duration.
#define BOOL PCSX2BOOL
#include "OEHost.h"
#include "common/Error.h"
#include "pcsx2/CDVD/CDVDcommon.h"
#include "pcsx2/Host/AudioStream.h"
#include "pcsx2/Host.h"
#include "pcsx2/SIO/Pad/Pad.h"
#include "pcsx2/SIO/Pad/PadDualshock2.h"
#include "pcsx2/SPU2/spu2.h"
#include "pcsx2/VMManager.h"
#undef BOOL

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <OpenEmuBase/OEAudioBuffer.h>

// Defined by the engine patch PCSX2/patches/0001-openemu-metal-output.patch.
void GSDeviceMTLSetOutputTextures(void *texture0, void *texture1);
int GSDeviceMTLReadyOutputIndex();

#include <string>

static const NSUInteger kFrameWidth = 640;
static const NSUInteger kFrameHeight = 448;

/// BIOS dumps to look for, best first. Item 6 will choose by disc region.
static NSArray<NSString *> *PreferredBIOSNames(void)
{
	return @[@"scph39001.bin", @"scph70004.bin", @"scph10000.bin", @"scph50000.bin", @"scph30004r.bin"];
}

@implementation PCSX2GameCore {
	NSURL *_gameURL;
	NSString *_biosFilename;
	uint32_t *_videoBuffer;
	BOOL _ownsVideoBuffer;  // NO once OpenEmu hands us its own buffer
	BOOL _engineStarted;
	id<MTLDevice> _outputDevice;
	id<MTLTexture> _outputTextures[2];  // the engine draws into one while OpenEmu shows the other
	NSArray<NSURL *> *_discURLs;        // the discs of an .m3u playlist; one entry for a single disc
	NSView *_renderView;            // the engine attaches its Metal layer here
}

- (BOOL)loadFileAtURL:(NSURL *)url error:(NSError **)error
{
	// The engine reads .iso, .bin/.cue images and compressed images by itself, so
	// the URL goes through untouched. A .cue is mapped to its .bin the way the
	// old bridge did, because the engine opens the data track directly.
	if ([url.pathExtension caseInsensitiveCompare:@"m3u"] == NSOrderedSame) {
		// A playlist of discs, one path per line (relative to the playlist), for games on
		// more than one disc. The first disc boots; the others are swapped in with setDisc:.
		NSString *playlist = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
		NSMutableArray<NSURL *> *discs = [NSMutableArray array];
		for (NSString *rawLine in [playlist componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
			NSString *line = [rawLine stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
			if (line.length == 0 || [line hasPrefix:@"#"]) {
				continue;
			}
			[discs addObject:[self discURLForPath:line relativeTo:url]];
		}
		if (discs.count == 0) {
			if (error) {
				*error = [NSError errorWithDomain:OEGameCoreErrorDomain
											 code:OEGameCoreCouldNotLoadROMError
										 userInfo:@{NSLocalizedDescriptionKey: @"The playlist does not list any discs.",
													NSURLErrorKey: url}];
			}
			return NO;
		}
		_discURLs = discs;
	} else {
		_discURLs = @[[self discURLForPath:url.path relativeTo:url]];
	}
	_gameURL = _discURLs.firstObject;

	// Find a BIOS now so a missing one is reported before anything starts.
	NSFileManager *fm = NSFileManager.defaultManager;
	for (NSString *name in PreferredBIOSNames()) {
		if ([fm fileExistsAtPath:[self.biosDirectory URLByAppendingPathComponent:name].path]) {
			_biosFilename = name;
			break;
		}
	}
	if (_biosFilename == nil) {
		// Fall back to any .bin the user put in the BIOS folder.
		for (NSString *name in [fm contentsOfDirectoryAtPath:self.biosDirectory.path error:nil]) {
			if ([name.pathExtension caseInsensitiveCompare:@"bin"] == NSOrderedSame) {
				_biosFilename = name;
				break;
			}
		}
	}
	if (_biosFilename == nil) {
		if (error) {
			*error = [NSError errorWithDomain:OEGameCoreErrorDomain
										 code:OEGameCoreCouldNotLoadROMError
									 userInfo:@{NSLocalizedDescriptionKey: @"No PlayStation 2 BIOS found.",
												NSLocalizedRecoverySuggestionErrorKey: @"Add a PS2 BIOS dump (for example scph39001.bin) to the PlayStation 2 BIOS folder and try again.",
												NSURLErrorKey: url}];
		}
		return NO;
	}
	return YES;
}

// The engine opens an image's data directly, so a .cue is mapped to the .bin next to it
// (as the old bridge did). A relative path is taken from the playlist's folder.
- (NSURL *)discURLForPath:(NSString *)path relativeTo:(NSURL *)base
{
	NSURL *disc = path.isAbsolutePath
		? [NSURL fileURLWithPath:path]
		: [[base URLByDeletingLastPathComponent] URLByAppendingPathComponent:path];
	if ([disc.pathExtension caseInsensitiveCompare:@"cue"] == NSOrderedSame) {
		disc = [[disc URLByDeletingPathExtension] URLByAppendingPathExtension:@"bin"];
	}
	return disc;
}

- (void)setupEmulation
{
	NSBundle *bundle = [NSBundle bundleForClass:[self class]];
	NSFileManager *fm = NSFileManager.defaultManager;

	NSURL *memoryCards = self.batterySavesDirectory;
	NSURL *saveStates = [self.supportDirectory URLByAppendingPathComponent:@"sstates" isDirectory:YES];
	[fm createDirectoryAtURL:memoryCards withIntermediateDirectories:YES attributes:nil error:NULL];
	[fm createDirectoryAtURL:saveStates withIntermediateDirectories:YES attributes:nil error:NULL];

	OEHost::Folders folders;
	folders.resources = bundle.resourceURL.fileSystemRepresentation;
	folders.support = self.supportDirectory.fileSystemRepresentation;
	folders.bios = self.biosDirectory.fileSystemRepresentation;
	folders.memoryCards = memoryCards.fileSystemRepresentation;
	folders.saveStates = saveStates.fileSystemRepresentation;
	folders.biosFilename = _biosFilename.UTF8String;

	std::string failure;
	if (!OEHost::Initialize(folders, &failure)) {
		NSLog(@"[PCSX2] Engine setup failed: %s", failure.c_str());
	}

	// A black frame until item 3 sends the engine's picture here.
	_videoBuffer = (uint32_t *)calloc(kFrameWidth * kFrameHeight, sizeof(uint32_t));
	_ownsVideoBuffer = YES;
}

- (void)startEmulation
{
	if (_engineStarted) {
		[super startEmulation];
		[self releaseFrameWait];
		return;
	}

	[self ensureRenderView];

	// A game's rumble goes to OpenEmu as an "OEGameCoreRumble" notification (player from 1,
	// motor strengths 0 to 1); the helper app passes it on to the controller.
	OEHost::SetVibrationCallback([](u32 pad, float large, float small) {
		[NSNotificationCenter.defaultCenter postNotificationName:@"OEGameCoreRumble"
														  object:nil
														userInfo:@{@"player": @(pad + 1),
																   @"strongMotor": @(large),
																   @"weakMotor": @(small)}];
	});

	VMBootParameters params;
	params.filename = _gameURL.fileSystemRepresentation;
	params.source_type = CDVD_SourceType::Iso;
	params.fast_boot = true;
	params.fullscreen = false;

	_engineStarted = YES;
	OEHost::StartCPUThread(std::move(params), [](bool ok, const std::string &error) {
		if (!ok) {
			NSLog(@"[PCSX2] Boot failed: %s", error.c_str());
		}
	});

	[super startEmulation];
	[self releaseFrameWait];
}

// OpenEmu's Metal renderer makes the game loop wait after every frame for a signal that only
// OpenGL cores send, so a Metal core's loop would stall after one frame. The engine paces
// itself (VMManager::Throttle), so turn that wait off.
- (void)releaseFrameWait
{
	[self.renderDelegate suspendFPSLimiting];
}

- (void)stopEmulation
{
	_engineStarted = NO;  // stops executeFrame touching the stream while it is torn down
	OEHost::StopCPUThread();
	[super stopEmulation];
}

- (void)resetEmulation
{
	Host::RunOnCPUThread([]() { VMManager::Reset(); }, false);
}

- (void)setPauseEmulation:(BOOL)pauseEmulation
{
	if (_engineStarted) {
		Host::RunOnCPUThread([pauseEmulation]() {
			if (VMManager::HasValidVM()) {
				VMManager::SetState(pauseEmulation ? VMState::Paused : VMState::Running);
			}
		}, false);
	}
	[super setPauseEmulation:pauseEmulation];
}

- (void)executeFrame
{
	// The engine runs on its own CPU thread and draws its own picture. What is left per
	// frame is the sound: the engine mixes into a stream that goes nowhere (the Null
	// backend), and we drain it into OpenEmu's audio ring, the way the engine's libretro
	// frontend does.
	if (!_engineStarted) {
		return;
	}
	AudioStream *stream = SPU2::GetOutputStream();
	if (stream == nullptr) {
		return;
	}

	id<OEAudioBuffer> ring = [self audioBufferAtIndex:0];
	float samples[2048 * 2];
	int16_t pcm[2048 * 2];
	u32 frames;
	// Faster or slower than normal speed, the sound would only crackle and overflow OpenEmu's
	// ring, so drain it and drop it.
	const BOOL silent = self.rate != 1.0f;
	while ((frames = stream->PullFrames(samples, 2048)) > 0) {
		if (silent) {
			continue;
		}
		for (u32 i = 0; i < frames * 2; i++) {
			float s = samples[i] < -1.0f ? -1.0f : (samples[i] > 1.0f ? 1.0f : samples[i]);
			pcm[i] = (int16_t)(s * 32767.0f);
		}
		[ring write:pcm maxLength:frames * 2 * sizeof(int16_t)];
	}
}

- (void)dealloc
{
	if (_ownsVideoBuffer) {
		free(_videoBuffer);
	}
}

#pragma mark - Speed and frame step

// Fast-forward and slow motion arrive as a change of rate. The engine paces itself, so map
// the rate onto its speed limiter: faster than normal runs unlimited, slower uses its
// slow-motion speed, and normal goes back to its nominal speed.
- (void)setRate:(float)rate
{
	[super setRate:rate];
	if (!_engineStarted || rate <= 0.0f) {
		return;  // paused, or not running yet; a pause is handled in setPauseEmulation:
	}
	const LimiterModeType mode = rate > 1.0f ? LimiterModeType::Unlimited
							   : rate < 1.0f ? LimiterModeType::Slomo
											 : LimiterModeType::Nominal;
	Host::RunOnCPUThread([mode]() {
		if (VMManager::HasValidVM()) {
			VMManager::SetLimiterMode(mode);
		}
	}, false);
}

// While paused, run exactly one frame of the engine. OpenEmu's own loop only calls
// executeFrame, which does nothing for the engine's picture.
- (void)stepFrameForward
{
	[super stepFrameForward];
	if (!_engineStarted) {
		return;
	}
	Host::RunOnCPUThread([]() {
		if (VMManager::HasValidVM()) {
			VMManager::FrameAdvance(1);
		}
	}, false);
}

#pragma mark - Video

- (OEGameCoreRendering)gameCoreRendering
{
	return OEGameCoreRenderingMetal2;
}

// The engine needs a view for its Metal layer even though the picture goes to the
// texture below. Build it on the main thread and hand it over before the CPU thread starts.
- (void)ensureRenderView
{
	if (_renderView != nil) {
		return;
	}
	void (^make)(void) = ^{
		self->_renderView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kFrameWidth, kFrameHeight)];
	};
	if (NSThread.isMainThread) {
		make();
	} else {
		dispatch_sync(dispatch_get_main_queue(), make);
	}
	OEHost::SetRenderSurface((__bridge void *)_renderView, (u32)kFrameWidth, (u32)kFrameHeight);
}

// OpenEmu calls this while it sets up the renderer. The engine's last render pass
// writes into this texture (see the engine patch), so it needs the render-target usage.
- (void)createMetalTextureWithDevice:(id<MTLDevice>)device
{
	_outputDevice = device;
	MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
																					width:kFrameWidth
																				   height:kFrameHeight
																				mipmapped:NO];
	desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	desc.storageMode = MTLStorageModePrivate;
	_outputTextures[0] = [device newTextureWithDescriptor:desc];
	_outputTextures[1] = [device newTextureWithDescriptor:desc];
	GSDeviceMTLSetOutputTextures((__bridge void *)_outputTextures[0], (__bridge void *)_outputTextures[1]);
	[self ensureRenderView];
}

- (id<MTLDevice>)metalDevice
{
	return _outputDevice;
}

// The newest frame the GPU has finished. The engine draws the next one into the other texture.
- (id<MTLTexture>)metalTexture
{
	return _outputTextures[GSDeviceMTLReadyOutputIndex() & 1];
}

- (const void *)getVideoBufferWithHint:(void *)hint
{
	if (hint != NULL) {
		// The hint buffer belongs to OpenEmu; only free the one we made.
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
	return OEIntSizeMake(4, 3);
}

- (NSTimeInterval)frameInterval
{
	return 60;
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
	return 48000;
}

#pragma mark - Discs

- (NSUInteger)discCount
{
	return _discURLs.count;
}

// OpenEmu numbers discs from 1. The engine opens and closes the tray itself.
- (void)setDisc:(NSUInteger)discNumber
{
	if (!_engineStarted || discNumber < 1 || discNumber > _discURLs.count) {
		return;
	}
	const std::string path = _discURLs[discNumber - 1].fileSystemRepresentation;
	Host::RunOnCPUThread([path]() {
		if (VMManager::HasValidVM()) {
			VMManager::ChangeDisc(CDVD_SourceType::Iso, path);
		}
	}, false);
}

#pragma mark - Input

// OpenEmu's PlayStation 2 buttons, in the engine's DualShock 2 input numbering.
static int EngineInputForButton(OEPS2Button button)
{
	switch (button) {
		case OEPS2ButtonUp:            return PadDualshock2::PAD_UP;
		case OEPS2ButtonDown:          return PadDualshock2::PAD_DOWN;
		case OEPS2ButtonLeft:          return PadDualshock2::PAD_LEFT;
		case OEPS2ButtonRight:         return PadDualshock2::PAD_RIGHT;
		case OEPS2ButtonTriangle:      return PadDualshock2::PAD_TRIANGLE;
		case OEPS2ButtonCircle:        return PadDualshock2::PAD_CIRCLE;
		case OEPS2ButtonCross:         return PadDualshock2::PAD_CROSS;
		case OEPS2ButtonSquare:        return PadDualshock2::PAD_SQUARE;
		case OEPS2ButtonL1:            return PadDualshock2::PAD_L1;
		case OEPS2ButtonL2:            return PadDualshock2::PAD_L2;
		case OEPS2ButtonL3:            return PadDualshock2::PAD_L3;
		case OEPS2ButtonR1:            return PadDualshock2::PAD_R1;
		case OEPS2ButtonR2:            return PadDualshock2::PAD_R2;
		case OEPS2ButtonR3:            return PadDualshock2::PAD_R3;
		case OEPS2ButtonStart:         return PadDualshock2::PAD_START;
		case OEPS2ButtonSelect:        return PadDualshock2::PAD_SELECT;
		case OEPS2ButtonAnalogMode:    return PadDualshock2::PAD_ANALOG;
		case OEPS2LeftAnalogUp:        return PadDualshock2::PAD_L_UP;
		case OEPS2LeftAnalogDown:      return PadDualshock2::PAD_L_DOWN;
		case OEPS2LeftAnalogLeft:      return PadDualshock2::PAD_L_LEFT;
		case OEPS2LeftAnalogRight:     return PadDualshock2::PAD_L_RIGHT;
		case OEPS2RightAnalogUp:       return PadDualshock2::PAD_R_UP;
		case OEPS2RightAnalogDown:     return PadDualshock2::PAD_R_DOWN;
		case OEPS2RightAnalogLeft:     return PadDualshock2::PAD_R_LEFT;
		case OEPS2RightAnalogRight:    return PadDualshock2::PAD_R_RIGHT;
		default:                       return -1;
	}
}

// OpenEmu numbers players from 1; the engine's pad ports from 0. A press is 1, a
// release is 0, and a stick direction is the amount (0 to 1).
- (void)setPS2Button:(OEPS2Button)button value:(float)value forPlayer:(NSUInteger)player
{
	const int input = EngineInputForButton(button);
	if (input < 0 || player < 1) {
		return;
	}
	Pad::SetControllerState((u32)(player - 1), (u32)input, value);
}

- (oneway void)didMovePS2JoystickDirection:(OEPS2Button)button withValue:(CGFloat)value forPlayer:(NSUInteger)player
{
	[self setPS2Button:button value:(float)value forPlayer:player];
}

- (oneway void)didPushPS2Button:(OEPS2Button)button forPlayer:(NSUInteger)player
{
	[self setPS2Button:button value:1.0f forPlayer:player];
}

- (oneway void)didReleasePS2Button:(OEPS2Button)button forPlayer:(NSUInteger)player
{
	[self setPS2Button:button value:0.0f forPlayer:player];
}

#pragma mark - Save states

static NSError *SaveStateError(NSString *message, NSURL *url)
{
	return [NSError errorWithDomain:OEGameCoreErrorDomain
							   code:OEGameCoreCouldNotSaveStateError
						   userInfo:@{NSLocalizedDescriptionKey: message, NSURLErrorKey: url}];
}

// Both calls run on the engine's CPU thread and wait for it, since the engine only
// touches the machine from there. A save state is the engine's own zip file.
- (void)saveStateToFileAtURL:(NSURL *)fileURL completionHandler:(void (^)(BOOL, NSError *))block
{
	if (!_engineStarted) {
		block(NO, SaveStateError(@"The PlayStation 2 is not running.", fileURL));
		return;
	}

	const std::string path = fileURL.fileSystemRepresentation;
	bool saved = false;
	std::string failure;
	Host::RunOnCPUThread([&]() {
		if (!VMManager::HasValidVM()) {
			failure = "No game is running.";
			return;
		}
		// Not zipped on a background thread, so the file is complete when this returns.
		VMManager::SaveState(path.c_str(), false, false, [&failure](const std::string &error) {
			failure = error.empty() ? "The save failed." : error;
		});
		saved = failure.empty();
	}, true);

	if (saved) {
		block(YES, nil);
	} else {
		block(NO, SaveStateError([NSString stringWithFormat:@"Could not save the state: %s", failure.c_str()], fileURL));
	}
}

- (void)loadStateFromFileAtURL:(NSURL *)fileURL completionHandler:(void (^)(BOOL, NSError *))block
{
	// OpenEmu loads a resume (auto) save the moment the core starts, before the engine has
	// booted its virtual machine. Wait for the machine to exist instead of failing, up to 30 s.
	for (int waited = 0; waited < 600 && !(_engineStarted && VMManager::HasValidVM()); waited++) {
		usleep(50 * 1000);
	}
	if (!_engineStarted) {
		block(NO, SaveStateError(@"The PlayStation 2 is not running.", fileURL));
		return;
	}

	const std::string path = fileURL.fileSystemRepresentation;
	bool loaded = false;
	std::string failure;
	Host::RunOnCPUThread([&]() {
		if (!VMManager::HasValidVM()) {
			failure = "No game is running.";
			return;
		}
		Error error;
		loaded = VMManager::LoadState(path.c_str(), &error);
		if (!loaded) {
			failure = error.GetDescription();
		}
	}, true);

	if (loaded) {
		block(YES, nil);
	} else {
		block(NO, [NSError errorWithDomain:OEGameCoreErrorDomain
									  code:OEGameCoreCouldNotLoadStateError
								  userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not load the state: %s", failure.c_str()],
											 NSURLErrorKey: fileURL}]);
	}
}

@end
