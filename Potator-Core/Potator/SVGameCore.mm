/*
 Copyright (c) 2015, OpenEmu Team

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

#import "SVGameCore.h"
#import <OpenEmuBase/OERingBuffer.h>
#import <OpenEmuBase/OEMemoryRegionDescriptor.h>
#import <OpenGL/gl.h>
#import "OESVSystemResponderClient.h"


#import "supervision.h"

@interface SVGameCore () <OESVSystemResponderClient>
{
    uint16_t *videoBuffer;
    NSString *romName;
    double sampleRate;

    uint8_t *romBuffer;
    size_t   romBufferSize;

    COLOR_SCHEME displayMode;

    NSTimeInterval frameInterval;

    NSMutableDictionary<NSString *, NSNumber *> *_cheatList;
}

@end

#define SCREEN_HEIGHT 160
#define SCREEN_WIDTH  160
#define SCREEN_AREA SCREEN_HEIGHT*SCREEN_WIDTH

@implementation SVGameCore

static __weak SVGameCore *_current;

- (id)init
{
    self = [super init];
    if(self)
    {
        videoBuffer = (uint16_t*)malloc(SCREEN_AREA*2);

        romBuffer = NULL;
        romBufferSize = 0;

        displayMode = COLOUR_SCHEME_DEFAULT;
    }

    _current = self;

    return self;
}


- (void)dealloc
{
    free(videoBuffer);
}

#pragma mark - Input
- (oneway void)didPushSVButton:(OESVButton)button
{
    switch(button)
    {
        case OESVButtonA:      controls_state|=0x10; break;
        case OESVButtonB:      controls_state|=0x20; break;
        case OESVButtonStart:  controls_state|=0x80; break;
        case OESVButtonSelect: controls_state|=0x40; break;
        case OESVButtonUp:     controls_state|=0x08; break;
        case OESVButtonDown:   controls_state|=0x04; break;
        case OESVButtonLeft:   controls_state|=0x02; break;
        case OESVButtonRight:  controls_state|=0x01; break;
        default:;
    }}

- (oneway void)didReleaseSVButton:(OESVButton)button
{
    switch(button)
    {
        case OESVButtonA:      controls_state^=0x10; break;
        case OESVButtonB:      controls_state^=0x20; break;
        case OESVButtonStart:  controls_state^=0x80; break;
        case OESVButtonSelect: controls_state^=0x40; break;
        case OESVButtonUp:     controls_state^=0x08; break;
        case OESVButtonDown:   controls_state^=0x04; break;
        case OESVButtonLeft:   controls_state^=0x02; break;
        case OESVButtonRight:  controls_state^=0x01; break;
        default:;
    }
}

- (void)changeDisplayMode
{
    displayMode = (COLOR_SCHEME)((displayMode+1) % COLOUR_SCHEME_COUNT);
    supervision_set_colour_scheme(displayMode);
}

#pragma mark Exectuion

#pragma mark - Emulation
- (NSTimeInterval)frameInterval
{
    return frameInterval ? frameInterval : 2097152./35112.; // 59.7
}

- (void)resetEmulation
{
    supervision_reset();
}

- (void)stopEmulation
{
    supervision_done();

    [super stopEmulation];
}

- (void)executeFrame
{
    supervision_exec_fast((int16*)videoBuffer,1);

    // Direct RAM pokes (mempatch style): re-applied every frame since the emulated CPU
    // overwrites the same RAM addresses. Lower work RAM is CPU 0x0000-0x1FFF; upper (video)
    // RAM is CPU 0x4000-0x5FFF. Registers (0x2000-0x3FFF) and ROM (0x6000+) are not poked.
    for (NSString *key in _cheatList) {
        if (![_cheatList[key] boolValue]) continue;
        for (NSString *singleCode in [key componentsSeparatedByString:@"+"]) {
            NSRange colonRange = [singleCode rangeOfString:@":"];
            if (colonRange.location == NSNotFound) continue;
            unsigned int addr = 0, val = 0;
            if (![[NSScanner scannerWithString:[singleCode substringToIndex:colonRange.location]] scanHexInt:&addr]) continue;
            if (![[NSScanner scannerWithString:[singleCode substringFromIndex:colonRange.location + 1]] scanHexInt:&val]) continue;
            if (addr <= 0x1FFF)
                memorymap_lowerRam[addr] = (uint8_t)val;
            else if (addr >= 0x4000 && addr <= 0x5FFF)
                memorymap_upperRam[addr & 0x1FFF] = (uint8_t)val;
        }
    }
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    romName = [path copy];
    if(romBuffer != NULL)
    {
        NSLog(@"WARNING: Releasing current rom buffer!");
        free(romBuffer);
        romBuffer = NULL;
        romBufferSize = 0;
    }

    //load cart, read bytes, get length
    NSData* dataObj = [NSData dataWithContentsOfFile:[romName stringByStandardizingPath] options:0 error:error];
    if(dataObj == nil)
        return false;

    romBufferSize = [dataObj length];
    romBuffer = (uint8_t*)malloc(romBufferSize);
    [dataObj getBytes:romBuffer length:romBufferSize];

    supervision_init();
    return supervision_load(romBuffer, (uint32_t)romBufferSize);
}

#pragma mark - Video
- (const void *)videoBuffer
{
    return videoBuffer;
}

- (OEIntRect)screenRect
{
    return OEIntRectMake(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT);
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(SCREEN_WIDTH, SCREEN_HEIGHT);
}

- (OEIntSize)aspectSize
{
    return OEIntSizeMake(1, 1);
}

- (GLenum)pixelFormat
{
    // Palette packs pixels as x-B5-G5-R5 (R in the low bits, see RGB555 in gpu.c), which the
    // Metal renderer maps to r5g5b5a1Unorm via RGBA + 1_5_5_5_REV. BGRA is not an accepted
    // Metal combination here and also swaps R/B.
    return GL_RGBA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_SHORT_1_5_5_5_REV;
}

- (GLenum)internalPixelFormat
{
    return GL_RGB5;
}

#pragma mark - Audio
- (double)audioSampleRate
{
    return sampleRate ? sampleRate : 48000;
}

- (NSUInteger)channelCount
{
    return 2;
}

#pragma mark - Save States
- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    const char * path = [fileName cStringUsingEncoding:NSUTF8StringEncoding];
    int success = sv_saveState(path, 0);
    if(block) block(success==1, nil);

}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    const char * path = [fileName cStringUsingEncoding:NSUTF8StringEncoding];
    int success = sv_loadState(path, 0);
    if(block) block(success==1, nil);
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
    // Watara Supervision work RAM is CPU 0x0000-0x1FFF (8KB), backed by memorymap_lowerRam.
    // Upper RAM (0x4000-0x5FFF) is the LCD framebuffer, excluded from search as pure video noise.
    NSData *data = [NSData dataWithBytes:memorymap_lowerRam length:0x2000];
    OEMemoryRegionDescriptor *descriptor = [OEMemoryRegionDescriptor descriptorWithName:@"System RAM"
                                                                                address:0x0000
                                                                           addressBytes:2
                                                                                   data:data];
    return @[descriptor];
}
@end
