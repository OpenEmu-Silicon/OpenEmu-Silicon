/*
 Copyright (c) 2010 OpenEmu Team

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

#import "PokeMiniGameCore.h"

#import <OpenEmuBase/OERingBuffer.h>
#import <OpenEmuBase/OEMemoryRegionDescriptor.h>
#import <OpenGL/gl.h>
#import "PokeMini.h"
#import "Hardware.h"
#import "Joystick.h"
#import "Video_x1.h"

@interface PokeMiniGameCore () <OEPMSystemResponderClient>
{
    uint8_t *audioStream;
    uint32_t *videoBuffer;
    int videoWidth, videoHeight;
    NSString *romPath;
    NSMutableDictionary<NSString *, NSNumber *> *_cheatList;
}
@end

PokeMiniGameCore *current;

// Sound buffer size
#define SOUNDBUFFER	2048
#define PMSOUNDBUFF	(SOUNDBUFFER*2)

int OpenEmu_KeysMapping[] =
{
    0,		// Menu
    1,		// A
    2,		// B
    3,		// C
    4,		// Up
    5,		// Down
    6,		// Left
    7,		// Right
    8,		// Power
    9		// Shake
};

@implementation PokeMiniGameCore

- (id)init
{
    if(self = [super init])
    {
        videoWidth = 96;
        videoHeight = 64;
        
        audioStream = malloc(PMSOUNDBUFF);
        videoBuffer = malloc(videoWidth*videoHeight*4);
        memset(videoBuffer, 0, videoWidth*videoHeight*4);
        memset(audioStream, 0, PMSOUNDBUFF);
    }

    current = self;
    return self;
}

- (void)dealloc
{
    PokeMini_VideoPalette_Free();
    PokeMini_Destroy();
    free(audioStream);
    free(videoBuffer);
}

#pragma - mark Execution

- (void)setupEmulation
{
    CommandLineInit();
    CommandLine.eeprom_share = 1;
    
    // Set video spec and check if is supported
    if(!PokeMini_SetVideo((TPokeMini_VideoSpec *)&PokeMini_Video1x1, 32, CommandLine.lcdfilter, CommandLine.lcdmode))
    {
        NSLog(@"Couldn't set video spec.");
    }
    
    if(!PokeMini_Create(0, PMSOUNDBUFF))
    {
        NSLog(@"Error while initializing emulator.");
    }
    
    PokeMini_GotoCustomDir([[self biosDirectoryPath] UTF8String]);
    if(FileExist(CommandLine.bios_file))
    {
        PokeMini_LoadBIOSFile(CommandLine.bios_file);
    }
    
    [self EEPROMSetup];
    
    JoystickSetup("OpenEmu", 0, 30000, NULL, 12, OpenEmu_KeysMapping);
    
    PokeMini_VideoPalette_Init(PokeMini_RGB32, 0);
    PokeMini_VideoPalette_Index(CommandLine.palette, CommandLine.custompal, CommandLine.lcdcontrast, CommandLine.lcdbright);
    PokeMini_ApplyChanges();
    PokeMini_UseDefaultCallbacks();
    
    MinxAudio_ChangeEngine(MINX_AUDIO_GENERATED);
}

- (void)EEPROMSetup
{
    PokeMini_CustomLoadEEPROM = loadEEPROM;
    PokeMini_CustomSaveEEPROM = saveEEPROM;
    
    NSString *extensionlessFilename = [[romPath lastPathComponent] stringByDeletingPathExtension];
    NSString *batterySavesDirectory = [self batterySavesDirectoryPath];
    
    if([batterySavesDirectory length] != 0)
    {
        [[NSFileManager defaultManager] createDirectoryAtPath:batterySavesDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
        
        NSString *filePath = [batterySavesDirectory stringByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"eep"]];
        
        strcpy(CommandLine.eeprom_file, [filePath UTF8String]);
        loadEEPROM(CommandLine.eeprom_file);
    }
}

// Read EEPROM
int loadEEPROM(const char *filename)
{
    FILE *fp;
    
    // Read EEPROM from RAM file
    fp = fopen(filename, "rb");
    if (!fp) return 0;
    fread(EEPROM, 8192, 1, fp);
    fclose(fp);
    
    return 1;
}

// Write EEPROM
int saveEEPROM(const char *filename)
{
    FILE *fp;
    
    // Write EEPROM to RAM file
    fp = fopen(filename, "wb");
    if (!fp) return 0;
    fwrite(EEPROM, 8192, 1, fp);
    fclose(fp);
    
    return 1;
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    romPath = path;
    return YES;
}

- (void)executeFrame
{
    // Emulate 1 frame
    PokeMini_EmulateFrame();

    // Direct RAM pokes (mempatch style): re-applied every frame since the emulated CPU
    // overwrites the same RAM addresses. PM_RAM[0] maps to CPU address 0x1000; RAM spans
    // CPU 0x1000-0x1FFF, so only addresses in that range are poked.
    for (NSString *key in _cheatList) {
        if (![_cheatList[key] boolValue]) continue;
        NSArray<NSString *> *codes = [key componentsSeparatedByString:@"+"];
        for (NSString *singleCode in codes) {
            NSRange colonRange = [singleCode rangeOfString:@":"];
            if (colonRange.location == NSNotFound) continue;
            unsigned int addr = 0, val = 0;
            if (![[NSScanner scannerWithString:[singleCode substringToIndex:colonRange.location]] scanHexInt:&addr]) continue;
            if (![[NSScanner scannerWithString:[singleCode substringFromIndex:colonRange.location + 1]] scanHexInt:&val]) continue;
            if (addr >= 0x1000 && addr <= 0x1FFF)
                PM_RAM[addr - 0x1000] = (uint8_t)val;
        }
    }

    if(PokeMini_Rumbling) {
        PokeMini_VideoBlit(videoBuffer + PokeMini_GenRumbleOffset(current->videoWidth), current->videoWidth);
    }
    else
    {
        PokeMini_VideoBlit(videoBuffer, current->videoWidth);
    }
    LCDDirty = 0;
    
    MinxAudio_GetSamplesU8(audioStream, PMSOUNDBUFF);
    [[current ringBufferAtIndex:0] write:audioStream maxLength:PMSOUNDBUFF];
}

- (void)startEmulation
{
    if(self.rate != 0) return;

    [super startEmulation];
    PokeMini_LoadROM((char*)[romPath UTF8String]);
}

- (void)stopEmulation
{
    PokeMini_SaveFromCommandLines(1);
    
    [super stopEmulation];
}

- (void)resetEmulation
{
    PokeMini_Reset(1);
}

#pragma mark - Save State

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    block(PokeMini_SaveSSFile(fileName.fileSystemRepresentation, romPath.fileSystemRepresentation) ? YES : NO, nil);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    block(PokeMini_LoadSSFile(fileName.fileSystemRepresentation) ? YES : NO, nil);
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
    // Pokemon Mini RAM is CPU 0x1000-0x1FFF (4KB), backed by PM_RAM[0]..PM_RAM[0x0FFF].
    NSData *data = [NSData dataWithBytes:PM_RAM length:0x1000];
    OEMemoryRegionDescriptor *descriptor = [OEMemoryRegionDescriptor descriptorWithName:@"RAM"
                                                                                address:0x1000
                                                                           addressBytes:2
                                                                                   data:data];
    return @[descriptor];
}

#pragma mark - Video

- (OEIntSize)aspectSize
{
    return (OEIntSize){videoWidth, videoHeight};
}

- (OEIntRect)screenRect
{
    return OEIntRectMake(0, 0, videoWidth, videoHeight);
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(videoWidth, videoHeight);
}

- (const void *)getVideoBufferWithHint:(void *)hint
{
    return videoBuffer = (hint ?: videoBuffer);
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
    return 72;
}

#pragma mark - Audio

- (double)audioSampleRate
{
    return 44100;
}

- (NSUInteger)audioBitDepth
{
    return 8;
}

- (NSUInteger)channelCount
{
    return 1;
}

#pragma mark - Input

- (oneway void)didPushPMButton:(OEPMButton)button forPlayer:(NSUInteger)player
{
    JoystickButtonsEvent(button, 1);
}

- (oneway void)didReleasePMButton:(OEPMButton)button forPlayer:(NSUInteger)player
{
    JoystickButtonsEvent(button, 0);
}

@end
