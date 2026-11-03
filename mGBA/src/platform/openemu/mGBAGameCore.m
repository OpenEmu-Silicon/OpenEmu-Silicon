/*
 Copyright (c) 2016, Jeffrey Pfau

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS ''AS IS''
 AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 POSSIBILITY OF SUCH DAMAGE.
 */

#import "mGBAGameCore.h"


#include <mgba-util/common.h>

#include <mgba/core/blip_buf.h>
#include <mgba/core/core.h>
#include <mgba/core/cheats.h>
#include <mgba/core/serialize.h>
#include <mgba/gba/core.h>
#include <mgba/internal/gba/cheats.h>
#include <mgba/internal/gba/input.h>
#include <mgba/internal/gba/memory.h>
#include <mgba-util/circle-buffer.h>
#include <mgba-util/memory.h>
#include <mgba-util/vfs.h>

#import <OpenEmuBase/OEGameCoreController.h>
#import <OpenEmuBase/OERingBuffer.h>
#import <OpenEmuBase/OEMemoryRegionDescriptor.h>
#import "OEGBASystemResponderClient.h"
#import <OpenGL/gl.h>

#define RC_CLIENT_SUPPORTS_HASH 1
#include <rc_client.h>
#include <rc_consoles.h>
#import "OERetroAchievementsTransport.h"
#import "OERetroAchievementsBridge.h"

#define SAMPLES 1024

// Session payload keys and notification name are defined in OERetroAchievementsTransport.h.

#ifdef DEBUG
    #error "Cores should not be compiled in DEBUG! Follow the guide https://github.com/OpenEmu/OpenEmu/wiki/Compiling-From-Source-Guide"
#endif

const char* const binaryName = "mGBA";
const char* const projectName = "mGBA";
const char* projectVersion;

@interface mGBAGameCore () <OEGBASystemResponderClient>
{
	struct mCore* core;
	void* outputBuffer;
	NSMutableDictionary *cheatSets;
	OERetroAchievementsBridge *_raBridge;
    NSString *_romPath;
}
- (struct mCore *)mCore;
@end

// rcheevos GBA address space → hardware bus address:
//   0x000000–0x007FFF  →  IWRAM  0x03000000
//   0x008000–0x047FFF  →  EWRAM  0x02000000
//   0x048000–0x057FFF  →  SRAM   0x0E000000
static uint32_t gba_rc_to_hw(uint32_t addr) {
    if (addr < 0x008000) return 0x03000000 + addr;
    if (addr < 0x048000) return 0x02000000 + (addr - 0x008000);
    if (addr < 0x058000) return 0x0E000000 + (addr - 0x048000);
    return addr;
}

static uint32_t mGBA_rc_read_memory(uint32_t address, uint8_t *buffer,
                                     uint32_t num_bytes, rc_client_t *client)
{
    OERetroAchievementsBridge *bridge = (__bridge OERetroAchievementsBridge *)rc_client_get_userdata(client);
    mGBAGameCore *c = (mGBAGameCore *)bridge.core;
    if (!c) { return 0; }
    struct mCore *mcore = [c mCore];
    if (!mcore) { return 0; }
    for (uint32_t i = 0; i < num_bytes; i++) {
        uint32_t a = address + i;
        if (a >= 0x058000) { return i; }  // past SRAM region — short-read.
        buffer[i] = mcore->busRead8(mcore, gba_rc_to_hw(a));
    }
    return num_bytes;
}


static void _log(struct mLogger* log,
                 int category,
                 enum mLogLevel level,
                 const char* format,
                 va_list args)
{}

static struct mLogger logger = { .log = _log };

@implementation mGBAGameCore

- (struct mCore *)mCore { return core; }

- (id)init
{
	if ((self = [super init]))
	{
		core = GBACoreCreate();
		mCoreInitConfig(core, nil);

		struct mCoreOptions opts = {
			.useBios = true,
		};
        
        // Set up a logger. The default logger prints everything to STDOUT, which is not usually desirable.
        mLogSetDefaultLogger(&logger);

		mCoreConfigLoadDefaults(&core->config, &opts);
		core->init(core);
		outputBuffer = nil;

		unsigned width, height;
		core->desiredVideoDimensions(core, &width, &height);
		outputBuffer = malloc(width * height * BYTES_PER_PIXEL);
		core->setVideoBuffer(core, outputBuffer, width);
		core->setAudioBufferSize(core, SAMPLES);

		cheatSets = [[NSMutableDictionary alloc] init];
	}

	return self;
}


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

- (void)dealloc
{
    mCoreConfigDeinit(&core->config);
	core->deinit(core);
	free(outputBuffer);
}

#pragma mark - Execution

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    projectVersion = [self.owner.bundle.infoDictionary[@"CFBundleVersion"] UTF8String];

	NSString *batterySavesDirectory = [self batterySavesDirectoryPath];
	[[NSFileManager defaultManager] createDirectoryAtURL:[NSURL fileURLWithPath:batterySavesDirectory]
	                                withIntermediateDirectories:YES
	                                attributes:nil
	                                error:nil];
	if (core->dirs.save) {
		core->dirs.save->close(core->dirs.save);
	}
	core->dirs.save = VDirOpen([batterySavesDirectory fileSystemRepresentation]);

	if (!mCoreLoadFile(core, [path fileSystemRepresentation])) {
		if (error) {
			*error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadROMError userInfo:nil];
		}
		return NO;
	}
	mCoreAutoloadSave(core);

	core->reset(core);

    _romPath = path;
    _raBridge = [[OERetroAchievementsBridge alloc] initWithGameCore:self
                                                        memoryReader:mGBA_rc_read_memory
                                                           consoleID:RC_CONSOLE_GAMEBOY_ADVANCE];
    [_raBridge startWithROMPath:path];
    [_raBridge markROMReady];

	return YES;
}

- (void)executeFrame
{
	core->runFrame(core);

	[_raBridge doFrame];

	int16_t samples[SAMPLES * 2];
	size_t available = 0;
	available = blip_samples_avail(core->getAudioChannel(core, 0));
	blip_read_samples(core->getAudioChannel(core, 0), samples, available, true);
	blip_read_samples(core->getAudioChannel(core, 1), samples + 1, available, true);
	[[self audioBufferAtIndex:0] write:samples maxLength:available * 4];
}

- (void)stopEmulation
{
    [_raBridge shutdown];
    _raBridge = nil;
    [super stopEmulation];
}

- (void)resetEmulation
{
	[_raBridge reset];
	core->reset(core);
}

- (void)setupEmulation
{
	blip_set_rates(core->getAudioChannel(core, 0), core->frequency(core), 32768);
	blip_set_rates(core->getAudioChannel(core, 1), core->frequency(core), 32768);
}

#pragma mark - Video

- (OEIntSize)aspectSize
{
	return OEIntSizeMake(3, 2);
}

- (OEIntRect)screenRect
{
	unsigned width, height;
	core->desiredVideoDimensions(core, &width, &height);
    return OEIntRectMake(0, 0, width, height);
}

- (OEIntSize)bufferSize
{
	unsigned width, height;
	core->desiredVideoDimensions(core, &width, &height);
    return OEIntSizeMake(width, height);
}

- (const void *)getVideoBufferWithHint:(void *)hint
{
	OEIntSize bufferSize = [self bufferSize];

	if (!hint)
	{
		hint = outputBuffer;
	}

	outputBuffer = hint;
	core->setVideoBuffer(core, hint, bufferSize.width);

	return hint;
}

- (GLenum)pixelFormat
{
    return GL_RGBA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_INT_8_8_8_8_REV;
}

- (NSTimeInterval)frameInterval
{
	return core->frequency(core) / (double) core->frameCycles(core);
}

#pragma mark - Audio

- (NSUInteger)channelCount
{
    return 2;
}

- (double)audioSampleRate
{
    return 32768;
}

#pragma mark - Save State

- (NSData *)serializeStateWithError:(NSError **)outError
{
	struct VFile* vf = VFileMemChunk(nil, 0);
	if (!mCoreSaveStateNamed(core, vf, SAVESTATE_SAVEDATA)) {
		if (outError) {
			*outError = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadStateError userInfo:nil];
		}
		vf->close(vf);
		return nil;
	}
	size_t size = vf->size(vf);
	void* data = vf->map(vf, size, MAP_READ);
	NSData *nsdata = [NSData dataWithBytes:data length:size];
	vf->unmap(vf, data, size);
	vf->close(vf);
	return nsdata;
}

- (BOOL)deserializeState:(NSData *)state withError:(NSError **)outError
{
	struct VFile* vf = VFileFromConstMemory(state.bytes, state.length);
	if (!mCoreLoadStateNamed(core, vf, SAVESTATE_SAVEDATA)) {
		if (outError) {
			*outError = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadStateError userInfo:nil];
		}
		vf->close(vf);
		return NO;
	}
	vf->close(vf);
	return YES;
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
	struct VFile* vf = VFileOpen([fileName fileSystemRepresentation], O_CREAT | O_TRUNC | O_RDWR);
	block(mCoreSaveStateNamed(core, vf, 0), nil);
	vf->close(vf);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
	struct VFile* vf = VFileOpen([fileName fileSystemRepresentation], O_RDONLY);
	BOOL ok = mCoreLoadStateNamed(core, vf, 0);
	vf->close(vf);
	if (ok) {
		[_raBridge reset];
	}
	block(ok, nil);
}

#pragma mark - Input

const int GBAMap[] = {
	GBA_KEY_UP,
	GBA_KEY_DOWN,
	GBA_KEY_LEFT,
	GBA_KEY_RIGHT,
	GBA_KEY_A,
	GBA_KEY_B,
	GBA_KEY_L,
	GBA_KEY_R,
	GBA_KEY_START,
	GBA_KEY_SELECT
};

- (oneway void)didPushGBAButton:(OEGBAButton)button forPlayer:(NSUInteger)player
{
	UNUSED(player);
	core->addKeys(core, 1 << GBAMap[button]);
}

- (oneway void)didReleaseGBAButton:(OEGBAButton)button forPlayer:(NSUInteger)player
{
	UNUSED(player);
	core->clearKeys(core, 1 << GBAMap[button]);
}

#pragma mark - Cheats

- (void)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled
{
	code = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	code = [code stringByReplacingOccurrencesOfString:@" " withString:@""];

	NSString *codeId = [code stringByAppendingFormat:@"/%@", type];
	struct mCheatSet* cheatSet = [[cheatSets objectForKey:codeId] pointerValue];
	if (cheatSet) {
		cheatSet->enabled = enabled;
		return;
	}
	struct mCheatDevice* cheats = core->cheatDevice(core);
	cheatSet = cheats->createSet(cheats, [codeId UTF8String]);
	size_t size = mCheatSetsSize(&cheats->cheats);
	if (size) {
		cheatSet->copyProperties(cheatSet, *mCheatSetsGetPointer(&cheats->cheats, size - 1));
	}
	int codeType = GBA_CHEAT_AUTODETECT;
	NSArray *codeSet = [code componentsSeparatedByString:@"+"];
	for (id c in codeSet) {
		mCheatAddLine(cheatSet, [c UTF8String], codeType);
	}
	cheatSet->enabled = enabled;
	[cheatSets setObject:[NSValue valueWithPointer:cheatSet] forKey:codeId];
	mCheatAddSet(cheats, cheatSet);
}

- (NSArray<OEMemoryRegionDescriptor *> *)readableMemoryRegions
{
	const struct mCoreMemoryBlock* blocks = NULL;
	size_t count = core->listMemoryBlocks(core, &blocks);
	NSMutableArray *regions = [NSMutableArray arrayWithCapacity:count];
	for (size_t i = 0; i < count; i++) {
		if (strcmp(blocks[i].shortName, "IWRAM") != 0 &&
		    strcmp(blocks[i].shortName, "EWRAM") != 0) {
			continue;
		}
		size_t size = 0;
		void* memory = core->getMemoryBlock(core, blocks[i].id, &size);
		if (memory && size > 0) {
			NSData *data = [NSData dataWithBytes:memory length:size];
			NSString *name = [NSString stringWithUTF8String:blocks[i].shortName];
			OEMemoryRegionDescriptor *descriptor = [OEMemoryRegionDescriptor
			    descriptorWithName:name
			              address:blocks[i].start
			         addressBytes:4
			                 data:data];
			[regions addObject:descriptor];
		}
	}
	return regions;
}

#pragma mark - Live Memory

// Live memory areas for Archipelago clients. The names and layouts match what those
// clients expect from other GBA emulators:
//   ROM         the cartridge ROM from 0x08000000, writable (some games patch ROM at runtime)
//   EWRAM       0x02000000, 256 KiB
//   IWRAM       0x03000000, 32 KiB
//   System Bus  the full 32-bit GBA bus; writes reach RAM, ROM and SRAM

static NSString *const mGBALiveMemorySystemBus = @"System Bus";
static const uint32_t mGBASystemBusSize = 0x10000000;

/// The memory block behind a plain area, or NO if the name is not one of them.
static BOOL mGBALiveMemoryArea(struct mCore *core, NSString *area, uint8_t **data, size_t *size, uint32_t *base)
{
	size_t region;
	if ([area isEqualToString:@"ROM"]) {
		region = REGION_CART0;
		*base = BASE_CART0;
	} else if ([area isEqualToString:@"EWRAM"]) {
		region = REGION_WORKING_RAM;
		*base = BASE_WORKING_RAM;
	} else if ([area isEqualToString:@"IWRAM"]) {
		region = REGION_WORKING_IRAM;
		*base = BASE_WORKING_IRAM;
	} else {
		return NO;
	}

	size_t blockSize = 0;
	*data = core->getMemoryBlock(core, region, &blockSize);
	*size = *data ? blockSize : 0;
	return YES;
}

- (BOOL)mGBAHasLiveMemory
{
	uint8_t *rom = NULL;
	size_t romSize = 0;
	uint32_t base = 0;
	return mGBALiveMemoryArea(core, @"ROM", &rom, &romSize, &base) && rom && romSize > 0;
}

- (NSString *)liveMemoryPlatform
{
	return [self mGBAHasLiveMemory] ? @"GBA" : nil;
}

- (NSArray<NSString *> *)liveMemoryAreaNames
{
	if (![self mGBAHasLiveMemory]) return @[];
	return @[@"ROM", @"EWRAM", @"IWRAM", mGBALiveMemorySystemBus];
}

- (NSUInteger)sizeOfLiveMemoryArea:(NSString *)area
{
	if (![self mGBAHasLiveMemory]) return 0;
	if ([area isEqualToString:mGBALiveMemorySystemBus]) return mGBASystemBusSize;

	uint8_t *data = NULL;
	size_t size = 0;
	uint32_t base = 0;
	return mGBALiveMemoryArea(core, area, &data, &size, &base) ? size : 0;
}

- (BOOL)readLiveMemoryArea:(NSString *)area offset:(uint64_t)offset length:(NSUInteger)length into:(uint8_t *)buffer
{
	if (![self mGBAHasLiveMemory]) return NO;
	memset(buffer, 0, length);

	if ([area isEqualToString:mGBALiveMemorySystemBus]) {
		// rawRead8 looks at memory without the side effects of a real bus read.
		for (NSUInteger i = 0; i < length && offset + i < mGBASystemBusSize; i++)
			buffer[i] = (uint8_t)core->rawRead8(core, (uint32_t)(offset + i), -1);
		return YES;
	}

	uint8_t *data = NULL;
	size_t size = 0;
	uint32_t base = 0;
	if (!mGBALiveMemoryArea(core, area, &data, &size, &base)) return NO;
	if (offset < size)
		memcpy(buffer, data + offset, MIN(length, size - offset));
	return YES;
}

- (BOOL)writeLiveMemoryArea:(NSString *)area offset:(uint64_t)offset bytes:(const uint8_t *)bytes length:(NSUInteger)length
{
	if (![self mGBAHasLiveMemory]) return NO;

	if ([area isEqualToString:mGBALiveMemorySystemBus]) {
		for (NSUInteger i = 0; i < length && offset + i < mGBASystemBusSize; i++)
			core->rawWrite8(core, (uint32_t)(offset + i), -1, bytes[i]);
		return YES;
	}

	uint8_t *data = NULL;
	size_t size = 0;
	uint32_t base = 0;
	if (!mGBALiveMemoryArea(core, area, &data, &size, &base)) return NO;
	if (offset >= size) return YES;

	NSUInteger count = MIN(length, size - offset);
	if ([area isEqualToString:@"ROM"]) {
		// The ROM may be mapped straight from the file. rawWrite8 copies it first, and the
		// bounds check above keeps it from growing the ROM.
		for (NSUInteger i = 0; i < count; i++)
			core->rawWrite8(core, base + (uint32_t)(offset + i), -1, bytes[i]);
	} else {
		memcpy(data + offset, bytes, count);
	}
	return YES;
}

@end

