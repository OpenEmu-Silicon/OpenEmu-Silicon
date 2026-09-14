/*
 Copyright (c) 2023, OpenEmu Team

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

#import "JollyCVGameCore.h"

#include "jcv.h"
#include "jcv_memio.h"
#include "jcv_mixer.h"
#include "jcv_vdp.h"
#include "jcv_z80.h"

#import <OpenEmuBase/OERingBuffer.h>
#import <OpenEmuBase/OEMemoryRegionDescriptor.h>
#import "OEColecoVisionSystemResponderClient.h"
#import <OpenGL/gl.h>

#define SAMPLERATE 48000
#define FRAMERATE 60
#define CHANNELS 1
#define NUMINPUTS 2

@interface JollyCVGameCore () <OEColecoVisionSystemResponderClient>
{
    NSData *_romData;
    uint8_t _padData[NUMINPUTS][OEColecoVisionButtonCount];
    int16_t *_soundBuffer;
    NSMutableDictionary<NSString *, NSNumber *> *_cheatList;
}
@end

@implementation JollyCVGameCore

static __weak JollyCVGameCore *_current;

- (id)init
{
	if ((self = [super init]))
	{
        _current = self;
        _soundBuffer = (int16_t*)calloc(6400, sizeof(int16_t));
	}

	return self;
}

- (void)dealloc
{
    jcv_deinit();
    free(_soundBuffer);
}

#pragma mark - Execution

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    memset(_padData, 0, sizeof(_padData));

    // Set up JollyCV. yes, yes... jolly good!
    jcv_input_set_callback(&jcv_input_poll);
    jcv_mixer_set_callback(&jcv_audio_out);
    jcv_mixer_set_rate(SAMPLERATE);
    jcv_mixer_set_buffer(_soundBuffer);
    jcv_mixer_set_rsqual(3);
    jcv_vdp_set_palette(0); // 0 = TeaTime, 1 = SYoung
    jcv_set_region(REGION_NTSC);
    jcv_init();

    // Load BIOS
    NSString *biosPath = [self.biosDirectoryPath stringByAppendingPathComponent:@"coleco.rom"];
    if (!jcv_bios_load_file(biosPath.fileSystemRepresentation))
        return NO;

    // Load ROM
    _romData = [[NSData dataWithContentsOfFile:path] copy];
    if (_romData == nil)
        return NO;

    if (!jcv_rom_load((void *)_romData.bytes, _romData.length)) {
        if (error) {
            *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadROMError userInfo:nil];
        }
        return NO;
    }

	return YES;
}

- (void)executeFrame
{
    jcv_exec();

    // Raw RAM pokes: re-applied every frame since nothing else preserves them
    // across the emulated CPU's own writes to the same addresses.
    uint8_t *ram = jcv_get_ram();
    for (NSString *key in _cheatList) {
        if (![_cheatList[key] boolValue]) continue;
        NSArray<NSString *> *codes = [key componentsSeparatedByString:@"+"];
        for (NSString *singleCode in codes) {
            NSRange colonRange = [singleCode rangeOfString:@":"];
            if (colonRange.location == NSNotFound) continue;
            unsigned int addr = 0, val = 0;
            if (![[NSScanner scannerWithString:[singleCode substringToIndex:colonRange.location]] scanHexInt:&addr]) continue;
            if (![[NSScanner scannerWithString:[singleCode substringFromIndex:colonRange.location + 1]] scanHexInt:&val]) continue;
            ram[addr & 0x3FF] = (uint8_t)val;
        }
    }
}

- (void)resetEmulation
{
    jcv_reset(0);
}

#pragma mark - Video

- (OEIntSize)aspectSize
{
    // Adjust Pixel Aspect Ratio
    // Stretch the 256px wide playfield (not including overscan) to 292px for a 8:7 (1.14) PAR
    return OEIntSizeMake(CV_VDP_WIDTH * (8.0/7.0), CV_VDP_HEIGHT_OVERSCAN);
}

- (OEIntRect)screenRect
{
    return OEIntRectMake(6, 0, CV_VDP_WIDTH_OVERSCAN - 12, CV_VDP_HEIGHT_OVERSCAN);
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(CV_VDP_WIDTH_OVERSCAN, CV_VDP_HEIGHT_OVERSCAN);
}

- (const void *)getVideoBufferWithHint:(void *)hint
{
    jcv_vdp_set_buffer((uint32_t *)hint);
    return hint;
}

- (GLenum)pixelFormat
{
    return GL_BGRA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_INT_8_8_8_8_REV;
}

- (NSTimeInterval)frameInterval
{
	return 60;
}

#pragma mark - Audio

- (NSUInteger)channelCount
{
    return CHANNELS;
}

- (double)audioSampleRate
{
    return SAMPLERATE;
}

#pragma mark - Save State

- (NSData *)serializeStateWithError:(NSError **)outError
{
    const void *bytes = jcv_state_save_raw();
    size_t length = jcv_state_size();

    if(length)
        return [NSData dataWithBytes:bytes length:length];

    if(outError) {
        *outError = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotSaveStateError  userInfo:@{
            NSLocalizedDescriptionKey : @"Save state data could not be written",
            NSLocalizedRecoverySuggestionErrorKey : @"The emulator could not write the state data."
        }];
    }

    return nil;
}

- (BOOL)deserializeState:(NSData *)state withError:(NSError **)outError
{
    const void *bytes = state.bytes;
    size_t length = state.length;

    jcv_state_load_raw(bytes);

    size_t serialSize = jcv_state_size();

    if(serialSize != length)
    {
        if (outError) {
            *outError = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreStateHasWrongSizeError  userInfo:@{
                NSLocalizedDescriptionKey : @"Save state has wrong file size.",
                NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:@"The size of the save state does not have the right size, %lu expected, got: %ld.", serialSize, state.length],
            }];
        }
        return NO;
    }

    return YES;
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    block(jcv_state_save(fileName.fileSystemRepresentation) ? YES : NO, nil);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    block(jcv_state_load(fileName.fileSystemRepresentation) ? YES : NO, nil);
}

#pragma mark - Input

// ColecoVision Paddle
static uint16_t cv_input_map[] = {
    CV_INPUT_U, CV_INPUT_D, CV_INPUT_L, CV_INPUT_R, CV_INPUT_FL, CV_INPUT_FR,
    CV_INPUT_1, CV_INPUT_2, CV_INPUT_3, CV_INPUT_4, CV_INPUT_5, CV_INPUT_6,
    CV_INPUT_7, CV_INPUT_8, CV_INPUT_9, CV_INPUT_0, CV_INPUT_STR, CV_INPUT_PND
};

- (oneway void)didPushColecoVisionButton:(OEColecoVisionButton)button forPlayer:(NSUInteger)player;
{
    _padData[player-1][button] = 1;
}

- (oneway void)didReleaseColecoVisionButton:(OEColecoVisionButton)button forPlayer:(NSUInteger)player;
{
    _padData[player-1][button] = 0;
}

#pragma mark - Cheats

- (void)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled
{
    if (!_cheatList)
        _cheatList = [NSMutableDictionary dictionary];

    code = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    code = [code stringByReplacingOccurrencesOfString:@" " withString:@""];

    if (enabled)
        _cheatList[code] = @YES;
    else
        [_cheatList removeObjectForKey:code];
}

- (NSArray<OEMemoryRegionDescriptor *> *)readableMemoryRegions
{
    // Reported at 0x0000 (not the real $6000 CPU address) to match CrabEmu's
    // RAM-relative addressing for cheat search and imported cheats.
    NSData *ramData = [NSData dataWithBytes:jcv_get_ram() length:0x400];
    return @[
        [OEMemoryRegionDescriptor descriptorWithName:@"RAM"
                                              address:0x0000
                                         addressBytes:2
                                                 data:ramData]
    ];
}

#pragma mark - JollyCV callbacks

void jcv_audio_out(size_t samples)
{
    GET_CURRENT_OR_RETURN();
    id<OEAudioBuffer> buf = [current audioBufferAtIndex:0];
    [buf write:current->_soundBuffer maxLength:samples * sizeof(int16_t)];
}

uint16_t jcv_input_poll(int port)
{
    uint16_t b = 0x8080; // Always preset bit 7 for both segments

    GET_CURRENT_OR_RETURN(b);
    for (int i = 0; i < OEColecoVisionButtonCount; ++i)
        if (current->_padData[port][i]) b |= cv_input_map[i];

    return b;
}

@end
