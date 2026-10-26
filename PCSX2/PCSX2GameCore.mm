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
#include "pcsx2/CDVD/CDVDcommon.h"
#include "pcsx2/Host.h"
#include "pcsx2/VMManager.h"
#undef BOOL

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
	BOOL _engineStarted;
}

- (BOOL)loadFileAtURL:(NSURL *)url error:(NSError **)error
{
	// The engine reads .iso, .bin/.cue images and compressed images by itself, so
	// the URL goes through untouched. A .cue is mapped to its .bin the way the
	// old bridge did, because the engine opens the data track directly.
	if ([url.pathExtension caseInsensitiveCompare:@"cue"] == NSOrderedSame) {
		_gameURL = [[url URLByDeletingPathExtension] URLByAppendingPathExtension:@"bin"];
	} else {
		_gameURL = [url copy];
	}

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
}

- (void)startEmulation
{
	if (_engineStarted) {
		[super startEmulation];
		return;
	}

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
}

- (void)stopEmulation
{
	OEHost::StopCPUThread();
	_engineStarted = NO;
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
	// The engine runs on its own CPU thread. Nothing to do per frame until item 3.
}

- (void)dealloc
{
	free(_videoBuffer);
}

#pragma mark - Video

- (OEGameCoreRendering)gameCoreRendering
{
	return OEGameCoreRenderingBitmap;
}

- (const void *)getVideoBufferWithHint:(void *)hint
{
	if (hint != NULL) {
		free(_videoBuffer);
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
	return GL_BGRA;
}

- (GLenum)pixelType
{
	return GL_UNSIGNED_INT_8_8_8_8_REV;
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

#pragma mark - Input (item 5)

- (oneway void)didMovePS2JoystickDirection:(OEPS2Button)button withValue:(CGFloat)value forPlayer:(NSUInteger)player
{
}

- (oneway void)didPushPS2Button:(OEPS2Button)button forPlayer:(NSUInteger)player
{
}

- (oneway void)didReleasePS2Button:(OEPS2Button)button forPlayer:(NSUInteger)player
{
}

#pragma mark - Save states (item 6)

- (void)saveStateToFileAtURL:(NSURL *)fileURL completionHandler:(void (^)(BOOL, NSError *))block
{
	block(NO, [NSError errorWithDomain:OEGameCoreErrorDomain
								  code:OEGameCoreDoesNotSupportSaveStatesError
							  userInfo:@{NSLocalizedDescriptionKey: @"PlayStation 2 save states are not available yet."}]);
}

- (void)loadStateFromFileAtURL:(NSURL *)fileURL completionHandler:(void (^)(BOOL, NSError *))block
{
	block(NO, [NSError errorWithDomain:OEGameCoreErrorDomain
								  code:OEGameCoreDoesNotSupportSaveStatesError
							  userInfo:@{NSLocalizedDescriptionKey: @"PlayStation 2 save states are not available yet."}]);
}

@end
