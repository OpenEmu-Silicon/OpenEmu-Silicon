#import <OpenEmuBase/OERingBuffer.h>
#import <OpenGL/gl.h>
#import "JaguarGameCore.h"
#import "jaguar.h"
#import "file.h"
#import "jagbios.h"
#import "jagbios2.h"
#include "memory.h"
#include "log.h"
#include "tom.h"
#include "dsp.h"
#include "settings.h"
#include "joystick.h"
#include "dac.h"

#import "OERetroAchievementsTransport.h"
#import "OERetroAchievementsBridge.h"
#include <rc_consoles.h>

@interface JaguarGameCore () <OEJaguarSystemResponderClient>
{
    int videoWidth, videoHeight;
    double sampleRate;
    uint32_t *buffer;

    OERetroAchievementsBridge *_raBridge;
}
@end
@implementation JaguarGameCore

static JaguarGameCore *current;

// rcheevos addresses Jaguar RAM from 0 across the 2 MB main RAM; jaguarMainRAM points at that
// block (jagMemSpace + 0x000000). The bridge gates reads for ROM-ready and shutdown.
static uint32_t jaguar_rc_read_memory(uint32_t address, uint8_t *buffer,
                                      uint32_t num_bytes, rc_client_t *client)
{
    if (address >= 0x200000)
        return 0;
    if (address + num_bytes > 0x200000)
        num_bytes = 0x200000 - address;
    memcpy(buffer, jaguarMainRAM + address, num_bytes);
    return num_bytes;
}

- (id)init
{
    if (self = [super init]) {
        videoWidth = 1024;
        videoHeight = 512;
        sampleRate = 48000;
        buffer = new uint32_t[videoWidth * videoHeight];
        sampleBuffer = (uint16_t *)malloc(2048 * sizeof(uint16_t));
        memset(sampleBuffer, 0, 2048 * sizeof(uint16_t));
    }
    
    current = self;
    
    return self;
}

- (BOOL)loadFileAtPath:(NSString *)path
{
    NSString *batterySavesDirectory = [self batterySavesDirectoryPath];
    
    if([batterySavesDirectory length] != 0)
    {
        [[NSFileManager defaultManager] createDirectoryAtPath:batterySavesDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
        
        NSString *filePath = [batterySavesDirectory stringByAppendingString:@"/"];
        strcpy(vjs.EEPROMPath, [filePath UTF8String]);
    }
    
    //LogInit("vj.log");                                      // initialize log file for debugging
	vjs.GPUEnabled = true;
	vjs.audioEnabled = true;                                  // not used currently
	vjs.DSPEnabled = true;
	vjs.hardwareTypeNTSC = true;
	vjs.useJaguarBIOS = false;
	vjs.renderType = 0;
	
	JaguarInit();                                             // set up hardware
    memcpy(jagMemSpace + 0xE00000, (vjs.biosType == BT_K_SERIES ? jaguarBootROM : jaguarBootROM2), 0x20000); // Use the stock BIOS
	[self initVideo];
	SET32(jaguarMainRAM, 0, 0x00200000);                      // set up stack
	JaguarLoadFile((char *)[path UTF8String]);                // load rom
	JaguarReset();

    // RAM is allocated by JaguarInit and the ROM is loaded; start RA (login + whole-file hash)
    // and mark ready so rcheevos can read memory during -doFrame.
    _raBridge = [[OERetroAchievementsBridge alloc] initWithGameCore:self
                                                       memoryReader:jaguar_rc_read_memory
                                                          consoleID:(uint32_t)RC_CONSOLE_ATARI_JAGUAR];
    [_raBridge startWithROMPath:path];
    [_raBridge markROMReady];
    
    return YES;
    
}

- (void)executeFrame
{
    JaguarExecuteNew();
    
    SDLSoundCallback(NULL, sampleBuffer, 2048*2);
    [[current ringBufferAtIndex:0] write:sampleBuffer maxLength:2048*2];

    [_raBridge doFrame];
}

- (void)initVideo
{
    JaguarSetScreenPitch(videoWidth);
    JaguarSetScreenBuffer(buffer);
    for (int i = 0; i < videoWidth * videoHeight; ++i)
        buffer[i] = 0xFF00FFFF;
}

- (NSUInteger)audioBitDepth
{
    return 16;
}

- (void)setupEmulation
{
}

- (void)stopEmulation
{
    [_raBridge shutdown];
    _raBridge = nil;

    JaguarDone();

    [super stopEmulation];
}

- (void)resetEmulation
{
    JaguarReset();
    [_raBridge reset];
}

- (void)dealloc
{
    [_raBridge shutdown];
    _raBridge = nil;

    free(buffer);
    free(sampleBuffer);
}

#pragma mark - RetroAchievements
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

- (OEIntRect)screenRect
{
    return OEIntRectMake(0, 0, TOMGetVideoModeWidth(), TOMGetVideoModeHeight());
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(videoWidth, videoHeight);
}

- (OEIntSize)aspectSize
{
    return OEIntSizeMake(4, 3);
}

- (const void *)getVideoBufferWithHint:(void *)hint
{
    if (hint && hint != buffer) {
        buffer = (uint32_t *)hint;
        JaguarSetScreenBuffer(buffer);
    }
    return buffer;
}

- (GLenum)pixelFormat
{
    return GL_RGBA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_INT_8_8_8_8;
}

- (double)audioSampleRate
{
    return sampleRate;
}

- (NSTimeInterval)frameInterval
{
    return 60;
}

- (NSUInteger)channelCount
{
    return 2;
}

- (oneway void)didPushJaguarButton:(OEJaguarButton)button forPlayer:(NSUInteger)player
{
    uint8_t *currentController;
    
    if (player == 1) {
        currentController = joypad0Buttons;
    }
    else {
        currentController = joypad1Buttons;
    }
    
    // special cases to prevent invalid inputs
    if (button == OEJaguarButtonRight && currentController[BUTTON_L]) {
        currentController[BUTTON_L] = 0x00;
        currentController[BUTTON_R] = 0x01;
    }
    else if (button == OEJaguarButtonLeft && currentController[BUTTON_R]) {
        currentController[BUTTON_R] = 0x00;
        currentController[BUTTON_L] = 0x01;
    }
    else if (button == OEJaguarButtonDown && currentController[BUTTON_U]) {
        currentController[BUTTON_U] = 0x00;
        currentController[BUTTON_D] = 0x01;
    }
    else if (button == OEJaguarButtonUp && currentController[BUTTON_D]) {
        currentController[BUTTON_D] = 0x00;
        currentController[BUTTON_U] = 0x01;
    }
    else {
        int index = [self getIndexForOEJaguarButton:button];
        currentController[index] = 0x01;
    }
}

- (oneway void)didReleaseJaguarButton:(OEJaguarButton)button forPlayer:(NSUInteger)player
{
    uint8_t *currentController;
    
    if (player == 1) {
        currentController = joypad0Buttons;
    }
    else {
        currentController = joypad1Buttons;
    }
    
    int index = [self getIndexForOEJaguarButton:button];
    currentController[index] = 0x00;
}

- (int)getIndexForOEJaguarButton:(OEJaguarButton)btn {    
    switch (btn) {
        case OEJaguarButtonUp:
            return BUTTON_U;
        case OEJaguarButtonDown:
            return BUTTON_D;
        case OEJaguarButtonLeft:
            return BUTTON_L;
        case OEJaguarButtonRight:
            return BUTTON_R;
        case OEJaguarButtonA:
            return BUTTON_A;
        case OEJaguarButtonB:
            return BUTTON_B;
        case OEJaguarButtonC:
            return BUTTON_C;
        case OEJaguarButtonPause:
            return BUTTON_PAUSE;
        case OEJaguarButtonOption:
            return BUTTON_OPTION;
        case OEJaguarButton1:
            return BUTTON_1;
        case OEJaguarButton2:
            return BUTTON_2;
        case OEJaguarButton3:
            return BUTTON_3;
        case OEJaguarButton4:
            return BUTTON_4;
        case OEJaguarButton5:
            return BUTTON_5;
        case OEJaguarButton6:
            return BUTTON_6;
        case OEJaguarButton7:
            return BUTTON_7;
        case OEJaguarButton8:
            return BUTTON_8;
        case OEJaguarButton9:
            return BUTTON_9;
        case OEJaguarButton0:
            return BUTTON_0;
        case OEJaguarButtonAsterisk:
            return BUTTON_s;
        case OEJaguarButtonPound:
            return BUTTON_d;
        default:
            return -1;
    }
}

@end
