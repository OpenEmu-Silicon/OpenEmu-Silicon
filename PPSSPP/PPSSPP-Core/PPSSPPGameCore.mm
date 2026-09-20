/*
 Copyright (c) 2013, OpenEmu Team

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

#import "PPSSPPGameCore.h"
#import <OpenEmuBase/OEGameCoreController.h>
#import <OpenEmuBase/OEMemoryRegionDescriptor.h>
#import <OpenEmuBase/OERingBuffer.h>
#import <OpenGL/gl.h>

#include "Common/GPU/OpenGL/OpenEmuGLContext.h"

#include "System/NativeApp.h"

#define ExceptionInfo PPSSPPExceptionInfo
#include "Core/Core.h"
#include "Core/Config.h"
#include "Core/ConfigValues.h"
#include "Core/CoreParameter.h"
#include "Core/CoreTiming.h"
#include "Core/ELF/ParamSFO.h"
#include "Core/HLE/sceCtrl.h"
#include "Core/HLE/sceUtility.h"
#include "Core/Host.h"
#include "Core/MemMap.h"
#include "Core/SaveState.h"
#include "Core/System.h"
#undef ExceptionInfo

#include "Common/File/Path.h"
#include "Common/GraphicsContext.h"
#include "Common/LogManager.h"
#include "Common/Data/Text/I18n.h"

#include "GPU/GPUInterface.h"
#include "thin3d_create.h"
#include "GLRenderManager.h"
#include "DataFormatGL.h"

#define AUDIO_FREQ          44100
#define AUDIO_CHANNELS      2
#define AUDIO_SAMPLESIZE    sizeof(int16_t)



namespace SaveState {
    struct SaveStart {
        void DoState(PointerWrap &p);
    };
} // namespace SaveState

namespace OpenEmuCoreThread {
    enum class EmuThreadState {
        DISABLED,
        START_REQUESTED,
        RUNNING,
        PAUSE_REQUESTED,
        PAUSED,
        QUIT_REQUESTED,
        STOPPED,
    };
} //namespace OpenEmuThreadCore

void NativeSetThreadState(OpenEmuCoreThread::EmuThreadState threadState);

@interface PPSSPPGameCore () <OEPSPSystemResponderClient, OEAudioBuffer>
{
    CoreParameter _coreParam;
    bool _isInitialized;
    bool _shouldReset;
	
	//Hack for analog stick.
	float x;
	float y;

   OpenEmuGLContext *OEgraphicsContext;

    // Cheats: OpenEmu hands us CwCheat codes one at a time; we buffer their enabled state and
    // flush them to PPSSPP's per-game <DISC_ID>.ini once the disc has booted (see -executeFrame).
    NSMutableDictionary<NSString *, NSNumber *> *_cheats;
    BOOL _cheatsDirty;
}
@end

PPSSPPGameCore *_current = 0;

@implementation PPSSPPGameCore


- (instancetype)init
{
    (self = [super init]);
    
    _current = self;
    
    return self;
}
# pragma mark - Execution

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    NSURL *romURL = [NSURL fileURLWithPath:path];
    _cheats = [NSMutableDictionary dictionary];
    _cheatsDirty = NO;
    NSURL *resourceURL = self.owner.bundle.resourceURL;
    NSURL *supportDirectoryURL = [NSURL fileURLWithPath:self.supportDirectoryPath isDirectory:YES];

    // Copy PSP firmware font files from the plugin bundle into the support directory.
    // Remove before copying so stale files from older installs don't linger.
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSURL *fontSourceDirectory = [resourceURL URLByAppendingPathComponent:@"flash0/font" isDirectory:YES];
    NSURL *fontDestinationDirectory = [supportDirectoryURL URLByAppendingPathComponent:@"font" isDirectory:YES];
    NSArray *fontFiles = [fileManager contentsOfDirectoryAtURL:fontSourceDirectory includingPropertiesForKeys:@[NSURLNameKey] options:0 error:nil];
    [fileManager createDirectoryAtURL:fontDestinationDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    for(NSURL *fontURL in fontFiles)
    {
        NSURL *destinationFontURL = [fontDestinationDirectory URLByAppendingPathComponent:fontURL.lastPathComponent];
        [fileManager removeItemAtURL:destinationFontURL error:nil];
        [fileManager copyItemAtURL:fontURL toURL:destinationFontURL error:nil];
    }

    g_Config.bEnableLogging = true;
    g_Config.iFastForwardMode = (int)FastForwardMode::CONTINUOUS;
    g_Config.bMemStickInserted = true;
    g_Config.iGlobalVolume = VOLUME_FULL - 1;
    g_Config.iAltSpeedVolume = -1;
    g_Config.bEnableSound = true;
    g_Config.iCwCheatRefreshRate = 60;
    g_Config.iMemStickSizeGB = 16;

    g_Config.iFirmwareVersion = PSP_DEFAULT_FIRMWARE;
    g_Config.iPSPModel = PSP_MODEL_SLIM;

    LogManager::Init(&g_Config.bEnableLogging);

    g_Config.Load("");

    if (!LogManager::GetInstance()) {
        LogManager::Init(&g_Config.bEnableLogging);
    }

    g_Config.SetSearchPath(GetSysDirectory(DIRECTORY_SYSTEM));
    g_Config.Load();

    // Re-apply path and backend settings after Load() so a stale user config
    // (e.g. from a previous Rosetta-era install) cannot override them.
    // Paths must point at OpenEmu's support directory; iGPUBackend must stay
    // OPENGL because this build has no Metal/Vulkan path.
    NSString *directoryString      = [supportDirectoryURL.path stringByAppendingString:@"/"];
    g_Config.currentDirectory      = Path(directoryString.fileSystemRepresentation);
    g_Config.defaultCurrentDirectory = Path(directoryString.fileSystemRepresentation);
    g_Config.memStickDirectory     = Path(directoryString.fileSystemRepresentation);
    g_Config.flash0Directory       = Path(directoryString.fileSystemRepresentation);
    g_Config.internalDataDirectory = Path(directoryString.fileSystemRepresentation);
    g_Config.appCacheDirectory     = Path([directoryString stringByAppendingString:@"/cache/"].fileSystemRepresentation);
    g_Config.iGPUBackend           = (int)GPUBackend::OPENGL;
    g_Config.bHideStateWarnings    = false;
    g_Config.iLanguage             = PSP_SYSTEMPARAM_LANGUAGE_ENGLISH;

    // Cheats are controlled entirely by -setCheat:setType:setEnabled:; force-disable here (after
    // the config Load above) so a stale saved config can't auto-start the CwCheat engine with a
    // disc ID that isn't known yet.
    g_Config.bEnableCheats         = false;
    
    _coreParam.cpuCore      = CPUCore::JIT;
    _coreParam.gpuCore      = GPUCORE_GLES;
    _coreParam.enableSound  = true;
    _coreParam.fileToStart  = Path(romURL.fileSystemRepresentation);
    _coreParam.mountIso     = Path();
    _coreParam.startBreak  = false;
    _coreParam.printfEmuLog = false;
    _coreParam.headLess     = false;

    _coreParam.renderWidth  = 480;
    _coreParam.renderHeight = 272;
    _coreParam.pixelWidth   = 480;
    _coreParam.pixelHeight  = 272;

    coreState = CORE_POWERUP;
    
    
    return true;
}

- (void)stopEmulation
{
    NativeSetThreadState(OpenEmuCoreThread::EmuThreadState::PAUSE_REQUESTED);

    PSP_Shutdown();

    NativeShutdownGraphics();
    NativeShutdown();

    [super stopEmulation];
}

- (void)resetEmulation
{
    _shouldReset = YES;
}

- (void)executeFrame
{
    if(!_isInitialized)
    {
        // This is where PPSSPP will look for ppge_atlas.zim, requires trailing forward slash
        NSString *resourcePath = [self.owner.bundle.resourcePath stringByAppendingString:@"/"];

        OEgraphicsContext = OpenEmuGLContext::CreateGraphicsContext();
        
        NativeInit(0, nil, nil, resourcePath.fileSystemRepresentation, nil);

        OEgraphicsContext->InitFromRenderThread(nullptr);
        
        _coreParam.graphicsContext = OEgraphicsContext;
       
        NativeInitGraphics(OEgraphicsContext);
    }

    if(_shouldReset)
    {
        NativeSetThreadState(OpenEmuCoreThread::EmuThreadState::PAUSE_REQUESTED);
        PSP_Shutdown();
    }

    if(!_isInitialized || _shouldReset)
    {
        _isInitialized = YES;
        _shouldReset = NO;

        std::string error_string;
        if(!PSP_Init(_coreParam, &error_string)) {
            NSLog(@"[PPSSPP] PSP_Init failed: %s", error_string.c_str());
            // Shut down cleanly so OpenEmu surfaces "core quit unexpectedly"
            // rather than crashing via null gpu pointer below.
            [self performSelectorOnMainThread:@selector(stopEmulation) withObject:nil waitUntilDone:NO];
            return;
        }

        host->BootDone();
		host->UpdateDisassembly();

        if (PSP_CoreParameter().compat.flags().RequireBufferedRendering && g_Config.bSkipBufferEffects) {
            g_Config.bSkipBufferEffects = false;
        }

        if (PSP_CoreParameter().compat.flags().RequireBlockTransfer && g_Config.bSkipGPUReadbacks) {
            g_Config.bSkipGPUReadbacks = false;
        }

        if (PSP_CoreParameter().compat.flags().RequireDefaultCPUClock && g_Config.iLockedCPUSpeed != 0) {
            g_Config.iLockedCPUSpeed = 0;
        }

        gpu->NotifyConfigChanged();

        //Start the Emulator Thread
        NativeSetThreadState(OpenEmuCoreThread::EmuThreadState::START_REQUESTED);
        
    } else {
        //If Fast forward rate is detected, unthrottle the rndering
        PSP_CoreParameter().fastForward = (self.rate > 1) ? true : false;

        // Flush any pending cheats now that the disc (and its DISC_ID) is available.
        [self writePendingCheats];

        //Let PPSSPP Core run a loop and return
        UpdateRunLoop();
    }
}
# pragma mark - Cheats

- (void)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled
{
    NSString *key = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (key.length == 0)
        return;

    if (_cheats == nil)
        _cheats = [NSMutableDictionary dictionary];

    _cheats[key] = @(enabled);
    _cheatsDirty = YES;
}

// Rebuilds a stored code into the one-pair-per-line form PPSSPP's parser needs: each _L/_M tag
// followed by exactly two hex words on its own line. A single stored code may hold several pairs
// (multi-line codes), even all on one line if the user pasted it that way.
- (NSString *)cheatLinesForCode:(NSString *)code
{
    NSArray<NSString *> *rawTokens = [code componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *token in rawTokens) {
        if (token.length > 0)
            [tokens addObject:token];
    }

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSUInteger i = 0;
    while (i < tokens.count) {
        NSString *tag = tokens[i].uppercaseString;
        if (([tag isEqualToString:@"_L"] || [tag isEqualToString:@"_M"]) && i + 2 < tokens.count) {
            [lines addObject:[NSString stringWithFormat:@"%@ %@ %@", tag, tokens[i + 1], tokens[i + 2]]];
            i += 3;
        } else {
            i += 1;
        }
    }

    return [lines componentsJoinedByString:@"\n"];
}

// Writes every enabled cheat into PPSSPP's per-game <DISC_ID>.ini and asks the running engine to
// reload. The CwCheat engine keys that file on the disc's DISC_ID, which only exists once the game
// has booted far enough to read PARAM.SFO — until then we keep the codes buffered and retry.
- (void)writePendingCheats
{
    if (!_cheatsDirty)
        return;

    std::string discID = g_paramSFO.GetValueString("DISC_ID");
    if (discID.empty())
        return;

    Path cheatDir = GetSysDirectory(DIRECTORY_CHEATS);
    NSString *cheatDirPath = [NSString stringWithUTF8String:cheatDir.c_str()];
    [[NSFileManager defaultManager] createDirectoryAtPath:cheatDirPath withIntermediateDirectories:YES attributes:nil error:nil];

    Path cheatFile = cheatDir / (discID + ".ini");
    NSString *cheatFilePath = [NSString stringWithUTF8String:cheatFile.c_str()];

    NSMutableString *contents = [NSMutableString string];
    [contents appendFormat:@"_S %s\n", discID.c_str()];
    [contents appendString:@"_G OpenEmu\n"];

    NSUInteger enabledCount = 0;
    for (NSString *code in _cheats) {
        if (![_cheats[code] boolValue])
            continue;
        NSString *lines = [self cheatLinesForCode:code];
        if (lines.length == 0)
            continue;
        enabledCount += 1;
        [contents appendFormat:@"_C1 Cheat %lu\n", (unsigned long)enabledCount];
        [contents appendString:lines];
        [contents appendString:@"\n"];
    }

    [contents writeToFile:cheatFilePath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // Toggling bEnableCheats to match the enabled count lets hleCheat start the engine (now that
    // the disc ID is valid) or stop it when nothing is enabled; bReloadCheats forces a re-parse.
    g_Config.bEnableCheats = (enabledCount > 0);
    g_Config.bReloadCheats = true;
    _cheatsDirty = NO;
}

- (NSArray<OEMemoryRegionDescriptor *> *)readableMemoryRegions
{
    if (!_isInitialized)
        return @[];

    // Expose only user RAM (0x08800000 .. kernel base + g_MemorySize). Results below the user base
    // (kernel/volatile RAM) can't be expressed as a CwCheat write, so there's no point searching them.
    const uint32_t base = PSP_GetUserMemoryBase();
    const uint32_t end  = PSP_GetUserMemoryEnd();
    if (end <= base)
        return @[];

    const uint32_t size = end - base;
    const uint8_t *ptr = Memory::GetPointerRange(base, size);
    if (ptr == nullptr)
        return @[];

    NSData *data = [NSData dataWithBytes:ptr length:size];
    OEMemoryRegionDescriptor *descriptor = [OEMemoryRegionDescriptor descriptorWithName:@"User RAM"
                                                                                address:base
                                                                           addressBytes:4
                                                                                   data:data];
    return @[descriptor];
}

# pragma mark - Video

- (OEGameCoreRendering)gameCoreRendering
{
    return OEGameCoreRenderingOpenGL3Video;
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(480, 272);
}

- (OEIntSize)aspectSize
{
    return OEIntSizeMake(16, 9);
}

- (NSTimeInterval)frameInterval
{
    return 59.94;
}

# pragma mark - Audio

- (NSUInteger)channelCount
{
    return AUDIO_CHANNELS;
}

- (double)audioSampleRate
{
    return AUDIO_FREQ;
}

- (id<OEAudioBuffer>)audioBufferAtIndex:(NSUInteger)index
{
    return self;
}

- (NSUInteger)read:(void *)buffer maxLength:(NSUInteger)len
{
    NativeMix((short *)buffer, (int)(len / (AUDIO_CHANNELS * sizeof(uint16_t))));
    return len;
}

- (NSUInteger)write:(const void *)buffer maxLength:(NSUInteger)length
{
    return 0;
}

- (NSUInteger)length
{
    return AUDIO_FREQ / 15;
}

# pragma mark - Save States

static void _OESaveStateCallback(SaveState::Status status, std::string message, void *cbUserData)
{
    void (^block)(BOOL, NSError *) = (__bridge_transfer void(^)(BOOL, NSError *))cbUserData;

    [_current endPausedExecution];
    
    block((status != SaveState::Status::FAILURE), nil);
}

static void _OELoadStateCallback(SaveState::Status status, std::string message, void *cbUserData)
{
    void (^block)(BOOL, NSError *) = (__bridge_transfer void(^)(BOOL, NSError *))cbUserData;

    //Unpause the EmuThread by requesting it to start again
    NativeSetThreadState(OpenEmuCoreThread::EmuThreadState::START_REQUESTED);
    NSError *error = nil;
        
    if(status == SaveState::Status::WARNING) {
        error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadStateError userInfo:@{
            NSLocalizedDescriptionKey : NSLocalizedString(@"PPSSPP Save State Warning", @"PPSSPP Save State Warning description."),
            NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:NSLocalizedString(@"This save state was created from a previous version of PPSSPP, or simulates over 4 hours of time played.\n\nSave states preserve bugs from old PPSSPP versions and states from long sessions can also expose bugs rarely seen on a real PSP.\n\nIt is recommended to \"clean load\" for less bugs:\n\n1. Save in-game (memory stick, not save state), then stop emulation.\n2. Go to OpenEmu > Preferences > Library, click \"Reset warnings\".\n3. Reopen your game and click \"No\" when prompted to \"Continue where you left off\".", @"PPSSPP Save State Warning.")]
        }];
    } else if(status == SaveState::Status::FAILURE) {
        error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadStateError userInfo:@{
            NSLocalizedDescriptionKey : NSLocalizedString(@"The Save State failed to Load", @"PPSSPP Save State Failure description."),
            NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:NSLocalizedString(@"Could not load Save State.", @"PPSSPP Save State Failure.")]
        }];
    }
    
    block((status == SaveState::Status::SUCCESS), error);
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    [self beginPausedExecution];
    SaveState::Save(Path(fileName.fileSystemRepresentation),0, _OESaveStateCallback, (__bridge_retained void *)[block copy]);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    SaveState::Load(Path(fileName.fileSystemRepresentation), 0,_OELoadStateCallback, (__bridge_retained void *)[block copy]);
    if(_isInitialized){
        //We need to pause our EmuThread so we don't try to process the save state in the middle of a Frame Render
        NativeSetThreadState(OpenEmuCoreThread::EmuThreadState::PAUSE_REQUESTED);

        SaveState::Process();
    }
}

# pragma mark - Input

const int buttonMap[] = { CTRL_UP, CTRL_DOWN, CTRL_LEFT, CTRL_RIGHT, 0, 0, 0, 0, CTRL_TRIANGLE, CTRL_CIRCLE, CTRL_CROSS, CTRL_SQUARE, CTRL_LTRIGGER, CTRL_RTRIGGER, CTRL_START, CTRL_SELECT };

- (oneway void)didMovePSPJoystickDirection:(OEPSPButton)button withValue:(CGFloat)value forPlayer:(NSUInteger)player
{
    if(button == OEPSPAnalogUp || button == OEPSPAnalogDown)
        y = (button == OEPSPAnalogUp ? value : -value);
    else
        x = (button == OEPSPAnalogRight ? value : -value);
	__CtrlSetAnalogXY(0, x, y);
}

- (oneway void)didPushPSPButton:(OEPSPButton)button forPlayer:(NSUInteger)player
{
    __CtrlButtonDown(buttonMap[button]);
}

- (oneway void)didReleasePSPButton:(OEPSPButton)button forPlayer:(NSUInteger)player
{
    __CtrlButtonUp(buttonMap[button]);
}

@end
