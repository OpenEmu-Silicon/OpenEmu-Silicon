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

#import "blueMSXGameCore.h"
#import <OpenEmuBase/OEGameCoreController.h>
#import <OpenEmuBase/OERingBuffer.h>
#import <OpenEmuBase/OEMemoryRegionDescriptor.h>
#import <OpenGL/gl.h>
#import "OEMSXSystemResponderClient.h"
#import "OEColecoVisionSystemResponderClient.h"

#define RC_CLIENT_SUPPORTS_HASH 1
#include <rc_client.h>
#include <rc_consoles.h>
#import "OERetroAchievementsTransport.h"
#import "OERetroAchievementsBridge.h"

#include "ArchInput.h"
#include "ArchNotifications.h"
#include "Actions.h"
#include "JoystickPort.h"
#include "Machine.h"
#include "MidiIO.h"
#include "UartIO.h"
#include "Casette.h"
#include "Emulator.h"
#include "Board.h"
#include "Coleco.h"
#include "MSX.h"
#include "SlotManager.h"
#include "Language.h"
#include "LaunchFile.h"
#include "PrinterIO.h"
#include "InputEvent.h"

#import "Emulator.h"
#include "ArchEvent.h"

#include "Properties.h"
#include "VideoRender.h"
#include "AudioMixer.h"
#include "CMCocoaBuffer.h"


#define SOUND_SAMPLE_RATE     44100
#define SOUND_FRAME_SIZE      8192
#define SOUND_BYTES_PER_FRAME 2

#define FB_MAX_WIDTH (272 * 2)
#define FB_MAX_HEIGHT 240

#define virtualCodeSet(eventCode) self->virtualCodeMap[eventCode] = 1
#define virtualCodeUnset(eventCode) self->virtualCodeMap[eventCode] = 0
#define virtualCodeClear() memset(self->virtualCodeMap, 0, sizeof(self->virtualCodeMap));

@interface blueMSXGameCore () <OEMSXSystemResponderClient, OEColecoVisionSystemResponderClient>
{
    uint32_t *_videoBuffer;
    int _videoWidth, _videoHeight;
    int virtualCodeMap[256];
    BOOL _isDoubleWidth;
    NSString *fileToLoad;
    RomType romTypeToLoad;
    Properties *properties;
    Video *video;
    Mixer *mixer;
    NSMutableDictionary<NSString *, NSNumber *> *_cheatList;
    OERetroAchievementsBridge *_raBridge;
}

- (void)initializeEmulator;

@end

static blueMSXGameCore *_core;
static Int32 mixAudio(void *param, Int16 *buffer, UInt32 count);
static int framebufferScanline = 0;

// rcheevos ColecoVision map: virtual 0x0000-0x03FF == real 0x6000-0x63FF System RAM (see
// rc_memory_regions_colecovision) -- colecoGetRam() is already RAM-relative, same as the
// cheat search descriptor, so no rebasing is needed here.
static uint32_t bluemsx_rc_read_memory(uint32_t address, uint8_t *buffer,
                                        uint32_t num_bytes, rc_client_t *client)
{
    UInt8 *ram = colecoGetRam();
    if (!ram) return 0;

    uint32_t i;
    for (i = 0; i < num_bytes; i++) {
        if (address + i >= 0x400)
            return i;
        buffer[i] = ram[address + i];
    }
    return num_bytes;
}

// rcheevos MSX map exposes the raw linear main RAM contiguously (rc_memory_regions_msx),
// not the Z80's banked logical view. rc_client passes the region-relative address, so index
// msxGetRamData() directly and stop at the emulated RAM size.
static uint32_t bluemsx_rc_read_memory_msx(uint32_t address, uint8_t *buffer,
                                            uint32_t num_bytes, rc_client_t *client)
{
    UInt8 *ram = msxGetRamData();
    UInt32 ramSize = msxGetRamSize();
    if (!ram || ramSize == 0) return 0;

    uint32_t i;
    for (i = 0; i < num_bytes; i++) {
        if (address + i >= ramSize)
            return i;
        buffer[i] = ram[address + i];
    }
    return num_bytes;
}

@implementation blueMSXGameCore

- (id)init
{
    if ((self = [super init]))
    {
        _videoWidth =  272;
        _videoHeight =  240;
        _isDoubleWidth = NO;

        _core = self;
    }

    return self;
}

- (void)dealloc
{
    [_raBridge shutdown];
    _raBridge = nil;

    free(_videoBuffer);
    propDestroy(properties);
    mixerSetWriteCallback(mixer, NULL, NULL, 0);
    mixerDestroy(mixer);
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

- (void)initializeEmulator
{
    NSString *resourcePath = [[[self owner] bundle] resourcePath];

    __block NSString *machinesPath = [resourcePath stringByAppendingPathComponent:@"Machines"];
    __block NSString *machineName;

    if([[self systemIdentifier] isEqualToString:@"openemu.system.colecovision"])
        machineName = @"COL - ColecoVision";
    else
        machineName = @"MSX2+ - C-BIOS - JP";

    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *supportPath = [NSURL fileURLWithPath:[self supportDirectoryPath]];
    NSURL *customMachinesPath = [supportPath URLByAppendingPathComponent:@"Machines"];

    if ([customMachinesPath checkResourceIsReachableAndReturnError:NULL] == YES && ![[self systemIdentifier] isEqualToString:@"openemu.system.colecovision"])
    {
        NSArray *customMachines = [fm contentsOfDirectoryAtURL:customMachinesPath
                                    includingPropertiesForKeys:nil
                                                       options:NSDirectoryEnumerationSkipsHiddenFiles
                                                         error:NULL];

        [customMachines enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop)
        {
            NSString *customMachine = [[obj lastPathComponent] stringByDeletingPathExtension];

            machinesPath = [customMachinesPath path];
            machineName = customMachine;

            NSLog(@"blueMSX: Will use custom machine \"%@\"", customMachine);

            *stop = YES;
        }];
    }
    else
    {
        [fm createDirectoryAtURL:customMachinesPath
      withIntermediateDirectories:YES
                       attributes:nil
                            error:NULL];
    }

    properties = propCreate(0, EMU_LANG_ENGLISH, P_KBD_EUROPEAN, P_EMU_SYNCNONE, "");

    // Set machine name
    machineSetDirectory([machinesPath UTF8String]);
    strncpy(properties->emulation.machineName,
            [machineName UTF8String], PROP_MAXPATH - 1);

    // Set up properties
    properties->emulation.speed = 50;
    properties->emulation.syncMethod = P_EMU_SYNCTOVBLANKASYNC;
    properties->emulation.enableFdcTiming = YES;
    properties->emulation.vdpSyncMode = P_VDP_SYNCAUTO;

    properties->video.brightness = 100;
    properties->video.contrast = 100;
    properties->video.saturation = 100;
    properties->video.gamma = 100;
    properties->video.colorSaturationWidth = 0;
    properties->video.colorSaturationEnable = NO;
    properties->video.deInterlace = YES;
    properties->video.monitorType = P_VIDEO_PALNONE;
    properties->video.monitorColor = P_VIDEO_COLOR;
    properties->video.scanlinesPct = 100;
    properties->video.scanlinesEnable = (properties->video.scanlinesPct < 100);

    properties->sound.mixerChannel[MIXER_CHANNEL_PSG].volume = 100;
    properties->sound.mixerChannel[MIXER_CHANNEL_PSG].pan = 50;
    properties->sound.mixerChannel[MIXER_CHANNEL_PSG].enable = YES;
    properties->sound.mixerChannel[MIXER_CHANNEL_SCC].volume = 100;
    properties->sound.mixerChannel[MIXER_CHANNEL_SCC].pan = 50;
    properties->sound.mixerChannel[MIXER_CHANNEL_SCC].enable = YES;
    properties->sound.mixerChannel[MIXER_CHANNEL_MSXMUSIC].volume = 100;
    properties->sound.mixerChannel[MIXER_CHANNEL_MSXMUSIC].pan = 50;
    properties->sound.mixerChannel[MIXER_CHANNEL_MSXMUSIC].enable = YES;
    properties->sound.mixerChannel[MIXER_CHANNEL_MSXAUDIO].volume = 100;
    properties->sound.mixerChannel[MIXER_CHANNEL_MSXAUDIO].pan = 50;
    properties->sound.mixerChannel[MIXER_CHANNEL_MSXAUDIO].enable = YES;
    properties->sound.mixerChannel[MIXER_CHANNEL_KEYBOARD].volume = 100;
    properties->sound.mixerChannel[MIXER_CHANNEL_KEYBOARD].pan = 50;
    properties->sound.mixerChannel[MIXER_CHANNEL_KEYBOARD].enable = YES;
    properties->sound.mixerChannel[MIXER_CHANNEL_MOONSOUND].volume = 100;
    properties->sound.mixerChannel[MIXER_CHANNEL_MOONSOUND].pan = 50;
    properties->sound.mixerChannel[MIXER_CHANNEL_MOONSOUND].enable = YES;

    if([[self systemIdentifier] isEqualToString:@"openemu.system.colecovision"])
    {
        properties->joy1.typeId = JOYSTICK_PORT_COLECOJOYSTICK;
        properties->joy2.typeId = JOYSTICK_PORT_COLECOJOYSTICK;
    }
    else
    {
        properties->joy1.typeId = JOYSTICK_PORT_JOYSTICK;
        properties->joy2.typeId = JOYSTICK_PORT_JOYSTICK;
    }

    // Init translations (unused for the most part)
    langSetLanguage(properties->language);
    langInit();

    // Init input
    joystickPortSetType(0, properties->joy1.typeId);
    joystickPortSetType(1, properties->joy2.typeId);

    // Init misc. devices
    printerIoSetType(properties->ports.Lpt.type, properties->ports.Lpt.fileName);
    printerIoSetType(properties->ports.Lpt.type, properties->ports.Lpt.fileName);
    uartIoSetType(properties->ports.Com.type, properties->ports.Com.fileName);
    midiIoSetMidiOutType(properties->sound.MidiOut.type, properties->sound.MidiOut.fileName);
    midiIoSetMidiInType(properties->sound.MidiIn.type, properties->sound.MidiIn.fileName);
    ykIoSetMidiInType(properties->sound.YkIn.type, properties->sound.YkIn.fileName);

    // Init mixer
    mixer = mixerCreate();

    for (int i = 0; i < MIXER_CHANNEL_TYPE_COUNT; i++)
    {
        mixerSetChannelTypeVolume(mixer, i, properties->sound.mixerChannel[i].volume);
        mixerSetChannelTypePan(mixer, i, properties->sound.mixerChannel[i].pan);
        mixerEnableChannelType(mixer, i, properties->sound.mixerChannel[i].enable);
    }

    mixerSetMasterVolume(mixer, properties->sound.masterVolume);
    mixerEnableMaster(mixer, properties->sound.masterEnable);
    mixerSetStereo(mixer, YES);
    mixerSetWriteCallback(mixer, mixAudio, (__bridge void *)[self ringBufferAtIndex:0], SOUND_FRAME_SIZE);

    // Init media DB
    mediaDbLoad([[resourcePath stringByAppendingPathComponent:@"Databases"] UTF8String]);
    mediaDbSetDefaultRomType(properties->cartridge.defaultType);

    // Init board
    boardSetFdcTimingEnable(properties->emulation.enableFdcTiming);
    boardSetY8950Enable(properties->sound.chip.enableY8950);
    boardSetYm2413Enable(properties->sound.chip.enableYM2413);
    boardSetMoonsoundEnable(properties->sound.chip.enableMoonsound);
    boardSetVideoAutodetect(properties->video.detectActiveMonitor);
    boardEnableSnapshots(0);

    // Init storage
    for (int i = 0; i < PROP_MAX_CARTS; i++)
    {
        if (properties->media.carts[i].fileName[0])
            insertCartridge(properties, i, properties->media.carts[i].fileName,
                            properties->media.carts[i].fileNameInZip,
                            properties->media.carts[i].type, -1);
    }

    for (int i = 0; i < PROP_MAX_DISKS; i++)
    {
        if (properties->media.disks[i].fileName[0])
            insertDiskette(properties, i, properties->media.disks[i].fileName,
                           properties->media.disks[i].fileNameInZip, -1);
    }

    for (int i = 0; i < PROP_MAX_TAPES; i++)
    {
        if (properties->media.tapes[i].fileName[0])
            insertCassette(properties, i, properties->media.tapes[i].fileName,
                           properties->media.tapes[i].fileNameInZip, 0);
    }

    tapeSetReadOnly(properties->cassette.readOnly);

    // Misc. initialization
    emulatorInit(properties, mixer);
    actionInit(video, properties, mixer);
    emulatorRestartSound();
}

- (void)startEmulation
{
    // propertiesSetDirectory("", "");
    // tapeSetDirectory("/Cassettes", "");

    NSURL *batterySavesPath = [NSURL fileURLWithPath:[self batterySavesDirectoryPath]];
    [[NSFileManager defaultManager] createDirectoryAtURL:batterySavesPath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];

    boardSetDirectory([[self batterySavesDirectoryPath] UTF8String]);

    tryLaunchUnknownFile(properties, [fileToLoad UTF8String], YES);

    // The emulated RAM (colecoGetRam() / msxGetRamData()) only becomes valid once
    // tryLaunchUnknownFile has built the board, so the memory reader is gated open here
    // rather than in loadFileAtPath (bridge/observer registration already happened there,
    // so the helper's post-load token replay still lands).
    if (_raBridge)
        [_raBridge markROMReady];

    [super startEmulation];
}

- (void)stopEmulation
{
    [_raBridge shutdown];
    _raBridge = nil;

    emulatorSuspend();
    emulatorStop();

    [super stopEmulation];
}

- (void)setPauseEmulation:(BOOL)pauseEmulation
{
    if (pauseEmulation)
        emulatorSetState(EMU_PAUSED);
    else
        emulatorSetState(EMU_RUNNING);

    [super setPauseEmulation:pauseEmulation];
}

- (void)resetEmulation
{
    [_raBridge reset];
    actionEmuResetSoft();
}

- (void)fastForward:(BOOL)flag
{
    [super fastForward:flag];

    properties->emulation.speed = flag ? 100 : 50;
    emulatorSetFrequency(properties->emulation.speed, NULL);
}

- (oneway void)didPushColecoVisionButton:(OEColecoVisionButton)button forPlayer:(NSUInteger)player;
{
    int code = -1;

    switch (button)
    {
        case OEColecoVisionButtonUp:
            code = (player == 1) ? EC_JOY1_UP : EC_JOY2_UP;
            break;
        case OEColecoVisionButtonDown:
            code = (player == 1) ? EC_JOY1_DOWN : EC_JOY2_DOWN;
            break;
        case OEColecoVisionButtonLeft:
            code = (player == 1) ? EC_JOY1_LEFT : EC_JOY2_LEFT;
            break;
        case OEColecoVisionButtonRight:
            code = (player == 1) ? EC_JOY1_RIGHT : EC_JOY2_RIGHT;
            break;
        case OEColecoVisionButtonLeftAction:
            code = (player == 1) ? EC_JOY1_BUTTON1 : EC_JOY2_BUTTON1;
            break;
        case OEColecoVisionButtonRightAction:
            code = (player == 1) ? EC_JOY1_BUTTON2 : EC_JOY2_BUTTON2;
            break;
        case OEColecoVisionButton1:
            code = (player == 1) ? EC_COLECO1_1 : EC_COLECO2_1;
            break;
        case OEColecoVisionButton2:
            code = (player == 1) ? EC_COLECO1_2 : EC_COLECO2_2;
            break;
        case OEColecoVisionButton3:
            code = (player == 1) ? EC_COLECO1_3 : EC_COLECO2_3;
            break;
        case OEColecoVisionButton4:
            code = (player == 1) ? EC_COLECO1_4 : EC_COLECO2_4;
            break;
        case OEColecoVisionButton5:
            code = (player == 1) ? EC_COLECO1_5 : EC_COLECO2_5;
            break;
        case OEColecoVisionButton6:
            code = (player == 1) ? EC_COLECO1_6 : EC_COLECO2_6;
            break;
        case OEColecoVisionButton7:
            code = (player == 1) ? EC_COLECO1_7 : EC_COLECO2_7;
            break;
        case OEColecoVisionButton8:
            code = (player == 1) ? EC_COLECO1_8 : EC_COLECO2_8;
            break;
        case OEColecoVisionButton9:
            code = (player == 1) ? EC_COLECO1_9 : EC_COLECO2_9;
            break;
        case OEColecoVisionButton0:
            code = (player == 1) ? EC_COLECO1_0 : EC_COLECO2_0;
            break;
        case OEColecoVisionButtonAsterisk:
            code = (player == 1) ? EC_COLECO1_STAR : EC_COLECO2_STAR;
            break;
        case OEColecoVisionButtonPound:
            code = (player == 1) ? EC_COLECO1_HASH : EC_COLECO2_HASH;
            break;
        default:
            break;
    }

    if (code != -1)
        virtualCodeSet(code);
}

- (oneway void)didReleaseColecoVisionButton:(OEColecoVisionButton)button forPlayer:(NSUInteger)player;
{
    int code = -1;

    switch (button)
    {
        case OEColecoVisionButtonUp:
            code = (player == 1) ? EC_JOY1_UP : EC_JOY2_UP;
            break;
        case OEColecoVisionButtonDown:
            code = (player == 1) ? EC_JOY1_DOWN : EC_JOY2_DOWN;
            break;
        case OEColecoVisionButtonLeft:
            code = (player == 1) ? EC_JOY1_LEFT : EC_JOY2_LEFT;
            break;
        case OEColecoVisionButtonRight:
            code = (player == 1) ? EC_JOY1_RIGHT : EC_JOY2_RIGHT;
            break;
        case OEColecoVisionButtonLeftAction:
            code = (player == 1) ? EC_JOY1_BUTTON1 : EC_JOY2_BUTTON1;
            break;
        case OEColecoVisionButtonRightAction:
            code = (player == 1) ? EC_JOY1_BUTTON2 : EC_JOY2_BUTTON2;
            break;
        case OEColecoVisionButton1:
            code = (player == 1) ? EC_COLECO1_1 : EC_COLECO2_1;
            break;
        case OEColecoVisionButton2:
            code = (player == 1) ? EC_COLECO1_2 : EC_COLECO2_2;
            break;
        case OEColecoVisionButton3:
            code = (player == 1) ? EC_COLECO1_3 : EC_COLECO2_3;
            break;
        case OEColecoVisionButton4:
            code = (player == 1) ? EC_COLECO1_4 : EC_COLECO2_4;
            break;
        case OEColecoVisionButton5:
            code = (player == 1) ? EC_COLECO1_5 : EC_COLECO2_5;
            break;
        case OEColecoVisionButton6:
            code = (player == 1) ? EC_COLECO1_6 : EC_COLECO2_6;
            break;
        case OEColecoVisionButton7:
            code = (player == 1) ? EC_COLECO1_7 : EC_COLECO2_7;
            break;
        case OEColecoVisionButton8:
            code = (player == 1) ? EC_COLECO1_8 : EC_COLECO2_8;
            break;
        case OEColecoVisionButton9:
            code = (player == 1) ? EC_COLECO1_9 : EC_COLECO2_9;
            break;
        case OEColecoVisionButton0:
            code = (player == 1) ? EC_COLECO1_0 : EC_COLECO2_0;
            break;
        case OEColecoVisionButtonAsterisk:
            code = (player == 1) ? EC_COLECO1_STAR : EC_COLECO2_STAR;
            break;
        case OEColecoVisionButtonPound:
            code = (player == 1) ? EC_COLECO1_HASH : EC_COLECO2_HASH;
            break;
        default:
            break;
    }

    if (code != -1)
        virtualCodeUnset(code);
}

- (oneway void)didPushMSXJoystickButton:(OEMSXJoystickButton)button
                             controller:(NSInteger)index
{
    int code = -1;

    switch (button)
    {
    case OEMSXJoystickUp:
        code = (index == 1) ? EC_JOY1_UP : EC_JOY2_UP;
        break;
    case OEMSXJoystickDown:
        code = (index == 1) ? EC_JOY1_DOWN : EC_JOY2_DOWN;
        break;
    case OEMSXJoystickLeft:
        code = (index == 1) ? EC_JOY1_LEFT : EC_JOY2_LEFT;
        break;
    case OEMSXJoystickRight:
        code = (index == 1) ? EC_JOY1_RIGHT : EC_JOY2_RIGHT;
        break;
    case OEMSXButtonA:
        code = (index == 1) ? EC_JOY1_BUTTON1 : EC_JOY2_BUTTON1;
        break;
    case OEMSXButtonB:
        code = (index == 1) ? EC_JOY1_BUTTON2 : EC_JOY2_BUTTON2;
        break;
    default:
        break;
    }

    if (code != -1)
        virtualCodeSet(code);
}

- (oneway void)didReleaseMSXJoystickButton:(OEMSXJoystickButton)button
                                controller:(NSInteger)index
{
    int code = -1;

    switch (button)
    {
    case OEMSXJoystickUp:
        code = (index == 1) ? EC_JOY1_UP : EC_JOY2_UP;
        break;
    case OEMSXJoystickDown:
        code = (index == 1) ? EC_JOY1_DOWN : EC_JOY2_DOWN;
        break;
    case OEMSXJoystickLeft:
        code = (index == 1) ? EC_JOY1_LEFT : EC_JOY2_LEFT;
        break;
    case OEMSXJoystickRight:
        code = (index == 1) ? EC_JOY1_RIGHT : EC_JOY2_RIGHT;
        break;
    case OEMSXButtonA:
        code = (index == 1) ? EC_JOY1_BUTTON1 : EC_JOY2_BUTTON1;
        break;
    case OEMSXButtonB:
        code = (index == 1) ? EC_JOY1_BUTTON2 : EC_JOY2_BUTTON2;
        break;
    default:
        break;
    }

    if (code != -1)
        virtualCodeUnset(code);
}

- (oneway void)didPressKey:(OEMSXKey)key
{
    virtualCodeSet(key);
}

- (oneway void)didReleaseKey:(OEMSXKey)key
{
    virtualCodeUnset(key);
}

- (void)executeFrame
{
    // Update controls
    memcpy(eventMap, _core->virtualCodeMap, sizeof(_core->virtualCodeMap));

    // Raw pokes (ColecoVision/MSX only): re-applied every frame since nothing
    // else preserves them across the emulated CPU's own writes to the same addresses.
    BOOL isColeco = [[self systemIdentifier] isEqualToString:@"openemu.system.colecovision"];
    BOOL isMSX = [[self systemIdentifier] isEqualToString:@"openemu.system.msx"];
    // colecoGetRam() is NULL until the board finishes initializing; MSX pokes go through
    // slotWrite instead, which has no such startup window.
    UInt8 *ram = isColeco ? colecoGetRam() : NULL;
    if (isMSX || ram)
    {
        for (NSString *key in _cheatList)
        {
            if (![_cheatList[key] boolValue]) continue;
            NSArray<NSString *> *codes = [key componentsSeparatedByString:@"+"];
            for (NSString *singleCode in codes)
            {
                NSRange colonRange = [singleCode rangeOfString:@":"];
                if (colonRange.location == NSNotFound) continue;
                unsigned int addr = 0, val = 0;
                if (![[NSScanner scannerWithString:[singleCode substringToIndex:colonRange.location]] scanHexInt:&addr]) continue;
                if (![[NSScanner scannerWithString:[singleCode substringFromIndex:colonRange.location + 1]] scanHexInt:&val]) continue;
                if (isColeco)
                    ram[addr & 0x3FF] = (UInt8)val;
                else
                    slotWrite(NULL, (UInt16)addr, (UInt8)val);
            }
        }
    }

    [_raBridge doFrame];
}

- (NSTimeInterval)frameInterval
{
    return boardGetRefreshRate() ? boardGetRefreshRate() : 60;
}

#pragma mark - OE I/O

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    [self initializeEmulator];

    fileToLoad = nil;
    romTypeToLoad = ROM_UNKNOWN;

    const char *cpath = [path UTF8String];
    MediaType *mediaType = mediaDbLookupRomByPath(cpath);
    if (!mediaType)
        mediaType = mediaDbGuessRomByPath(cpath);

    if (mediaType)
        romTypeToLoad = mediaDbGetRomType(mediaType);

    fileToLoad = path;

    // Bridge/observer must be registered here, not in startEmulation: the helper replays
    // the cached RA token immediately after loadFileAtPath returns, and a bridge created
    // later would miss that one-time replay and never log in / show the boot placard.
    // markROMReady is deferred to startEmulation, once the emulated RAM is actually valid.
    if ([[self systemIdentifier] isEqualToString:@"openemu.system.colecovision"])
    {
        _raBridge = [[OERetroAchievementsBridge alloc] initWithGameCore:self
                                                            memoryReader:bluemsx_rc_read_memory
                                                               consoleID:RC_CONSOLE_COLECOVISION];
        [_raBridge startWithROMPath:path];
    }
    else if ([[self systemIdentifier] isEqualToString:@"openemu.system.msx"])
    {
        _raBridge = [[OERetroAchievementsBridge alloc] initWithGameCore:self
                                                            memoryReader:bluemsx_rc_read_memory_msx
                                                               consoleID:RC_CONSOLE_MSX];
        [_raBridge startWithROMPath:path];
    }

    return YES;
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    emulatorSuspend();
    boardSaveState([fileName fileSystemRepresentation], 1);
    emulatorResume();

    block(YES, nil);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        emulatorSuspend();
        emulatorStop();
        emulatorStart([fileName fileSystemRepresentation]);

        block(YES, nil);
    });
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
    if ([[self systemIdentifier] isEqualToString:@"openemu.system.msx"])
    {
        // Dumps the Z80's current logical view of the full address space (whatever is
        // banked in via slots/subslots right now), same as the built-in debugger does.
        UInt8 mem[0x10000];
        for (int i = 0; i < 0x10000; i++)
            mem[i] = slotPeek(NULL, (UInt16)i);

        NSData *memData = [NSData dataWithBytes:mem length:0x10000];
        return @[
            [OEMemoryRegionDescriptor descriptorWithName:@"RAM"
                                                  address:0x0000
                                             addressBytes:2
                                                     data:memData]
        ];
    }

    if (![[self systemIdentifier] isEqualToString:@"openemu.system.colecovision"])
        return @[];

    UInt8 *ram = colecoGetRam();
    if (!ram) return @[];

    // Reported at 0x0000 (not the real $6000 CPU address) to match CrabEmu/JollyCV's
    // RAM-relative addressing for cheat search and imported cheats.
    NSData *ramData = [NSData dataWithBytes:ram length:0x400];
    return @[
        [OEMemoryRegionDescriptor descriptorWithName:@"RAM"
                                              address:0x0000
                                         addressBytes:2
                                                 data:ramData]
    ];
}

#pragma mark - OE Video

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(FB_MAX_WIDTH, FB_MAX_HEIGHT);
}

- (OEIntRect)screenRect
{
    return OEIntRectMake(0, 0, _videoWidth, _videoHeight);
}

- (OEIntSize)aspectSize
{
    return OEIntSizeMake(256 * (8.0/7.0), 240);
}

- (const void *)getVideoBufferWithHint:(void *)hint
{
    if (!hint) {
        if (!_videoBuffer) _videoBuffer = (uint32_t *)malloc(FB_MAX_WIDTH * FB_MAX_HEIGHT * sizeof(uint32_t));
        hint = _videoBuffer;
    }
    return _videoBuffer = (uint32_t *)hint;
}

- (GLenum)pixelFormat
{
    return GL_BGRA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_INT_8_8_8_8_REV;
}

#pragma mark - OE Audio

- (double)audioSampleRate
{
    return SOUND_SAMPLE_RATE;
}

- (NSUInteger)channelCount
{
    return 2;
}

#pragma mark - Audio

static Int32 mixAudio(void *param, Int16 *buffer, UInt32 count)
{
    [[_core ringBufferAtIndex:0] write:buffer maxLength:count * SOUND_BYTES_PER_FRAME];

    return 0;
}

#pragma mark - blueMSX callbacks

#pragma mark - Emulation callbacks

void archEmulationStartNotification()
{
}

void archEmulationStopNotification()
{
}

void archEmulationStartFailure()
{
}

#pragma mark - Debugging callbacks

void archTrap(UInt8 value)
{
}

#pragma mark - Input Callbacks

void archPollInput()
{
}

UInt8 archJoystickGetState(int joystickNo)
{
    return 0; // Coleco-specific; unused
}

void archKeyboardSetSelectedKey(int keyCode)
{
}

#pragma mark - Mouse Callbacks

void archMouseGetState(int *dx, int *dy)
{
    // FIXME
//    @autoreleasepool
//    {
//        NSPoint coordinates = theEmulator.mouse.pointerCoordinates;
//        *dx = (int)coordinates.x;
//        *dy = (int)coordinates.y;
//    }
}

int archMouseGetButtonState(int checkAlways)
{
    // FIXME
//    @autoreleasepool
//    {
//        return theEmulator.mouse.buttonState;
//    }
    return 0;
}

void archMouseEmuEnable(AmEnableMode mode)
{
    // FIXME
//    @autoreleasepool
//    {
//        theEmulator.mouse.mouseMode = mode;
//    }
}

void archMouseSetForceLock(int lock)
{
}

#pragma mark - Sound callbacks

void archSoundCreate(Mixer* mixer, UInt32 sampleRate, UInt32 bufferSize, Int16 channels)
{
}

void archSoundDestroy()
{
}

void archSoundResume()
{
}

void archSoundSuspend()
{
}

#pragma mark - Video callbacks

int archUpdateEmuDisplay(int syncMode)
{
    return 1;
}

void archUpdateWindow()
{
}

void *archScreenCapture(ScreenCaptureType type, int *bitmapSize, int onlyBmp)
{
    return NULL;
}

// Framebuffer

Pixel *frameBufferGetLine(FrameBuffer *frameBuffer, int y)
{
    return (_core->_videoBuffer + y * FB_MAX_WIDTH);
}

FrameBufferData *frameBufferDataCreate(int maxWidth, int maxHeight, int defaultHorizZoom)
{
    return (void *)_core->_videoBuffer;
}

FrameBufferData *frameBufferGetActive()
{
    return (void *)_core->_videoBuffer;
}

FrameBuffer *frameBufferGetDrawFrame()
{
    return (void *)_core->_videoBuffer;
}

FrameBuffer *frameBufferFlipDrawFrame()
{
    return (void *)_core->_videoBuffer;
}

void frameBufferSetLineCount(FrameBuffer *frameBuffer, int val)
{
    _core->_videoHeight = val;
}

int frameBufferGetLineCount(FrameBuffer *frameBuffer) {
    return _core->_videoHeight;
}

int frameBufferGetDoubleWidth(FrameBuffer *frameBuffer, int y)
{
    return _core->_isDoubleWidth;
}

void frameBufferSetDoubleWidth(FrameBuffer *frameBuffer, int y, int val)
{
    if(_core->_isDoubleWidth != val)
    {
        _core->_isDoubleWidth = val;
        _core->_videoWidth = _core->_isDoubleWidth ? FB_MAX_WIDTH : 272;
    }
}

// MSX Ascii Laser and Gunstick
void frameBufferSetScanline(int scanline)
{
    framebufferScanline = scanline;
}

int frameBufferGetScanline()
{
    return framebufferScanline;
}

int frameBufferGetMaxWidth(FrameBuffer *frameBuffer)
{
    return _core->_videoWidth;
}

void frameBufferDataDestroy(FrameBufferData *frameData) {}
void frameBufferSetActive(FrameBufferData *frameData) {}
void frameBufferSetMixMode(FrameBufferMixMode mode, FrameBufferMixMode mask) {}
void frameBufferClearDeinterlace() {}
void frameBufferSetInterlace(FrameBuffer *frameBuffer, int val) {}

@end
