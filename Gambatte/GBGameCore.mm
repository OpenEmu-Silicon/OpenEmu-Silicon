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

#import "GBGameCore.h"
#import <OpenEmuBase/OERingBuffer.h>
#import <OpenEmuBase/OEMemoryRegionDescriptor.h>
#import "OEGBSystemResponderClient.h"
#import <OpenGL/gl.h>

#include <sstream>
#include "gambatte.h"
#include "gbcpalettes.h"
#include "resamplerinfo.h"
#include "resampler.h"

#include <os/log.h>
#define RC_CLIENT_SUPPORTS_HASH 1
#include <rc_client.h>
#include <rc_consoles.h>
#import "OERetroAchievementsTransport.h"
#import "OERetroAchievementsBridge.h"

#define OptionDefault(_NAME_, _PREFKEY_) @{ OEGameCoreDisplayModeNameKey : _NAME_, OEGameCoreDisplayModePrefKeyNameKey : _PREFKEY_, OEGameCoreDisplayModeStateKey : @YES, }
#define Option(_NAME_, _PREFKEY_) @{ OEGameCoreDisplayModeNameKey : _NAME_, OEGameCoreDisplayModePrefKeyNameKey : _PREFKEY_, OEGameCoreDisplayModeStateKey : @NO, }
#define OptionIndented(_NAME_, _PREFKEY_) @{ OEGameCoreDisplayModeNameKey : _NAME_, OEGameCoreDisplayModePrefKeyNameKey : _PREFKEY_, OEGameCoreDisplayModeStateKey : @NO, OEGameCoreDisplayModeIndentationLevelKey : @(1), }
#define OptionToggleable(_NAME_, _PREFKEY_) @{ OEGameCoreDisplayModeNameKey : _NAME_, OEGameCoreDisplayModePrefKeyNameKey : _PREFKEY_, OEGameCoreDisplayModeStateKey : @NO, OEGameCoreDisplayModeAllowsToggleKey : @YES, }
#define OptionToggleableNoSave(_NAME_, _PREFKEY_) @{ OEGameCoreDisplayModeNameKey : _NAME_, OEGameCoreDisplayModePrefKeyNameKey : _PREFKEY_, OEGameCoreDisplayModeStateKey : @NO, OEGameCoreDisplayModeAllowsToggleKey : @YES, OEGameCoreDisplayModeDisallowPrefSaveKey : @YES, }
#define Label(_NAME_) @{ OEGameCoreDisplayModeLabelKey : _NAME_, }
#define SeparatorItem() @{ OEGameCoreDisplayModeSeparatorItemKey : @"",}

gambatte::GB gb;
Resampler *resampler;
uint32_t pad[OEGBButtonCount];

class GetInput : public gambatte::InputGetter
{
public:
    unsigned operator()()
    {
        return pad[0];
    }
} static GetInput;

@interface GBGameCore () <OEGBSystemResponderClient>
{
    uint32_t *_videoBuffer;
    uint32_t *_inSoundBuffer;
    int16_t *_outSoundBuffer;
    double _sampleRate;
    NSMutableDictionary <NSString *, NSNumber *> *_cheatList;
    NSMutableArray <NSMutableDictionary <NSString *, id> *> *_availableDisplayModes;
    OERetroAchievementsBridge *_raBridge;
    NSString *_romPath;
    int _rcConsole;
}

- (void)applyCheat:(NSString *)code;

- (void)loadDisplayModeOptions;
- (NSString *)gameInternalName;
- (BOOL)gameHasInternalPalette;
- (void)loadPalette;
- (void)loadPaletteDefault;
- (void)changePalette:(NSString *)palette;
@end

// rcheevos memory callback.
//
// rcheevos GB/GBC address space (consoleinfo.c):
//   0x0000–0xFFFF → full 16-bit Game Boy bus
//
// Reads via gambatte::GB::busRead8() — wraps Memory::read(addr, 0).
//
static uint32_t gambatte_rc_read_memory(uint32_t address, uint8_t *buffer,
                                         uint32_t num_bytes, rc_client_t *client)
{
    for (uint32_t i = 0; i < num_bytes; i++) {
        uint32_t addr = address + i;
        if (addr <= 0xFFFF)
            buffer[i] = gb.busRead8((uint16_t)addr);
        else
            return i;
    }
    return num_bytes;
}

@implementation GBGameCore

- (id)init
{
    if((self = [super init]))
    {
        _inSoundBuffer = (uint32_t *)malloc(2064 * 2 * 4);
        _outSoundBuffer = (int16_t *)malloc(2064 * 2 * 2);
        _cheatList = [NSMutableDictionary dictionary];
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
    free(_videoBuffer);
    free(_inSoundBuffer);
    free(_outSoundBuffer);
}

# pragma mark - Execution

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    memset(pad, 0, sizeof(pad));

    if (!_videoBuffer)
        _videoBuffer = (uint32_t *)malloc(160 * 144 * 4);

    // Set battery save dir
    NSURL *batterySavesDirectory = [NSURL fileURLWithPath:self.batterySavesDirectoryPath];
    [[NSFileManager defaultManager] createDirectoryAtURL:batterySavesDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    gb.setSaveDir(batterySavesDirectory.fileSystemRepresentation);

    // Set input state callback
    gb.setInputGetter(&GetInput);

    // Setup resampler
    double fps = 4194304.0 / 70224.0;
    double inSampleRate = fps * 35112; // 2097152

    // 2 = "Very high quality (polyphase FIR)", see resamplerinfo.cpp
    resampler = ResamplerInfo::get(2).create(inSampleRate, 48000.0, 2 * 2064);

    unsigned long mul, div;
    resampler->exactRatio(mul, div);

    double outSampleRate = inSampleRate * mul / div;
    _sampleRate = outSampleRate; // 47994.326636

    if (gb.load(path.fileSystemRepresentation) != 0)
        return NO;

    [self loadDisplayModeOptions];

    _romPath = path;
    _rcConsole = gb.isCgb() ? RC_CONSOLE_GAMEBOY_COLOR : RC_CONSOLE_GAMEBOY;

    _raBridge = [[OERetroAchievementsBridge alloc] initWithGameCore:self
                                                        memoryReader:gambatte_rc_read_memory
                                                           consoleID:(uint32_t)_rcConsole];
    [_raBridge startWithROMPath:path];
    [_raBridge markROMReady];

    return YES;
}

- (void)executeFrame
{
    size_t samples = 2064;

    while (gb.runFor(_videoBuffer, 160, _inSoundBuffer, samples) == -1) {
        [self outputAudio:samples];
        samples = 2064;
    }

    [_raBridge doFrame];

    [self outputAudio:samples];
}

- (void)resetEmulation
{
    [_raBridge reset];
    gb.reset();
}

- (void)stopEmulation
{
    [_raBridge shutdown];
    _raBridge = nil;

    gb.saveSavedata();

    delete resampler;

    [super stopEmulation];
}

- (NSTimeInterval)frameInterval
{
    return 59.727501;
}

# pragma mark - Video

- (const void *)getVideoBufferWithHint:(void *)hint
{
    if (!hint) {
        if (!_videoBuffer) _videoBuffer = (uint32_t *)malloc(160 * 144 * 4);
        hint = _videoBuffer;
    }
    return _videoBuffer = (uint32_t*)hint;
}

- (OEIntRect)screenRect
{
    return OEIntRectMake(0, 0, 160, 144);
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(160, 144);
}

- (OEIntSize)aspectSize
{
    return OEIntSizeMake(10, 9);
}

- (GLenum)pixelFormat
{
    return GL_BGRA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_INT_8_8_8_8_REV;
}

# pragma mark - Audio

- (double)audioSampleRate
{
    return _sampleRate;
}

- (NSUInteger)channelCount
{
    return 2;
}

# pragma mark - Save States

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    int success = gb.saveState(0, 0, fileName.fileSystemRepresentation);
    if(block) block(success==1, nil);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    int success = gb.loadState(fileName.fileSystemRepresentation);
    // Notify the rcheevos client that emulator state has been externally replaced.
    // Without this, the RA library keeps evaluating achievement conditions against
    // stale pre-load state. Matches the reset already present in deserializeState:.
    if (success == 1)
        [_raBridge reset];
    if(block) block(success==1, nil);
}

- (NSData *)serializeStateWithError:(NSError **)outError
{
    std::stringstream stream(std::ios::in|std::ios::out|std::ios::binary);

    if(gb.serializeState(stream)) {
        stream.seekg(0, std::ios::end);
        NSUInteger length = stream.tellg();
        stream.seekg(0, std::ios::beg);

        char *bytes = (char *)malloc(length);
        stream.read(bytes, length);

        return [NSData dataWithBytesNoCopy:bytes length:length];
    }

    if(outError) {
        *outError = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotSaveStateError userInfo:@{
            NSLocalizedDescriptionKey : @"Save state data could not be written",
            NSLocalizedRecoverySuggestionErrorKey : @"The emulator could not write the state data."
        }];
    }

    return nil;
}

- (BOOL)deserializeState:(NSData *)state withError:(NSError **)outError
{
    std::stringstream stream(std::ios::in|std::ios::out|std::ios::binary);

    char const *bytes = (char const *)(state.bytes);
    std::streamsize size = state.length;
    stream.write(bytes, size);

    if(gb.deserializeState(stream)) {
        [_raBridge reset];
        return YES;
    }

    if(outError) {
        *outError = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadStateError userInfo:@{
            NSLocalizedDescriptionKey : @"The save state data could not be read",
            NSLocalizedRecoverySuggestionErrorKey : @"Could not load data from the save state"
        }];
    }
    return NO;
}

# pragma mark - Input

const int GBMap[] = {gambatte::InputGetter::UP, gambatte::InputGetter::DOWN, gambatte::InputGetter::LEFT, gambatte::InputGetter::RIGHT, gambatte::InputGetter::A, gambatte::InputGetter::B, gambatte::InputGetter::START, gambatte::InputGetter::SELECT};
- (oneway void)didPushGBButton:(OEGBButton)button;
{
    pad[0] |= GBMap[button];
}

- (oneway void)didReleaseGBButton:(OEGBButton)button;
{
    pad[0] &= ~GBMap[button];
}

#pragma mark - Cheats

- (void)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled
{
    // Sanitize
    code = [code stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];

    // Gambatte expects cheats UPPERCASE
    code = code.uppercaseString;

    // Remove any spaces
    code = [code stringByReplacingOccurrencesOfString:@" " withString:@""];

    if (enabled)
        _cheatList[code] = @YES;
    else
        [_cheatList removeObjectForKey:code];

    NSMutableArray <NSString *> *combinedGameSharkCodes = [NSMutableArray array];
    NSMutableArray <NSString *> *combinedGameGenieCodes = [NSMutableArray array];

    // Gambatte expects all cheats in one combined string per-type e.g. 01xxxxxx+01xxxxxx
    // Add enabled per-type cheats to arrays and later join them all by a '+' separator
    for (NSString *key in _cheatList)
    {
        if ([_cheatList[key] boolValue])
        {
            // GameShark
            if (![key containsString:@"-"])
                [combinedGameSharkCodes addObject:key];
            // Game Genie
            else if ([key containsString:@"-"])
                [combinedGameGenieCodes addObject:key];
        }
    }

    // Apply combined cheats or force a final reset if all cheats are disabled
    [self applyCheat:combinedGameSharkCodes.count != 0 ? [combinedGameSharkCodes componentsJoinedByString:@"+"] : @"0"];
    [self applyCheat:combinedGameGenieCodes.count != 0 ? [combinedGameGenieCodes componentsJoinedByString:@"+"] : @"0-"];
}

# pragma mark - Display Mode

- (NSArray <NSDictionary <NSString *, id> *> *)displayModes
{
    if (_availableDisplayModes.count == 0)
    {
        _availableDisplayModes = [NSMutableArray array];

        NSArray <NSDictionary <NSString *, id> *> *availableModesWithDefault;

        if (gb.isCgb())
        {
            availableModesWithDefault =
            @[
                Label(@"Color Correction"),
                OptionDefault(@"Default", @"colorCorrection"),
                Option(@"Modern", @"colorCorrection"),
            ];
        }
        else
        {
            availableModesWithDefault =
            @[
                Option(@"Internal", @"palette"),
                Option(@"Grayscale", @"palette"),
                Option(@"Greenscale", @"palette"),
                Option(@"Pocket", @"palette"),
                SeparatorItem(),
                Label(@"GBC Palettes"),
                Option(@"Blue", @"palette"),
                Option(@"Dark Blue", @"palette"),
                Option(@"Green", @"palette"),
                Option(@"Dark Green", @"palette"),
                Option(@"Brown", @"palette"),
                Option(@"Dark Brown", @"palette"),
                Option(@"Red", @"palette"),
                Option(@"Yellow", @"palette"),
                Option(@"Orange", @"palette"),
                Option(@"Pastel Mix", @"palette"),
                Option(@"Inverted", @"palette"),
            ];
        }

        // Deep mutable copy
        _availableDisplayModes = (NSMutableArray *)CFBridgingRelease(CFPropertyListCreateDeepCopy(kCFAllocatorDefault, (CFArrayRef)availableModesWithDefault, kCFPropertyListMutableContainers));

        if (!gb.isCgb() && ![self gameHasInternalPalette])
            [_availableDisplayModes removeObjectAtIndex:0];
    }

    return [_availableDisplayModes copy];
}

- (void)changeDisplayWithMode:(NSString *)displayMode
{
    // NOTE: This is a more complex implementation to serve as an example for handling submenus,
    // toggleable options and multiple groups of mutually exclusive options.

    if (_availableDisplayModes.count == 0)
        [self displayModes];

    // First check if 'displayMode' is toggleable and grab its preference key
    BOOL isDisplayModeToggleable = NO;
    BOOL isValidDisplayMode = NO;
    BOOL displayModeState = NO;
    NSString *displayModePrefKey;

    for (NSDictionary *modeDict in _availableDisplayModes)
    {
        if ([modeDict[OEGameCoreDisplayModeNameKey] isEqualToString:displayMode])
        {
            displayModeState = [modeDict[OEGameCoreDisplayModeStateKey] boolValue];
            displayModePrefKey = modeDict[OEGameCoreDisplayModePrefKeyNameKey];
            isDisplayModeToggleable = [modeDict[OEGameCoreDisplayModeAllowsToggleKey] boolValue];
            isValidDisplayMode = YES;
            break;
        }
        // Submenu Items
        for (NSDictionary *subModeDict in modeDict[OEGameCoreDisplayModeGroupItemsKey])
        {
            if ([subModeDict[OEGameCoreDisplayModeNameKey] isEqualToString:displayMode])
            {
                displayModeState = [subModeDict[OEGameCoreDisplayModeStateKey] boolValue];
                displayModePrefKey = subModeDict[OEGameCoreDisplayModePrefKeyNameKey];
                isDisplayModeToggleable = [subModeDict[OEGameCoreDisplayModeAllowsToggleKey] boolValue];
                isValidDisplayMode = YES;
                break;
            }
        }
    }

    // Disallow a 'displayMode' not found in _availableDisplayModes
    if (!isValidDisplayMode)
        return;

    // Handle option state changes
    for (NSMutableDictionary *optionDict in _availableDisplayModes)
    {
        NSString *modeName = optionDict[OEGameCoreDisplayModeNameKey];
        NSString *prefKey  = optionDict[OEGameCoreDisplayModePrefKeyNameKey];

        if (!modeName && !optionDict[OEGameCoreDisplayModeGroupNameKey])
            continue;
        // Mutually exclusive option state change
        else if ([modeName isEqualToString:displayMode] && !isDisplayModeToggleable)
            optionDict[OEGameCoreDisplayModeStateKey] = @YES;
        // Reset mutually exclusive options that are the same prefs group as 'displayMode'
        else if (!isDisplayModeToggleable && [prefKey isEqualToString:displayModePrefKey])
            optionDict[OEGameCoreDisplayModeStateKey] = @NO;
        // Toggleable option state change
        else if ([modeName isEqualToString:displayMode] && isDisplayModeToggleable)
            optionDict[OEGameCoreDisplayModeStateKey] = @(!displayModeState);
        // Submenu group
        else if (optionDict[OEGameCoreDisplayModeGroupNameKey])
        {
            // Submenu items
            for (NSMutableDictionary *subOptionDict in optionDict[OEGameCoreDisplayModeGroupItemsKey])
            {
                NSString *modeName = subOptionDict[OEGameCoreDisplayModeNameKey];
                NSString *prefKey  = subOptionDict[OEGameCoreDisplayModePrefKeyNameKey];

                if (!modeName)
                    continue;
                // Mutually exclusive option state change
                else if ([modeName isEqualToString:displayMode] && !isDisplayModeToggleable)
                    subOptionDict[OEGameCoreDisplayModeStateKey] = @YES;
                // Reset mutually exclusive options that are the same prefs group as 'displayMode'
                else if (!isDisplayModeToggleable && [prefKey isEqualToString:displayModePrefKey])
                    subOptionDict[OEGameCoreDisplayModeStateKey] = @NO;
                // Toggleable option state change
                else if ([modeName isEqualToString:displayMode] && isDisplayModeToggleable)
                    subOptionDict[OEGameCoreDisplayModeStateKey] = @(!displayModeState);
            }

            continue;
        }
    }

    // Set the new palette
    if ([displayModePrefKey isEqualToString:@"palette"])
        [self changePalette:displayMode];
    else if ([displayModePrefKey isEqualToString:@"colorCorrection"])
        gb.setCgbColorCorrection([displayMode isEqual:@"Modern"] ? 1 : 0);
}

# pragma mark - Misc Helper Methods

- (void)outputAudio:(size_t)frames
{
    if (!frames)
        return;

    size_t len = resampler->resample(_outSoundBuffer, reinterpret_cast<const int16_t *>(_inSoundBuffer), frames);

    if (len)
        [[self audioBufferAtIndex:0] write:_outSoundBuffer maxLength:len << 2];
}

- (void)applyCheat:(NSString *)code
{
    std::string s = [code UTF8String];
    if (s.find("-") != std::string::npos)
        gb.setGameGenie(s);
    else
        gb.setGameShark(s);
}

- (void)loadDisplayModeOptions
{
    if (gb.isCgb())
    {
        // Restore color correction
        NSString *lastColorCorrection = self.displayModeInfo[@"colorCorrection"] ?: @"Default";
        [self changeDisplayWithMode:lastColorCorrection];
    }
    else
    {
        // Load built-in GBC palette for monochrome games if supported
        [self loadPalette];
    }
}

- (NSString *)gameInternalName
{
    NSString *title = [NSString stringWithUTF8String:gb.romTitle().c_str()];
    return title;
}

- (BOOL)gameHasInternalPalette
{
    unsigned short *gbc_bios_palette = NULL;
    NSString *title = [self gameInternalName];
    gbc_bios_palette = const_cast<unsigned short *>(findGbcTitlePal(title.UTF8String));

    return gbc_bios_palette != 0 ? YES : NO;
}

- (void)loadPalette
{
    // Only temporary, so core doesn't crash on an older OpenEmu version
    if (![self respondsToSelector:@selector(displayModeInfo)])
    {
        [self loadPaletteDefault];
    }
    // No previous palette saved, set a default
    else if (self.displayModeInfo[@"palette"] == nil)
    {
        [self loadPaletteDefault];
    }
    else
    {
        NSString *lastPalette = self.displayModeInfo[@"palette"];
        // Don't try to load "Internal" palette for a game without one
        if ([lastPalette isEqualToString:@"Internal"] && ![self gameHasInternalPalette])
            [self changeDisplayWithMode:@"Grayscale"];
        else
            [self changeDisplayWithMode:lastPalette];
    }
}

- (void)loadPaletteDefault
{
    if ([self gameHasInternalPalette])
        // load a GBC BIOS builtin palette
        [self changeDisplayWithMode:@"Internal"];
    else
        // no custom palette found, load the default (Original Grayscale)
        [self changeDisplayWithMode:@"Grayscale"];
}

- (void)changePalette:(NSString *)palette
{
    NSDictionary <NSString *, NSString *> *paletteNames =
    @{
      @"Internal"   : @"Internal",
      @"Grayscale"  : @"GBC - Grayscale",
      @"Greenscale" : @"Greenscale",
      @"Pocket"     : @"Pocket",
      @"Blue"       : @"GBC - Blue",
      @"Dark Blue"  : @"GBC - Dark Blue",
      @"Green"      : @"GBC - Green",
      @"Dark Green" : @"GBC - Dark Green",
      @"Brown"      : @"GBC - Brown",
      @"Dark Brown" : @"GBC - Dark Brown",
      @"Red"        : @"GBC - Red",
      @"Yellow"     : @"GBC - Yellow",
      @"Orange"     : @"GBC - Orange",
      @"Pastel Mix" : @"GBC - Pastel Mix",
      @"Inverted"   : @"GBC - Inverted",
      };

    palette = paletteNames[palette];
    unsigned short *gbc_bios_palette = NULL;

    if ([palette isEqualToString:@"Internal"])
    {
        NSString *title = [self gameInternalName];
        gbc_bios_palette = const_cast<unsigned short *>(findGbcTitlePal(title.UTF8String));
    }
    else if ([palette isEqualToString:@"Greenscale"])
    {
        // GB Pea Soup Green
        gb.setDmgPaletteColor(0, 0, 8369468);
        gb.setDmgPaletteColor(0, 1, 6728764);
        gb.setDmgPaletteColor(0, 2, 3629872);
        gb.setDmgPaletteColor(0, 3, 3223857);
        gb.setDmgPaletteColor(1, 0, 8369468);
        gb.setDmgPaletteColor(1, 1, 6728764);
        gb.setDmgPaletteColor(1, 2, 3629872);
        gb.setDmgPaletteColor(1, 3, 3223857);
        gb.setDmgPaletteColor(2, 0, 8369468);
        gb.setDmgPaletteColor(2, 1, 6728764);
        gb.setDmgPaletteColor(2, 2, 3629872);
        gb.setDmgPaletteColor(2, 3, 3223857);
        return;
    }
    else if ([palette isEqualToString:@"Pocket"])
    {
        // GB Pocket
        gb.setDmgPaletteColor(0, 0, 13487791);
        gb.setDmgPaletteColor(0, 1, 10987158);
        gb.setDmgPaletteColor(0, 2, 6974033);
        gb.setDmgPaletteColor(0, 3, 2828823);
        gb.setDmgPaletteColor(1, 0, 13487791);
        gb.setDmgPaletteColor(1, 1, 10987158);
        gb.setDmgPaletteColor(1, 2, 6974033);
        gb.setDmgPaletteColor(1, 3, 2828823);
        gb.setDmgPaletteColor(2, 0, 13487791);
        gb.setDmgPaletteColor(2, 1, 10987158);
        gb.setDmgPaletteColor(2, 2, 6974033);
        gb.setDmgPaletteColor(2, 3, 2828823);

//        gb.setDmgPaletteColor(0, 0, 13029285);
//        gb.setDmgPaletteColor(0, 1, 9213547);
//        gb.setDmgPaletteColor(0, 2, 4870457);
//        gb.setDmgPaletteColor(0, 3, 1580056);
//        gb.setDmgPaletteColor(1, 0, 13029285);
//        gb.setDmgPaletteColor(1, 1, 9213547);
//        gb.setDmgPaletteColor(1, 2, 4870457);
//        gb.setDmgPaletteColor(1, 3, 1580056);
//        gb.setDmgPaletteColor(2, 0, 13029285);
//        gb.setDmgPaletteColor(2, 1, 9213547);
//        gb.setDmgPaletteColor(2, 2, 4870457);
//        gb.setDmgPaletteColor(2, 3, 1580056);
        return;
    }
    else
        gbc_bios_palette = const_cast<unsigned short *>(findGbcDirPal(palette.UTF8String));

    unsigned long rgb32 = 0;
    for (unsigned palnum = 0; palnum < 3; ++palnum)
    {
        for (unsigned colornum = 0; colornum < 4; ++colornum)
        {
            rgb32 = gbcToRgb32(gbc_bios_palette[palnum * 4 + colornum]);
            gb.setDmgPaletteColor(palnum, colornum, rgb32);
        }
    }
}

- (NSArray<OEMemoryRegionDescriptor *> *)readableMemoryRegions
{
    if (!gb.isLoaded()) return @[];
    const NSUInteger wramSize = 0x2000;
    NSMutableData *wramData = [NSMutableData dataWithLength:wramSize];
    uint8_t *bytes = (uint8_t *)wramData.mutableBytes;
    for (NSUInteger i = 0; i < wramSize; i++) {
        bytes[i] = gb.busRead8(0xC000 + i);
    }

    return @[
        [OEMemoryRegionDescriptor descriptorWithName:@"WRAM"
                                            address:0xC000
                                       addressBytes:2
                                               data:wramData]
    ];
}

#pragma mark - Live Memory

// Live memory areas for Archipelago clients. The names and layouts match what those
// clients expect from other Game Boy emulators:
//   ROM         the whole ROM image, writable (some games patch ROM at runtime)
//   WRAM        all work RAM banks in order, bank n at n * 0x1000 (0x2000 bytes on GB, 0x8000 on GBC)
//   CartRAM     all cartridge RAM banks in order
//   System Bus  the 16-bit Game Boy bus; writes only reach work RAM and enabled cartridge RAM

static NSString *const GBLiveMemorySystemBus = @"System Bus";
static const NSUInteger GBSystemBusSize = 0x10000;

/// Finds a plain memory area. Returns NO if the name is not one of them.
static BOOL GBLiveMemoryArea(NSString *area, unsigned char **data, size_t *size)
{
    gambatte::GB::MemoryArea which;
    if ([area isEqualToString:@"ROM"])
        which = gambatte::GB::MEMORY_ROM;
    else if ([area isEqualToString:@"WRAM"])
        which = gambatte::GB::MEMORY_WRAM;
    else if ([area isEqualToString:@"CartRAM"])
        which = gambatte::GB::MEMORY_CARTRAM;
    else
        return NO;

    std::size_t areaSize = 0;
    *data = gb.memoryArea(which, areaSize);
    *size = *data ? areaSize : 0;
    return YES;
}

- (NSString *)liveMemoryPlatform
{
    if (!gb.isLoaded()) return nil;
    return gb.isCgb() ? @"GBC" : @"GB";
}

- (NSArray<NSString *> *)liveMemoryAreaNames
{
    if (!gb.isLoaded()) return @[];
    return @[@"ROM", @"WRAM", @"CartRAM", GBLiveMemorySystemBus];
}

- (NSUInteger)sizeOfLiveMemoryArea:(NSString *)area
{
    if (!gb.isLoaded()) return 0;
    if ([area isEqualToString:GBLiveMemorySystemBus]) return GBSystemBusSize;

    unsigned char *data = NULL;
    size_t size = 0;
    return GBLiveMemoryArea(area, &data, &size) ? size : 0;
}

- (BOOL)readLiveMemoryArea:(NSString *)area offset:(uint64_t)offset length:(NSUInteger)length into:(uint8_t *)buffer
{
    if (!gb.isLoaded()) return NO;
    memset(buffer, 0, length);

    if ([area isEqualToString:GBLiveMemorySystemBus]) {
        for (NSUInteger i = 0; i < length && offset + i < GBSystemBusSize; i++)
            buffer[i] = gb.busRead8((uint16_t)(offset + i));
        return YES;
    }

    unsigned char *data = NULL;
    size_t size = 0;
    if (!GBLiveMemoryArea(area, &data, &size)) return NO;
    if (offset < size)
        memcpy(buffer, data + offset, MIN(length, size - offset));
    return YES;
}

- (BOOL)writeLiveMemoryArea:(NSString *)area offset:(uint64_t)offset bytes:(const uint8_t *)bytes length:(NSUInteger)length
{
    if (!gb.isLoaded()) return NO;

    if ([area isEqualToString:GBLiveMemorySystemBus]) {
        for (NSUInteger i = 0; i < length && offset + i < GBSystemBusSize; i++)
            gb.busWritePlain((uint16_t)(offset + i), bytes[i]);
        return YES;
    }

    unsigned char *data = NULL;
    size_t size = 0;
    if (!GBLiveMemoryArea(area, &data, &size)) return NO;
    if (offset < size)
        memcpy(data + offset, bytes, MIN(length, size - offset));
    return YES;
}

@end
