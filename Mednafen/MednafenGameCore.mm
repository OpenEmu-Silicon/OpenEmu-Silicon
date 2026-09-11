/*
 Copyright (c) 2020, OpenEmu Team


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

#include "mednafen.h"
#include "settings-driver.h"
#include "state-driver.h"
#include "mednafen-driver.h"
#include "MemoryStream.h"
#include "mednafen/psx/psx.h"
#include "mednafen/pce/pce.h"
#include "mednafen/mempatcher-driver.h"
#include "mednafen/ss/ss.h"

#import "MednafenGameCore.h"
#import <OpenEmuBase/OERingBuffer.h>
#import <OpenEmuBase/OEMemoryRegionDescriptor.h>
#import <OpenEmuBase/OEGameCoreDisplayModes.h>
#import <OpenGL/gl.h>
#import "OELynxSystemResponderClient.h"
#import "OENGPSystemResponderClient.h"
#import "OEPCESystemResponderClient.h"
#import "OEPCECDSystemResponderClient.h"
#import "OEPCFXSystemResponderClient.h"
#import "OEPSXSystemResponderClient.h"
#import "OESaturnSystemResponderClient.h"
#import "OEVBSystemResponderClient.h"
#import "OEWSSystemResponderClient.h"

#include <os/log.h>
#define RC_CLIENT_SUPPORTS_HASH 1
#include <rc_client.h>
#import "OERetroAchievementsBridge.h"
#include <rc_consoles.h>
#import "OERetroAchievementsTransport.h"

extern "C" uint8_t *MDFNLynx_GetRAMPointer(void);
extern "C" uint8_t *MDFNNGP_GetRAMPointer(void);
extern "C" uint8_t *MDFNPCE_GetCDRAMPointer(void);
extern "C" uint8_t *MDFNPCE_GetSysCardRAMPointer(void);
extern "C" uint8_t *MDFNPCE_GetSaveRAMPointer(void);
extern "C" uint8_t *MDFNPCE_GetMainRAMPointer(void);
extern "C" uint32_t MDFNPCE_GetMainRAMSize(void);
extern "C" uint8_t *MDFNPCFX_GetRAMPointer(void);
extern "C" uint8_t *MDFNPCFX_GetBackupRAMPointer(void);
extern "C" uint8_t *MDFNPCFX_GetExBackupRAMPointer(void);
extern "C" uint8_t *MDFNVB_GetWRAMPointer(void);
extern "C" uint8_t *MDFNVB_GetGPRAMPointer(void);
extern "C" uint32_t MDFNVB_GetGPRAMSize(void);
extern "C" uint8_t *MDFNWS_GetRAMPointer(void);
extern "C" uint32_t MDFNWS_GetRAMSize(void);
extern "C" uint8_t *MDFNWS_GetSRAMPointer(void);
extern "C" uint32_t MDFNWS_GetSRAMSize(void);
extern "C" uint8_t *MDFNWS_GetROMPointer(void);
extern "C" uint32_t MDFNWS_GetROMSize(void);

#ifdef DEBUG
    #error "Cores should not be compiled in DEBUG! Follow the guide https://github.com/OpenEmu/OpenEmu/wiki/Compiling-From-Source-Guide"
#endif

#define OptionDefault(_NAME_, _PREFKEY_) @{ OEGameCoreDisplayModeNameKey : _NAME_, OEGameCoreDisplayModePrefKeyNameKey : _PREFKEY_, OEGameCoreDisplayModeStateKey : @YES, }
#define Option(_NAME_, _PREFKEY_) @{ OEGameCoreDisplayModeNameKey : _NAME_, OEGameCoreDisplayModePrefKeyNameKey : _PREFKEY_, OEGameCoreDisplayModeStateKey : @NO, }
#define OptionIndented(_NAME_, _PREFKEY_) @{ OEGameCoreDisplayModeNameKey : _NAME_, OEGameCoreDisplayModePrefKeyNameKey : _PREFKEY_, OEGameCoreDisplayModeStateKey : @NO, OEGameCoreDisplayModeIndentationLevelKey : @(1), }
#define OptionToggleable(_NAME_, _PREFKEY_) @{ OEGameCoreDisplayModeNameKey : _NAME_, OEGameCoreDisplayModePrefKeyNameKey : _PREFKEY_, OEGameCoreDisplayModeStateKey : @NO, OEGameCoreDisplayModeAllowsToggleKey : @YES, }
#define OptionToggleableNoSave(_NAME_, _PREFKEY_) @{ OEGameCoreDisplayModeNameKey : _NAME_, OEGameCoreDisplayModePrefKeyNameKey : _PREFKEY_, OEGameCoreDisplayModeStateKey : @NO, OEGameCoreDisplayModeAllowsToggleKey : @YES, OEGameCoreDisplayModeDisallowPrefSaveKey : @YES, }
#define Label(_NAME_) @{ OEGameCoreDisplayModeLabelKey : _NAME_, }
#define SeparatorItem() @{ OEGameCoreDisplayModeSeparatorItemKey : @"",}

using namespace Mednafen;

static MDFNGI *game;
static MDFN_Surface *surf;

namespace MDFN_IEN_VB
{
    extern void VIP_SetParallaxDisable(bool disabled);
    extern void VIP_SetAnaglyphColors(uint32 lcolor, uint32 rcolor);
}

// ~2 seconds at 75 fps — time for Lynx game code to clear 0xFF-initialized RAM before RA reads it
static const uint32_t kLynxRAWarmupFrames = 150;

@interface MednafenGameCore () <OELynxSystemResponderClient, OENGPSystemResponderClient, OEPCESystemResponderClient, OEPCECDSystemResponderClient, OEPCFXSystemResponderClient, OEPSXSystemResponderClient, OESaturnSystemResponderClient, OEVBSystemResponderClient, OEWSSystemResponderClient>
{
    uint32_t *_inputBuffer[13];
    int _videoWidth, _videoHeight;
    int _videoOffsetX, _videoOffsetY;
    int _mouseScaledX, _mouseScaledY;
    int _multiTapPlayerCount;
    double _sampleRate;
    double _masterClock;

    NSString *_mednafenCoreModule;
    NSTimeInterval _mednafenCoreTiming;
    OEIntSize _mednafenCoreAspect;
    NSUInteger _maxDiscs;
    NSUInteger _multiDiscTotal;
    BOOL _isSBIRequired;
    BOOL _isMultiDiscGame;
    BOOL _isSS3DControlPadSupportedGame;
    BOOL _isSSVirtuaGunSupportedGame;
    BOOL _isPCE6ButtonPadSupportedGame;
    BOOL _isPSXJustifierSupportedGame;
    BOOL _isPSXGunConSupportedGame;
    NSMutableArray *_allCueSheetFiles;
    NSMutableArray <NSMutableDictionary <NSString *, id> *> *_availableDisplayModes;

    OERetroAchievementsBridge *_raBridge;
    NSString *_romPath;
    int _rcConsole;
    NSMutableDictionary<NSString *, NSNumber *> *_cheatList;
    // wswan ROM-patch cheats only: cheat code -> {rom offset: original byte}, so disabling a code
    // can revert exactly the bytes it touched. wsCartROM isn't a mempatcher page, so unlike RAM
    // 'R' patches, nothing else puts these bytes back once written.
    NSMutableDictionary<NSString *, NSMutableDictionary<NSNumber *, NSNumber *> *> *_romPatchBackups;
    BOOL _isSystemPCECD;
    uint32_t _lynxFrameCount;
    // Owned C-string copy of the active console module name (e.g. "psx", "pce").
    // Read from the RA memory-reader trampoline on the bridge's serial queue
    // without holding ObjC refs, so we can't use _mednafenCoreModule.UTF8String
    // directly — that pointer's lifetime is tied to autorelease-pool drains and
    // could dangle silently if the backing NSString is ever built dynamically.
    // strdup'd at loadFileAtPath; freed in stopEmulation and dealloc.
    char *_cachedModule;
}
- (NSString *)mednafenCoreModule;
- (BOOL)isSystemPCECD;
- (const char *)oeRACachedModule;
- (BOOL)raLynxMemoryWarmingUp;

- (void)initializeMednafen;
- (void)loadDisplayModeOptions;

@end

static __weak MednafenGameCore *_current;

#pragma mark - RetroAchievements

// rcheevos memory callback. Each Mednafen system exposes its main RAM differently;
// dispatch on the active core module. Address-space mappings come from
// Vendor/rcheevos/src/rcheevos/consoleinfo.c (rc_memory_regions_*).
//
//   psx     0x000000-0x1FFFFF  MainRAM (2 MB) — kernel + system RAM contiguous
//   pce     0x000000-0x001FFF  8 KB system RAM via PCE_PeekMainRAM()
//   pcecd   0x000000-0x001FFF  8 KB system RAM via PCE_PeekMainRAM()
//           0x002000-0x011FFF  64 KB CD RAM
//           0x012000-0x041FFF  192 KB Super System Card RAM
//           0x042000-0x0427FF  2 KB CD battery-backed save RAM
//   lynx    0x000000-0x00FFFF  64 KB system RAM via MDFNLynx_GetRAMPointer()
//   ngp     0x000000-0x003FFF  16 KB CPUExRAM via MDFNNGP_GetRAMPointer()
//
// PSX scratchpad (0x200000-0x2003FF) is intentionally left unmapped — the
// overwhelming majority of PSX achievement sets only touch main RAM.
// PCE-CD regions return short-reads when the underlying buffer hasn't been
// allocated for a particular game (e.g. plain HuCard loaded as pcecd).
static uint32_t mednafen_rc_read_memory(uint32_t address, uint8_t *buffer,
                                        uint32_t num_bytes, rc_client_t *client)
{
    OERetroAchievementsBridge *bridge = (__bridge OERetroAchievementsBridge *)rc_client_get_userdata(client);
    MednafenGameCore *c = (MednafenGameCore *)bridge.core;
    if (!c) { return 0; }
    const char *mod = [c oeRACachedModule];
    if (!mod) { return 0; }

    if (strcmp(mod, "psx") == 0) {
        for (uint32_t i = 0; i < num_bytes; i++) {
            uint32_t a = address + i;
            if (a < 0x200000) {
                buffer[i] = MDFN_IEN_PSX::MainRAM.data8[a];
            } else if (a < 0x200400) {
                // Scratchpad: rcheevos maps 0x200000–0x2003FF → CPU 0x1F800000 (1 KB)
                if (!MDFN_IEN_PSX::CPU) { return i; }
                buffer[i] = MDFN_IEN_PSX::CPU->GetScratchRAMData()[a - 0x200000];
            } else {
                return i;
            }
        }
        return num_bytes;
    }
    if (strcmp(mod, "pce") == 0 && ![c isSystemPCECD]) {
        for (uint32_t i = 0; i < num_bytes; i++) {
            if (address + i >= 0x2000) { return i; }
            buffer[i] = MDFN_IEN_PCE::PCE_PeekMainRAM(address + i);
        }
        return num_bytes;
    }
    if (strcmp(mod, "pce") == 0 && [c isSystemPCECD]) {
        uint8_t *cdram     = MDFNPCE_GetCDRAMPointer();      // 64 KB,  may be NULL
        uint8_t *syscard   = MDFNPCE_GetSysCardRAMPointer(); // 192 KB, may be NULL
        uint8_t *saveram   = MDFNPCE_GetSaveRAMPointer();    // 2 KB,   always present
        for (uint32_t i = 0; i < num_bytes; i++) {
            uint32_t a = address + i;
            if (a < 0x002000) {
                buffer[i] = MDFN_IEN_PCE::PCE_PeekMainRAM(a);
            } else if (a < 0x012000) {
                if (!cdram) { return i; }
                buffer[i] = cdram[a - 0x002000];
            } else if (a < 0x042000) {
                if (!syscard) { return i; }
                buffer[i] = syscard[a - 0x012000];
            } else if (a < 0x042800) {
                buffer[i] = saveram[a - 0x042000];
            } else {
                return i;
            }
        }
        return num_bytes;
    }
    if (strcmp(mod, "lynx") == 0) {
        uint8_t *ram = MDFNLynx_GetRAMPointer();
        if (!ram) { return 0; }
        if (c && [c raLynxMemoryWarmingUp]) {
            // Mirror the post-warmup bounds so an out-of-range read short-reads consistently.
            uint32_t n = (address >= 0x10000) ? 0 : MIN(num_bytes, 0x10000 - address);
            memset(buffer, 0, n);
            return n;
        }
        for (uint32_t i = 0; i < num_bytes; i++) {
            if (address + i >= 0x10000) { return i; }
            buffer[i] = ram[address + i];
        }
        return num_bytes;
    }
    if (strcmp(mod, "wswan") == 0) {
        uint8_t *ram = MDFNWS_GetRAMPointer();
        if (!ram) { return 0; }
        uint8_t *sram = MDFNWS_GetSRAMPointer();
        uint32_t sramSize = MDFNWS_GetSRAMSize();
        for (uint32_t i = 0; i < num_bytes; i++) {
            uint32_t a = address + i;
            if (a < 0x10000) {
                buffer[i] = ram[a];
            } else if (sram && sramSize > 0 && a < 0x10000 + sramSize) {
                buffer[i] = sram[a - 0x10000];
            } else {
                return i;
            }
        }
        return num_bytes;
    }
    if (strcmp(mod, "ngp") == 0) {
        uint8_t *ram = MDFNNGP_GetRAMPointer();
        if (!ram) { return 0; }
        for (uint32_t i = 0; i < num_bytes; i++) {
            if (address + i >= 0x4000) { return i; }
            buffer[i] = ram[address + i];
        }
        return num_bytes;
    }
    if (strcmp(mod, "pcfx") == 0) {
        uint8_t *ram = MDFNPCFX_GetRAMPointer();
        if (!ram) { return 0; }
        uint8_t *bram = MDFNPCFX_GetBackupRAMPointer();
        uint8_t *exbram = MDFNPCFX_GetExBackupRAMPointer();
        for (uint32_t i = 0; i < num_bytes; i++) {
            uint32_t a = address + i;
            if (a < 0x200000) {
                buffer[i] = ram[a];
            } else if (a < 0x208000) {
                buffer[i] = bram[a - 0x200000];
            } else if (a < 0x210000) {
                buffer[i] = exbram[a - 0x208000];
            } else {
                return i;
            }
        }
        return num_bytes;
    }
    if (strcmp(mod, "vb") == 0) {
        uint8_t *wram = MDFNVB_GetWRAMPointer();
        if (!wram) { return 0; }
        uint8_t *gpram = MDFNVB_GetGPRAMPointer();
        uint32_t gpramSize = MDFNVB_GetGPRAMSize();
        for (uint32_t i = 0; i < num_bytes; i++) {
            uint32_t a = address + i;
            if (a < 0x10000) {
                buffer[i] = wram[a];
            } else if (a < 0x20000) {
                if (!gpram || gpramSize == 0) { return i; }
                buffer[i] = gpram[(a - 0x10000) & (gpramSize - 1)];
            } else {
                return i;
            }
        }
        return num_bytes;
    }
    if (strcmp(mod, "ss") == 0) {
        // Expose raw ne16 buffer layout — matches how Beetle Saturn (libretro)
        // exposes memory, which is what achievement sets are authored against.
        const uint8_t *workL = MDFN_IEN_SS::SS_GetWorkRAML();
        const uint8_t *workH = MDFN_IEN_SS::SS_GetWorkRAMH();
        if (!workL || !workH) { return 0; }
        for (uint32_t i = 0; i < num_bytes; i++) {
            uint32_t a = address + i;
            if (a < 0x100000) {
                buffer[i] = workL[a & 0xFFFFF];
            } else if (a < 0x200000) {
                buffer[i] = workH[(a - 0x100000) & 0xFFFFF];
            } else {
                return i;
            }
        }
        return num_bytes;
    }
    return 0;
}

@implementation MednafenGameCore

- (NSString *)mednafenCoreModule { return _mednafenCoreModule; }
- (BOOL)isSystemPCECD { return _isSystemPCECD; }
- (const char *)oeRACachedModule { return _cachedModule; }
- (BOOL)raLynxMemoryWarmingUp {
    // Lynx RAM inits to 0xFF; wait for game code to run before exposing memory to RA.
    return _lynxFrameCount < kLynxRAWarmupFrames;
}

- (void)initializeMednafen
{
    MDFNI_InitializeModules();

    std::vector<MDFNSetting> settings;

    NSString *batterySavesDirectory = self.batterySavesDirectoryPath;
    NSString *biosPath = self.biosDirectoryPath;

    MDFNI_Initialize(biosPath.fileSystemRepresentation, settings);

    // Set bios/system file and memcard save paths
    MDFNI_SetSetting("pce.cdbios", [[biosPath stringByAppendingPathComponent:@"syscard3"] stringByAppendingPathExtension:@"pce"].fileSystemRepresentation); // PCE CD BIOS
    MDFNI_SetSetting("pcfx.bios", [[biosPath stringByAppendingPathComponent:@"pcfx"] stringByAppendingPathExtension:@"rom"].fileSystemRepresentation); // PCFX BIOS
    MDFNI_SetSetting("psx.bios_jp", [[biosPath stringByAppendingPathComponent:@"scph5500"] stringByAppendingPathExtension:@"bin"].fileSystemRepresentation); // JP SCPH-5500 BIOS
    MDFNI_SetSetting("psx.bios_na", [[biosPath stringByAppendingPathComponent:@"scph5501"] stringByAppendingPathExtension:@"bin"].fileSystemRepresentation); // NA SCPH-5501 BIOS
    MDFNI_SetSetting("psx.bios_eu", [[biosPath stringByAppendingPathComponent:@"scph5502"] stringByAppendingPathExtension:@"bin"].fileSystemRepresentation); // EU SCPH-5502 BIOS
    MDFNI_SetSetting("ss.bios_jp", [[biosPath stringByAppendingPathComponent:@"sega_101"] stringByAppendingPathExtension:@"bin"].fileSystemRepresentation); // JP SS BIOS
    MDFNI_SetSetting("ss.bios_na_eu", [[biosPath stringByAppendingPathComponent:@"mpr-17933"] stringByAppendingPathExtension:@"bin"].fileSystemRepresentation); // NA/EU SS BIOS
    MDFNI_SetSetting("filesys.path_sav", batterySavesDirectory.fileSystemRepresentation); // Memcards

    // VB defaults. dox http://mednafen.sourceforge.net/documentation/09x/vb.html
    MDFNI_SetSetting("vb.disable_parallax", "1");       // Disable parallax for BG and OBJ rendering
    MDFNI_SetSetting("vb.anaglyph.preset", "disabled"); // Disable anaglyph preset
    MDFNI_SetSetting("vb.anaglyph.lcolor", "0xFF0000"); // Anaglyph l color
    MDFNI_SetSetting("vb.anaglyph.rcolor", "0x000000"); // Anaglyph r color
    //MDFNI_SetSetting("vb.allow_draw_skip", "1");      // Allow draw skipping
    //MDFNI_SetSetting("vb.instant_display_hack", "1"); // Display latency reduction hack
    //MDFNI_SetSetting("vb.ledonscale", "1.9921875"); // Old brightness level before 0.9.44 update

    MDFNI_SetSetting("pce.slstart", "0"); // PCE: First rendered scanline
    MDFNI_SetSetting("pce.slend", "239"); // PCE: Last rendered scanline

    MDFNI_SetSetting("psx.h_overscan", "0"); // Remove PSX overscan

    //MDFNI_SetSetting("ss.input.port1.gun_chairs", "0x1000000"); // SS: Disable crosshair drawing

    // PlayStation SBI required games (LibCrypt)
    NSDictionary<NSString *, NSNumber *> *sbiRequiredGames =
    @{
      @"SLES-01226" : @1, // Actua Ice Hockey 2 (Europe)
      @"SLES-02563" : @1, // Anstoss - Premier Manager (Germany)
      @"SCES-01564" : @1, // Ape Escape (Europe)
      @"SCES-02028" : @1, // Ape Escape (France)
      @"SCES-02029" : @1, // Ape Escape (Germany)
      @"SCES-02030" : @1, // Ape Escape (Italy)
      @"SCES-02031" : @1, // Ape Escape - La Invasión de los Monos (Spain)
      @"SLES-03324" : @1, // Astérix - Mega Madness (Europe) (En,Fr,De,Es,It,Nl)
      @"SCES-02366" : @1, // Barbie - Aventure Equestre (France)
      @"SCES-02365" : @1, // Barbie - Race & Ride (Europe)
      @"SCES-02367" : @1, // Barbie - Race & Ride (Germany)
      @"SCES-02368" : @1, // Barbie - Race & Ride (Italy)
      @"SCES-02369" : @1, // Barbie - Race & Ride (Spain)
      @"SCES-02488" : @1, // Barbie - Sports Extrême (France)
      @"SCES-02489" : @1, // Barbie - Super Sport (Germany)
      @"SCES-02487" : @1, // Barbie - Super Sports (Europe)
      @"SCES-02490" : @1, // Barbie - Super Sports (Italy)
      @"SCES-02491" : @1, // Barbie - Super Sports (Spain)
      @"SLES-02977" : @1, // BDFL Manager 2001 (Germany)
      @"SLES-03605" : @1, // BDFL Manager 2002 (Germany)
      @"SLES-02293" : @1, // Canal+ Premier Manager (Europe) (Fr,Es,It)
      @"SCES-02834" : @1, // Crash Bash (Europe) (En,Fr,De,Es,It)
      @"SCES-02105" : @1, // CTR - Crash Team Racing (Europe) (En,Fr,De,Es,It,Nl) (EDC) / (No EDC)
      @"SLES-02207" : @1, // Dino Crisis (Europe)
      @"SLES-02208" : @1, // Dino Crisis (France)
      @"SLES-02209" : @1, // Dino Crisis (Germany)
      @"SLES-02210" : @1, // Dino Crisis (Italy)
      @"SLES-02211" : @1, // Dino Crisis (Spain)
      @"SCES-02004" : @1, // Disney Fais Ton Histoire! - Mulan (France)
      @"SCES-02006" : @1, // Disney Libro Animato Creativo - Mulan (Italy)
      @"SCES-01516" : @1, // Disney Tarzan (France)
      @"SCES-01519" : @1, // Disney Tarzan (Spain)
      @"SLES-03191" : @1, // Disney's 102 Dalmatians - Puppies to the Rescue (Europe) (Fr,De,Es,It,Nl)
      @"SLES-03189" : @1, // Disney's 102 Dalmatians - Puppies to the Rescue (Europe)
      @"SCES-02007" : @1, // Disney's Aventura Interactiva - Mulan (Spain)
      @"SCES-01695" : @1, // Disney's Story Studio - Mulan (Europe)
      @"SCES-01431" : @1, // Disney's Tarzan (Europe)
      @"SCES-02185" : @1, // Disney's Tarzan (Netherlands)
      @"SCES-02182" : @1, // Disney's Tarzan (Sweden)
      @"SCES-02264" : @1, // Disney's Verhalenstudio - Mulan (Netherlands)
      @"SCES-02005" : @1, // Disneys Interaktive Abenteuer - Mulan (Germany)
      @"SCES-01517" : @1, // Disneys Tarzan (Germany)
      @"SCES-01518" : @1, // Disneys Tarzan (Italy)
      @"SLES-02538" : @1, // EA Sports Superbike 2000 (Europe) (En,Fr,De,Es,It,Sv)
      @"SLES-01715" : @1, // Eagle One - Harrier Attack (Europe) (En,Fr,De,Es,It)
      @"SCES-01704" : @1, // Esto es Futbol (Spain)
      @"SLES-03061" : @1, // F.A. Premier League Football Manager 2001, The (Europe)
      @"SLES-02722" : @1, // F1 2000 (Europe) (En,Fr,De,Nl)
      @"SLES-02724" : @1, // F1 2000 (Italy)
      @"SLES-02965" : @1, // Final Fantasy IX (Europe) (Disc 1)
      @"SLES-12965" : @1, // Final Fantasy IX (Europe) (Disc 2)
      @"SLES-22965" : @1, // Final Fantasy IX (Europe) (Disc 3)
      @"SLES-32965" : @1, // Final Fantasy IX (Europe) (Disc 4)
      @"SLES-02966" : @1, // Final Fantasy IX (France) (Disc 1)
      @"SLES-12966" : @1, // Final Fantasy IX (France) (Disc 2)
      @"SLES-22966" : @1, // Final Fantasy IX (France) (Disc 3)
      @"SLES-32966" : @1, // Final Fantasy IX (France) (Disc 4)
      @"SLES-02967" : @1, // Final Fantasy IX (Germany) (Disc 1)
      @"SLES-12967" : @1, // Final Fantasy IX (Germany) (Disc 2)
      @"SLES-22967" : @1, // Final Fantasy IX (Germany) (Disc 3)
      @"SLES-32967" : @1, // Final Fantasy IX (Germany) (Disc 4)
      @"SLES-02968" : @1, // Final Fantasy IX (Italy) (Disc 1)
      @"SLES-12968" : @1, // Final Fantasy IX (Italy) (Disc 2)
      @"SLES-22968" : @1, // Final Fantasy IX (Italy) (Disc 3)
      @"SLES-32968" : @1, // Final Fantasy IX (Italy) (Disc 4)
      @"SLES-02969" : @1, // Final Fantasy IX (Spain) (Disc 1)
      @"SLES-12969" : @1, // Final Fantasy IX (Spain) (Disc 2)
      @"SLES-22969" : @1, // Final Fantasy IX (Spain) (Disc 3)
      @"SLES-32969" : @1, // Final Fantasy IX (Spain) (Disc 4)
      @"SLES-02080" : @1, // Final Fantasy VIII (Europe, Australia) (Disc 1)
      @"SLES-12080" : @1, // Final Fantasy VIII (Europe, Australia) (Disc 2)
      @"SLES-22080" : @1, // Final Fantasy VIII (Europe, Australia) (Disc 3)
      @"SLES-32080" : @1, // Final Fantasy VIII (Europe, Australia) (Disc 4)
      @"SLES-02081" : @1, // Final Fantasy VIII (France) (Disc 1)
      @"SLES-12081" : @1, // Final Fantasy VIII (France) (Disc 2)
      @"SLES-22081" : @1, // Final Fantasy VIII (France) (Disc 3)
      @"SLES-32081" : @1, // Final Fantasy VIII (France) (Disc 4)
      @"SLES-02082" : @1, // Final Fantasy VIII (Germany) (Disc 1)
      @"SLES-12082" : @1, // Final Fantasy VIII (Germany) (Disc 2)
      @"SLES-22082" : @1, // Final Fantasy VIII (Germany) (Disc 3)
      @"SLES-32082" : @1, // Final Fantasy VIII (Germany) (Disc 4)
      @"SLES-02083" : @1, // Final Fantasy VIII (Italy) (Disc 1)
      @"SLES-12083" : @1, // Final Fantasy VIII (Italy) (Disc 2)
      @"SLES-22083" : @1, // Final Fantasy VIII (Italy) (Disc 3)
      @"SLES-32083" : @1, // Final Fantasy VIII (Italy) (Disc 4)
      @"SLES-02084" : @1, // Final Fantasy VIII (Spain) (Disc 1)
      @"SLES-12084" : @1, // Final Fantasy VIII (Spain) (Disc 2)
      @"SLES-22084" : @1, // Final Fantasy VIII (Spain) (Disc 3)
      @"SLES-32084" : @1, // Final Fantasy VIII (Spain) (Disc 4)
      @"SLES-02978" : @1, // Football Manager Campionato 2001 (Italy)
      @"SCES-02222" : @1, // Formula One 99 (Europe) (En,Es,Fi)
      @"SCES-01979" : @1, // Formula One 99 (Europe) (En,Fr,De,It)
      @"SLES-02767" : @1, // Frontschweine (Germany)
      @"SCES-01702" : @1, // Fussball Live (Germany)
      @"SLES-03062" : @1, // Fussball Manager 2001 (Germany)
      @"SLES-02328" : @1, // Galerians (Europe) (Disc 1)
      @"SLES-12328" : @1, // Galerians (Europe) (Disc 2)
      @"SLES-22328" : @1, // Galerians (Europe) (Disc 3)
      @"SLES-02329" : @1, // Galerians (France) (Disc 1)
      @"SLES-12329" : @1, // Galerians (France) (Disc 2)
      @"SLES-22329" : @1, // Galerians (France) (Disc 3)
      @"SLES-02330" : @1, // Galerians (Germany) (Disc 1)
      @"SLES-12330" : @1, // Galerians (Germany) (Disc 2)
      @"SLES-22330" : @1, // Galerians (Germany) (Disc 3)
      @"SLES-01241" : @1, // Gekido - Urban Fighters (Europe) (En,Fr,De,Es,It)
      @"SLES-01041" : @1, // Hogs of War (Europe)
      @"SLES-03489" : @1, // Italian Job, The (Europe)
      @"SLES-03626" : @1, // Italian Job, The (Europe) (Fr,De,Es)
      @"SCES-01444" : @1, // Jackie Chan Stuntmaster (Europe)
      @"SLES-01362" : @1, // Le Mans 24 Hours (Europe) (En,Fr,De,Es,It,Pt)
      @"SLES-01301" : @1, // Legacy of Kain - Soul Reaver (Europe)
      @"SLES-02024" : @1, // Legacy of Kain - Soul Reaver (France)
      @"SLES-02025" : @1, // Legacy of Kain - Soul Reaver (Germany)
      @"SLES-02027" : @1, // Legacy of Kain - Soul Reaver (Italy)
      @"SLES-02026" : @1, // Legacy of Kain - Soul Reaver (Spain)
      @"SLES-02766" : @1, // Les Cochons de Guerre (France)
      @"SLES-02975" : @1, // LMA Manager 2001 (Europe)
      @"SLES-03603" : @1, // LMA Manager 2002 (Europe)
      @"SLES-03530" : @1, // Lucky Luke - Western Fever (Europe) (En,Fr,De,Es,It,Nl)
      @"SCES-00311" : @1, // MediEvil (Europe)
      @"SCES-01492" : @1, // MediEvil (France)
      @"SCES-01493" : @1, // MediEvil (Germany)
      @"SCES-01494" : @1, // MediEvil (Italy)
      @"SCES-01495" : @1, // MediEvil (Spain)
      @"SCES-02544" : @1, // MediEvil 2 (Europe) (En,Fr,De)
      @"SCES-02545" : @1, // MediEvil 2 (Europe) (Es,It,Pt)
      @"SCES-02546" : @1, // MediEvil 2 (Russia)
      @"SLES-03519" : @1, // Men in Black - The Series - Crashdown (Europe)
      @"SLES-03520" : @1, // Men in Black - The Series - Crashdown (France)
      @"SLES-03521" : @1, // Men in Black - The Series - Crashdown (Germany)
      @"SLES-03522" : @1, // Men in Black - The Series - Crashdown (Italy)
      @"SLES-03523" : @1, // Men in Black - The Series - Crashdown (Spain)
      @"SLES-01545" : @1, // Michelin Rally Masters - Race of Champions (Europe) (En,De,Sv)
      @"SLES-02395" : @1, // Michelin Rally Masters - Race of Champions (Europe) (Fr,Es,It)
      @"SLES-02839" : @1, // Mike Tyson Boxing (Europe) (En,Fr,De,Es,It)
      @"SLES-01906" : @1, // Mission - Impossible (Europe) (En,Fr,De,Es,It)
      @"SLES-02830" : @1, // MoHo (Europe) (En,Fr,De,Es,It)
      @"SCES-01701" : @1, // Monde des Bleus, Le - Le jeu officiel de l'équipe de France (France)
      @"SLES-02086" : @1, // N-Gen Racing (Europe) (En,Fr,De,Es,It)
      @"SLES-02689" : @1, // Need for Speed - Porsche 2000 (Europe) (En,De,Sv)
      @"SLES-02700" : @1, // Need for Speed - Porsche 2000 (Europe) (Fr,Es,It)
      @"SLES-02558" : @1, // Parasite Eve II (Europe) (Disc 1)
      @"SLES-12558" : @1, // Parasite Eve II (Europe) (Disc 2)
      @"SLES-02559" : @1, // Parasite Eve II (France) (Disc 1)
      @"SLES-12559" : @1, // Parasite Eve II (France) (Disc 2)
      @"SLES-02560" : @1, // Parasite Eve II (Germany) (Disc 1)
      @"SLES-12560" : @1, // Parasite Eve II (Germany) (Disc 2)
      @"SLES-02562" : @1, // Parasite Eve II (Italy) (Disc 1)
      @"SLES-12562" : @1, // Parasite Eve II (Italy) (Disc 2)
      @"SLES-02561" : @1, // Parasite Eve II (Spain) (Disc 1)
      @"SLES-12561" : @1, // Parasite Eve II (Spain) (Disc 2)
      @"SLES-02061" : @1, // PGA European Tour Golf (Europe) (En,De)
      @"SLES-02292" : @1, // Premier Manager 2000 (Europe)
      @"SLES-00017" : @1, // Prince Naseem Boxing (Europe) (En,Fr,De,Es,It)
      @"SLES-01943" : @1, // Radikal Bikers (Europe) (En,Fr,De,Es,It)
      @"SLES-02824" : @1, // RC Revenge (Europe) (En,Fr,De,Es)
      @"SLES-02529" : @1, // Resident Evil 3 - Nemesis (Europe)
      @"SLES-02530" : @1, // Resident Evil 3 - Nemesis (France)
      @"SLES-02531" : @1, // Resident Evil 3 - Nemesis (Germany)
      @"SLES-02698" : @1, // Resident Evil 3 - Nemesis (Ireland)
      @"SLES-02533" : @1, // Resident Evil 3 - Nemesis (Italy)
      @"SLES-02532" : @1, // Resident Evil 3 - Nemesis (Spain)
      @"SLES-00995" : @1, // Ronaldo V-Football (Europe) (En,Fr,Nl,Sv)
      @"SLES-02681" : @1, // Ronaldo V-Football (Europe) (De,Es,It,Pt)
      @"SLES-02112" : @1, // SaGa Frontier 2 (Europe)
      @"SLES-02113" : @1, // SaGa Frontier 2 (France)
      @"SLES-02118" : @1, // SaGa Frontier 2 (Germany)
      @"SLES-02763" : @1, // SnoCross Championship Racing (Europe) (En,Fr,De,Es,It)
      @"SCES-02290" : @1, // Space Debris (Europe)
      @"SCES-02430" : @1, // Space Debris (France)
      @"SCES-02431" : @1, // Space Debris (Germany)
      @"SCES-02432" : @1, // Space Debris (Italy)
      @"SCES-01763" : @1, // Speed Freaks (Europe)
      @"SCES-02835" : @1, // Spyro - Year of the Dragon (Europe) (En,Fr,De,Es,It) (v1.0) / (v1.1)
      @"SCES-02104" : @1, // Spyro 2 - Gateway to Glimmer (Europe) (En,Fr,De,Es,It)
      @"SLES-02857" : @1, // Sydney 2000 (Europe)
      @"SLES-02858" : @1, // Sydney 2000 (France)
      @"SLES-02859" : @1, // Sydney 2000 (Germany)
      @"SLES-02861" : @1, // Sydney 2000 (Spain)
      @"SLES-03245" : @1, // TechnoMage - De Terugkeer der Eeuwigheid (Netherlands)
      @"SLES-02831" : @1, // TechnoMage - Die Rückkehr der Ewigkeit (Germany)
      @"SLES-03242" : @1, // TechnoMage - En Quête de L'Eternité (France)
      @"SLES-03241" : @1, // TechnoMage - Return of Eternity (Europe)
      @"SLES-02688" : @1, // Theme Park World (Europe) (En,Fr,De,Es,It,Nl,Sv)
      @"SCES-01882" : @1, // This Is Football (Europe) (Fr,Nl)
      @"SCES-01700" : @1, // This Is Football (Europe)
      @"SCES-01703" : @1, // This Is Football (Italy)
      @"SLES-02572" : @1, // TOCA World Touring Cars (Europe) (En,Fr,De)
      @"SLES-02573" : @1, // TOCA World Touring Cars (Europe) (Es,It)
      @"SLES-02704" : @1, // UEFA Euro 2000 (Europe)
      @"SLES-02705" : @1, // UEFA Euro 2000 (France)
      @"SLES-02706" : @1, // UEFA Euro 2000 (Germany)
      @"SLES-02707" : @1, // UEFA Euro 2000 (Italy)
      @"SLES-01733" : @1, // UEFA Striker (Europe) (En,Fr,De,Es,It,Nl)
      @"SLES-02071" : @1, // Urban Chaos (Europe) (En,Es,It)
      @"SLES-02355" : @1, // Urban Chaos (Germany)
      @"SLES-01907" : @1, // V-Rally - Championship Edition 2 (Europe) (En,Fr,De)
      @"SLES-02754" : @1, // Vagrant Story (Europe)
      @"SLES-02755" : @1, // Vagrant Story (France)
      @"SLES-02756" : @1, // Vagrant Story (Germany)
      @"SLES-02733" : @1, // Walt Disney World Quest - Magical Racing Tour (Europe) (En,Fr,De,Es,It,Nl,Sv,No,Da)
      @"SCES-01909" : @1, // Wip3out (Europe) (En,Fr,De,Es,It)
      };

    // PlayStation Multitap supported games (incomplete list)
    NSDictionary<NSString *, NSNumber *> *psxMultiTapGames =
    @{
      @"SLES-02339" : @3, // Arcade Party Pak (Europe, Australia)
      @"SLUS-00952" : @3, // Arcade Party Pak (USA)
      @"SLES-02537" : @3, // Bishi Bashi Special (Europe)
      @"SLPM-86123" : @3, // Bishi Bashi Special (Japan)
      @"SLPM-86539" : @3, // Bishi Bashi Special 3: Step Champ (Japan)
      @"SLPS-01701" : @3, // Capcom Generation - Dai 4 Shuu Kokou no Eiyuu (Japan)
      @"SLPS-01567" : @3, // Captain Commando (Japan)
      @"SLUS-00682" : @3, // Jeopardy! (USA)
      @"SLUS-01173" : @3, // Jeopardy! 2nd Edition (USA)
      @"SLES-03752" : @3, // Quiz Show (Italy) (Disc 1)
      @"SLES-13752" : @3, // Quiz Show (Italy) (Disc 2)
      @"SLES-02849" : @3, // Rampage - Through Time (Europe) (En,Fr,De)
      @"SLUS-01065" : @3, // Rampage - Through Time (USA)
      @"SLES-02021" : @3, // Rampage 2 - Universal Tour (Europe)
      @"SLUS-00742" : @3, // Rampage 2 - Universal Tour (USA)
      @"SLUS-01174" : @3, // Wheel of Fortune - 2nd Edition (USA)
      @"SLES-03499" : @3, // You Don't Know Jack (Germany)
      @"SLUS-00716" : @3, // You Don't Know Jack (USA) (Disc 1)
      @"SLUS-00762" : @3, // You Don't Know Jack (USA) (Disc 2)
      @"SLUS-01194" : @3, // You Don't Know Jack - Mock 2 (USA)
      @"SLES-00015" : @4, // Actua Golf (Europe) (En,Fr,De)
      @"SLPS-00298" : @4, // Actua Golf (Japan)
      @"SLUS-00198" : @4, // VR Golf '97 (USA) (En,Fr)
      @"SLES-00044" : @4, // Actua Golf 2 (Europe)
      @"SLUS-00636" : @4, // FOX Sports Golf '99 (USA)
      @"SLES-01042" : @4, // Actua Golf 3 (Europe)
      @"SLES-00188" : @4, // Actua Ice Hockey (Europe) (En,Fr,De,Sv,Fi)
      @"SLPM-86078" : @4, // Actua Ice Hockey (Japan)
      @"SLES-01226" : @4, // Actua Ice Hockey 2 (Europe)
      @"SLES-00021" : @4, // Actua Soccer 2 (Europe) (En,Fr)
      @"SLES-01029" : @4, // Actua Soccer 2 (Germany) (En,De)
      @"SLES-01028" : @4, // Actua Soccer 2 (Italy)
      @"SLES-00265" : @4, // Actua Tennis (Europe)
      @"SLES-01396" : @4, // Actua Tennis (Europe) (Fr,De)
      @"SLES-00189" : @4, // Adidas Power Soccer (Europe) (En,Fr,De,Es,It)
      @"SCUS-94502" : @4, // Adidas Power Soccer (USA)
      @"SLES-00857" : @4, // Adidas Power Soccer 2 (Europe) (En,Fr,De,Es,It,Nl)
      @"SLES-00270" : @4, // Adidas Power Soccer International '97 (Europe) (En,Fr,De,Es,It,Nl)
      @"SLES-01239" : @4, // Adidas Power Soccer 98 (Europe) (En,Fr,De,Es,It,Nl)
      @"SLUS-00547" : @4, // Adidas Power Soccer 98 (USA)
      @"SLES-03963" : @4, // All Star Tennis (Europe)
      @"SLPS-02228" : @4, // Simple 1500 Series Vol. 26 - The Tennis (Japan)
      @"SLUS-01348" : @4, // Tennis (USA)
      @"SLES-01433" : @4, // All Star Tennis '99 (Europe) (En,Fr,De,Es,It)
      @"SLES-02764" : @4, // All Star Tennis 2000 (Europe) (En,De,Es,It)
      @"SLES-02765" : @4, // All Star Tennis 2000 (France)
      @"SCES-00263" : @4, // Namco Tennis Smash Court (Europe)
      @"SLPS-00450" : @4, // Smash Court (Japan)
      @"SCES-01833" : @4, // Anna Kournikova's Smash Court Tennis (Europe)
      @"SLPS-01693" : @4, // Smash Court 2 (Japan)
      @"SLPS-03001" : @4, // Smash Court 3 (Japan)
      @"SLES-00712" : @4, // Arcade's Greatest Hits - The Atari Collection 2 (Europe)
      @"SLUS-00449" : @4, // Arcade's Greatest Hits - The Atari Collection 2 (USA)
      @"SLES-03808" : @4, // Atari Anniversary Edition Redux (Europe)
      @"SLUS-01427" : @4, // Atari Anniversary Edition Redux (USA)
      @"SLPS-01486" : @4, // Carom Shot 2 (Japan)
      @"SLUS-00659" : @4, // Backstreet Billiards (USA)
      @"SLES-03579" : @4, // Junior Sports Football (Europe)
      @"SLES-03581" : @4, // Junior Sports Fussball (Germany)
      @"SLUS-01094" : @4, // Backyard Soccer (USA)
      @"SLES-03210" : @4, // Hunter, The (Europe)
      @"SLPM-86400" : @4, // SuperLite 1500 Series - Battle Sugoroku the Hunter - A.R.0062 (Japan)
      @"SLUS-01335" : @4, // Battle Hunter (USA)
      @"SLES-00476" : @4, // Blast Chamber (Europe) (En,Fr,De,Es,It)
      @"SLPS-00622" : @4, // Kyuu Bakukku (Japan)
      @"SLUS-00219" : @4, // Blast Chamber (USA)
      @"SLES-00845" : @4, // Blaze & Blade - Eternal Quest (Europe)
      @"SLES-01274" : @4, // Blaze & Blade - Eternal Quest (Germany)
      @"SLPS-01209" : @4, // Blaze & Blade - Eternal Quest (Japan)
      @"SLPS-01576" : @4, // Blaze & Blade Busters (Japan)
      @"SCES-01443" : @4, // Blood Lines (Europe) (En,Fr,De,Es,It)
      @"SLPS-03002" : @4, // Bomberman Land (Japan) (v1.0) / (v1.1) / (v1.2)
      @"SLES-00258" : @4, // Break Point (Europe) (En,Fr)
      @"SLES-02854" : @4, // Break Out (Europe) (En,Fr,De,It)
      @"SLUS-01170" : @4, // Break Out (USA)
      @"SLES-00759" : @4, // Brian Lara Cricket (Europe)
      @"SLES-01486" : @4, // Caesars Palace II (Europe)
      @"SLES-02476" : @4, // Caesars Palace 2000 - Millennium Gold Edition (Europe)
      @"SLUS-01089" : @4, // Caesars Palace 2000 - Millennium Gold Edition (USA)
      @"SLES-03206" : @4, // Card Shark (Europe)
      @"SLPS-02225" : @4, // Trump Shiyouyo! (Japan) (v1.0)
      @"SLPS-02612" : @4, // Trump Shiyouyo! (Japan) (v1.1)
      @"SLUS-01454" : @4, // Family Card Games Fun Pack (USA)
      @"SLES-02825" : @4, // Catan - Die erste Insel (Germany)
      @"SLUS-00886" : @4, // Chessmaster II (USA)
      @"SLES-00753" : @4, // Circuit Breakers (Europe) (En,Fr,De,Es,It)
      @"SLUS-00697" : @4, // Circuit Breakers (USA)
      @"SLUS-00196" : @4, // College Slam (USA)
      @"SCES-02834" : @4, // Crash Bash (Europe) (En,Fr,De,Es,It)
      @"SCPS-10140" : @4, // Crash Bandicoot Carnival (Japan)
      @"SCUS-94570" : @4, // Crash Bash (USA)
      @"SCES-02105" : @4, // CTR - Crash Team Racing (Europe) (En,Fr,De,Es,It,Nl) (EDC) / (No EDC)
      @"SCPS-10118" : @4, // Crash Bandicoot Racing (Japan)
      @"SCUS-94426" : @4, // CTR - Crash Team Racing (USA)
      @"SLES-03729" : @4, // Cubix Robots for Everyone - Race 'n Robots (Europe)
      @"SLUS-01422" : @4, // Cubix Robots for Everyone - Race 'n Robots (USA)
      @"SLES-02371" : @4, // CyberTiger (Australia)
      @"SLES-02370" : @4, // CyberTiger (Europe) (En,Fr,De,Es,Sv)
      @"SLUS-01004" : @4, // CyberTiger (USA)
      @"SLES-03488" : @4, // David Beckham Soccer (Europe)
      @"SLES-03682" : @4, // David Beckham Soccer (Europe) (Fr,De,Es,It)
      @"SLUS-01455" : @4, // David Beckham Soccer (USA)
      @"SLES-00096" : @4, // Davis Cup Complete Tennis (Europe)
      @"SCES-02060" : @4, // Destruction Derby Raw (Europe)
      @"SLUS-00912" : @4, // Destruction Derby Raw (USA)
      @"SCES-03705" : @4, // Disney's Party Time with Winnie the Pooh (Europe)
      @"SCES-03744" : @4, // Disney's Winnie l'Ourson - C'est la récré! (France)
      @"SCES-03745" : @4, // Disney's Party mit Winnie Puuh (Germany)
      @"SCES-03749" : @4, // Disney Pooh e Tigro! E Qui la Festa (Italy)
      @"SLPS-03460" : @4, // Pooh-San no Minna de Mori no Daikyosou! (Japan)
      @"SCES-03746" : @4, // Disney's Spelen met Winnie de Poeh en zijn Vriendjes! (Netherlands)
      @"SCES-03748" : @4, // Disney Ven a la Fiesta! con Winnie the Pooh (Spain)
      @"SLUS-01437" : @4, // Disney's Pooh's Party Game - In Search of the Treasure (USA)
      @"SLPS-00155" : @4, // DX Jinsei Game (Japan)
      @"SLPS-00918" : @4, // DX Jinsei Game II (Japan) (v1.0) / (v1.1)
      @"SLPS-02469" : @4, // DX Jinsei Game III (Japan)
      @"SLPM-86963" : @4, // DX Jinsei Game IV (Japan)
      @"SLPM-87187" : @4, // DX Jinsei Game V (Japan)
      @"SLES-02823" : @4, // ECW Anarchy Rulz (Europe)
      @"SLES-03069" : @4, // ECW Anarchy Rulz (Germany)
      @"SLUS-01169" : @4, // ECW Anarchy Rulz (USA)
      @"SLES-02535" : @4, // ECW Hardcore Revolution (Europe) (v1.0) / (v1.1)
      @"SLES-02536" : @4, // ECW Hardcore Revolution (Germany) (v1.0) / (v1.1)
      @"SLUS-01045" : @4, // ECW Hardcore Revolution (USA)
      @"SLUS-01186" : @4, // ESPN MLS Gamenight (USA)
      @"SLES-03082" : @4, // European Super League (Europe) (En,Fr,De,Es,It,Pt)
      @"SLES-02142" : @4, // F.A. Premier League Stars, The (Europe)
      @"SLES-02143" : @4, // Bundesliga Stars 2000 (Germany)
      @"SLES-02702" : @4, // Primera Division Stars (Spain)
      @"SLES-03063" : @4, // F.A. Premier League Stars 2001, The (Europe)
      @"SLES-03064" : @4, // LNF Stars 2001 (France)
      @"SLES-03065" : @4, // Bundesliga Stars 2001 (Germany)
      @"SLES-00548" : @4, // Fantastic Four (Europe) (En,Fr,De,Es,It)
      @"SLPS-01034" : @4, // Fantastic Four (Japan)
      @"SLUS-00395" : @4, // Fantastic Four (USA)
      @"SLPS-02065" : @4, // Fire Pro Wrestling G (Japan) (v1.0)
      @"SLPS-02817" : @4, // Fire Pro Wrestling G (Japan) (v1.1)
      @"SLUS-00635" : @4, // FOX Sports Soccer '99 (USA) (En,Es)
      @"SLES-00704" : @4, // Frogger (Europe) (En,Fr,De,Es,It)
      @"SLPS-01399" : @4, // Frogger (Japan)
      @"SLUS-00506" : @4, // Frogger (USA)
      @"SLES-02853" : @4, // Frogger 2 - Swampy's Revenge (Europe) (En,Fr,De,It)
      @"SLUS-01172" : @4, // Frogger 2 - Swampy's Revenge (USA)
      @"SCES-00269" : @4, // Galaxian^3 (Europe)
      @"SLPS-00270" : @4, // Galaxian^3 (Japan)
      @"SLES-01241" : @4, // Gekido - Urban Fighters (Europe) (En,Fr,De,Es,It)
      @"SLUS-00970" : @4, // Gekido - Urban Fighters (USA)
      @"SLPM-86761" : @4, // Simple 1500 Series Vol. 60 - The Table Hockey (Japan)
      @"SLPS-03362" : @4, // Simple Character 2000 Series Vol. 05 - High School Kimengumi - The Table Hockey (Japan)
      @"SLES-01041" : @4, // Hogs of War (Europe)
      @"SLUS-01195" : @4, // Hogs of War (USA)
      @"SCES-00983" : @4, // Everybody's Golf (Europe) (En,Fr,De,Es,It)
      @"SCPS-10042" : @4, // Minna no Golf (Japan)
      @"SCUS-94188" : @4, // Hot Shots Golf (USA)
      @"SCES-02146" : @4, // Everybody's Golf 2 (Europe)
      @"SCPS-10093" : @4, // Minna no Golf 2 (Japan) (v1.0)
      @"SCUS-94476" : @4, // Hot Shots Golf 2 (USA)
      @"SLES-03595" : @4, // Hot Wheels - Extreme Racing (Europe)
      @"SLUS-01293" : @4, // Hot Wheels - Extreme Racing (USA)
      @"SLPM-86651" : @4, // Hunter X Hunter - Maboroshi no Greed Island (Japan)
      @"SLES-00309" : @4, // Hyper Tennis - Final Match (Europe)
      @"SLES-00309" : @4, // Hyper Final Match Tennis (Japan)
      @"SLES-02550" : @4, // International Superstar Soccer (Europe) (En,De)
      @"SLES-03149" : @4, // International Superstar Soccer (Europe) (Fr,Es,It)
      @"SLPM-86317" : @4, // Jikkyou J. League 1999 - Perfect Striker (Japan)
      @"SLES-00511" : @4, // International Superstar Soccer Deluxe (Europe)
      @"SLPM-86538" : @4, // J. League Jikkyou Winning Eleven 2000 (Japan)
      @"SLPM-86668" : @4, // J. League Jikkyou Winning Eleven 2000 2nd (Japan)
      @"SLPM-86835" : @4, // J. League Jikkyou Winning Eleven 2001 (Japan)
      @"SLES-00333" : @4, // International Track & Field (Europe)
      @"SLPM-86002" : @4, // Hyper Olympic in Atlanta (Japan)
      @"SLUS-00238" : @4, // International Track & Field (USA)
      @"SLES-02448" : @4, // International Track & Field 2 (Europe)
      @"SLPM-86482" : @4, // Ganbare! Nippon! Olympic 2000 (Japan)
      @"SLUS-00987" : @4, // International Track & Field 2000 (USA)
      @"SLES-02424" : @4, // ISS Pro Evolution (Europe) (Es,It)
      @"SLES-02095" : @4, // ISS Pro Evolution (Europe) (En,Fr,De) (EDC) / (No EDC)
      @"SLPM-86291" : @4, // World Soccer Jikkyou Winning Eleven 4 (Japan) (v1.0) / (v1.1)
      @"SLUS-01014" : @4, // ISS Pro Evolution (USA)
      @"SLES-03321" : @4, // ISS Pro Evolution 2 (Europe) (En,Fr,De)
      @"SLPM-86600" : @4, // World Soccer Jikkyou Winning Eleven 2000 - U-23 Medal e no Chousen (Japan)
      @"SLPS-00832" : @4, // Iwatobi Penguin Rocky x Hopper (Japan)
      @"SLPS-01283" : @4, // Iwatobi Penguin Rocky x Hopper 2 - Tantei Monogatari (Japan)
      @"SLES-02572" : @4, // TOCA World Touring Cars (Europe) (En,Fr,De)
      @"SLES-02573" : @4, // TOCA World Touring Cars (Europe) (Es,It)
      @"SLPS-02852" : @4, // WTC World Touring Car Championship (Japan)
      @"SLUS-01139" : @4, // Jarrett & Labonte Stock Car Racing (USA)
      @"SLES-03328" : @4, // Jetracer (Europe) (En,Fr,De)
      @"SLPS-00473" : @4, // Jigsaw Island - Japan Graffiti (Japan)
      @"SLPM-86918" : @4, // Jigsaw Island - Japan Graffiti (Japan) (Major Wave Series)
      @"SLES-04089" : @4, // Jigsaw Madness (Europe) (En,Fr,De,Es,It)
      @"SLUS-01509" : @4, // Jigsaw Madness (USA)
      @"SLES-00377" : @4, // Jonah Lomu Rugby (Europe) (En,De,Es,It)
      @"SLES-00611" : @4, // Jonah Lomu Rugby (France)
      @"SLPS-01268" : @4, // Great Rugby Jikkyou '98 - World Cup e no Michi (Japan)
      @"SLES-01061" : @4, // Kick Off World (Europe) (En,Fr)
      @"SLES-01327" : @4, // Kick Off World (Europe) (Es,Nl)
      @"SLES-01062" : @4, // Kick Off World (Germany)
      @"SLES-01328" : @4, // Kick Off World (Greece)
      @"SLES-01063" : @4, // Kick Off World Manager (Italy)
      @"SCES-03922" : @4, // Klonoa - Beach Volleyball (Europe) (En,Fr,De,Es,It)
      @"SLPS-03433" : @4, // Klonoa Beach Volley - Saikyou Team Ketteisen! (Japan)
      @"SLUS-01125" : @4, // Kurt Warner's Arena Football Unleashed (USA)
      @"SLPS-00686" : @4, // Love Game's - Wai Wai Tennis (Japan)
      @"SLES-02272" : @4, // Yeh Yeh Tennis (Europe) (En,Fr,De)
      @"SLPS-02983" : @4, // Love Game's - Wai Wai Tennis 2 (Japan)
      @"SLPM-86899" : @4, // Love Game's -  Wai Wai Tennis Plus (Japan)
      @"SLES-01594" : @4, // Michael Owen's World League Soccer 99 (Europe) (En,Fr,It)
      @"SLES-02499" : @4, // Midnight in Vegas (Europe) (En,Fr,De) (v1.0) / (v1.1)
      @"SLUS-00836" : @4, // Vegas Games 2000 (USA)
      @"SLES-03246" : @4, // Monster Racer (Europe) (En,Fr,De,Es,It,Pt)
      @"SLES-03813" : @4, // Monte Carlo Games Compendium (Europe) (Disc 1)
      @"SLES-13813" : @4, // Monte Carlo Games Compendium (Europe) (Disc 2)
      @"SLES-00945" : @4, // Monopoly (Europe) (En,Fr,De,Es,Nl) (v1.0) / (v1.1)
      @"SLPS-00741" : @4, // Monopoly (Japan)
      @"SLES-00310" : @4, // Motor Mash (Europe) (En,Fr,De)
      @"SCES-03085" : @4, // Ms. Pac-Man Maze Madness (Europe) (En,Fr,De,Es,It)
      @"SLPS-03000" : @4, // Ms. Pac-Man Maze Madness (Japan)
      @"SLUS-01018" : @4, // Ms. Pac-Man Maze Madness (USA) (v1.0) / (v1.1)
      @"SLES-02224" : @4, // Music 2000 (Europe) (En,Fr,De,Es,It)
      @"SLUS-01006" : @4, // MTV Music Generator (USA)
      @"SLES-00999" : @4, // Nagano Winter Olympics '98 (Europe)
      @"SLPM-86056" : @4, // Hyper Olympic in Nagano (Japan)
      @"SLUS-00591" : @4, // Nagano Winter Olympics '98 (USA)
      @"SLUS-00329" : @4, // NBA Hangtime (USA)
      @"SLES-00529" : @4, // NBA Jam Extreme (Europe)
      @"SLPS-00699" : @4, // NBA Jam Extreme (Japan)
      @"SLUS-00388" : @4, // NBA Jam Extreme (USA)
      @"SLES-00068" : @4, // NBA Jam - Tournament Edition (Europe)
      @"SLPS-00199" : @4, // NBA Jam - Tournament Edition (Japan)
      @"SLUS-00002" : @4, // NBA Jam - Tournament Edition (USA)
      @"SLES-02336" : @4, // NBA Showtime - NBA on NBC (Europe)
      @"SLUS-00948" : @4, // NBA Showtime - NBA on NBC (USA)
      @"SLES-02689" : @4, // Need for Speed - Porsche 2000 (Europe) (En,De,Sv)
      @"SLES-02700" : @4, // Need for Speed - Porsche 2000 (Europe) (Fr,Es,It)
      @"SLUS-01104" : @4, // Need for Speed - Porsche Unleashed (USA)
      @"SLES-01907" : @4, // V-Rally - Championship Edition 2 (Europe) (En,Fr,De)
      @"SLPS-02516" : @4, // V-Rally - Championship Edition 2 (Japan)
      @"SLUS-01003" : @4, // Need for Speed - V-Rally 2 (USA)
      @"SLES-02335" : @4, // NFL Blitz 2000 (Europe)
      @"SLUS-00861" : @4, // NFL Blitz 2000 (USA)
      @"SLUS-01146" : @4, // NFL Blitz 2001 (USA)
      @"SLUS-00327" : @4, // NHL Open Ice - 2 on 2 Challenge (USA)
      @"SLES-00113" : @4, // Olympic Soccer (Europe) (En,Fr,De,Es,It)
      @"SLPS-00523" : @4, // Olympic Soccer (Japan)
      @"SLUS-00156" : @4, // Olympic Soccer (USA)
      @"SLPS-03056" : @4, // Oshigoto-shiki Jinsei Game - Mezase Shokugyou King (Japan)
      @"SLPS-00899" : @4, // Panzer Bandit (Japan)
      @"SLPM-86016" : @4, // Paro Wars (Japan)
      @"SLUS-01130" : @4, // Peter Jacobsen's Golden Tee Golf (USA)
      @"SLES-00201" : @4, // Pitball (Europe) (En,Fr,De,Es,It)
      @"SLPS-00607" : @4, // Pitball (Japan)
      @"SLUS-00146" : @4, // Pitball (USA)
      @"SLUS-01033" : @4, // Polaris SnoCross (USA)
      @"SLES-02020" : @4, // Pong (Europe) (En,Fr,De,Es,It,Nl)
      @"SLUS-00889" : @4, // Pong - The Next Level (USA)
      @"SLUS-01445" : @4, // Power Play - Sports Trivia (USA)
      @"SLES-02808" : @4, // Beach Volleyball (Europe) (En,Fr,De,Es,It)
      @"SLUS-01196" : @4, // Power Spike - Pro Beach Volleyball (USA)
      @"SLES-00785" : @4, // Poy Poy (Europe)
      @"SLPM-86034" : @4, // Poitters' Point (Japan)
      @"SLUS-00486" : @4, // Poy Poy (USA)
      @"SLES-01536" : @4, // Poy Poy 2 (Europe)
      @"SLPM-86061" : @4, // Poitters' Point 2 - Sodom no Inbou
      @"SLES-01544" : @4, // Premier Manager Ninety Nine (Europe)
      @"SLES-01864" : @4, // Premier Manager Novanta Nove (Italy)
      @"SLES-02292" : @4, // Premier Manager 2000 (Europe)
      @"SLES-02293" : @4, // Canal+ Premier Manager (Europe) (Fr,Es,It)
      @"SLES-02563" : @4, // Anstoss - Premier Manager (Germany)
      @"SLES-00738" : @4, // Premier Manager 98 (Europe)
      @"SLES-01284" : @4, // Premier Manager 98 (Italy)
      @"SLES-03795" : @4, // Pro Evolution Soccer (Europe) (En,Fr,De)
      @"SLES-03796" : @4, // Pro Evolution Soccer (Europe) (Es,It)
      @"SLES-03946" : @4, // Pro Evolution Soccer 2 (Europe) (En,Fr,De)
      @"SLES-03957" : @4, // Pro Evolution Soccer 2 (Europe) (Es,It)
      @"SLPM-87056" : @4, // World Soccer Winning Eleven 2002 (Japan)
      @"SLPS-01006" : @4, // Pro Wres Sengokuden - Hyper Tag Match (Japan)
      @"SLPM-86868" : @4, // Simple 1500 Series Vol. 69 - The Putter Golf (Japan)
      @"SLUS-01371" : @4, // Putter Golf (USA)
      @"SLPS-03114" : @4, // Puyo Puyo Box (Japan)
      @"SLUS-00757" : @4, // Quake II (USA)
      @"SLPS-02909" : @4, // Simple 1500 Series Vol. 34 - The Quiz Bangumi (Japan)
      @"SLPS-03384" : @4, // Nice Price Series Vol. 06 - Quiz de Battle (Japan)
      @"SLES-03511" : @4, // Rageball (Europe)
      @"SLUS-01461" : @4, // Rageball (USA)
      @"SLPM-86272" : @4, // Rakugaki Showtime
      @"SCES-00408" : @4, // Rally Cross (Europe)
      @"SIPS-60022" : @4, // Rally Cross (Japan)
      @"SCUS-94308" : @4, // Rally Cross (USA)
      @"SLES-01103" : @4, // Rat Attack (Europe) (En,Fr,De,Es,It,Nl)
      @"SLUS-00656" : @4, // Rat Attack! (USA)
      @"SLES-00707" : @4, // Risk (Europe) (En,Fr,De,Es)
      @"SLUS-00616" : @4, // Risk - The Game of Global Domination (USA)
      @"SLES-02552" : @4, // Road Rash - Jailbreak (Europe) (En,Fr,De)
      @"SLUS-01053" : @4, // Road Rash - Jailbreak (USA)
      @"SCES-01630" : @4, // Running Wild (Europe)
      @"SCUS-94272" : @4, // Running Wild (USA)
      @"SLES-00217" : @4, // Sampras Extreme Tennis (Europe) (En,Fr,De,Es,It)
      @"SLPS-00594" : @4, // Sampras Extreme Tennis (Japan)
      @"SLES-01286" : @4, // S.C.A.R.S. (Europe) (En,Fr,De,Es,It)
      @"SLUS-00692" : @4, // S.C.A.R.S. (USA)
      @"SLES-03642" : @4, // Scrabble (Europe) (En,De,Es)
      @"SLUS-00903" : @4, // Scrabble (USA)
      @"SLPS-02912" : @4, // SD Gundam - G Generation-F (Japan) (Disc 1)
      @"SLPS-02913" : @4, // SD Gundam - G Generation-F (Japan) (Disc 2)
      @"SLPS-02914" : @4, // SD Gundam - G Generation-F (Japan) (Disc 3)
      @"SLPS-02915" : @4, // SD Gundam - G Generation-F (Japan) (Premium Disc)
      @"SLPS-03195" : @4, // SD Gundam - G Generation-F.I.F (Japan)
      @"SLPS-00785" : @4, // SD Gundam - GCentury (Japan) (v1.0) / (v1.1)
      @"SLPS-01560" : @4, // SD Gundam - GGeneration (Japan) (v1.0) / (v1.1)
      @"SLPS-01561" : @4, // SD Gundam - GGeneration (Premium Disc) (Japan)
      @"SLPS-02200" : @4, // SD Gundam - GGeneration-0 (Japan) (Disc 1) (v1.0)
      @"SLPS-02201" : @4, // SD Gundam - GGeneration-0 (Japan) (Disc 2) (v1.0)
      @"SLPS-00637" : @4, // Shin Nihon Pro Wrestling - Toukon Retsuden 2 (Japan)
      @"SLPS-01366" : @4, // Shin Nihon Pro Wrestling - Toukon Retsuden 3 (Japan)
      @"SLPS-01314" : @4, // Shin Nihon Pro Wrestling - Toukon Retsuden 3 (Japan) (Antonio Inoki Intai Kinen Genteiban)
      @"SLES-03776" : @4, // Sky Sports Football Quiz (Europe)
      @"SLES-03856" : @4, // Sky Sports Football Quiz - Season 02 (Europe)
      @"SLES-00076" : @4, // Slam 'n Jam '96 featuring Magic & Kareem (Europe)
      @"SLPS-00426" : @4, // Magic Johnson to Kareem Abdul-Jabbar no Slam 'n Jam '96 (Japan)
      @"SLUS-00022" : @4, // Slam 'n Jam '96 featuring Magic & Kareem (USA)
      @"SLES-02194" : @4, // Sled Storm (Europe) (En,Fr,De,Es)
      @"SLUS-00955" : @4, // Sled Storm (USA)
      @"SLES-01972" : @4, // South Park - Chef's Luv Shack (Europe)
      @"SLUS-00997" : @4, // South Park - Chef's Luv Shack (USA)
      @"SCES-01763" : @4, // Speed Freaks (Europe)
      @"SCUS-94563" : @4, // Speed Punks (USA)
      @"SLES-00023" : @4, // Striker 96 (Europe) (v1.0)
      @"SLPS-00127" : @4, // Striker - World Cup Premiere Stage (Japan)
      @"SLUS-00210" : @4, // Striker 96 (USA)
      @"SLES-01733" : @4, // UEFA Striker (Europe) (En,Fr,De,Es,It,Nl)
      @"SLUS-01078" : @4, // Striker Pro 2000 (USA)
      @"SLPS-01264" : @4, // Suchie-Pai Adventure - Doki Doki Nightmare (Japan) (Disc 1)
      @"SLPS-01265" : @4, // Suchie-Pai Adventure - Doki Doki Nightmare (Japan) (Disc 2)
      @"SLES-00213" : @4, // Syndicate Wars (Europe) (En,Fr,Es,It,Sv)
      @"SLES-00212" : @4, // Syndicate Wars (Germany)
      @"SLUS-00262" : @4, // Syndicate Wars (USA)
      @"SLPS-01100" : @4, // Tales of Destiny (Japan) (v1.0) / (v1.1)
      @"SLUS-00626" : @4, // Tales of Destiny (USA)
      @"SLPS-03050" : @4, // Tales of Eternia (Japan) (Disc 1)
      @"SLPS-03051" : @4, // Tales of Eternia (Japan) (Disc 2)
      @"SLPS-03052" : @4, // Tales of Eternia (Japan) (Disc 3)
      @"SLUS-01355" : @4, // Tales of Destiny II (USA) (Disc 1)
      @"SLUS-01367" : @4, // Tales of Destiny II (USA) (Disc 2)
      @"SLUS-01368" : @4, // Tales of Destiny II (USA) (Disc 3)
      @"SLPS-01770" : @4, // Tales of Phantasia (Japan)
      @"SCES-01923" : @4, // Team Buddies (Europe) (En,Fr,De)
      @"SLUS-00869" : @4, // Team Buddies (USA)
      @"SLES-00935" : @4, // Tennis Arena (Europe) (En,Fr,De,Es,It)
      @"SLPS-01303" : @4, // Tennis Arena (Japan)
      @"SLUS-00596" : @4, // Tennis Arena (USA)
      @"SLPS-00321" : @4, // Tetris X (Japan)
      @"SLES-01675" : @4, // Tiger Woods 99 USA Tour Golf (Australia)
      @"SLES-01674" : @4, // Tiger Woods 99 PGA Tour Golf (Europe) (En,Fr,De,Es,Sv)
      @"SLPS-02012" : @4, // Tiger Woods 99 PGA Tour Golf (Japan)
      @"SLUS-00785" : @4, // Tiger Woods 99 PGA Tour Golf (USA) (v1.0) / (v1.1)
      @"SLES-03337" : @4, // Tiger Woods USA Tour 2001 (Australia)
      @"SLES-03148" : @4, // Tiger Woods PGA Tour Golf (Europe)
      @"SLUS-01273" : @4, // Tiger Woods PGA Tour Golf (USA)
      @"SLES-02595" : @4, // Tiger Woods USA Tour 2000 (Australia)
      @"SLES-02551" : @4, // Tiger Woods PGA Tour 2000 (Europe) (En,Fr,De,Es,Sv)
      @"SLUS-01054" : @4, // Tiger Woods PGA Tour 2000 (USA)
      @"SLUS-00752" : @4, // Thrill Kill (USA) (Unreleased)
      @"SLPS-01113" : @4, // Toshinden Card Quest (Japan)
      @"SLES-00256" : @4, // Trash It (Europe) (En,Fr,De,Es,It)
      @"SCUS-94249" : @4, // Twisted Metal III (USA) (v1.0) / (v1.1)
      @"SCUS-94560" : @4, // Twisted Metal 4 (USA)
      @"SLES-02806" : @4, // UEFA Challenge (Europe) (En,Fr,De,Nl)
      @"SLES-02807" : @4, // UEFA Challenge (Europe) (Fr,Es,It,Pt)
      @"SLES-01622" : @4, // UEFA Champions League - Season 1998-99 (Europe)
      @"SLES-01745" : @4, // UEFA Champions League - Saison 1998-99 (Germany)
      @"SLES-01746" : @4, // UEFA Champions League - Stagione 1998-99 (Italy)
      @"SLES-02918" : @4, // Vegas Casino (Europe)
      @"SLPS-00467" : @4, // Super Casino Special (Japan)
      @"SLES-00761" : @4, // Viva Football (Europe) (En,Fr,De,Es,It,Pt)
      @"SLES-01341" : @4, // Absolute Football (France) (En,Fr,De,Es,It,Pt)
      @"SLUS-00953" : @4, // Viva Soccer (USA) (En,Fr,De,Es,It,Pt)
      @"SLES-02193" : @4, // WCW Mayhem (Europe)
      @"SLUS-00963" : @4, // WCW Mayhem (USA)
      @"SLES-03806" : @4, // Westlife - Fan-O-Mania (Europe)
      @"SLES-03779" : @4, // Westlife - Fan-O-Mania (Europe) (Fr,De)
      @"SLES-00717" : @4, // World League Soccer '98 (Europe) (En,Es,It)
      @"SLES-01166" : @4, // World League Soccer '98 (France)
      @"SLES-01167" : @4, // World League Soccer '98 (Germany)
      @"SLPS-01389" : @4, // World League Soccer (Japan)
      @"SLES-02170" : @4, // Wu-Tang - Taste the Pain (Europe)
      @"SLES-02171" : @4, // Wu-Tang - Shaolin Style (France)
      @"SLES-02172" : @4, // Wu-Tang - Shaolin Style (Germany)
      @"SLUS-00929" : @4, // Wu-Tang - Shaolin Style (USA)
      @"SLES-01980" : @4, // WWF Attitude (Europe)
      @"SLES-02255" : @4, // WWF Attitude (Germany)
      @"SLUS-00831" : @4, // WWF Attitude (USA)
      @"SLES-00286" : @4, // WWF In Your House (Europe)
      @"SLPS-00695" : @4, // WWF In Your House (Japan)
      @"SLUS-00246" : @4, // WWF In Your House (USA) (v1.0) / (v1.1)
      @"SLES-02619" : @4, // WWF SmackDown! (Europe)
      @"SLPS-02885" : @4, // Exciting Pro Wres (Japan)
      @"SLUS-00927" : @4, // WWF SmackDown! (USA)
      @"SLES-03251" : @4, // WWF SmackDown! 2 - Know Your Role (Europe)
      @"SLPS-03122" : @4, // Exciting Pro Wres 2 (Japan)
      @"SLUS-01234" : @4, // WWF SmackDown! 2 - Know Your Role (USA)
      @"SLES-00804" : @4, // WWF War Zone (Europe)
      @"SLUS-00495" : @4, // WWF War Zone (USA) (v1.0) / (v1.1)
      @"SLPS-01849" : @4, // Zen Nihon Pro Wres - Ouja no Tamashii (Japan)
      @"SLPS-02934" : @4, // Zen Nihon Pro Wres - Ouja no Tamashii (Japan) (Reprint)
      @"SLES-01893" : @5, // Bomberman (Europe)
      @"SLPS-01717" : @5, // Bomberman (Japan)
      @"SLUS-01189" : @5, // Bomberman - Party Edition (USA)
      @"SCES-01078" : @5, // Bomberman World (Europe) (En,Fr,De,Es,It)
      @"SLPS-01155" : @5, // Bomberman World (Japan)
      @"SLUS-00680" : @5, // Bomberman World (USA)
      @"SCES-01312" : @5, // Devil Dice (Europe) (En,Fr,De,Es,It)
      @"SCPS-10051" : @5, // XI [sai] (Japan) (En,Ja)
      @"SLUS-00672" : @5, // Devil Dice (USA)
      @"SLPS-02943" : @5, // DX Monopoly (Japan)
      @"SLES-00865" : @5, // Overboard! (Europe)
      @"SLUS-00558" : @5, // Shipwreckers! (USA)
      @"SLES-01376" : @6, // Brunswick Circuit Pro Bowling (Europe)
      @"SLUS-00571" : @6, // Brunswick Circuit Pro Bowling (USA)
      @"SLUS-00769" : @6, // Game of Life, The (USA)
      @"SLES-03362" : @6, // NBA Hoopz (Europe) (En,Fr,De)
      @"SLUS-01331" : @6, // NBA Hoopz (USA)
      @"SLES-00313" : @6, // NHL Powerplay (Europe)
      @"SLPS-00595" : @6, // NHL Powerplay '96 (Japan)
      @"SLUS-00227" : @6, // NHL Powerplay '96 (USA)
      @"SLES-00284" : @6, // Space Jam (Europe)
      @"SLPS-00697" : @6, // Space Jam (Japan)
      @"SLUS-00243" : @6, // Space Jam (USA)
      @"SLES-00534" : @6, // Ten Pin Alley (Europe)
      @"SLUS-00377" : @6, // Ten Pin Alley (USA)
      @"SLPS-01243" : @6, // Tenant Wars (Japan)
      @"SLPM-86240" : @6, // SuperLite 1500 Series - Tenant Wars Alpha - SuperLite 1500 Version (Japan)
      @"SLUS-01333" : @6, // Board Game - Top Shop (USA)
      @"SLES-03830" : @8, // 2002 FIFA World Cup Korea Japan (Europe) (En,Sv)
      @"SLES-03831" : @8, // Coupe du Monde FIFA 2002 (France)
      @"SLES-03832" : @8, // 2002 FIFA World Cup Korea Japan (Germany)
      @"SLES-03833" : @8, // 2002 FIFA World Cup Korea Japan (Italy)
      @"SLES-03834" : @8, // 2002 FIFA World Cup Korea Japan (Spain)
      @"SLUS-01449" : @8, // 2002 FIFA World Cup (USA) (En,Es)
      @"SLES-01210" : @8, // Actua Soccer 3 (Europe)
      @"SLES-01644" : @8, // Actua Soccer 3 (France)
      @"SLES-01645" : @8, // Actua Soccer 3 (Germany)
      @"SLES-01646" : @8, // Actua Soccer 3 (Italy)
      @"SLPM-86044" : @8, // Break Point (Japan)
      @"SLES-02618" : @8, // Brunswick Circuit Pro Bowling 2 (Europe)
      @"SLUS-00856" : @8, // Brunswick Circuit Pro Bowling 2 (USA)
      @"SCUS-94156" : @8, // Cardinal Syn (USA)
      @"SLES-02948" : @8, // Chris Kamara's Street Soccer (Europe)
      @"SLES-00080" : @8, // Supersonic Racers (Europe) (En,Fr,De,Es,It)
      @"SLPS-01025" : @8, // Dare Devil Derby 3D (Japan)
      @"SLUS-00300" : @8, // Dare Devil Derby 3D (USA)
      @"SLES-00116" : @8, // FIFA Soccer 96 (Europe) (En,Fr,De,Es,It,Sv)
      @"SLUS-00038" : @8, // FIFA Soccer 96 (USA)
      @"SLES-00504" : @8, // FIFA 97 (Europe) (En,Fr,De,Es,It,Sv)
      @"SLES-00505" : @8, // FIFA 97 (France) (En,Fr,De,Es,It,Sv)
      @"SLES-00506" : @8, // FIFA 97 (Germany) (En,Fr,De,Es,It,Sv)
      @"SLPS-00878" : @8, // FIFA Soccer 97 (Japan)
      @"SLUS-00269" : @8, // FIFA Soccer 97 (USA)
      @"SLES-00914" : @8, // FIFA - Road to World Cup 98 (Europe) (En,Fr,De,Es,Nl,Sv)
      @"SLES-00915" : @8, // FIFA - En Route pour la Coupe du Monde 98 (France) (En,Fr,De,Es,Nl,Sv)
      @"SLES-00916" : @8, // FIFA - Die WM-Qualifikation 98 (Germany) (En,Fr,De,Es,Nl,Sv)
      @"SLES-00917" : @8, // FIFA - Road to World Cup 98 (Italy)
      @"SLPS-01383" : @8, // FIFA - Road to World Cup 98 (Japan)
      @"SLES-00918" : @8, // FIFA - Rumbo al Mundial 98 (Spain) (En,Fr,De,Es,Nl,Sv)
      @"SLUS-00520" : @8, // FIFA - Road to World Cup 98 (USA) (En,Fr,De,Es,Nl,Sv)
      @"SLES-01584" : @8, // FIFA 99 (Europe) (En,Fr,De,Es,Nl,Sv)
      @"SLES-01585" : @8, // FIFA 99 (France) (En,Fr,De,Es,Nl,Sv)
      @"SLES-01586" : @8, // FIFA 99 (Germany) (En,Fr,De,Es,Nl,Sv)
      @"SLES-01587" : @8, // FIFA 99 (Italy)
      @"SLPS-02309" : @8, // FIFA 99 - Europe League Soccer (Japan)
      @"SLES-01588" : @8, // FIFA 99 (Spain) (En,Fr,De,Es,Nl,Sv)
      @"SLUS-00782" : @8, // FIFA 99 (USA)
      @"SLES-02315" : @8, // FIFA 2000 (Europe) (En,De,Es,Nl,Sv) (v1.0) / (v1.1)
      @"SLES-02316" : @8, // FIFA 2000 (France)
      @"SLES-02317" : @8, // FIFA 2000 (Germany) (En,De,Es,Nl,Sv)
      @"SLES-02320" : @8, // FIFA 2000 (Greece)
      @"SLES-02319" : @8, // FIFA 2000 (Italy)
      @"SLPS-02675" : @8, // FIFA 2000 - Europe League Soccer (Japan)
      @"SLES-02318" : @8, // FIFA 2000 (Spain) (En,De,Es,Nl,Sv)
      @"SLUS-00994" : @8, // FIFA 2000 - Major League Soccer (USA) (En,De,Es,Nl,Sv)
      @"SLES-03140" : @8, // FIFA 2001 (Europe) (En,De,Es,Nl,Sv)
      @"SLES-03141" : @8, // FIFA 2001 (France)
      @"SLES-03142" : @8, // FIFA 2001 (Germany) (En,De,Es,Nl,Sv)
      @"SLES-03143" : @8, // FIFA 2001 (Greece)
      @"SLES-03145" : @8, // FIFA 2001 (Italy)
      @"SLES-03146" : @8, // FIFA 2001 (Spain) (En,De,Es,Nl,Sv)
      @"SLUS-01262" : @8, // FIFA 2001 (USA)
      @"SLES-03666" : @8, // FIFA Football 2002 (Europe) (En,De,Es,Nl,Sv)
      @"SLES-03668" : @8, // FIFA Football 2002 (France)
      @"SLES-03669" : @8, // FIFA Football 2002 (Germany) (En,De,Es,Nl,Sv)
      @"SLES-03671" : @8, // FIFA Football 2002 (Italy)
      @"SLES-03672" : @8, // FIFA Football 2002 (Spain) (En,De,Es,Nl,Sv)
      @"SLUS-01408" : @8, // FIFA Soccer 2002 (USA) (En,Es)
      @"SLES-03977" : @8, // FIFA Football 2003 (Europe) (En,Nl,Sv)
      @"SLES-03978" : @8, // FIFA Football 2003 (France)
      @"SLES-03979" : @8, // FIFA Football 2003 (Germany)
      @"SLES-03980" : @8, // FIFA Football 2003 (Italy)
      @"SLES-03981" : @8, // FIFA Football 2003 (Spain)
      @"SLUS-01504" : @8, // FIFA Soccer 2003 (USA)
      @"SLES-04115" : @8, // FIFA Football 2004 (Europe) (En,Nl,Sv)
      @"SLES-04116" : @8, // FIFA Football 2004 (France)
      @"SLES-04117" : @8, // FIFA Football 2004 (Germany)
      @"SLES-04119" : @8, // FIFA Football 2004 (Italy)
      @"SLES-04118" : @8, // FIFA Football 2004 (Spain)
      @"SLUS-01578" : @8, // FIFA Soccer 2004 (USA) (En,Es)
      @"SLES-04165" : @8, // FIFA Football 2005 (Europe) (En,Nl)
      @"SLES-04166" : @8, // FIFA Football 2005 (France)
      @"SLES-04168" : @8, // FIFA Football 2005 (Germany)
      @"SLES-04167" : @8, // FIFA Football 2005 (Italy)
      @"SLES-04169" : @8, // FIFA Football 2005 (Spain)
      @"SLUS-01585" : @8, // FIFA Soccer 2005 (USA) (En,Es)
      @"SLUS-01129" : @8, // FoxKids.com - Micro Maniacs Racing (USA)
      @"SLES-03084" : @8, // Inspector Gadget - Gadget's Crazy Maze (Europe) (En,Fr,De,Es,It,Nl)
      @"SLUS-01267" : @8, // Inspector Gadget - Gadget's Crazy Maze (USA) (En,Fr,De,Es,It,Nl)
      @"SLUS-00500" : @8, // Jimmy Johnson's VR Football '98 (USA)
      @"SLES-00436" : @8, // Madden NFL 97 (Europe)
      @"SLUS-00018" : @8, // Madden NFL 97 (USA)
      @"SLES-00904" : @8, // Madden NFL 98 (Europe)
      @"SLUS-00516" : @8, // Madden NFL 98 (USA) / (Alt)
      @"SLES-01427" : @8, // Madden NFL 99 (Europe)
      @"SLUS-00729" : @8, // Madden NFL 99 (USA)
      @"SLES-02192" : @8, // Madden NFL 2000 (Europe)
      @"SLUS-00961" : @8, // Madden NFL 2000 (USA)
      @"SLES-03067" : @8, // Madden NFL 2001 (Europe)
      @"SLUS-01241" : @8, // Madden NFL 2001 (USA)
      @"SLUS-01402" : @8, // Madden NFL 2002 (USA)
      @"SLUS-01482" : @8, // Madden NFL 2003 (USA)
      @"SLUS-01570" : @8, // Madden NFL 2004 (USA)
      @"SLUS-01584" : @8, // Madden NFL 2005 (USA)
      @"SLUS-00526" : @8, // March Madness '98 (USA)
      @"SLUS-00559" : @8, // Micro Machines V3 (USA)
      @"SLUS-00507" : @8, // Monopoly (USA)
      @"SLUS-01178" : @8, // Monster Rancher Battle Card - Episode II (USA)
      @"SLES-02299" : @8, // NBA Basketball 2000 (Europe) (En,Fr,De,Es,It)
      @"SLUS-00926" : @8, // NBA Basketball 2000 (USA)
      @"SLES-01003" : @8, // NBA Fastbreak '98 (Europe)
      @"SLUS-00492" : @8, // NBA Fastbreak '98 (USA)
      @"SLES-00171" : @8, // NBA in the Zone (Europe)
      @"SLPS-00188" : @8, // NBA Power Dunkers (Japan)
      @"SLUS-00048" : @8, // NBA in the Zone (USA)
      @"SLES-00560" : @8, // NBA in the Zone 2 (Europe)
      @"SLPM-86011" : @8, // NBA Power Dunkers 2 (Japan)
      @"SLUS-00294" : @8, // NBA in the Zone 2 (USA)
      @"SLES-00882" : @8, // NBA Pro 98 (Europe)
      @"SLPM-86060" : @8, // NBA Power Dunkers 3 (Japan)
      @"SLUS-00445" : @8, // NBA in the Zone '98 (USA) (v1.0) / (v1.1)
      @"SLES-01970" : @8, // NBA Pro 99 (Europe)
      @"SLPM-86176" : @8, // NBA Power Dunkers 4 (Japan)
      @"SLUS-00791" : @8, // NBA in the Zone '99 (USA)
      @"SLES-02513" : @8, // NBA in the Zone 2000 (Europe)
      @"SLPM-86397" : @8, // NBA Power Dunkers 5 (Japan)
      @"SLUS-01028" : @8, // NBA in the Zone 2000 (USA)
      @"SLES-00225" : @8, // NBA Live 96 (Europe)
      @"SLPS-00389" : @8, // NBA Live 96 (Japan)
      @"SLUS-00060" : @8, // NBA Live 96 (USA)
      @"SLES-00517" : @8, // NBA Live 97 (Europe) (En,Fr,De)
      @"SLPS-00736" : @8, // NBA Live 97 (Japan)
      @"SLUS-00267" : @8, // NBA Live 97 (USA)
      @"SLES-00906" : @8, // NBA Live 98 (Europe) (En,Es,It)
      @"SLES-00952" : @8, // NBA Live 98 (Germany)
      @"SLPS-01296" : @8, // NBA Live 98 (Japan)
      @"SLUS-00523" : @8, // NBA Live 98 (USA)
      @"SLES-01446" : @8, // NBA Live 99 (Europe)
      @"SLES-01455" : @8, // NBA Live 99 (Germany)
      @"SLES-01456" : @8, // NBA Live 99 (Italy)
      @"SLPS-02033" : @8, // NBA Live 99 (Japan)
      @"SLES-01457" : @8, // NBA Live 99 (Spain)
      @"SLUS-00736" : @8, // NBA Live 99 (USA)
      @"SLES-02358" : @8, // NBA Live 2000 (Europe)
      @"SLES-02360" : @8, // NBA Live 2000 (Germany)
      @"SLES-02361" : @8, // NBA Live 2000 (Italy)
      @"SLPS-02603" : @8, // NBA Live 2000 (Japan)
      @"SLES-02362" : @8, // NBA Live 2000 (Spain)
      @"SLUS-00998" : @8, // NBA Live 2000 (USA)
      @"SLES-03128" : @8, // NBA Live 2001 (Europe)
      @"SLES-03129" : @8, // NBA Live 2001 (France)
      @"SLES-03130" : @8, // NBA Live 2001 (Germany)
      @"SLES-03131" : @8, // NBA Live 2001 (Italy)
      @"SLES-03132" : @8, // NBA Live 2001 (Spain)
      @"SLUS-01271" : @8, // NBA Live 2001 (USA)
      @"SLES-03718" : @8, // NBA Live 2002 (Europe)
      @"SLES-03719" : @8, // NBA Live 2002 (France)
      @"SLES-03720" : @8, // NBA Live 2002 (Germany)
      @"SLES-03721" : @8, // NBA Live 2002 (Italy)
      @"SLES-03722" : @8, // NBA Live 2002 (Spain)
      @"SLUS-01416" : @8, // NBA Live 2002 (USA)
      @"SLES-03982" : @8, // NBA Live 2003 (Europe)
      @"SLES-03969" : @8, // NBA Live 2003 (France)
      @"SLES-03968" : @8, // NBA Live 2003 (Germany)
      @"SLES-03970" : @8, // NBA Live 2003 (Italy)
      @"SLES-03971" : @8, // NBA Live 2003 (Spain)
      @"SLUS-01483" : @8, // NBA Live 2003 (USA)
      @"SCES-00067" : @8, // Total NBA '96 (Europe)
      @"SIPS-60008" : @8, // Total NBA '96 (Japan)
      @"SCUS-94500" : @8, // NBA Shoot Out (USA)
      @"SCES-00623" : @8, // Total NBA '97 (Europe)
      @"SIPS-60015" : @8, // Total NBA '97 (Japan)
      @"SCUS-94552" : @8, // NBA Shoot Out '97 (USA)
      @"SCES-01079" : @8, // Total NBA 98 (Europe)
      @"SCUS-94171" : @8, // NBA ShootOut 98 (USA)
      @"SCUS-94561" : @8, // NBA ShootOut 2000 (USA)
      @"SCUS-94581" : @8, // NBA ShootOut 2001 (USA)
      @"SCUS-94641" : @8, // NBA ShootOut 2002 (USA)
      @"SCUS-94673" : @8, // NBA ShootOut 2003 (USA)
      @"SCUS-94691" : @8, // NBA ShootOut 2004 (USA)
      @"SLUS-00142" : @8, // NCAA Basketball Final Four 97 (USA)
      @"SCUS-94264" : @8, // NCAA Final Four 99 (USA)
      @"SCUS-94562" : @8, // NCAA Final Four 2000 (USA)
      @"SCUS-94579" : @8, // NCAA Final Four 2001 (USA)
      @"SLUS-00514" : @8, // NCAA Football 98 (USA)
      @"SLUS-00688" : @8, // NCAA Football 99 (USA)
      @"SLUS-00932" : @8, // NCAA Football 2000 (USA) (v1.0) / (v1.1)
      @"SLUS-01219" : @8, // NCAA Football 2001 (USA)
      @"SCUS-94509" : @8, // NCAA Football GameBreaker (USA)
      @"SCUS-94172" : @8, // NCAA GameBreaker 98 (USA)
      @"SCUS-94246" : @8, // NCAA GameBreaker 99 (USA)
      @"SCUS-94557" : @8, // NCAA GameBreaker 2000 (USA)
      @"SCUS-94573" : @8, // NCAA GameBreaker 2001 (USA)
      @"SLUS-00805" : @8, // NCAA March Madness 99 (USA)
      @"SLUS-01023" : @8, // NCAA March Madness 2000 (USA)
      @"SLUS-01320" : @8, // NCAA March Madness 2001 (USA)
      @"SCES-00219" : @8, // NFL GameDay (Europe)
      @"SCUS-94505" : @8, // NFL GameDay (USA)
      @"SCUS-94510" : @8, // NFL GameDay 97 (USA)
      @"SCUS-94173" : @8, // NFL GameDay 98 (USA)
      @"SCUS-94234" : @8, // NFL GameDay 99 (USA) (v1.0) / (v1.1)
      @"SCUS-94556" : @8, // NFL GameDay 2000 (USA)
      @"SCUS-94575" : @8, // NFL GameDay 2001 (USA)
      @"SCUS-94639" : @8, // NFL GameDay 2002 (USA)
      @"SCUS-94665" : @8, // NFL GameDay 2003 (USA)
      @"SCUS-94690" : @8, // NFL GameDay 2004 (USA)
      @"SCUS-94695" : @8, // NFL GameDay 2005 (USA)
      @"SLES-00449" : @8, // NFL Quarterback Club 97 (Europe)
      @"SLUS-00011" : @8, // NFL Quarterback Club 97 (USA)
      @"SCUS-94420" : @8, // NFL Xtreme 2 (USA)
      @"SLES-00492" : @8, // NHL 97 (Europe)
      @"SLES-00533" : @8, // NHL 97 (Germany)
      @"SLPS-00861" : @8, // NHL 97 (Japan)
      @"SLUS-00030" : @8, // NHL 97 (USA)
      @"SLES-00907" : @8, // NHL 98 (Europe) (En,Sv,Fi)
      @"SLES-00512" : @8, // NHL 98 (Germany)
      @"SLUS-00519" : @8, // NHL 98 (USA)
      @"SLES-01445" : @8, // NHL 99 (Europe) (En,Fr,Sv,Fi)
      @"SLES-01458" : @8, // NHL 99 (Germany)
      @"SLUS-00735" : @8, // NHL 99 (USA)
      @"SLES-02225" : @8, // NHL 2000 (Europe) (En,Sv,Fi)
      @"SLES-02227" : @8, // NHL 2000 (Germany)
      @"SLUS-00965" : @8, // NHL 2000 (USA)
      @"SLES-03139" : @8, // NHL 2001 (Europe) (En,Sv,Fi)
      @"SLES-03154" : @8, // NHL 2001 (Germany)
      @"SLUS-01264" : @8, // NHL 2001 (USA)
      @"SLES-02514" : @8, // NHL Blades of Steel 2000 (Europe)
      @"SLPM-86193" : @8, // NHL Blades of Steel 2000 (Japan)
      @"SLUS-00825" : @8, // NHL Blades of Steel 2000 (USA)
      @"SLES-00624" : @8, // NHL Breakaway 98 (Europe)
      @"SLUS-00391" : @8, // NHL Breakaway 98 (USA)
      @"SLES-02298" : @8, // NHL Championship 2000 (Europe) (En,Fr,De,Sv)
      @"SLUS-00925" : @8, // NHL Championship 2000 (USA)
      @"SCES-00392" : @8, // NHL Face Off '97 (Europe)
      @"SIPS-60018" : @8, // NHL PowerRink '97 (Japan)
      @"SCUS-94550" : @8, // NHL Face Off '97 (USA)
      @"SCES-01022" : @8, // NHL FaceOff 98 (Europe)
      @"SCUS-94174" : @8, // NHL FaceOff 98 (USA)
      @"SCES-01736" : @8, // NHL FaceOff 99 (Europe)
      @"SCUS-94235" : @8, // NHL FaceOff 99 (USA)
      @"SCES-02451" : @8, // NHL FaceOff 2000 (Europe)
      @"SCUS-94558" : @8, // NHL FaceOff 2000 (USA)
      @"SCUS-94577" : @8, // NHL FaceOff 2001 (USA)
      @"SLES-00418" : @8, // NHL Powerplay 98 (Europe) (En,Fr,De)
      @"SLUS-00528" : @8, // NHL Powerplay 98 (USA) (En,Fr,De)
      @"SLES-00110" : @8, // Olympic Games (Europe) (En,Fr,De,Es,It)
      @"SLPS-00465" : @8, // Atlanta Olympics '96
      @"SLUS-00148" : @8, // Olympic Summer Games (USA)
      @"SLES-01559" : @8, // Pro 18 - World Tour Golf (Europe) (En,Fr,De,Es,It,Sv)
      @"SLUS-00817" : @8, // Pro 18 - World Tour Golf (USA)
      @"SLES-00472" : @8, // Riot (Europe)
      @"SCUS-94551" : @8, // Professional Underground League of Pain (USA)
      @"SLES-01203" : @8, // Puma Street Soccer (Europe) (En,Fr,De,It)
      @"SLES-01436" : @8, // Rival Schools - United by Fate (Europe) (Disc 1) (Evolution Disc)
      @"SLES-11436" : @8, // Rival Schools - United by Fate (Europe) (Disc 2) (Arcade Disc)
      @"SLPS-01240" : @8, // Shiritsu Justice Gakuen - Legion of Heroes (Japan) (Disc 1) (Evolution Disc)
      @"SLPS-01241" : @8, // Shiritsu Justice Gakuen - Legion of Heroes (Japan) (Disc 2) (Arcade Disc)
      @"SLPS-02120" : @8, // Shiritsu Justice Gakuen - Nekketsu Seishun Nikki 2 (Japan)
      @"SLES-01658" : @8, // Shaolin (Europe)
      @"SLPS-02168" : @8, // Lord of Fist (Japan)
      @"SLES-00296" : @8, // Street Racer (Europe)
      @"SLPS-00610" : @8, // Street Racer Extra (Japan)
      @"SLUS-00099" : @8, // Street Racer (USA)
      @"SLES-02857" : @8, // Sydney 2000 (Europe)
      @"SLES-02858" : @8, // Sydney 2000 (France)
      @"SLES-02859" : @8, // Sydney 2000 (Germany)
      @"SLPM-86626" : @8, // Sydney 2000 (Japan)
      @"SLES-02861" : @8, // Sydney 2000 (Spain)
      @"SLUS-01177" : @8, // Sydney 2000 (USA)
      @"SCES-01700" : @8, // This Is Football (Europe)
      @"SCES-01882" : @8, // This Is Football (Europe) (Fr,Nl)
      @"SCES-01701" : @8, // Monde des Bleus, Le - Le jeu officiel de l'equipe de France (France)
      @"SCES-01702" : @8, // Fussball Live (Germany)
      @"SCES-01703" : @8, // This Is Football (Italy)
      @"SCES-01704" : @8, // Esto es Futbol (Spain)
      @"SCES-03070" : @8, // This Is Football 2 (Europe)
      @"SCES-03073" : @8, // Monde des Bleus 2, Le (France)
      @"SCES-03074" : @8, // Fussball Live 2 (Germany)
      @"SCES-03075" : @8, // This Is Football 2 (Italy)
      @"SCES-03072" : @8, // This Is Football 2 (Netherlands)
      @"SCES-03076" : @8, // Esto es Futbol 2 (Spain)
      @"SLPS-00682" : @8, // Triple Play 97 (Japan)
      @"SLUS-00237" : @8, // Triple Play 97 (USA)
      @"SLPS-00887" : @8, // Triple Play 98 (Japan)
      @"SLUS-00465" : @8, // Triple Play 98 (USA)
      @"SLUS-00618" : @8, // Triple Play 99 (USA) (En,Es)
      @"SLES-02577" : @8, // UEFA Champions League - Season 1999-2000 (Europe)
      @"SLES-02578" : @8, // UEFA Champions League - Season 1999-2000 (France)
      @"SLES-02579" : @8, // UEFA Champions League - Season 1999-2000 (Germany)
      @"SLES-02580" : @8, // UEFA Champions League - Season 1999-2000 (Italy)
      @"SLES-03262" : @8, // UEFA Champions League - Season 2000-2001 (Europe)
      @"SLES-03281" : @8, // UEFA Champions League - Season 2000-2001 (Germany)
      @"SLES-02704" : @8, // UEFA Euro 2000 (Europe)
      @"SLES-02705" : @8, // UEFA Euro 2000 (France)
      @"SLES-02706" : @8, // UEFA Euro 2000 (Germany)
      @"SLES-02707" : @8, // UEFA Euro 2000 (Italy)
      @"SLES-01265" : @8, // World Cup 98 (Europe) (En,Fr,De,Es,Nl,Sv,Da)
      @"SLES-01266" : @8, // Coupe du Monde 98 (France)
      @"SLES-01267" : @8, // Frankreich 98 - Die Fussball-WM (Germany) (En,Fr,De,Es,Nl,Sv,Da)
      @"SLES-01268" : @8, // World Cup 98 - Coppa del Mondo (Italy)
      @"SLPS-01719" : @8, // FIFA World Cup 98 - France 98 Soushuuhen (Japan)
      @"SLUS-00644" : @8, // World Cup 98 (USA)
      };

    // 5-player-or-less games requiring Multitap on port 2 instead of port 1
    NSArray<NSString *> *psxMultiTap5PlayerPort2 =
    @[
      @"SLES-01893", // Bomberman (Europe)
      @"SLPS-01717", // Bomberman (Japan)
      @"SLUS-01189", // Bomberman - Party Edition (USA)
      @"SLPS-00473", // Jigsaw Island - Japan Graffiti (Japan)
      @"SLPM-86918", // Jigsaw Island - Japan Graffiti (Japan) (Major Wave Series)
      @"SLES-04089", // Jigsaw Madness (Europe) (En,Fr,De,Es,It)
      @"SLUS-01509", // Jigsaw Madness (USA)
      @"SLES-01286", // S.C.A.R.S. (Europe) (En,Fr,De,Es,It)
      @"SLUS-00692", // S.C.A.R.S. (USA)
      @"SLPS-01849", // Zen Nihon Pro Wres - Ouja no Tamashii (Japan)
      @"SLPS-02934", // Zen Nihon Pro Wres - Ouja no Tamashii (Japan) (Reprint)
      ];

    // PlayStation multi-disc games (mostly complete, few missing obscure undumped/unverified JP releases)
    NSDictionary<NSString *, NSNumber *> *psxMultiDiscGames =
    @{
      @"SLPS-00071" : @2, // 3x3 Eyes - Kyuusei Koushu (Japan) (Disc 1)
      @"SLPS-00072" : @2, // 3x3 Eyes - Kyuusei Koushu (Japan) (Disc 2)
      @"SLPS-01497" : @3, // 3x3 Eyes - Tenrinou Genmu (Japan) (Disc 1)
      @"SLPS-01498" : @3, // 3x3 Eyes - Tenrinou Genmu (Japan) (Disc 2)
      @"SLPS-01499" : @3, // 3x3 Eyes - Tenrinou Genmu (Japan) (Disc 3)
      @"SLUS-01037" : @3, // Baldur's Gate (USA) (Disc 1 - 3) (Unreleased)
      @"SLPS-01995" : @4, // 70's Robot Anime - Geppy-X - The Super Boosted Armor (Japan) (Disc 1)
      @"SLPS-01996" : @4, // 70's Robot Anime - Geppy-X - The Super Boosted Armor (Japan) (Disc 2)
      @"SLPS-01997" : @4, // 70's Robot Anime - Geppy-X - The Super Boosted Armor (Japan) (Disc 3)
      @"SLPS-01998" : @4, // 70's Robot Anime - Geppy-X - The Super Boosted Armor (Japan) (Disc 4)
      @"SCES-02153" : @2, // A Sangre Fria (Spain) (Disc 1)
      @"SCES-12153" : @2, // A Sangre Fria (Spain) (Disc 2)
      @"SCES-02152" : @2, // A Sangue Freddo (Italy) (Disc 1)
      @"SCES-12152" : @2, // A Sangue Freddo (Italy) (Disc 2)
      @"SLPS-02095" : @2, // Abe '99 (Japan) (Disc 1)
      @"SLPS-02096" : @2, // Abe '99 (Japan) (Disc 2)
      @"SLPS-02020" : @2, // Ace Combat 3 - Electrosphere (Japan) (Disc 1) (v1.0) / (v1.1)
      @"SLPS-02021" : @2, // Ace Combat 3 - Electrosphere (Japan) (Disc 2) (v1.0) / (v1.1)
      @"SCPS-10131" : @2, // Aconcagua (Japan) (Disc 1)
      @"SCPS-10132" : @2, // Aconcagua (Japan) (Disc 2)
      @"SLPM-86254" : @4, // Aitakute... Your Smiles in My Heart (Japan) (Disc 1)
      @"SLPM-86255" : @4, // Aitakute... Your Smiles in My Heart (Japan) (Disc 2)
      @"SLPM-86256" : @4, // Aitakute... Your Smiles in My Heart (Japan) (Disc 3)
      @"SLPM-86257" : @4, // Aitakute... Your Smiles in My Heart (Japan) (Disc 4)
      @"SLPS-01527" : @3, // Alive (Japan) (Disc 1)
      @"SLPS-01528" : @3, // Alive (Japan) (Disc 2)
      @"SLPS-01529" : @3, // Alive (Japan) (Disc 3)
      @"SLES-04107" : @2, // All Star Action (Europe) (Disc 1)
      @"SLES-14107" : @2, // All Star Action (Europe) (Disc 2)
      @"SLPS-01187" : @3, // Alnam no Tsubasa - Shoujin no Sora no Kanata e (Japan) (Disc 1)
      @"SLPS-01188" : @3, // Alnam no Tsubasa - Shoujin no Sora no Kanata e (Japan) (Disc 2)
      @"SLPS-01189" : @3, // Alnam no Tsubasa - Shoujin no Sora no Kanata e (Japan) (Disc 3)
      @"SLES-02801" : @2, // Alone in the Dark - The New Nightmare (Europe) (Disc 1)
      @"SLES-12801" : @2, // Alone in the Dark - The New Nightmare (Europe) (Disc 2)
      @"SLES-02802" : @2, // Alone in the Dark - The New Nightmare (France) (Disc 1)
      @"SLES-12802" : @2, // Alone in the Dark - The New Nightmare (France) (Disc 2)
      @"SLES-02803" : @2, // Alone in the Dark - The New Nightmare (Germany) (Disc 1)
      @"SLES-12803" : @2, // Alone in the Dark - The New Nightmare (Germany) (Disc 2)
      @"SLES-02805" : @2, // Alone in the Dark - The New Nightmare (Italy) (Disc 1)
      @"SLES-12805" : @2, // Alone in the Dark - The New Nightmare (Italy) (Disc 2)
      @"SLES-02804" : @2, // Alone in the Dark - The New Nightmare (Spain) (Disc 1)
      @"SLES-12804" : @2, // Alone in the Dark - The New Nightmare (Spain) (Disc 2)
      @"SLUS-01201" : @2, // Alone in the Dark - The New Nightmare (USA) (Disc 1)
      @"SLUS-01377" : @2, // Alone in the Dark - The New Nightmare (USA) (Disc 2)
      @"SLES-02348" : @2, // Amerzone - Das Testament des Forschungsreisenden (Germany) (Disc 1)
      @"SLES-12348" : @2, // Amerzone - Das Testament des Forschungsreisenden (Germany) (Disc 2)
      @"SLES-02349" : @2, // Amerzone - El Legado del Explorador (Spain) (Disc 1)
      @"SLES-12349" : @2, // Amerzone - El Legado del Explorador (Spain) (Disc 2)
      @"SLES-02350" : @2, // Amerzone - Il Testamento dell'Esploratore (Italy) (Disc 1)
      @"SLES-12350" : @2, // Amerzone - Il Testamento dell'Esploratore (Italy) (Disc 2)
      @"SLES-02347" : @2, // Amerzone - The Explorer's Legacy (Europe) (Disc 1)
      @"SLES-12347" : @2, // Amerzone - The Explorer's Legacy (Europe) (Disc 2)
      @"SLES-02346" : @2, // Amerzone, L' (France) (Disc 1)
      @"SLES-12346" : @2, // Amerzone, L' (France) (Disc 2)
      @"SLPS-01108" : @2, // Ancient Roman - Power of Dark Side (Japan) (Disc 1)
      @"SLPS-01109" : @2, // Ancient Roman - Power of Dark Side (Japan) (Disc 2)
      @"SLPS-01830" : @2, // Animetic Story Game 1 - Card Captor Sakura (Japan) (Disc 1)
      @"SLPS-01831" : @2, // Animetic Story Game 1 - Card Captor Sakura (Japan) (Disc 2)
      @"SLPS-01068" : @2, // Ankh - Tutankhamen no Nazo (Japan) (Disc 1)
      @"SLPS-01069" : @2, // Ankh - Tutankhamen no Nazo (Japan) (Disc 2)
      @"SLPS-02940" : @2, // Ao no Rokugou - Antarctica (Japan) (Disc 1)
      @"SLPS-02941" : @2, // Ao no Rokugou - Antarctica (Japan) (Disc 2)
      //@"SCPS-10040" : @2, // Arc the Lad - Monster Game with Casino Game (Japan) (Disc 1) (Monster Game)
      //@"SCPS-10041" : @2, // Arc the Lad - Monster Game with Casino Game (Japan) (Disc 2) (Casino Game)
      @"SLUS-01253" : @2, // Arc the Lad Collection - Arc the Lad III (USA) (Disc 1)
      @"SLUS-01254" : @2, // Arc the Lad Collection - Arc the Lad III (USA) (Disc 2)
      @"SCPS-10106" : @2, // Arc the Lad III (Japan) (Disc 1) (v1.0) / (v1.1)
      @"SCPS-10107" : @2, // Arc the Lad III (Japan) (Disc 2) (v1.0) / (v1.1)
      @"SLPS-01855" : @2, // Armored Core - Master of Arena (Japan) (Disc 1) (v1.0)
      @"SLPS-01856" : @2, // Armored Core - Master of Arena (Japan) (Disc 2) (v1.0)
      @"SLPS-91444" : @2, // Armored Core - Master of Arena (Japan) (Disc 1) (v1.1)
      @"SLPS-91445" : @2, // Armored Core - Master of Arena (Japan) (Disc 2) (v1.1)
      @"SLUS-01030" : @2, // Armored Core - Master of Arena (USA) (Disc 1)
      @"SLUS-01081" : @2, // Armored Core - Master of Arena (USA) (Disc 2)
      @"SLPM-86088" : @2, // Astronoka (Japan) (Disc 1)
      @"SLPM-86089" : @2, // Astronoka (Japan) (Disc 2)
      @"SLPM-86185" : @3, // Athena - Awakening from the Ordinary Life (Japan) (Disc 1)
      @"SLPM-86186" : @3, // Athena - Awakening from the Ordinary Life (Japan) (Disc 2)
      @"SLPM-86187" : @3, // Athena - Awakening from the Ordinary Life (Japan) (Disc 3)
      @"SLES-01603" : @3, // Atlantis - Das sagenhafte Abenteuer (Germany) (Disc 1)
      @"SLES-11603" : @3, // Atlantis - Das sagenhafte Abenteuer (Germany) (Disc 2)
      @"SLES-21603" : @3, // Atlantis - Das sagenhafte Abenteuer (Germany) (Disc 3)
      @"SLES-01602" : @3, // Atlantis - Secrets d'Un Monde Oublie (France) (Disc 1)
      @"SLES-11602" : @3, // Atlantis - Secrets d'Un Monde Oublie (France) (Disc 2)
      @"SLES-21602" : @3, // Atlantis - Secrets d'Un Monde Oublie (France) (Disc 3)
      @"SLES-01604" : @3, // Atlantis - Segreti d'Un Mondo Perduto (Italy) (Disc 1)
      @"SLES-11604" : @3, // Atlantis - Segreti d'Un Mondo Perduto (Italy) (Disc 2)
      @"SLES-21604" : @3, // Atlantis - Segreti d'Un Mondo Perduto (Italy) (Disc 3)
      @"SLES-01291" : @3, // Atlantis - The Lost Tales (Europe) (Disc 1)
      @"SLES-11291" : @3, // Atlantis - The Lost Tales (Europe) (Disc 2)
      @"SLES-21291" : @3, // Atlantis - The Lost Tales (Europe) (Disc 3)
      @"SLES-01605" : @3, // Atlantis - The Lost Tales (Europe) (En,Es,Nl,Sv) (Disc 1)
      @"SLES-11605" : @3, // Atlantis - The Lost Tales (Europe) (En,Es,Nl,Sv) (Disc 2)
      @"SLES-21605" : @3, // Atlantis - The Lost Tales (Europe) (En,Es,Nl,Sv) (Disc 3)
      @"SLPS-00946" : @2, // Ayakashi Ninden Kunoichiban (Japan) (Disc 1)
      @"SLPS-00947" : @2, // Ayakashi Ninden Kunoichiban (Japan) (Disc 2)
      @"SLPS-01003" : @3, // B Senjou no Alice - Alice on Borderlines (Japan) (Disc 1)
      @"SLPS-01004" : @3, // B Senjou no Alice - Alice on Borderlines (Japan) (Disc 2)
      @"SLPS-01005" : @3, // B Senjou no Alice - Alice on Borderlines (Japan) (Disc 3)
      @"SLPS-01446" : @2, // Back Guiner - Yomigaeru Yuusha Tachi - Hishou Hen 'Uragiri no Senjou' (Japan) (Disc 1)
      @"SLPS-01447" : @2, // Back Guiner - Yomigaeru Yuusha Tachi - Hishou Hen 'Uragiri no Senjou' (Japan) (Disc 2)
      @"SLPS-01217" : @2, // Back Guiner - Yomigaeru Yuusha Tachi - Kakusei Hen 'Guiner Tensei' (Japan) (Disc 1)
      @"SLPS-01218" : @2, // Back Guiner - Yomigaeru Yuusha Tachi - Kakusei Hen 'Guiner Tensei' (Japan) (Disc 2)
      @"SLPM-86126" : @2, // Beat Mania (Japan) (Disc 1) (Arcade)
      @"SLPM-86127" : @2, // Beat Mania (Japan) (Disc 2) (Append)
      @"SLPS-01510" : @2, // Biohazard 2 - Dual Shock Ver. (Japan) (Disc 1) (Leon Hen)
      @"SLPS-01511" : @2, // Biohazard 2 - Dual Shock Ver. (Japan) (Disc 2) (Claire Hen)
      @"SLPS-01222" : @2, // Biohazard 2 (Japan) (Disc 1) (v1.0)
      @"SLPS-01223" : @2, // Biohazard 2 (Japan) (Disc 2) (v1.0)
      @"SLPS-02962" : @2, // Black Matrix + (Japan) (Disc 1)
      @"SLPS-02963" : @2, // Black Matrix + (Japan) (Disc 2)
      @"SLPS-03571" : @2, // Black Matrix 00 (Japan) (Disc 1)
      @"SLPS-03572" : @2, // Black Matrix 00 (Japan) (Disc 2)
      @"SCPS-10094" : @2, // Book of Watermarks, The (Japan) (Disc 1)
      @"SCPS-10095" : @2, // Book of Watermarks, The (Japan) (Disc 2)
      @"SLPS-00514" : @2, // Brain Dead 13 (Japan) (Disc 1)
      @"SLPS-00515" : @2, // Brain Dead 13 (Japan) (Disc 2)
      @"SLUS-00083" : @2, // BrainDead 13 (USA) (Disc 1)
      @"SLUS-00171" : @2, // BrainDead 13 (USA) (Disc 2)
      @"SLPS-02580" : @2, // Brave Saga 2 (Japan) (Disc 1)
      @"SLPS-02581" : @2, // Brave Saga 2 (Japan) (Disc 2)
      @"SLPS-02661" : @2, // Brigandine - Grand Edition (Japan) (Disc 1)
      @"SLPS-02662" : @2, // Brigandine - Grand Edition (Japan) (Disc 2)
      //@"SLPS-01232" : @2, // Bust A Move - Dance & Rhythm Action (Japan) (Disc 1)
      //@"SLPS-01233" : @2, // Bust A Move - Dance & Rhythm Action (Japan) (Disc 2) (Premium CD-ROM)
      //@"SLES-01881" : @4, // Capcom Generations (Europe) (Disc 1) (Wings of Destiny)
      //@"SLES-11881" : @4, // Capcom Generations (Europe) (Disc 2) (Chronicles of Arthur)
      //@"SLES-21881" : @4, // Capcom Generations (Europe) (Disc 3) (The First Generation)
      //@"SLES-31881" : @4, // Capcom Generations (Europe) (Disc 4) (Blazing Guns)
      //@"SLES-02098" : @3, // Capcom Generations (Germany) (Disc 1) (Wings of Destiny)
      //@"SLES-12098" : @3, // Capcom Generations (Germany) (Disc 2) (Chronicles of Arthur)
      //@"SLES-22098" : @3, // Capcom Generations (Germany) (Disc 3) (The First Generation)
      @"SCES-02816" : @2, // Chase the Express - El Expreso de la Muerte (Spain) (Disc 1)
      @"SCES-12816" : @2, // Chase the Express - El Expreso de la Muerte (Spain) (Disc 2)
      @"SCES-02812" : @2, // Chase the Express (Europe) (Disc 1)
      @"SCES-12812" : @2, // Chase the Express (Europe) (Disc 2)
      @"SCES-02813" : @2, // Chase the Express (France) (Disc 1)
      @"SCES-12813" : @2, // Chase the Express (France) (Disc 2)
      @"SCES-02814" : @2, // Chase the Express (Germany) (Disc 1)
      @"SCES-12814" : @2, // Chase the Express (Germany) (Disc 2)
      @"SCES-02815" : @2, // Chase the Express (Italy) (Disc 1)
      @"SCES-12815" : @2, // Chase the Express (Italy) (Disc 2)
      @"SCPS-10109" : @2, // Chase the Express (Japan) (Disc 1)
      @"SCPS-10110" : @2, // Chase the Express (Japan) (Disc 2)
      @"SLPS-01834" : @2, // Chibi Chara Game Ginga Eiyuu Densetsu (Reinhart Version) (Japan) (Disc 1)
      @"SLPS-01835" : @2, // Chibi Chara Game Ginga Eiyuu Densetsu (Reinhart Version) (Japan) (Disc 2)
      @"SLPS-02005" : @2, // Chou Jikuu Yousai Macross - Ai Oboete Imasu ka (Japan) (Disc 1)
      @"SLPS-02006" : @2, // Chou Jikuu Yousai Macross - Ai Oboete Imasu ka (Japan) (Disc 2)
      @"SLES-00165" : @2, // Chronicles of the Sword (Europe) (Disc 1)
      @"SLES-10165" : @2, // Chronicles of the Sword (Europe) (Disc 2)
      @"SLES-00166" : @2, // Chronicles of the Sword (France) (Disc 1)
      @"SLES-10166" : @2, // Chronicles of the Sword (France) (Disc 2)
      @"SLES-00167" : @2, // Chronicles of the Sword (Germany) (Disc 1)
      @"SLES-10167" : @2, // Chronicles of the Sword (Germany) (Disc 2)
      @"SCUS-94700" : @2, // Chronicles of the Sword (USA) (Disc 1)
      @"SCUS-94701" : @2, // Chronicles of the Sword (USA) (Disc 2)
      @"SLPM-87395" : @2, // Chrono Cross (Japan) (Disc 1)
      @"SLPM-87396" : @2, // Chrono Cross (Japan) (Disc 2)
      @"SLUS-01041" : @2, // Chrono Cross (USA) (Disc 1)
      @"SLUS-01080" : @2, // Chrono Cross (USA) (Disc 2)
      @"SLPS-01813" : @3, // Cinema Eikaiwa Series Dai-1-dan - Tengoku ni Ikenai Papa (Japan) (Disc 1) (Joukan)
      @"SLPS-01814" : @3, // Cinema Eikaiwa Series Dai-1-dan - Tengoku ni Ikenai Papa (Japan) (Disc 2) (Chuukan)
      @"SLPS-01815" : @3, // Cinema Eikaiwa Series Dai-1-dan - Tengoku ni Ikenai Papa (Japan) (Disc 3) (Gekan)
      @"SLPS-01872" : @3, // Cinema Eikaiwa Series Dai-2-dan - Interceptor (Japan) (Disc 1) (Joukan)
      @"SLPS-01873" : @3, // Cinema Eikaiwa Series Dai-2-dan - Interceptor (Japan) (Disc 2) (Chuukan)
      @"SLPS-01874" : @3, // Cinema Eikaiwa Series Dai-2-dan - Interceptor (Japan) (Disc 3) (Gekan)
      @"SLPS-01954" : @3, // Cinema Eikaiwa Series Dai-3-dan - Arashigaoka (Japan) (Disc 1) (Joukan)
      @"SLPS-01955" : @3, // Cinema Eikaiwa Series Dai-3-dan - Arashigaoka (Japan) (Disc 2) (Chuukan)
      @"SLPS-01956" : @3, // Cinema Eikaiwa Series Dai-3-dan - Arashigaoka (Japan) (Disc 3) (Gekan)
      @"SLPS-02016" : @4, // Cinema Eikaiwa Series Dai-4-dan - Boy's Life (Japan) (Disc 1)
      @"SLPS-02017" : @4, // Cinema Eikaiwa Series Dai-4-dan - Boy's Life (Japan) (Disc 2)
      @"SLPS-02018" : @4, // Cinema Eikaiwa Series Dai-4-dan - Boy's Life (Japan) (Disc 3)
      @"SLPS-02019" : @4, // Cinema Eikaiwa Series Dai-4-dan - Boy's Life (Japan) (Disc 4)
      @"SLPS-02060" : @4, // Cinema Eikaiwa Series Dai-5-dan - Zombie (Japan) (Disc 1)
      @"SLPS-02061" : @4, // Cinema Eikaiwa Series Dai-5-dan - Zombie (Japan) (Disc 2)
      @"SLPS-02062" : @4, // Cinema Eikaiwa Series Dai-5-dan - Zombie (Japan) (Disc 3)
      @"SLPS-02063" : @4, // Cinema Eikaiwa Series Dai-5-dan - Zombie (Japan) (Disc 4)
      @"SLPM-86241" : @4, // Cinema Eikaiwa Series Dai-6-dan - Ai no Hate ni (Japan) (Disc 1)
      @"SLPM-86242" : @4, // Cinema Eikaiwa Series Dai-6-dan - Ai no Hate ni (Japan) (Disc 2)
      @"SLPM-86243" : @4, // Cinema Eikaiwa Series Dai-6-dan - Ai no Hate ni (Japan) (Disc 3)
      @"SLPM-86244" : @4, // Cinema Eikaiwa Series Dai-6-dan - Ai no Hate ni (Japan) (Disc 4)
      @"SCPS-10077" : @2, // Circadia (Japan) (Disc 1)
      @"SCPS-10078" : @2, // Circadia (Japan) (Disc 2)
      @"SCES-02151" : @2, // Cold Blood (Germany) (Disc 1)
      @"SCES-12151" : @2, // Cold Blood (Germany) (Disc 2)
      @"SLES-00860" : @2, // Colony Wars (Europe) (Disc 1)
      @"SLES-10860" : @2, // Colony Wars (Europe) (Disc 2)
      @"SLES-00861" : @2, // Colony Wars (France) (Disc 1)
      @"SLES-10861" : @2, // Colony Wars (France) (Disc 2)
      @"SLES-00862" : @2, // Colony Wars (Germany) (Disc 1)
      @"SLES-10862" : @2, // Colony Wars (Germany) (Disc 2)
      @"SLES-00863" : @2, // Colony Wars (Italy) (Disc 1)
      @"SLES-10863" : @2, // Colony Wars (Italy) (Disc 2)
      @"SLPS-01403" : @2, // Colony Wars (Japan) (Disc 1)
      @"SLPS-01404" : @2, // Colony Wars (Japan) (Disc 2)
      @"SLES-00864" : @2, // Colony Wars (Spain) (Disc 1)
      @"SLES-10864" : @2, // Colony Wars (Spain) (Disc 2)
      @"SLUS-00543" : @2, // Colony Wars (USA) (Disc 1)
      @"SLUS-00554" : @2, // Colony Wars (USA) (Disc 2)
      //@"SLES-01345" : @2, // Command & Conquer - Alarmstufe Rot - Gegenschlag (Germany) (Disc 1) (Die Alliierten)
      //@"SLES-11345" : @2, // Command & Conquer - Alarmstufe Rot - Gegenschlag (Germany) (Disc 2) (Die Sowjets)
      //@"SLES-01007" : @2, // Command & Conquer - Alarmstufe Rot (Germany) (Disc 1)
      //@"SLES-11007" : @2, // Command & Conquer - Alarmstufe Rot (Germany) (Disc 2)
      //@"SLES-01344" : @2, // Command & Conquer - Alerte Rouge - Mission Tesla (France) (Disc 1) (Allies)
      //@"SLES-11344" : @2, // Command & Conquer - Alerte Rouge - Mission Tesla (France) (Disc 2) (Sovietiques)
      //@"SLES-01006" : @2, // Command & Conquer - Alerte Rouge (France) (Disc 1) (Allies)
      //@"SLES-11006" : @2, // Command & Conquer - Alerte Rouge (France) (Disc 2) (Sovietiques)
      //@"SLES-01343" : @2, // Command & Conquer - Red Alert - Retaliation (Europe) (Disc 1) (Allies)
      //@"SLES-11343" : @2, // Command & Conquer - Red Alert - Retaliation (Europe) (Disc 2) (Soviet)
      //@"SLUS-00665" : @2, // Command & Conquer - Red Alert - Retaliation (USA) (Disc 1) (Allies)
      //@"SLUS-00667" : @2, // Command & Conquer - Red Alert - Retaliation (USA) (Disc 2) (Soviet)
      //@"SLES-00949" : @2, // Command & Conquer - Red Alert (Europe) (Disc 1) (Allies)
      //@"SLES-10949" : @2, // Command & Conquer - Red Alert (Europe) (Disc 2) (Soviet)
      //@"SLUS-00431" : @2, // Command & Conquer - Red Alert (USA) (Disc 1) (Allies)
      //@"SLUS-00485" : @2, // Command & Conquer - Red Alert (USA) (Disc 2) (Soviet)
      //@"SLES-00532" : @2, // Command & Conquer - Teil 1 - Der Tiberiumkonflikt (Germany) (Disc 1) (GDI)
      //@"SLES-10532" : @2, // Command & Conquer - Teil 1 - Der Tiberiumkonflikt (Germany) (Disc 2) (NOD)
      //@"SLES-00530" : @2, // Command & Conquer (Europe) (Disc 1) (GDI)
      //@"SLES-10530" : @2, // Command & Conquer (Europe) (Disc 2) (NOD)
      //@"SLES-00531" : @2, // Command & Conquer (France) (Disc 1) (GDI)
      //@"SLES-10531" : @2, // Command & Conquer (France) (Disc 2) (NOD)
      //@"SLUS-00379" : @2, // Command & Conquer (USA) (Disc 1) (GDI)
      //@"SLUS-00410" : @2, // Command & Conquer (USA) (Disc 2) (NOD)
      //@"SLPS-00976" : @2, // Command & Conquer Complete (Japan) (Disc 1) (GDI)
      //@"SLPS-00977" : @2, // Command & Conquer Complete (Japan) (Disc 2) (NOD)
      @"SLPS-02504" : @2, // Countdown Vampires (Japan) (Disc 1)
      @"SLPS-02505" : @2, // Countdown Vampires (Japan) (Disc 2)
      @"SLUS-00898" : @2, // Countdown Vampires (USA) (Disc 1)
      @"SLUS-01199" : @2, // Countdown Vampires (USA) (Disc 2)
      @"SLUS-01151" : @2, // Covert Ops - Nuclear Dawn (USA) (Disc 1)
      @"SLUS-01157" : @2, // Covert Ops - Nuclear Dawn (USA) (Disc 2)
      @"SLPS-00120" : @2, // Creature Shock (Japan) (Disc 1)
      @"SLPS-00121" : @2, // Creature Shock (Japan) (Disc 2)
      @"SLPM-86280" : @2, // Cross Tantei Monogatari (Japan) (Disc 1)
      @"SLPM-86281" : @2, // Cross Tantei Monogatari (Japan) (Disc 2)
      @"SLPS-01912" : @2, // Cybernetic Empire (Japan) (Disc 1)
      @"SLPS-01913" : @2, // Cybernetic Empire (Japan) (Disc 2)
      @"SLPS-00055" : @3, // Cyberwar (Japan) (Disc 1)
      @"SLPS-00056" : @3, // Cyberwar (Japan) (Disc 2)
      @"SLPS-00057" : @3, // Cyberwar (Japan) (Disc 3)
      @"SLES-00065" : @3, // D (Europe) (Disc 1)
      @"SLES-10065" : @3, // D (Europe) (Disc 2)
      @"SLES-20065" : @3, // D (Europe) (Disc 3)
      @"SLES-00161" : @3, // D (France) (Disc 1)
      @"SLES-10161" : @3, // D (France) (Disc 2)
      @"SLES-20161" : @3, // D (France) (Disc 3)
      @"SLES-00160" : @3, // D (Germany) (Disc 1)
      @"SLES-10160" : @3, // D (Germany) (Disc 2)
      @"SLES-20160" : @3, // D (Germany) (Disc 3)
      @"SLUS-00128" : @3, // D (USA) (Disc 1)
      @"SLUS-00173" : @3, // D (USA) (Disc 2)
      @"SLUS-00174" : @3, // D (USA) (Disc 3)
      @"SLPS-00133" : @3, // D no Shokutaku - Complete Graphics (Japan) (Disc 1)
      @"SLPS-00134" : @3, // D no Shokutaku - Complete Graphics (Japan) (Disc 2)
      @"SLPS-00135" : @3, // D no Shokutaku - Complete Graphics (Japan) (Disc 3)
      @"SLPM-86210" : @3, // Dancing Blade Katte ni Momotenshi II - Tears of Eden (Japan) (Disc 1)
      @"SLPM-86211" : @3, // Dancing Blade Katte ni Momotenshi II - Tears of Eden (Japan) (Disc 2)
      @"SLPM-86212" : @3, // Dancing Blade Katte ni Momotenshi II - Tears of Eden (Japan) (Disc 3)
      @"SLPM-86100" : @3, // Dancing Blade Katte ni Momotenshi! (Japan) (Disc 1)
      @"SLPM-86101" : @3, // Dancing Blade Katte ni Momotenshi! (Japan) (Disc 2)
      @"SLPM-86102" : @3, // Dancing Blade Katte ni Momotenshi! (Japan) (Disc 3)
      @"SCES-02150" : @2, // De Sang Froid (France) (Disc 1)
      @"SCES-12150" : @2, // De Sang Froid (France) (Disc 2)
      @"SLPS-00225" : @3, // DeathMask (Japan) (Disc 1)
      @"SLPS-00226" : @3, // DeathMask (Japan) (Disc 2)
      @"SLPS-00227" : @3, // DeathMask (Japan) (Disc 3)
      @"SLPS-00660" : @2, // Deep Sea Adventure - Kaitei Kyuu Panthalassa no Nazo (Japan) (Disc 1)
      @"SLPS-00661" : @2, // Deep Sea Adventure - Kaitei Kyuu Panthalassa no Nazo (Japan) (Disc 2)
      @"SLPS-01921" : @2, // Devil Summoner - Soul Hackers (Japan) (Disc 1)
      @"SLPS-01922" : @2, // Devil Summoner - Soul Hackers (Japan) (Disc 2)
      @"SLPS-01503" : @2, // Dezaemon Kids! (Japan) (Disc 1)
      @"SLPS-01504" : @2, // Dezaemon Kids! (Japan) (Disc 2)
      @"SLPS-01507" : @3, // Doki Doki Pretty League - Nekketsu Otome Seishunki (Japan) (Disc 1)
      @"SLPS-01508" : @3, // Doki Doki Pretty League - Nekketsu Otome Seishunki (Japan) (Disc 2)
      @"SLPS-01509" : @3, // Doki Doki Pretty League - Nekketsu Otome Seishunki (Japan) (Disc 3)
      @"SLES-02761" : @2, // Dracula - La Risurrezione (Italy) (Disc 1)
      @"SLES-12761" : @2, // Dracula - La Risurrezione (Italy) (Disc 2)
      @"SLES-02762" : @2, // Dracula - Ressurreição (Portugal) (Disc 1)
      @"SLES-12762" : @2, // Dracula - Ressurreição (Portugal) (Disc 2)
      @"SLES-02760" : @2, // Dracula - Resurreccion (Spain) (Disc 1)
      @"SLES-12760" : @2, // Dracula - Resurreccion (Spain) (Disc 2)
      @"SLES-02758" : @2, // Dracula - Resurrection (France) (Disc 1)
      @"SLES-12758" : @2, // Dracula - Resurrection (France) (Disc 2)
      @"SLES-02759" : @2, // Dracula - Resurrection (Germany) (Disc 1)
      @"SLES-12759" : @2, // Dracula - Resurrection (Germany) (Disc 2)
      @"SLUS-01440" : @2, // Dracula - The Last Sanctuary (USA) (Disc 1)
      @"SLUS-01443" : @2, // Dracula - The Last Sanctuary (USA) (Disc 2)
      @"SLES-02757" : @2, // Dracula - The Resurrection (Europe) (Disc 1)
      @"SLES-12757" : @2, // Dracula - The Resurrection (Europe) (Disc 2)
      @"SLUS-01284" : @2, // Dracula - The Resurrection (USA) (Disc 1)
      @"SLUS-01316" : @2, // Dracula - The Resurrection (USA) (Disc 2)
      @"SLES-03350" : @2, // Dracula 2 - Die letzte Zufluchtsstaette (Germany) (Disc 1)
      @"SLES-13350" : @2, // Dracula 2 - Die letzte Zufluchtsstaette (Germany) (Disc 2)
      @"SLES-03352" : @2, // Dracula 2 - El Ultimo Santuario (Spain) (Disc 1)
      @"SLES-13352" : @2, // Dracula 2 - El Ultimo Santuario (Spain) (Disc 2)
      @"SLES-03351" : @2, // Dracula 2 - L'Ultimo Santuario (Italy) (Disc 1)
      @"SLES-13351" : @2, // Dracula 2 - L'Ultimo Santuario (Italy) (Disc 2)
      @"SLES-03349" : @2, // Dracula 2 - Le Dernier Sanctuaire (France) (Disc 1)
      @"SLES-13349" : @2, // Dracula 2 - Le Dernier Sanctuaire (France) (Disc 2)
      @"SLES-03348" : @2, // Dracula 2 - The Last Sanctuary (Europe) (Disc 1)
      @"SLES-13348" : @2, // Dracula 2 - The Last Sanctuary (Europe) (Disc 2)
      @"SLPM-86500" : @2, // Dragon Quest VII - Eden no Senshitachi (Japan) (Disc 1) (v1.0) / (v1.1)
      @"SLPM-86501" : @2, // Dragon Quest VII - Eden no Senshitachi (Japan) (Disc 2) (v1.0) / (v1.1)
      @"SCES-01705" : @2, // Dragon Valor (Europe) (Disc 1)
      @"SCES-11705" : @2, // Dragon Valor (Europe) (Disc 2)
      @"SCES-02565" : @2, // Dragon Valor (France) (Disc 1)
      @"SCES-12565" : @2, // Dragon Valor (France) (Disc 2)
      @"SCES-02566" : @2, // Dragon Valor (Germany) (Disc 1)
      @"SCES-12566" : @2, // Dragon Valor (Germany) (Disc 2)
      @"SCES-02567" : @2, // Dragon Valor (Italy) (Disc 1)
      @"SCES-12567" : @2, // Dragon Valor (Italy) (Disc 2)
      @"SLPS-02190" : @2, // Dragon Valor (Japan) (Disc 1)
      @"SLPS-02191" : @2, // Dragon Valor (Japan) (Disc 2)
      @"SCES-02568" : @2, // Dragon Valor (Spain) (Disc 1)
      @"SCES-12568" : @2, // Dragon Valor (Spain) (Disc 2)
      @"SLUS-01092" : @2, // Dragon Valor (USA) (Disc 1)
      @"SLUS-01164" : @2, // Dragon Valor (USA) (Disc 2)
      @"SLUS-01206" : @2, // Dragon Warrior VII (USA) (Disc 1)
      @"SLUS-01346" : @2, // Dragon Warrior VII (USA) (Disc 2)
      @"SLES-02993" : @2, // Driver 2 - Back on the Streets (Europe) (Disc 1) (v1.0) / (v1.1)
      @"SLES-12993" : @2, // Driver 2 - Back on the Streets (Europe) (Disc 2) (v1.0) / (v1.1)
      @"SLES-02994" : @2, // Driver 2 - Back on the Streets (France) (Disc 1)
      @"SLES-12994" : @2, // Driver 2 - Back on the Streets (France) (Disc 2)
      @"SLES-02995" : @2, // Driver 2 - Back on the Streets (Germany) (Disc 1) (v1.0) / (v1.1)
      @"SLES-12995" : @2, // Driver 2 - Back on the Streets (Germany) (Disc 2) (v1.0) / (v1.1)
      @"SLES-02996" : @2, // Driver 2 - Back on the Streets (Italy) (Disc 1)
      @"SLES-12996" : @2, // Driver 2 - Back on the Streets (Italy) (Disc 2)
      @"SLES-02997" : @2, // Driver 2 - Back on the Streets (Spain) (Disc 1)
      @"SLES-12997" : @2, // Driver 2 - Back on the Streets (Spain) (Disc 2)
      @"SLUS-01161" : @2, // Driver 2 (USA) (Disc 1) (v1.0) / (v1.1)
      @"SLUS-01318" : @2, // Driver 2 (USA) (Disc 2) (v1.0) / (v1.1)
      @"SLPS-00370" : @2, // Dungeon Creator (Japan) (Disc 1)
      @"SLPS-00371" : @2, // Dungeon Creator (Japan) (Disc 2) (Memory Bank Disc)
      @"SLPS-00844" : @2, // Eberouge (Japan) (Disc 1)
      @"SLPS-00845" : @2, // Eberouge (Japan) (Disc 2)
      @"SLPS-01791" : @2, // Ecsaform (Japan) (Disc 1)
      @"SLPS-01792" : @2, // Ecsaform (Japan) (Disc 2)
      @"SLPS-03141" : @2, // Eithea (Japan) (Disc 1)
      @"SLPS-03142" : @2, // Eithea (Japan) (Disc 2)
      @"SLPS-00973" : @2, // Elf o Karu Monotachi - Kanzenban (Japan) (Disc 1)
      @"SLPS-00974" : @2, // Elf o Karu Monotachi - Kanzenban (Japan) (Disc 2)
      @"SLPS-01456" : @3, // Elf wo Karu Monotachi II (Japan) (Disc 1)
      @"SLPS-01457" : @3, // Elf wo Karu Monotachi II (Japan) (Disc 2)
      @"SLPS-01458" : @3, // Elf wo Karu Monotachi II (Japan) (Disc 3)
      @"SLPS-00117" : @3, // Emit Value Pack (Japan) (Disc 1) (Vol. 1 - Toki no Maigo)
      @"SLPS-00118" : @3, // Emit Value Pack (Japan) (Disc 2) (Vol. 2 - Inochigake no Tabi)
      @"SLPS-00119" : @3, // Emit Value Pack (Japan) (Disc 3) (Vol. 3 - Watashi ni Sayonara wo)
      @"SLPS-01351" : @2, // Enigma (Japan) (Disc 1)
      @"SLPS-01352" : @2, // Enigma (Japan) (Disc 2)
      @"SLPM-86135" : @4, // Eurasia Express Satsujin Jiken (Japan) (Disc 1)
      @"SLPM-86136" : @4, // Eurasia Express Satsujin Jiken (Japan) (Disc 2)
      @"SLPM-86137" : @4, // Eurasia Express Satsujin Jiken (Japan) (Disc 3)
      @"SLPM-86138" : @4, // Eurasia Express Satsujin Jiken (Japan) (Disc 4)
      @"SLPM-86826" : @3, // Eve - The Fatal Attraction (Japan) (Disc 1)
      @"SLPM-86827" : @3, // Eve - The Fatal Attraction (Japan) (Disc 2)
      @"SLPM-86828" : @3, // Eve - The Fatal Attraction (Japan) (Disc 3)
      @"SLPS-01805" : @3, // Eve - The Lost One (Japan) (Disc 1) (Kyoko Disc) (v1.0)
      @"SLPS-01806" : @3, // Eve - The Lost One (Japan) (Disc 2) (Snake Disc) (v1.0)
      @"SLPS-01807" : @3, // Eve - The Lost One (Japan) (Disc 3) (Lost One Disc) (v1.0)
      @"SLPM-87246" : @3, // Eve - The Lost One (Japan) (Disc 1) (Kyoko Disc) (v1.1)
      @"SLPM-87247" : @3, // Eve - The Lost One (Japan) (Disc 2) (Snake Disc) (v1.1)
      @"SLPM-87248" : @3, // Eve - The Lost One (Japan) (Disc 3) (Lost One Disc) (v1.1)
      @"SLPM-86478" : @3, // Eve Zero (Japan) (Disc 1)
      @"SLPM-86479" : @3, // Eve Zero (Japan) (Disc 2)
      @"SLPM-86480" : @3, // Eve Zero (Japan) (Disc 3)
      @"SLPM-86475" : @3, // Eve Zero (Japan) (Disc 1) (Premium Box)
      @"SLPM-86476" : @3, // Eve Zero (Japan) (Disc 2) (Premium Box)
      @"SLPM-86477" : @3, // Eve Zero (Japan) (Disc 3) (Premium Box)
      @"SLES-03428" : @2, // Evil Dead - Hail to the King (Europe) (Disc 1)
      @"SLES-13428" : @2, // Evil Dead - Hail to the King (Europe) (Disc 2)
      @"SLUS-01072" : @2, // Evil Dead - Hail to the King (USA) (Disc 1)
      @"SLUS-01326" : @2, // Evil Dead - Hail to the King (USA) (Disc 2)
      @"SLES-03485" : @3, // Family Games Compendium (Europe) (Disc 1)
      @"SLES-13485" : @3, // Family Games Compendium (Europe) (Disc 2)
      @"SLES-23485" : @3, // Family Games Compendium (Europe) (En,Fr,De,It) (Disc 3)
      @"SLES-02166" : @4, // Fear Effect (Europe) (En,Es,It) (Disc 1)
      @"SLES-12166" : @4, // Fear Effect (Europe) (En,Es,It) (Disc 2)
      @"SLES-22166" : @4, // Fear Effect (Europe) (En,Es,It) (Disc 3)
      @"SLES-32166" : @4, // Fear Effect (Europe) (En,Es,It) (Disc 4)
      @"SLES-02167" : @4, // Fear Effect (France) (Disc 1)
      @"SLES-12167" : @4, // Fear Effect (France) (Disc 2)
      @"SLES-22167" : @4, // Fear Effect (France) (Disc 3)
      @"SLES-32167" : @4, // Fear Effect (France) (Disc 4)
      @"SLES-02168" : @4, // Fear Effect (Germany) (Disc 1)
      @"SLES-12168" : @4, // Fear Effect (Germany) (Disc 2)
      @"SLES-22168" : @4, // Fear Effect (Germany) (Disc 3)
      @"SLES-32168" : @4, // Fear Effect (Germany) (Disc 4)
      @"SLUS-00920" : @4, // Fear Effect (USA) (Disc 1)
      @"SLUS-01056" : @4, // Fear Effect (USA) (Disc 2)
      @"SLUS-01057" : @4, // Fear Effect (USA) (Disc 3)
      @"SLUS-01058" : @4, // Fear Effect (USA) (Disc 4)
      @"SLES-03386" : @4, // Fear Effect 2 - Retro Helix (Europe) (En,Fr,De) (Disc 1)
      @"SLES-13386" : @4, // Fear Effect 2 - Retro Helix (Europe) (En,Fr,De) (Disc 2)
      @"SLES-23386" : @4, // Fear Effect 2 - Retro Helix (Europe) (En,Fr,De) (Disc 3)
      @"SLES-33386" : @4, // Fear Effect 2 - Retro Helix (Europe) (En,Fr,De) (Disc 4)
      @"SLUS-01266" : @4, // Fear Effect 2 - Retro Helix (USA) (Disc 1) (v1.0) / (v1.1)
      @"SLUS-01275" : @4, // Fear Effect 2 - Retro Helix (USA) (Disc 2) (v1.0) / (v1.1)
      @"SLUS-01276" : @4, // Fear Effect 2 - Retro Helix (USA) (Disc 3) (v1.0) / (v1.1)
      @"SLUS-01277" : @4, // Fear Effect 2 - Retro Helix (USA) (Disc 4) (v1.0) / (v1.1)
      @"SLES-02965" : @4, // Final Fantasy IX (Europe) (Disc 1)
      @"SLES-12965" : @4, // Final Fantasy IX (Europe) (Disc 2)
      @"SLES-22965" : @4, // Final Fantasy IX (Europe) (Disc 3)
      @"SLES-32965" : @4, // Final Fantasy IX (Europe) (Disc 4)
      @"SLES-02966" : @4, // Final Fantasy IX (France) (Disc 1)
      @"SLES-12966" : @4, // Final Fantasy IX (France) (Disc 2)
      @"SLES-22966" : @4, // Final Fantasy IX (France) (Disc 3)
      @"SLES-32966" : @4, // Final Fantasy IX (France) (Disc 4)
      @"SLES-02967" : @4, // Final Fantasy IX (Germany) (Disc 1)
      @"SLES-12967" : @4, // Final Fantasy IX (Germany) (Disc 2)
      @"SLES-22967" : @4, // Final Fantasy IX (Germany) (Disc 3)
      @"SLES-32967" : @4, // Final Fantasy IX (Germany) (Disc 4)
      @"SLES-02968" : @4, // Final Fantasy IX (Italy) (Disc 1)
      @"SLES-12968" : @4, // Final Fantasy IX (Italy) (Disc 2)
      @"SLES-22968" : @4, // Final Fantasy IX (Italy) (Disc 3)
      @"SLES-32968" : @4, // Final Fantasy IX (Italy) (Disc 4)
      @"SLPS-02000" : @4, // Final Fantasy IX (Japan) (Disc 1)
      @"SLPS-02001" : @4, // Final Fantasy IX (Japan) (Disc 2)
      @"SLPS-02002" : @4, // Final Fantasy IX (Japan) (Disc 3)
      @"SLPS-02003" : @4, // Final Fantasy IX (Japan) (Disc 4)
      @"SLES-02969" : @4, // Final Fantasy IX (Spain) (Disc 1)
      @"SLES-12969" : @4, // Final Fantasy IX (Spain) (Disc 2)
      @"SLES-22969" : @4, // Final Fantasy IX (Spain) (Disc 3)
      @"SLES-32969" : @4, // Final Fantasy IX (Spain) (Disc 4)
      @"SLUS-01251" : @4, // Final Fantasy IX (USA) (Disc 1) (v1.0) / (v1.1)
      @"SLUS-01295" : @4, // Final Fantasy IX (USA) (Disc 2) (v1.0) / (v1.1)
      @"SLUS-01296" : @4, // Final Fantasy IX (USA) (Disc 3) (v1.0) / (v1.1)
      @"SLUS-01297" : @4, // Final Fantasy IX (USA) (Disc 4) (v1.0) / (v1.1)
      @"SCES-00867" : @3, // Final Fantasy VII (Europe) (Disc 1)
      @"SCES-10867" : @3, // Final Fantasy VII (Europe) (Disc 2)
      @"SCES-20867" : @3, // Final Fantasy VII (Europe) (Disc 3)
      @"SCES-00868" : @3, // Final Fantasy VII (France) (Disc 1)
      @"SCES-10868" : @3, // Final Fantasy VII (France) (Disc 2)
      @"SCES-20868" : @3, // Final Fantasy VII (France) (Disc 3)
      @"SCES-00869" : @3, // Final Fantasy VII (Germany) (Disc 1)
      @"SCES-10869" : @3, // Final Fantasy VII (Germany) (Disc 2)
      @"SCES-20869" : @3, // Final Fantasy VII (Germany) (Disc 3)
      @"SLPS-00700" : @3, // Final Fantasy VII (Japan) (Disc 1)
      @"SLPS-00701" : @3, // Final Fantasy VII (Japan) (Disc 2)
      @"SLPS-00702" : @3, // Final Fantasy VII (Japan) (Disc 3)
      @"SCES-00900" : @3, // Final Fantasy VII (Spain) (Disc 1) (v1.0) / (v1.1)
      @"SCES-10900" : @3, // Final Fantasy VII (Spain) (Disc 2) (v1.0) / (v1.1)
      @"SCES-20900" : @3, // Final Fantasy VII (Spain) (Disc 3) (v1.0) / (v1.1)
      @"SCUS-94163" : @3, // Final Fantasy VII (USA) (Disc 1)
      @"SCUS-94164" : @3, // Final Fantasy VII (USA) (Disc 2)
      @"SCUS-94165" : @3, // Final Fantasy VII (USA) (Disc 3)
      @"SLPS-01057" : @4, // Final Fantasy VII International (Japan) (Disc 1)
      @"SLPS-01058" : @4, // Final Fantasy VII International (Japan) (Disc 2)
      @"SLPS-01059" : @4, // Final Fantasy VII International (Japan) (Disc 3)
      @"SLPS-01060" : @4, // Final Fantasy VII International (Japan) (Disc 4) (Perfect Guide)
      @"SCES-02080" : @4, // Final Fantasy VIII (Europe, Australia) (Disc 1)
      @"SCES-12080" : @4, // Final Fantasy VIII (Europe, Australia) (Disc 2)
      @"SCES-22080" : @4, // Final Fantasy VIII (Europe, Australia) (Disc 3)
      @"SCES-32080" : @4, // Final Fantasy VIII (Europe, Australia) (Disc 4)
      @"SLES-02081" : @4, // Final Fantasy VIII (France) (Disc 1)
      @"SLES-12081" : @4, // Final Fantasy VIII (France) (Disc 2)
      @"SLES-22081" : @4, // Final Fantasy VIII (France) (Disc 3)
      @"SLES-32081" : @4, // Final Fantasy VIII (France) (Disc 4)
      @"SLES-02082" : @4, // Final Fantasy VIII (Germany) (Disc 1)
      @"SLES-12082" : @4, // Final Fantasy VIII (Germany) (Disc 2)
      @"SLES-22082" : @4, // Final Fantasy VIII (Germany) (Disc 3)
      @"SLES-32082" : @4, // Final Fantasy VIII (Germany) (Disc 4)
      @"SLES-02083" : @4, // Final Fantasy VIII (Italy) (Disc 1)
      @"SLES-12083" : @4, // Final Fantasy VIII (Italy) (Disc 2)
      @"SLES-22083" : @4, // Final Fantasy VIII (Italy) (Disc 3)
      @"SLES-32083" : @4, // Final Fantasy VIII (Italy) (Disc 4)
      @"SLPM-87384" : @4, // Final Fantasy VIII (Japan) (Disc 1)
      @"SLPM-87385" : @4, // Final Fantasy VIII (Japan) (Disc 2)
      @"SLPM-87386" : @4, // Final Fantasy VIII (Japan) (Disc 3)
      @"SLPM-87387" : @4, // Final Fantasy VIII (Japan) (Disc 4)
      @"SLES-02084" : @4, // Final Fantasy VIII (Spain) (Disc 1)
      @"SLES-12084" : @4, // Final Fantasy VIII (Spain) (Disc 2)
      @"SLES-22084" : @4, // Final Fantasy VIII (Spain) (Disc 3)
      @"SLES-32084" : @4, // Final Fantasy VIII (Spain) (Disc 4)
      @"SLUS-00892" : @4, // Final Fantasy VIII (USA) (Disc 1)
      @"SLUS-00908" : @4, // Final Fantasy VIII (USA) (Disc 2)
      @"SLUS-00909" : @4, // Final Fantasy VIII (USA) (Disc 3)
      @"SLUS-00910" : @4, // Final Fantasy VIII (USA) (Disc 4)
      @"SLPS-01708" : @2, // First Kiss Story (Japan) (Disc 1)
      @"SLPS-01709" : @2, // First Kiss Story (Japan) (Disc 2)
      @"SLUS-00101" : @3, // Fox Hunt (USA) (Disc 1)
      @"SLUS-00175" : @3, // Fox Hunt (USA) (Disc 2)
      @"SLUS-00176" : @3, // Fox Hunt (USA) (Disc 3)
      @"SLES-00082" : @2, // G-Police (Europe) (Disc 1)
      @"SLES-10082" : @2, // G-Police (Europe) (Disc 2)
      @"SLES-00853" : @2, // G-Police (France) (Disc 1)
      @"SLES-10853" : @2, // G-Police (France) (Disc 2)
      @"SLES-00854" : @2, // G-Police (Germany) (Disc 1)
      @"SLES-10854" : @2, // G-Police (Germany) (Disc 2)
      @"SLES-00855" : @2, // G-Police (Italy) (Disc 1)
      @"SLES-10855" : @2, // G-Police (Italy) (Disc 2)
      @"SCPS-10065" : @2, // G-Police (Japan) (Disc 1)
      @"SCPS-10066" : @2, // G-Police (Japan) (Disc 2)
      @"SLES-00856" : @2, // G-Police (Spain) (Disc 1)
      @"SLES-10856" : @2, // G-Police (Spain) (Disc 2)
      @"SLUS-00544" : @2, // G-Police (USA) (Disc 1)
      @"SLUS-00556" : @2, // G-Police (USA) (Disc 2)
      @"SLPS-01082" : @4, // Gadget - Past as Future (Japan) (Disc 1)
      @"SLPS-01083" : @4, // Gadget - Past as Future (Japan) (Disc 2)
      @"SLPS-01084" : @4, // Gadget - Past as Future (Japan) (Disc 3)
      @"SLPS-01085" : @4, // Gadget - Past as Future (Japan) (Disc 4)
      @"SLES-02328" : @3, // Galerians (Europe) (Disc 1)
      @"SLES-12328" : @3, // Galerians (Europe) (Disc 2)
      @"SLES-22328" : @3, // Galerians (Europe) (Disc 3)
      @"SLES-02329" : @3, // Galerians (France) (Disc 1)
      @"SLES-12329" : @3, // Galerians (France) (Disc 2)
      @"SLES-22329" : @3, // Galerians (France) (Disc 3)
      @"SLES-02330" : @3, // Galerians (Germany) (Disc 1)
      @"SLES-12330" : @3, // Galerians (Germany) (Disc 2)
      @"SLES-22330" : @3, // Galerians (Germany) (Disc 3)
      @"SLPS-02192" : @3, // Galerians (Japan) (Disc 1)
      @"SLPS-02193" : @3, // Galerians (Japan) (Disc 2)
      @"SLPS-02194" : @3, // Galerians (Japan) (Disc 3)
      @"SLUS-00986" : @3, // Galerians (USA) (Disc 1)
      @"SLUS-01098" : @3, // Galerians (USA) (Disc 2)
      @"SLUS-01099" : @3, // Galerians (USA) (Disc 3)
      @"SLPS-02246" : @2, // Gate Keepers (Japan) (Disc 1)
      @"SLPS-02247" : @2, // Gate Keepers (Japan) (Disc 2)
      @"SLPM-86226" : @2, // Glay - Complete Works (Japan) (Disc 1)
      @"SLPM-86227" : @2, // Glay - Complete Works (Japan) (Disc 2)
      @"SLPS-03061" : @2, // Go Go I Land (Japan) (Disc 1)
      @"SLPS-03062" : @2, // Go Go I Land (Japan) (Disc 2)
      @"SLUS-00319" : @2, // Golden Nugget (USA) (Disc 1)
      @"SLUS-00555" : @2, // Golden Nugget (USA) (Disc 2)
      //@"SCES-02380" : @2, // Gran Turismo 2 (Europe) (En,Fr,De,Es,It) (Disc 1) (Arcade Mode)
      //@"SCES-12380" : @2, // Gran Turismo 2 (Europe) (En,Fr,De,Es,It) (Disc 2) (Gran Turismo Mode)
      //@"SCPS-10116" : @2, // Gran Turismo 2 (Japan) (Disc 1) (Arcade)
      //@"SCPS-10117" : @2, // Gran Turismo 2 (Japan) (Disc 2) (Gran Turismo) (v1.0) / (v1.1)
      @"SLES-02397" : @2, // Grandia (Europe) (Disc 1)
      @"SLES-12397" : @2, // Grandia (Europe) (Disc 2)
      @"SLES-02398" : @2, // Grandia (France) (Disc 1)
      @"SLES-12398" : @2, // Grandia (France) (Disc 2)
      @"SLES-02399" : @2, // Grandia (Germany) (Disc 1)
      @"SLES-12399" : @2, // Grandia (Germany) (Disc 2)
      @"SLPS-02124" : @2, // Grandia (Japan) (Disc 1)
      @"SLPS-02125" : @2, // Grandia (Japan) (Disc 2)
      @"SCUS-94457" : @2, // Grandia (USA) (Disc 1)
      @"SCUS-94465" : @2, // Grandia (USA) (Disc 2)
      @"SLPS-02380" : @2, // Growlanser (Japan) (Disc 1)
      @"SLPS-02381" : @2, // Growlanser (Japan) (Disc 2)
      @"SLPS-01297" : @2, // Guardian Recall - Shugojuu Shoukan (Japan) (Disc 1)
      @"SLPS-01298" : @2, // Guardian Recall - Shugojuu Shoukan (Japan) (Disc 2)
      @"SLPS-00815" : @2, // Gundam 0079 - The War for Earth (Japan) (Disc 1)
      @"SLPS-00816" : @2, // Gundam 0079 - The War for Earth (Japan) (Disc 2)
      @"SLES-02441" : @2, // GZSZ Vol. 2 (Germany) (Disc 1)
      @"SLES-12441" : @2, // GZSZ Vol. 2 (Germany) (Disc 2)
      @"SLPS-00578" : @3, // Harukaze Sentai V-Force (Japan) (Disc 1)
      @"SLPS-00579" : @3, // Harukaze Sentai V-Force (Japan) (Disc 2)
      @"SLPS-00580" : @3, // Harukaze Sentai V-Force (Japan) (Disc 3)
      @"SLES-00461" : @2, // Heart of Darkness (Europe) (Disc 1) (EDC) / (No EDC)
      @"SLES-10461" : @2, // Heart of Darkness (Europe) (Disc 2)
      @"SLES-00462" : @2, // Heart of Darkness (France) (Disc 1)
      @"SLES-10462" : @2, // Heart of Darkness (France) (Disc 2)
      @"SLES-00463" : @2, // Heart of Darkness (Germany) (Disc 1)
      @"SLES-10463" : @2, // Heart of Darkness (Germany) (Disc 2) (EDC) / (No EDC)
      @"SLES-00464" : @2, // Heart of Darkness (Italy) (Disc 1)
      @"SLES-10464" : @2, // Heart of Darkness (Italy) (Disc 2)
      @"SLES-00465" : @2, // Heart of Darkness (Spain) (Disc 1)
      @"SLES-10465" : @2, // Heart of Darkness (Spain) (Disc 2)
      @"SLUS-00696" : @2, // Heart of Darkness (USA) (Disc 1)
      @"SLUS-00741" : @2, // Heart of Darkness (USA) (Disc 2)
      @"SLPS-03340" : @4, // Helix - Fear Effect (Japan) (Disc 1)
      @"SLPS-03341" : @4, // Helix - Fear Effect (Japan) (Disc 2)
      @"SLPS-03342" : @4, // Helix - Fear Effect (Japan) (Disc 3)
      @"SLPS-03343" : @4, // Helix - Fear Effect (Japan) (Disc 4)
      @"SLPS-02641" : @2, // Hexamoon Guardians (Japan) (Disc 1)
      @"SLPS-02642" : @2, // Hexamoon Guardians (Japan) (Disc 2)
      @"SLPS-01890" : @3, // Himiko-den - Renge (Japan) (Disc 1)
      @"SLPS-01891" : @3, // Himiko-den - Renge (Japan) (Disc 2)
      @"SLPS-01892" : @3, // Himiko-den - Renge (Japan) (Disc 3)
      @"SLPS-01626" : @2, // Himitsu Sentai Metamor V Deluxe (Japan) (Disc 1)
      @"SLPS-01627" : @2, // Himitsu Sentai Metamor V Deluxe (Japan) (Disc 2)
      @"SLPS-00325" : @2, // Hive Wars, The (Japan) (Disc 1)
      @"SLPS-00326" : @2, // Hive Wars, The (Japan) (Disc 2)
      @"SLUS-00120" : @2, // Hive, The (USA) (Disc 1)
      @"SLUS-00182" : @2, // Hive, The (USA) (Disc 2)
      @"SLPS-00290" : @3, // Idol Janshi Suchie-Pai II Limited (Japan) (Disc 1)
      @"SLPS-00291" : @3, // Idol Janshi Suchie-Pai II Limited (Japan) (Disc 2) (Bonus Disc Part 1)
      @"SLPS-00292" : @3, // Idol Janshi Suchie-Pai II Limited (Japan) (Disc 3) (Bonus Disc Part 2)
      @"SCES-02149" : @2, // In Cold Blood (Europe) (Disc 1)
      @"SCES-12149" : @2, // In Cold Blood (Europe) (Disc 2)
      @"SLUS-01294" : @2, // In Cold Blood (USA) (Disc 1)
      @"SLUS-01314" : @2, // In Cold Blood (USA) (Disc 2)
      @"SLPS-00144" : @2, // J.B. Harold - Blue Chicago Blues (Japan) (Disc 1)
      @"SLPS-00145" : @2, // J.B. Harold - Blue Chicago Blues (Japan) (Disc 2)
      @"SLPS-02076" : @2, // JailBreaker (Japan) (Disc 1)
      @"SLPS-02077" : @2, // JailBreaker (Japan) (Disc 2)
      @"SLPS-00397" : @2, // Jikuu Tantei DD - Maboroshi no Lorelei (Japan) (Disc 1) (v1.0) / (v1.1)
      @"SLPS-00398" : @2, // Jikuu Tantei DD - Maboroshi no Lorelei (Japan) (Disc 2) (v1.0) / (v1.1)
      @"SLPS-01533" : @2, // Jikuu Tantei DD 2 - Hangyaku no Apusararu (Japan) (Disc 1)
      @"SLPS-01534" : @2, // Jikuu Tantei DD 2 - Hangyaku no Apusararu (Japan) (Disc 2)
      @"SLPM-86342" : @2, // Jissen Pachi-Slot Hisshouhou! Single - Kamen Rider & Gallop (Japan) (Disc 1) (Kamen Rider)
      @"SLPM-86343" : @2, // Jissen Pachi-Slot Hisshouhou! Single - Kamen Rider & Gallop (Japan) (Disc 2) (Gallop)
      @"SLPS-01671" : @3, // Juggernaut - Senritsu no Tobira (Japan) (Disc 1)
      @"SLPS-01672" : @3, // Juggernaut - Senritsu no Tobira (Japan) (Disc 2)
      @"SLPS-01673" : @3, // Juggernaut - Senritsu no Tobira (Japan) (Disc 3)
      @"SLUS-00894" : @3, // Juggernaut (USA) (Disc 1)
      @"SLUS-00988" : @3, // Juggernaut (USA) (Disc 2)
      @"SLUS-00989" : @3, // Juggernaut (USA) (Disc 3)
      @"SLPS-00563" : @2, // Karyuujou (Japan) (Disc 1) (Ryuu Hangan Hen)
      @"SLPS-00564" : @2, // Karyuujou (Japan) (Disc 2) (Kou Yuukan Hen)
      @"SLPS-02570" : @2, // Kidou Senshi Gundam - Gihren no Yabou - Zeon no Keifu (Japan) (Disc 1) (Earth Federation Disc) (v1.0) / (v1.1)
      @"SLPS-02571" : @2, // Kidou Senshi Gundam - Gihren no Yabou - Zeon no Keifu (Japan) (Disc 2) (Zeon Disc) (v1.0) / (v1.1)
      @"SLPS-01142" : @2, // Kidou Senshi Z-Gundam (Japan) (Disc 1) (v1.0)
      @"SLPS-01143" : @2, // Kidou Senshi Z-Gundam (Japan) (Disc 2) (v1.0)
      @"SCPS-45160" : @2, // Kidou Senshi Z-Gundam (Japan) (Disc 1) (v1.1)
      @"SCPS-45161" : @2, // Kidou Senshi Z-Gundam (Japan) (Disc 2) (v1.1)
      @"SLPS-01340" : @2, // Kindaichi Shounen no Jikenbo 2 - Jigoku Yuuen Satsujin Jiken (Japan) (Disc 1)
      @"SLPS-01341" : @2, // Kindaichi Shounen no Jikenbo 2 - Jigoku Yuuen Satsujin Jiken (Japan) (Disc 2)
      @"SLPS-02223" : @2, // Kindaichi Shounen no Jikenbo 3 - Seiryuu Densetsu Satsujin Jiken (Japan) (Disc 1)
      @"SLPS-02224" : @2, // Kindaichi Shounen no Jikenbo 3 - Seiryuu Densetsu Satsujin Jiken (Japan) (Disc 2)
      @"SLPS-02681" : @2, // Kizuna toyuu Na no Pendant with Toybox Stories (Japan) (Disc 1)
      @"SLPS-02682" : @2, // Kizuna toyuu Na no Pendant with Toybox Stories (Japan) (Disc 2)
      @"SLES-02897" : @4, // Koudelka (Europe) (Disc 1)
      @"SLES-12897" : @4, // Koudelka (Europe) (Disc 2)
      @"SLES-22897" : @4, // Koudelka (Europe) (Disc 3)
      @"SLES-32897" : @4, // Koudelka (Europe) (Disc 4)
      @"SLES-02898" : @4, // Koudelka (France) (Disc 1)
      @"SLES-12898" : @4, // Koudelka (France) (Disc 2)
      @"SLES-22898" : @4, // Koudelka (France) (Disc 3)
      @"SLES-32898" : @4, // Koudelka (France) (Disc 4)
      @"SLES-02899" : @4, // Koudelka (Germany) (Disc 1)
      @"SLES-12899" : @4, // Koudelka (Germany) (Disc 2)
      @"SLES-22899" : @4, // Koudelka (Germany) (Disc 3)
      @"SLES-32899" : @4, // Koudelka (Germany) (Disc 4)
      @"SLES-02900" : @4, // Koudelka (Italy) (Disc 1)
      @"SLES-12900" : @4, // Koudelka (Italy) (Disc 2)
      @"SLES-22900" : @4, // Koudelka (Italy) (Disc 3)
      @"SLES-32900" : @4, // Koudelka (Italy) (Disc 4)
      @"SLPS-02460" : @4, // Koudelka (Japan) (Disc 1)
      @"SLPS-02461" : @4, // Koudelka (Japan) (Disc 2)
      @"SLPS-02462" : @4, // Koudelka (Japan) (Disc 3)
      @"SLPS-02463" : @4, // Koudelka (Japan) (Disc 4)
      @"SLES-02901" : @4, // Koudelka (Spain) (Disc 1)
      @"SLES-12901" : @4, // Koudelka (Spain) (Disc 2)
      @"SLES-22901" : @4, // Koudelka (Spain) (Disc 3)
      @"SLES-32901" : @4, // Koudelka (Spain) (Disc 4)
      @"SLUS-01051" : @4, // Koudelka (USA) (Disc 1)
      @"SLUS-01100" : @4, // Koudelka (USA) (Disc 2)
      @"SLUS-01101" : @4, // Koudelka (USA) (Disc 3)
      @"SLUS-01102" : @4, // Koudelka (USA) (Disc 4)
      @"SLPS-00669" : @4, // Kowloon's Gate - Kowloon Fuusuiden (Japan) (Disc 1) (Byakko)
      @"SLPS-00670" : @4, // Kowloon's Gate - Kowloon Fuusuiden (Japan) (Disc 2) (Genbu)
      @"SLPS-00671" : @4, // Kowloon's Gate - Kowloon Fuusuiden (Japan) (Disc 3) (Suzaku)
      @"SLPS-00672" : @4, // Kowloon's Gate - Kowloon Fuusuiden (Japan) (Disc 4) (Seiryuu)
      //@"SLPS-01818" : @2, // Langrisser IV & V - Final Edition (Japan) (Disc 1) (Langrisser IV Disc)
      //@"SLPS-01819" : @2, // Langrisser IV & V - Final Edition (Japan) (Disc 2) (Langrisser V Disc)
      @"SCES-03043" : @4, // Legend of Dragoon, The (Europe) (Disc 1)
      @"SCES-13043" : @4, // Legend of Dragoon, The (Europe) (Disc 2)
      @"SCES-23043" : @4, // Legend of Dragoon, The (Europe) (Disc 3)
      @"SCES-33043" : @4, // Legend of Dragoon, The (Europe) (Disc 4)
      @"SCES-03044" : @4, // Legend of Dragoon, The (France) (Disc 1)
      @"SCES-13044" : @4, // Legend of Dragoon, The (France) (Disc 2)
      @"SCES-23044" : @4, // Legend of Dragoon, The (France) (Disc 3)
      @"SCES-33044" : @4, // Legend of Dragoon, The (France) (Disc 4)
      @"SCES-03045" : @4, // Legend of Dragoon, The (Germany) (Disc 1)
      @"SCES-13045" : @4, // Legend of Dragoon, The (Germany) (Disc 2)
      @"SCES-23045" : @4, // Legend of Dragoon, The (Germany) (Disc 3)
      @"SCES-33045" : @4, // Legend of Dragoon, The (Germany) (Disc 4)
      @"SCES-03046" : @4, // Legend of Dragoon, The (Italy) (Disc 1)
      @"SCES-13046" : @4, // Legend of Dragoon, The (Italy) (Disc 2)
      @"SCES-23046" : @4, // Legend of Dragoon, The (Italy) (Disc 3)
      @"SCES-33046" : @4, // Legend of Dragoon, The (Italy) (Disc 4)
      @"SCPS-10119" : @4, // Legend of Dragoon, The (Japan) (Disc 1)
      @"SCPS-10120" : @4, // Legend of Dragoon, The (Japan) (Disc 2)
      @"SCPS-10121" : @4, // Legend of Dragoon, The (Japan) (Disc 3)
      @"SCPS-10122" : @4, // Legend of Dragoon, The (Japan) (Disc 4)
      @"SCES-03047" : @4, // Legend of Dragoon, The (Spain) (Disc 1)
      @"SCES-13047" : @4, // Legend of Dragoon, The (Spain) (Disc 2)
      @"SCES-23047" : @4, // Legend of Dragoon, The (Spain) (Disc 3)
      @"SCES-33047" : @4, // Legend of Dragoon, The (Spain) (Disc 4)
      @"SCUS-94491" : @4, // Legend of Dragoon, The (USA) (Disc 1)
      @"SCUS-94584" : @4, // Legend of Dragoon, The (USA) (Disc 2)
      @"SCUS-94585" : @4, // Legend of Dragoon, The (USA) (Disc 3)
      @"SCUS-94586" : @4, // Legend of Dragoon, The (USA) (Disc 4)
      @"SLPS-00185" : @2, // Lifescape - Seimei 40 Okunen Haruka na Tabi (Japan) (Disc 1) (Aquasphere)
      @"SLPS-00186" : @2, // Lifescape - Seimei 40 Okunen Haruka na Tabi (Japan) (Disc 2) (Landsphere)
      @"SLPM-86269" : @2, // Little Lovers - She So Game (Japan) (Disc 1)
      @"SLPM-86270" : @2, // Little Lovers - She So Game (Japan) (Disc 2)
      @"SLPS-03012" : @2, // Little Princess +1 - Marl Oukoku no Ningyou Hime 2 (Japan) (Disc 1)
      @"SLPS-03013" : @2, // Little Princess +1 - Marl Oukoku no Ningyou Hime 2 (Japan) (Disc 2)
      @"SLES-03159" : @2, // Louvre - A Maldicao (Portugal) (Disc 1)
      @"SLES-13159" : @2, // Louvre - A Maldicao (Portugal) (Disc 2)
      @"SLES-03174" : @2, // Louvre - L'Ultime Malediction (France) (Disc 1)
      @"SLES-13174" : @2, // Louvre - L'Ultime Malediction (France) (Disc 2)
      @"SLES-03161" : @2, // Louvre - La maldicion final (Spain) (Disc 1)
      @"SLES-13161" : @2, // Louvre - La maldicion final (Spain) (Disc 2)
      @"SLES-03160" : @2, // Louvre - La Maledizione Finale (Italy) (Disc 1)
      @"SLES-13160" : @2, // Louvre - La Maledizione Finale (Italy) (Disc 2)
      @"SLES-03158" : @2, // Louvre - The Final Curse (Europe) (Disc 1)
      @"SLES-13158" : @2, // Louvre - The Final Curse (Europe) (Disc 2)
      @"SLPS-01397" : @2, // Lunar - Silver Star Story (Japan) (Disc 1)
      @"SLPS-01398" : @2, // Lunar - Silver Star Story (Japan) (Disc 2)
      @"SLUS-00628" : @2, // Lunar - Silver Star Story Complete (USA) (Disc 1)
      @"SLUS-00899" : @2, // Lunar - Silver Star Story Complete (USA) (Disc 2)
      @"SLPS-02081" : @3, // Lunar 2 - Eternal Blue (Japan) (Disc 1)
      @"SLPS-02082" : @3, // Lunar 2 - Eternal Blue (Japan) (Disc 2)
      @"SLPS-02083" : @3, // Lunar 2 - Eternal Blue (Japan) (Disc 3)
      @"SLUS-01071" : @3, // Lunar 2 - Eternal Blue Complete (USA) (Disc 1)
      @"SLUS-01239" : @3, // Lunar 2 - Eternal Blue Complete (USA) (Disc 2)
      @"SLUS-01240" : @3, // Lunar 2 - Eternal Blue Complete (USA) (Disc 3)
      @"SLPS-00535" : @3, // Lupin 3sei - Cagliostro no Shiro - Saikai (Japan) (Disc 1)
      @"SLPS-00536" : @3, // Lupin 3sei - Cagliostro no Shiro - Saikai (Japan) (Disc 2)
      @"SLPS-00537" : @3, // Lupin 3sei - Cagliostro no Shiro - Saikai (Japan) (Disc 3)
      @"SLPS-02576" : @2, // Ma-Jyan de Pon! Hanahuda de Koi! Our Graduation (Japan) (Disc 1) (Ma-Jyan de Pon! Our Graduation)
      @"SLPS-02577" : @2, // Ma-Jyan de Pon! Hanahuda de Koi! Our Graduation (Japan) (Disc 2) (Hanahuda de Koi! Our Graduation)
      @"SLPS-02705" : @2, // Maboroshi Tsukiyo - Tsukiyono Kitan (Japan) (Disc 1)
      @"SLPS-02706" : @2, // Maboroshi Tsukiyo - Tsukiyono Kitan (Japan) (Disc 2)
      //@"SLES-02964" : @2, // Magical Drop III (Europe) (En,Fr,De,Es,It,Nl) (Disc 1) (Magical Drop III)
      //@"SLES-12964" : @2, // Magical Drop III (Europe) (En,Fr,De,Es,It,Nl) (Disc 2) (Magical Drop +1)
      @"SLPS-00645" : @2, // Mahou Shoujo Pretty Samy - Part 1 - In the Earth (Japan) (Disc 1) (Episode 23)
      @"SLPS-00646" : @2, // Mahou Shoujo Pretty Samy - Part 1 - In the Earth (Japan) (Disc 2) (Episode 24)
      @"SLPS-00760" : @2, // Mahou Shoujo Pretty Samy - Part 2 - In the Julyhelm (Japan) (Disc 1) (Episode 25)
      @"SLPS-00761" : @2, // Mahou Shoujo Pretty Samy - Part 2 - In the Julyhelm (Japan) (Disc 2) (Episode 26)
      @"SLPS-01136" : @3, // Maria - Kimitachi ga Umareta Wake (Japan) (Disc 1)
      @"SLPS-01137" : @3, // Maria - Kimitachi ga Umareta Wake (Japan) (Disc 2)
      @"SLPS-01138" : @3, // Maria - Kimitachi ga Umareta Wake (Japan) (Disc 3)
      @"SLPS-02240" : @3, // Maria 2 - Jutai Kokuchi no Nazo (Japan) (Disc 1)
      @"SLPS-02241" : @3, // Maria 2 - Jutai Kokuchi no Nazo (Japan) (Disc 2)
      @"SLPS-02242" : @3, // Maria 2 - Jutai Kokuchi no Nazo (Japan) (Disc 3)
      @"SLPM-87148" : @2, // Martialbeat 2 (Japan) (Disc 1) (Disc-B)
      @"SLPM-87149" : @2, // Martialbeat 2 (Japan) (Disc 2) (Disc-F)
      @"SLPM-87146" : @2, // Martialbeat 2 (Japan) (Disc 1) (Disc-B) (Controller Doukon Set)
      @"SLPM-87147" : @2, // Martialbeat 2 (Japan) (Disc 2) (Disc-F) (Controller Doukon Set)
      @"SLPS-03220" : @2, // Matsumoto Reiji 999 - Story of Galaxy Express 999 (Japan) (Disc 1)
      @"SLPS-03221" : @2, // Matsumoto Reiji 999 - Story of Galaxy Express 999 (Japan) (Disc 2)
      @"SLPS-01147" : @2, // Meltylancer - Re-inforce (Japan) (Disc 1)
      @"SLPS-01148" : @2, // Meltylancer - Re-inforce (Japan) (Disc 2)
      @"SLPM-86231" : @2, // Meltylancer - The 3rd Planet (Japan) (Disc 1)
      @"SLPM-86232" : @2, // Meltylancer - The 3rd Planet (Japan) (Disc 2)
      @"SLPS-03292" : @2, // Memories Off 2nd (Japan) (Disc 1)
      @"SLPS-03293" : @2, // Memories Off 2nd (Japan) (Disc 2)
      @"SLPS-03289" : @3, // Memories Off 2nd (Japan) (Disc 1) (Shokai Genteiban)
      @"SLPS-03290" : @3, // Memories Off 2nd (Japan) (Disc 2) (Shokai Genteiban)
      @"SLPS-03291" : @3, // Memories Off 2nd (Japan) (Disc 3) (Making Disc) (Shokai Genteiban)
      @"SLPM-87108" : @2, // Mermaid no Kisetsu - Curtain Call (Japan) (Disc 1)
      @"SLPM-87109" : @2, // Mermaid no Kisetsu - Curtain Call (Japan) (Disc 2)
      @"SLPM-86934" : @3, // Mermaid no Kisetsu (Japan) (Disc 1)
      @"SLPM-86935" : @3, // Mermaid no Kisetsu (Japan) (Disc 2)
      @"SLPM-86936" : @3, // Mermaid no Kisetsu (Japan) (Disc 3)
      @"SLPS-00680" : @2, // Meta-Ph-List Gamma X 2297 (Japan) (Disc 1)
      @"SLPS-00681" : @2, // Meta-Ph-List Gamma X 2297 (Japan) (Disc 2)
      @"SLPS-00680" : @2, // Meta-Ph-List Mu.X.2297 (Japan) (Disc 1)
      @"SLPS-00681" : @2, // Meta-Ph-List Mu.X.2297 (Japan) (Disc 2)
      @"SLPS-00867" : @2, // Metal Angel 3 (Japan) (Disc 1)
      @"SLPS-00868" : @2, // Metal Angel 3 (Japan) (Disc 2)
      @"SLPM-86247" : @2, // Metal Gear Solid - Integral (Japan) (En,Ja) (Disc 1)
      @"SLPM-86248" : @2, // Metal Gear Solid - Integral (Japan) (En,Ja) (Disc 2)
      //@"SLPM-86249" : @3, // Metal Gear Solid - Integral (Japan) (Disc 3) (VR-Disc)
      @"SCPS-45317" : @2, // Metal Gear Solid (Asia) (Disc 1)
      @"SCPS-45318" : @2, // Metal Gear Solid (Asia) (Disc 2)
      @"SLES-01370" : @2, // Metal Gear Solid (Europe) (Disc 1)
      @"SLES-11370" : @2, // Metal Gear Solid (Europe) (Disc 2)
      @"SLES-01506" : @2, // Metal Gear Solid (France) (Disc 1)
      @"SLES-11506" : @2, // Metal Gear Solid (France) (Disc 2)
      @"SLES-01507" : @2, // Metal Gear Solid (Germany) (Disc 1)
      @"SLES-11507" : @2, // Metal Gear Solid (Germany) (Disc 2)
      @"SLES-01508" : @2, // Metal Gear Solid (Italy) (Disc 1)
      @"SLES-11508" : @2, // Metal Gear Solid (Italy) (Disc 2)
      @"SLPM-86111" : @2, // Metal Gear Solid (Japan) (Disc 1) (Ichi)
      @"SLPM-86112" : @2, // Metal Gear Solid (Japan) (Disc 2) (Ni)
      @"SLES-01734" : @2, // Metal Gear Solid (Spain) (Disc 1) (v1.1)
      @"SLES-11734" : @2, // Metal Gear Solid (Spain) (Disc 2) (v1.1)
      @"SLUS-00594" : @2, // Metal Gear Solid (USA) (Disc 1) (v1.0) / (v1.1)
      @"SLUS-00776" : @2, // Metal Gear Solid (USA) (Disc 2) (v1.0) / (v1.1)
      @"SLPS-01611" : @2, // Mikagura Shoujo Tanteidan (Japan) (Disc 1)
      @"SLPS-01612" : @2, // Mikagura Shoujo Tanteidan (Japan) (Disc 2)
      @"SLPS-01609" : @2, // Million Classic (Japan) (Disc 1) (Honpen Game Senyou)
      @"SLPS-01610" : @2, // Million Classic (Japan) (Disc 2) (Taisen Game Senyou)
      @"SLPS-00951" : @2, // Minakata Hakudou Toujou (Japan) (Disc 1)
      @"SLPS-00952" : @2, // Minakata Hakudou Toujou (Japan) (Disc 2)
      @"SLPS-01276" : @2, // Misa no Mahou Monogatari (Japan) (Disc 1)
      @"SLPS-01277" : @2, // Misa no Mahou Monogatari (Japan) (Disc 2)
      @"SLES-03813" : @2, // Monte Carlo Games Compendium (Europe) (Disc 1)
      @"SLES-13813" : @2, // Monte Carlo Games Compendium (Europe) (Disc 2)
      @"SLPS-01001" : @2, // Moonlight Syndrome (Japan) (Disc 1)
      @"SLPS-01002" : @2, // Moonlight Syndrome (Japan) (Disc 2)
      @"SLPM-86130" : @2, // Moritaka Chisato - Safari Tokyo (Japan) (Disc 1)
      @"SLPM-86131" : @2, // Moritaka Chisato - Safari Tokyo (Japan) (Disc 2)
      @"SCPS-10018" : @2, // Motor Toon Grand Prix 2 (Japan) (Disc 1)
      @"SCPS-10019" : @2, // Motor Toon Grand Prix 2 (Japan) (Disc 2) (Taisen Senyou Disc)
      @"SLPS-01988" : @2, // Murakoshi Seikai no Bakuchou SeaBass Fishing (Japan) (Disc 1)
      @"SLPS-01989" : @2, // Murakoshi Seikai no Bakuchou SeaBass Fishing (Japan) (Disc 2)
      @"SLPS-00996" : @2, // My Dream - On Air ga Matenakute (Japan) (Disc 1)
      @"SLPS-00997" : @2, // My Dream - On Air ga Matenakute (Japan) (Disc 2)
      @"SLPS-01562" : @2, // Mystic Mind - Yureru Omoi (Japan) (Disc 1)
      @"SLPS-01563" : @2, // Mystic Mind - Yureru Omoi (Japan) (Disc 2)
      @"SLPM-86179" : @3, // Nanatsu no Hikan (Japan) (Disc 1)
      @"SLPM-86180" : @3, // Nanatsu no Hikan (Japan) (Disc 2)
      @"SLPM-86181" : @3, // Nanatsu no Hikan (Japan) (Disc 3)
      //@"SLPS-02665" : @2, // Natsuiro Kenjutsu Komachi (Japan) (Disc 1)
      //@"SLPS-02666" : @2, // Natsuiro Kenjutsu Komachi (Japan) (Disc 2) (Special Disc)
      @"SLES-03495" : @2, // Necronomicon - Das Mysterium der Daemmerung (Germany) (Disc 1)
      @"SLES-13495" : @2, // Necronomicon - Das Mysterium der Daemmerung (Germany) (Disc 2)
      @"SLES-03497" : @2, // Necronomicon - El Alba de las Tinieblas (Spain) (Disc 1)
      @"SLES-13497" : @2, // Necronomicon - El Alba de las Tinieblas (Spain) (Disc 2)
      @"SLES-03496" : @2, // Necronomicon - Ispirato Alle Opere Di (Italy) (Disc 1)
      @"SLES-13496" : @2, // Necronomicon - Ispirato Alle Opere Di (Italy) (Disc 2)
      @"SLES-03494" : @2, // Necronomicon - L'Aube des Tenebres (France) (Disc 1)
      @"SLES-13494" : @2, // Necronomicon - L'Aube des Tenebres (France) (Disc 2)
      @"SLES-03498" : @2, // Necronomicon - O Despertar das Trevas (Portugal) (Disc 1)
      @"SLES-13498" : @2, // Necronomicon - O Despertar das Trevas (Portugal) (Disc 2)
      @"SLES-03493" : @2, // Necronomicon - The Dawning of Darkness (Europe) (Disc 1)
      @"SLES-13493" : @2, // Necronomicon - The Dawning of Darkness (Europe) (Disc 2)
      @"SLPS-01543" : @3, // Neko Zamurai (Japan) (Disc 1)
      @"SLPS-01544" : @3, // Neko Zamurai (Japan) (Disc 2)
      @"SLPS-01545" : @3, // Neko Zamurai (Japan) (Disc 3)
      //@"SLPS-00823" : @2, // Neorude (Japan) (Disc 1) (Game Disc)
      //@"SLPS-00824" : @2, // Neorude (Japan) (Disc 2) (Special Disc)
      @"SLPS-00913" : @2, // Nessa no Hoshi (Japan) (Disc 1)
      @"SLPS-00914" : @2, // Nessa no Hoshi (Japan) (Disc 2)
      @"SLPS-01045" : @3, // Nightmare Project - Yakata (Japan) (Disc 1)
      @"SLPS-01046" : @3, // Nightmare Project - Yakata (Japan) (Disc 2)
      @"SLPS-01047" : @3, // Nightmare Project - Yakata (Japan) (Disc 3)
      @"SLPS-01193" : @3, // NOeL - La Neige (Japan) (Disc 1)
      @"SLPS-01194" : @3, // NOeL - La Neige (Japan) (Disc 2)
      @"SLPS-01195" : @3, // NOeL - La Neige (Japan) (Disc 3)
      @"SLPS-01190" : @3, // NOeL - La Neige (Japan) (Disc 1) (Special Edition)
      @"SLPS-01191" : @3, // NOeL - La Neige (Japan) (Disc 2) (Special Edition)
      @"SLPS-01192" : @3, // NOeL - La Neige (Japan) (Disc 3) (Special Edition)
      @"SLPS-00304" : @2, // NOeL - Not Digital (Japan) (Disc 1) (v1.0) / (v1.1)
      @"SLPS-00305" : @2, // NOeL - Not Digital (Japan) (Disc 2)
      @"SLPS-01895" : @3, // NOeL 3 - Mission on the Line (Japan) (Disc 1)
      @"SLPS-01896" : @3, // NOeL 3 - Mission on the Line (Japan) (Disc 2)
      @"SLPS-01897" : @3, // NOeL 3 - Mission on the Line (Japan) (Disc 3)
      @"SLPM-86609" : @3, // NOeL 3 - Mission on the Line (Japan) (Disc 1) (Major Wave Series)
      @"SLPM-86610" : @3, // NOeL 3 - Mission on the Line (Japan) (Disc 2) (Major Wave Series)
      @"SLPM-86611" : @3, // NOeL 3 - Mission on the Line (Japan) (Disc 3) (Major Wave Series)
      @"SCES-00011" : @2, // Novastorm (Europe) (Disc 1)
      @"SCES-10011" : @2, // Novastorm (Europe) (Disc 2)
      @"SLPS-00314" : @2, // Novastorm (Japan) (Disc 1)
      @"SLPS-00315" : @2, // Novastorm (Japan) (Disc 2)
      @"SCUS-94404" : @2, // Novastorm (USA) (Disc 1)
      @"SCUS-94407" : @2, // Novastorm (USA) (Disc 2)
      @"SLES-01480" : @2, // Oddworld - Abe's Exoddus (Europe) (Disc 1)
      @"SLES-11480" : @2, // Oddworld - Abe's Exoddus (Europe) (Disc 2)
      @"SLES-01503" : @2, // Oddworld - Abe's Exoddus (Germany) (Disc 1)
      @"SLES-11503" : @2, // Oddworld - Abe's Exoddus (Germany) (Disc 2)
      @"SLES-01504" : @2, // Oddworld - Abe's Exoddus (Italy) (Disc 1)
      @"SLES-11504" : @2, // Oddworld - Abe's Exoddus (Italy) (Disc 2)
      @"SLES-01505" : @2, // Oddworld - Abe's Exoddus (Spain) (Disc 1)
      @"SLES-11505" : @2, // Oddworld - Abe's Exoddus (Spain) (Disc 2)
      @"SLUS-00710" : @2, // Oddworld - Abe's Exoddus (USA) (Disc 1)
      @"SLUS-00731" : @2, // Oddworld - Abe's Exoddus (USA) (Disc 2)
      @"SLES-01502" : @2, // Oddworld - L'Exode d'Abe (France) (Disc 1)
      @"SLES-11502" : @2, // Oddworld - L'Exode d'Abe (France) (Disc 2)
      @"SLPS-01495" : @2, // Ojyousama Express (Japan) (Disc 1)
      @"SLPS-01496" : @2, // Ojyousama Express (Japan) (Disc 2)
      @"SLES-01879" : @2, // OverBlood 2 (Europe) (Disc 1) (v1.0) / (v1.1)
      @"SLES-11879" : @2, // OverBlood 2 (Europe) (Disc 2) (v1.0) / (v1.1)
      @"SLES-02187" : @2, // OverBlood 2 (Germany) (Disc 1)
      @"SLES-12187" : @2, // OverBlood 2 (Germany) (Disc 2)
      @"SLES-01880" : @2, // OverBlood 2 (Italy) (Disc 1)
      @"SLES-11880" : @2, // OverBlood 2 (Italy) (Disc 2)
      @"SLPS-01261" : @2, // OverBlood 2 (Japan) (Disc 1)
      @"SLPS-01262" : @2, // OverBlood 2 (Japan) (Disc 2)
      @"SLPS-01230" : @2, // Parasite Eve (Japan) (Disc 1)
      @"SLPS-01231" : @2, // Parasite Eve (Japan) (Disc 2)
      @"SLUS-00662" : @2, // Parasite Eve (USA) (Disc 1)
      @"SLUS-00668" : @2, // Parasite Eve (USA) (Disc 2)
      @"SLES-02558" : @2, // Parasite Eve II (Europe) (Disc 1)
      @"SLES-12558" : @2, // Parasite Eve II (Europe) (Disc 2)
      @"SLES-02559" : @2, // Parasite Eve II (France) (Disc 1)
      @"SLES-12559" : @2, // Parasite Eve II (France) (Disc 2)
      @"SLES-02560" : @2, // Parasite Eve II (Germany) (Disc 1)
      @"SLES-12560" : @2, // Parasite Eve II (Germany) (Disc 2)
      @"SLES-02562" : @2, // Parasite Eve II (Italy) (Disc 1)
      @"SLES-12562" : @2, // Parasite Eve II (Italy) (Disc 2)
      @"SLPS-02480" : @2, // Parasite Eve II (Japan) (Disc 1)
      @"SLPS-02481" : @2, // Parasite Eve II (Japan) (Disc 2)
      @"SLES-02561" : @2, // Parasite Eve II (Spain) (Disc 1)
      @"SLES-12561" : @2, // Parasite Eve II (Spain) (Disc 2)
      @"SLUS-01042" : @2, // Parasite Eve II (USA) (Disc 1)
      @"SLUS-01055" : @2, // Parasite Eve II (USA) (Disc 2)
      @"SLPM-86048" : @2, // Policenauts (Japan) (Disc 1)
      @"SLPM-86049" : @2, // Policenauts (Japan) (Disc 2)
      @"SCPS-10112" : @3, // PoPoLoCrois Monogatari II (Japan) (Disc 1)
      @"SCPS-10113" : @3, // PoPoLoCrois Monogatari II (Japan) (Disc 2)
      @"SCPS-10114" : @3, // PoPoLoCrois Monogatari II (Japan) (Disc 3)
      @"SLES-00070" : @3, // Psychic Detective (Europe) (Disc 1)
      @"SLES-10070" : @3, // Psychic Detective (Europe) (Disc 2)
      @"SLES-20070" : @3, // Psychic Detective (Europe) (Disc 3)
      @"SLUS-00165" : @3, // Psychic Detective (USA) (Disc 1)
      @"SLUS-00166" : @3, // Psychic Detective (USA) (Disc 2)
      @"SLUS-00167" : @3, // Psychic Detective (USA) (Disc 3)
      //@"SLPS-01018" : @2, // Psychic Force - Puzzle Taisen (Japan) (Disc 1) (Game Disc)
      //@"SLPS-01019" : @2, // Psychic Force - Puzzle Taisen (Japan) (Disc 2) (Premium CD-ROM)
      @"SCPS-18004" : @2, // Quest for Fame - Be a Virtual Rock Legend (Japan) (Disc 1)
      @"SCPS-18005" : @2, // Quest for Fame - Be a Virtual Rock Legend (Japan) (Disc 2)
      @"SLES-03752" : @2, // Quiz Show (Italy) (Disc 1)
      @"SLES-13752" : @2, // Quiz Show (Italy) (Disc 2)
      @"SLES-00519" : @2, // Raven Project, The (Europe) (En,Fr,De) (Disc 1)
      @"SLES-10519" : @2, // Raven Project, The (Europe) (En,Fr,De) (Disc 2)
      @"SLES-00519" : @2, // Raven Project, The (Germany) (En,Fr,De) (Disc 1)
      @"SLES-10519" : @2, // Raven Project, The (Germany) (En,Fr,De) (Disc 2)
      @"SLPS-01840" : @2, // Refrain Love 2 (Japan) (Disc 1)
      @"SLPS-01841" : @2, // Refrain Love 2 (Japan) (Disc 2)
      @"SLPS-01588" : @2, // Renai Kouza - Real Age (Japan) (Disc 1)
      @"SLPS-01589" : @2, // Renai Kouza - Real Age (Japan) (Disc 2)
      @"SLUS-00748" : @2, // Resident Evil 2 - Dual Shock Ver. (USA) (Disc 1) (Leon)
      @"SLUS-00756" : @2, // Resident Evil 2 - Dual Shock Ver. (USA) (Disc 2) (Claire)
      @"SLES-00972" : @2, // Resident Evil 2 (Europe) (Disc 1)
      @"SLES-10972" : @2, // Resident Evil 2 (Europe) (Disc 2)
      @"SLES-00973" : @2, // Resident Evil 2 (France) (Disc 1)
      @"SLES-10973" : @2, // Resident Evil 2 (France) (Disc 2)
      @"SLES-00974" : @2, // Resident Evil 2 (Germany) (Disc 1)
      @"SLES-10974" : @2, // Resident Evil 2 (Germany) (Disc 2)
      @"SLES-00975" : @2, // Resident Evil 2 (Italy) (Disc 1)
      @"SLES-10975" : @2, // Resident Evil 2 (Italy) (Disc 2)
      @"SLES-00976" : @2, // Resident Evil 2 (Spain) (Disc 1)
      @"SLES-10976" : @2, // Resident Evil 2 (Spain) (Disc 2)
      @"SLUS-00421" : @2, // Resident Evil 2 (USA) (Disc 1)
      @"SLUS-00592" : @2, // Resident Evil 2 (USA) (Disc 2)
      @"SLPS-00192" : @2, // Return to Zork (Japan) (Disc 1)
      @"SLPS-00193" : @2, // Return to Zork (Japan) (Disc 2)
      @"SLPS-01643" : @2, // Ridegear Guybrave II (Japan) (Disc 1)
      @"SLPS-01644" : @2, // Ridegear Guybrave II (Japan) (Disc 2)
      //@"SLES-01436" : @2, // Rival Schools - United by Fate (Europe) (Disc 1) (Evolution Disc)
      //@"SLES-11436" : @2, // Rival Schools - United by Fate (Europe) (Disc 2) (Arcade Disc)
      //@"SLUS-00681" : @2, // Rival Schools - United by Fate (USA) (Disc 1) (Arcade Disc)
      //@"SLUS-00771" : @2, // Rival Schools - United by Fate (USA) (Disc 2) (Evolution Disc)
      @"SLES-00963" : @5, // Riven - The Sequel to Myst (Europe) (Disc 1)
      @"SLES-10963" : @5, // Riven - The Sequel to Myst (Europe) (Disc 2)
      @"SLES-20963" : @5, // Riven - The Sequel to Myst (Europe) (Disc 3)
      @"SLES-30963" : @5, // Riven - The Sequel to Myst (Europe) (Disc 4)
      @"SLES-40963" : @5, // Riven - The Sequel to Myst (Europe) (Disc 5)
      @"SLES-01099" : @5, // Riven - The Sequel to Myst (France) (Disc 1)
      @"SLES-11099" : @5, // Riven - The Sequel to Myst (France) (Disc 2)
      @"SLES-21099" : @5, // Riven - The Sequel to Myst (France) (Disc 3)
      @"SLES-31099" : @5, // Riven - The Sequel to Myst (France) (Disc 4)
      @"SLES-41099" : @5, // Riven - The Sequel to Myst (France) (Disc 5)
      @"SLES-01100" : @5, // Riven - The Sequel to Myst (Germany) (Disc 1)
      @"SLES-11100" : @5, // Riven - The Sequel to Myst (Germany) (Disc 2)
      @"SLES-21100" : @5, // Riven - The Sequel to Myst (Germany) (Disc 3)
      @"SLES-31100" : @5, // Riven - The Sequel to Myst (Germany) (Disc 4)
      @"SLES-41100" : @5, // Riven - The Sequel to Myst (Germany) (Disc 5)
      @"SLPS-01180" : @5, // Riven - The Sequel to Myst (Japan) (Disc 1)
      @"SLPS-01181" : @5, // Riven - The Sequel to Myst (Japan) (Disc 2)
      @"SLPS-01182" : @5, // Riven - The Sequel to Myst (Japan) (Disc 3)
      @"SLPS-01183" : @5, // Riven - The Sequel to Myst (Japan) (Disc 4)
      @"SLPS-01184" : @5, // Riven - The Sequel to Myst (Japan) (Disc 5)
      @"SLUS-00535" : @5, // Riven - The Sequel to Myst (USA) (Disc 1)
      @"SLUS-00563" : @5, // Riven - The Sequel to Myst (USA) (Disc 2)
      @"SLUS-00564" : @5, // Riven - The Sequel to Myst (USA) (Disc 3)
      @"SLUS-00565" : @5, // Riven - The Sequel to Myst (USA) (Disc 4)
      @"SLUS-00580" : @5, // Riven - The Sequel to Myst (USA) (Disc 5)
      @"SLPS-01087" : @2, // RMJ - The Mystery Hospital (Japan) (Disc 1) (What's Going On)
      @"SLPS-01088" : @2, // RMJ - The Mystery Hospital (Japan) (Disc 2) (Fears Behind)
      @"SLPS-02861" : @2, // RPG Tkool 4 (Japan) (Disc 1)
      @"SLPS-02862" : @2, // RPG Tkool 4 (Japan) (Disc 2) (Character Tkool)
      @"SLPS-02761" : @3, // Saraba Uchuu Senkan Yamato - Ai no Senshi-tachi (Japan) (Disc 1)
      @"SLPS-02762" : @3, // Saraba Uchuu Senkan Yamato - Ai no Senshi-tachi (Japan) (Disc 2)
      @"SLPS-02763" : @3, // Saraba Uchuu Senkan Yamato - Ai no Senshi-tachi (Japan) (Disc 3)
      @"SLPS-02200" : @2, // SD Gundam - GGeneration-0 (Japan) (Disc 1) (v1.0)
      @"SLPS-02201" : @2, // SD Gundam - GGeneration-0 (Japan) (Disc 2) (v1.0)
      @"SLPS-03206" : @2, // SD Gundam - GGeneration-0 (Japan) (Disc 1) (v1.1)
      @"SLPS-03207" : @2, // SD Gundam - GGeneration-0 (Japan) (Disc 2) (v1.1)
      @"SLPS-02912" : @3, // SD Gundam - GGeneration-F (Japan) (Disc 1)
      @"SLPS-02913" : @3, // SD Gundam - GGeneration-F (Japan) (Disc 2)
      @"SLPS-02914" : @3, // SD Gundam - GGeneration-F (Japan) (Disc 3)
      @"SLPS-01603" : @2, // Serial Experiments Lain (Japan) (Disc 1)
      @"SLPS-01604" : @2, // Serial Experiments Lain (Japan) (Disc 2)
      @"SCES-02099" : @2, // Shadow Madness (Europe) (Disc 1)
      @"SCES-12099" : @2, // Shadow Madness (Europe) (Disc 2)
      @"SCES-02100" : @2, // Shadow Madness (France) (Disc 1)
      @"SCES-12100" : @2, // Shadow Madness (France) (Disc 2)
      @"SCES-02101" : @2, // Shadow Madness (Germany) (Disc 1)
      @"SCES-12101" : @2, // Shadow Madness (Germany) (Disc 2)
      @"SCES-02102" : @2, // Shadow Madness (Italy) (Disc 1)
      @"SCES-12102" : @2, // Shadow Madness (Italy) (Disc 2)
      @"SCES-02103" : @2, // Shadow Madness (Spain) (Disc 1)
      @"SCES-12103" : @2, // Shadow Madness (Spain) (Disc 2)
      @"SLUS-00468" : @2, // Shadow Madness (USA) (Disc 1)
      @"SLUS-00718" : @2, // Shadow Madness (USA) (Disc 2)
      @"SLPS-01377" : @2, // Shin Seiki Evangelion - Koutetsu no Girlfriend (Japan) (Disc 1)
      @"SLPS-01378" : @2, // Shin Seiki Evangelion - Koutetsu no Girlfriend (Japan) (Disc 2)
      //@"SLPS-01240" : @2, // Shiritsu Justice Gakuen - Legion of Heroes (Japan) (Disc 1) (Evolution Disc)
      //@"SLPS-01241" : @2, // Shiritsu Justice Gakuen - Legion of Heroes (Japan) (Disc 2) (Arcade Disc)
      //@"SLES-00071" : @2, // Shockwave Assault (Europe) (Disc 1) (Shockwave - Invasion Earth)
      //@"SLES-10071" : @2, // Shockwave Assault (Europe) (Disc 2) (Shockwave - Operation Jumpgate)
      //@"SLUS-00028" : @2, // Shockwave Assault (USA) (Disc 1) (Shockwave - Invasion Earth)
      //@"SLUS-00137" : @2, // Shockwave Assault (USA) (Disc 2) (Shockwave - Operation Jumpgate)
      @"SLPS-02401" : @2, // Shuukan Gallop - Blood Master (Japan) (Disc 1)
      @"SLPS-02402" : @2, // Shuukan Gallop - Blood Master (Japan) (Disc 2)
      @"SLPS-03154" : @2, // Sister Princess (Japan) (Disc 1) (v1.0)
      @"SLPS-03155" : @2, // Sister Princess (Japan) (Disc 2) (v1.0)
      @"SLPS-03156" : @2, // Sister Princess (Japan) (Disc 1) (v1.1)
      @"SLPS-03157" : @2, // Sister Princess (Japan) (Disc 2) (v1.1)
      @"SLPS-03521" : @2, // Sister Princess 2 (Japan) (Disc 1) (v1.0)
      @"SLPS-03522" : @2, // Sister Princess 2 (Japan) (Disc 2) (v1.0)
      @"SLPS-03523" : @2, // Sister Princess 2 (Japan) (Disc 1) (v1.1)
      @"SLPS-03524" : @2, // Sister Princess 2 (Japan) (Disc 2) (v1.1)
      @"SLPS-03556" : @2, // Sister Princess 2 - Premium Fan Disc (Japan) (Disc A)
      @"SLPS-03557" : @2, // Sister Princess 2 - Premium Fan Disc (Japan) (Disc B)
      @"SLPS-01843" : @2, // Sonata (Japan) (Disc 1)
      @"SLPS-01844" : @2, // Sonata (Japan) (Disc 2)
      @"SLPS-01444" : @2, // Sotsugyou M - Seito Kaichou no Karei naru Inbou (Japan) (Disc 1)
      @"SLPS-01445" : @2, // Sotsugyou M - Seito Kaichou no Karei naru Inbou (Japan) (Disc 2)
      @"SLPS-01722" : @2, // Sougaku Toshi Osaka (Japan) (Disc 1 - 2)
      @"SLPS-01291" : @3, // Soukaigi (Japan) (Disc 1)
      @"SLPS-01292" : @3, // Soukaigi (Japan) (Disc 2)
      @"SLPS-01293" : @3, // Soukaigi (Japan) (Disc 3)
      @"SLPS-02313" : @2, // Soukou Kihei Votoms - Koutetsu no Gunzei (Japan) (Disc 1)
      @"SLPS-02314" : @2, // Soukou Kihei Votoms - Koutetsu no Gunzei (Japan) (Disc 2)
      @"SLPS-01041" : @2, // Soukuu no Tsubasa - Gotha World (Japan) (Disc 1)
      @"SLPS-01042" : @2, // Soukuu no Tsubasa - Gotha World (Japan) (Disc 2)
      @"SLPS-01845" : @2, // Sound Novel Evolution 3 - Machi - Unmei no Kousaten (Japan) (Disc 1)
      @"SLPS-01846" : @2, // Sound Novel Evolution 3 - Machi - Unmei no Kousaten (Japan) (Disc 2)
      @"SLPM-86408" : @3, // Southern All Stars - Space MOSA Space Museum of Southern Art (Japan) (Disc 1) (Museum)
      @"SLPM-86409" : @3, // Southern All Stars - Space MOSA Space Museum of Southern Art (Japan) (Disc 2) (Library)
      @"SLPM-86410" : @3, // Southern All Stars - Space MOSA Space Museum of Southern Art (Japan) (Disc 3) (Theater)
      @"SLPS-01196" : @4, // Star Bowling DX, The (Japan) (Disc 1)
      @"SLPS-01197" : @4, // Star Bowling DX, The (Japan) (Disc 2)
      @"SLPS-01198" : @4, // Star Bowling DX, The (Japan) (Disc 3)
      @"SLPS-01199" : @4, // Star Bowling DX, The (Japan) (Disc 4)
      @"SCES-02159" : @2, // Star Ocean - The Second Story (Europe) (Disc 1)
      @"SCES-12159" : @2, // Star Ocean - The Second Story (Europe) (Disc 2)
      @"SCES-02160" : @2, // Star Ocean - The Second Story (France) (Disc 1)
      @"SCES-12160" : @2, // Star Ocean - The Second Story (France) (Disc 2)
      @"SCES-02161" : @2, // Star Ocean - The Second Story (Germany) (Disc 1)
      @"SCES-12161" : @2, // Star Ocean - The Second Story (Germany) (Disc 2)
      @"SLPM-86105" : @2, // Star Ocean - The Second Story (Japan) (Disc 1) (v1.0) / (v1.1)
      @"SLPM-86106" : @2, // Star Ocean - The Second Story (Japan) (Disc 2) (v1.0) / (v1.1)
      @"SCUS-94421" : @2, // Star Ocean - The Second Story (USA) (Disc 1)
      @"SCUS-94422" : @2, // Star Ocean - The Second Story (USA) (Disc 2)
      @"SLES-00654" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (Europe) (Disc 1)
      @"SLES-10654" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (Europe) (Disc 2)
      @"SLES-00656" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (France) (Disc 1)
      @"SLES-10656" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (France) (Disc 2)
      @"SLES-00584" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (Germany) (Disc 1)
      @"SLES-10584" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (Germany) (Disc 2)
      @"SLES-00643" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (Italy) (Disc 1)
      @"SLES-10643" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (Italy) (Disc 2)
      @"SLPS-00638" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (Japan) (Disc 1)
      @"SLPS-00639" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (Japan) (Disc 2)
      @"SLES-00644" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (Spain) (Disc 1)
      @"SLES-10644" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (Spain) (Disc 2)
      @"SLUS-00381" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (USA) (Disc 1)
      @"SLUS-00386" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (USA) (Disc 2)
      //@"SLES-00998" : @2, // Street Fighter Collection (Europe) (Disc 1)
      //@"SLES-10998" : @2, // Street Fighter Collection (Europe) (Disc 2)
      //@"SLPS-00800" : @2, // Street Fighter Collection (Japan) (Disc 1)
      //@"SLPS-00801" : @2, // Street Fighter Collection (Japan) (Disc 2)
      //@"SLUS-00423" : @2, // Street Fighter Collection (USA) (Disc 1) (v1.0) / (v1.1)
      //@"SLUS-00584" : @2, // Street Fighter Collection (USA) (Disc 2) (v1.0) / (v1.1)
      @"SLPS-00080" : @2, // Street Fighter II Movie (Japan) (Disc 1)
      @"SLPS-00081" : @2, // Street Fighter II Movie (Japan) (Disc 2)
      //@"SLPS-02620" : @2, // Strider Hiryuu 1 & 2 (Japan) (Disc 1) (Strider Hiryuu)
      //@"SLPS-02621" : @2, // Strider Hiryuu 1 & 2 (Japan) (Disc 2) (Strider Hiryuu 2)
      @"SLPS-01264" : @2, // Suchie-Pai Adventure - Doki Doki Nightmare (Japan) (Disc 1)
      @"SLPS-01265" : @2, // Suchie-Pai Adventure - Doki Doki Nightmare (Japan) (Disc 2)
      @"SLPS-03237" : @2, // Summon Night 2 (Japan) (Disc 1)
      @"SLPS-03238" : @2, // Summon Night 2 (Japan) (Disc 2) (v1.0) / (v1.1)
      @"SLPS-01051" : @3, // Super Adventure Rockman (Japan) (Disc 1) (Episode 1 Tsuki no Shinden)
      @"SLPS-01052" : @3, // Super Adventure Rockman (Japan) (Disc 2) (Episode 2 Shitou! Wily Numbers)
      @"SLPS-01053" : @3, // Super Adventure Rockman (Japan) (Disc 3) (Episode 3 Saigo no Tatakai!!)
      @"SLPS-02070" : @2, // Super Robot Taisen - Complete Box (Japan) (Disc 1) (Super Robot Wars Complete Box)
      @"SLPS-02071" : @2, // Super Robot Taisen - Complete Box (Japan) (Disc 2) (History of Super Robot Wars)
      @"SCES-02289" : @2, // Syphon Filter 2 - Conspiracion Mortal (Spain) (Disc 1)
      @"SCES-12289" : @2, // Syphon Filter 2 - Conspiracion Mortal (Spain) (Disc 2)
      @"SCES-02285" : @2, // Syphon Filter 2 (Europe) (Disc 1) (v1.0) / (v1.1)
      @"SCES-12285" : @2, // Syphon Filter 2 (Europe) (Disc 2) (v1.0) / (v1.1)
      @"SCES-02286" : @2, // Syphon Filter 2 (France) (Disc 1)
      @"SCES-12286" : @2, // Syphon Filter 2 (France) (Disc 2)
      @"SCES-02287" : @2, // Syphon Filter 2 (Germany) (Disc 1) (EDC) / (No EDC)
      @"SCES-12287" : @2, // Syphon Filter 2 (Germany) (Disc 2)
      @"SCES-02288" : @2, // Syphon Filter 2 (Italy) (Disc 1)
      @"SCES-12288" : @2, // Syphon Filter 2 (Italy) (Disc 2)
      @"SCUS-94451" : @2, // Syphon Filter 2 (USA) (Disc 1)
      @"SCUS-94492" : @2, // Syphon Filter 2 (USA) (Disc 2)
      @"SLPM-86782" : @2, // Taiho Shichauzo - You're Under Arrest (Japan) (Disc 1)
      @"SLPM-86783" : @2, // Taiho Shichauzo - You're Under Arrest (Japan) (Disc 2)
      @"SLPM-86780" : @2, // Taiho Shichauzo - You're Under Arrest (Japan) (Disc 1) (Shokai Genteiban)
      @"SLPM-86781" : @2, // Taiho Shichauzo - You're Under Arrest (Japan) (Disc 2) (Shokai Genteiban)
      @"SLUS-01355" : @3, // Tales of Destiny II (USA) (Disc 1)
      @"SLUS-01367" : @3, // Tales of Destiny II (USA) (Disc 2)
      @"SLUS-01368" : @3, // Tales of Destiny II (USA) (Disc 3)
      @"SLPS-03050" : @3, // Tales of Eternia (Japan) (Disc 1)
      @"SLPS-03051" : @3, // Tales of Eternia (Japan) (Disc 2)
      @"SLPS-03052" : @3, // Tales of Eternia (Japan) (Disc 3)
      @"SLPS-03045" : @3, // Tales of Eternia (Japan) (Disc 1) (Premium Box)
      @"SLPS-03046" : @3, // Tales of Eternia (Japan) (Disc 2) (Premium Box)
      @"SLPS-03047" : @3, // Tales of Eternia (Japan) (Disc 3) (Premium Box)
      @"SLPS-00451" : @2, // Tenchi Muyou! Toukou Muyou (Japan) (Disc 1)
      @"SLPS-00452" : @2, // Tenchi Muyou! Toukou Muyou (Japan) (Disc 2)
      @"SLPS-01780" : @2, // Thousand Arms (Japan) (Disc 1)
      @"SLUS-00845" : @2, // Thousand Arms (Japan) (Disc 2)
      @"SLPS-01781" : @2, // Thousand Arms (USA) (Disc 1)
      @"SLUS-00858" : @2, // Thousand Arms (USA) (Disc 2)
      //@"SLPS-00094" : @2, // Thunder Storm & Road Blaster (Japan) (Disc 1) (Thunder Storm)
      //@"SLPS-00095" : @2, // Thunder Storm & Road Blaster (Japan) (Disc 2) (Road Blaster)
      @"SLPS-01919" : @2, // To Heart (Japan) (Disc 1)
      @"SLPS-01920" : @2, // To Heart (Japan) (Disc 2)
      @"SLPM-86355" : @5, // Tokimeki Memorial 2 (Japan) (Disc 1) (v1.0) / (v1.1)
      @"SLPM-86356" : @5, // Tokimeki Memorial 2 (Japan) (Disc 2) (v1.0) / (v1.1)
      @"SLPM-86357" : @5, // Tokimeki Memorial 2 (Japan) (Disc 3) (v1.0) / (v1.1)
      @"SLPM-86358" : @5, // Tokimeki Memorial 2 (Japan) (Disc 4) (v1.0) / (v1.1)
      @"SLPM-86359" : @5, // Tokimeki Memorial 2 (Japan) (Disc 5) (v1.0) / (v1.1)
      @"SLPM-86549" : @2, // Tokimeki Memorial 2 Substories - Dancing Summer Vacation (Japan) (Disc 1)
      @"SLPM-86550" : @2, // Tokimeki Memorial 2 Substories - Dancing Summer Vacation (Japan) (Disc 2)
      @"SLPM-86775" : @2, // Tokimeki Memorial 2 Substories - Leaping School Festival (Japan) (Disc 1)
      @"SLPM-86776" : @2, // Tokimeki Memorial 2 Substories - Leaping School Festival (Japan) (Disc 2)
      @"SLPM-86881" : @2, // Tokimeki Memorial 2 Substories Vol. 3 - Memories Ringing On (Japan) (Disc 1)
      @"SLPM-86882" : @2, // Tokimeki Memorial 2 Substories Vol. 3 - Memories Ringing On (Japan) (Disc 2)
      @"SLPM-86361" : @2, // Tokimeki Memorial Drama Series Vol. 2 - Irodori no Love Song (Japan) (Disc 1)
      @"SLPM-86362" : @2, // Tokimeki Memorial Drama Series Vol. 2 - Irodori no Love Song (Japan) (Disc 2)
      @"SLPM-86224" : @2, // Tokimeki Memorial Drama Series Vol. 3 - Tabidachi no Uta (Japan) (Disc 1)
      @"SLPM-86225" : @2, // Tokimeki Memorial Drama Series Vol. 3 - Tabidachi no Uta (Japan) (Disc 2)
      @"SLPS-03333" : @3, // Tokyo Majin Gakuen - Gehouchou (Japan) (Disc 1) (You)
      @"SLPS-03334" : @3, // Tokyo Majin Gakuen - Gehouchou (Japan) (Disc 2) (In)
      @"SLPS-03335" : @3, // Tokyo Majin Gakuen - Gehouchou (Japan) (Disc 3) (Ja)
      @"SLPS-03330" : @3, // Tokyo Majin Gakuen - Gehouchou (Japan) (Disc 1) (You) (Genteiban)
      @"SLPS-03331" : @3, // Tokyo Majin Gakuen - Gehouchou (Japan) (Disc 2) (In) (Genteiban)
      @"SLPS-03332" : @3, // Tokyo Majin Gakuen - Gehouchou (Japan) (Disc 3) (Ja) (Genteiban)
      @"SLPS-01432" : @2, // Tokyo Majin Gakuen - Kenpuuchou (Japan) (Disc 1) (You)
      @"SLPS-01433" : @2, // Tokyo Majin Gakuen - Kenpuuchou (Japan) (Disc 2) (In)
      @"SLPS-00285" : @3, // Tokyo Shadow (Japan) (Disc 1)
      @"SLPS-00286" : @3, // Tokyo Shadow (Japan) (Disc 2)
      @"SLPS-00287" : @3, // Tokyo Shadow (Japan) (Disc 3)
      @"SLPS-02182" : @3, // Tokyo Wakusei Planetokio (Japan) (Disc 1)
      @"SLPS-02183" : @3, // Tokyo Wakusei Planetokio (Japan) (Disc 2)
      @"SLPS-02184" : @3, // Tokyo Wakusei Planetokio (Japan) (Disc 3)
      //@"SLPM-86196" : @2, // Tomb Raider III - Adventures of Lara Croft (Japan) (Disc 1) (Japanese Version)
      //@"SLPM-86197" : @2, // Tomb Raider III - Adventures of Lara Croft (Japan) (Disc 2) (International Version)
      @"SCPS-18007" : @2, // Tomoyasu Hotei - Stolen Song (Japan) (Disc 1) (v1.0)
      @"SCPS-18008" : @2, // Tomoyasu Hotei - Stolen Song (Japan) (Disc 2) (v1.0)
      @"SCPS-18009" : @2, // Tomoyasu Hotei - Stolen Song (Japan) (Disc 1) (v1.1)
      @"SCPS-18010" : @2, // Tomoyasu Hotei - Stolen Song (Japan) (Disc 2) (v1.1)
      @"SLPS-01743" : @3, // True Love Story 2 (Japan) (Disc 1)
      @"SLPS-01744" : @3, // True Love Story 2 (Japan) (Disc 2)
      @"SLPS-01745" : @3, // True Love Story 2 (Japan) (Disc 3)
      @"SLPS-00826" : @2, // Uchuu no Rendezvous - Rama (Japan) (Disc 1)
      @"SLPS-00827" : @2, // Uchuu no Rendezvous - Rama (Japan) (Disc 2)
      @"SLPS-00846" : @3, // Unsolved, The - Hyper Science Adventure (Japan) (Disc 1)
      @"SLPS-00847" : @3, // Unsolved, The - Hyper Science Adventure (Japan) (Disc 2)
      @"SLPS-00848" : @3, // Unsolved, The - Hyper Science Adventure (Japan) (Disc 3)
      @"SLPM-86371" : @2, // Valkyrie Profile (Japan) (Disc 1) (v1.0)
      @"SLPM-86372" : @2, // Valkyrie Profile (Japan) (Disc 2) (v1.0)
      @"SLPM-86379" : @2, // Valkyrie Profile (Japan) (Disc 1) (v1.1) / (v1.2)
      @"SLPM-86380" : @2, // Valkyrie Profile (Japan) (Disc 2) (v1.1) / (v1.2)
      @"SLUS-01156" : @2, // Valkyrie Profile (USA) (Disc 1)
      @"SLUS-01179" : @2, // Valkyrie Profile (USA) (Disc 2)
      @"SLPS-00775" : @2, // Voice Idol Collection - Pool Bar Story (Japan) (Disc 1)
      @"SLPS-00776" : @2, // Voice Idol Collection - Pool Bar Story (Japan) (Disc 2)
      @"SLPS-00590" : @2, // Voice Paradice Excella (Japan) (Disc 1)
      @"SLPS-00591" : @2, // Voice Paradice Excella (Japan) (Disc 2)
      @"SLPS-01213" : @2, // Wangan Trial (Japan) (Disc 1)
      @"SLPS-01214" : @2, // Wangan Trial (Japan) (Disc 2)
      @"SCPS-10089" : @2, // Wild Arms - 2nd Ignition (Japan) (Disc 1) (v1.0) / (v1.1)
      @"SCPS-10090" : @2, // Wild Arms - 2nd Ignition (Japan) (Disc 2) (v1.0) / (v1.1)
      @"SCUS-94484" : @2, // Wild Arms 2 (USA) (Disc 1)
      @"SCUS-94498" : @2, // Wild Arms 2 (USA) (Disc 2)
      @"SLES-00074" : @4, // Wing Commander III - Heart of the Tiger (Europe) (Disc 1)
      @"SLES-10074" : @4, // Wing Commander III - Heart of the Tiger (Europe) (Disc 2)
      @"SLES-20074" : @4, // Wing Commander III - Heart of the Tiger (Europe) (Disc 3)
      @"SLES-30074" : @4, // Wing Commander III - Heart of the Tiger (Europe) (Disc 4)
      @"SLES-00105" : @4, // Wing Commander III - Heart of the Tiger (Germany) (Disc 1)
      @"SLES-10105" : @4, // Wing Commander III - Heart of the Tiger (Germany) (Disc 2)
      @"SLES-20105" : @4, // Wing Commander III - Heart of the Tiger (Germany) (Disc 3)
      @"SLES-30105" : @4, // Wing Commander III - Heart of the Tiger (Germany) (Disc 4)
      @"SLPS-00477" : @4, // Wing Commander III - Heart of the Tiger (Japan) (Disc 1)
      @"SLPS-00478" : @4, // Wing Commander III - Heart of the Tiger (Japan) (Disc 2)
      @"SLPS-00479" : @4, // Wing Commander III - Heart of the Tiger (Japan) (Disc 3)
      @"SLPS-00480" : @4, // Wing Commander III - Heart of the Tiger (Japan) (Disc 4)
      @"SLUS-00019" : @4, // Wing Commander III - Heart of the Tiger (USA) (Disc 1)
      @"SLUS-00134" : @4, // Wing Commander III - Heart of the Tiger (USA) (Disc 2)
      @"SLUS-00135" : @4, // Wing Commander III - Heart of the Tiger (USA) (Disc 3)
      @"SLUS-00136" : @4, // Wing Commander III - Heart of the Tiger (USA) (Disc 4)
      @"SLES-00659" : @4, // Wing Commander IV - The Price of Freedom (Europe) (Disc 1)
      @"SLES-10659" : @4, // Wing Commander IV - The Price of Freedom (Europe) (Disc 2)
      @"SLES-20659" : @4, // Wing Commander IV - The Price of Freedom (Europe) (Disc 3)
      @"SLES-30659" : @4, // Wing Commander IV - The Price of Freedom (Europe) (Disc 4)
      @"SLES-00660" : @4, // Wing Commander IV - The Price of Freedom (France) (Disc 1)
      @"SLES-10660" : @4, // Wing Commander IV - The Price of Freedom (France) (Disc 2)
      @"SLES-20660" : @4, // Wing Commander IV - The Price of Freedom (France) (Disc 3)
      @"SLES-30660" : @4, // Wing Commander IV - The Price of Freedom (France) (Disc 4)
      @"SLES-00661" : @4, // Wing Commander IV - The Price of Freedom (Germany) (Disc 1)
      @"SLES-10661" : @4, // Wing Commander IV - The Price of Freedom (Germany) (Disc 2)
      @"SLES-20661" : @4, // Wing Commander IV - The Price of Freedom (Germany) (Disc 3)
      @"SLES-30661" : @4, // Wing Commander IV - The Price of Freedom (Germany) (Disc 4)
      @"SLUS-00270" : @4, // Wing Commander IV - The Price of Freedom (USA) (Disc 1)
      @"SLUS-00271" : @4, // Wing Commander IV - The Price of Freedom (USA) (Disc 2)
      @"SLUS-00272" : @4, // Wing Commander IV - The Price of Freedom (USA) (Disc 3)
      @"SLUS-00273" : @4, // Wing Commander IV - The Price of Freedom (USA) (Disc 4)
      @"SCES-01565" : @4, // X-Files, The (Europe) (Disc 1)
      @"SCES-11565" : @4, // X-Files, The (Europe) (Disc 2)
      @"SCES-21565" : @4, // X-Files, The (Europe) (Disc 3)
      @"SCES-31565" : @4, // X-Files, The (Europe) (Disc 4)
      @"SCES-01566" : @4, // X-Files, The (France) (Disc 1)
      @"SCES-11566" : @4, // X-Files, The (France) (Disc 2)
      @"SCES-21566" : @4, // X-Files, The (France) (Disc 3)
      @"SCES-31566" : @4, // X-Files, The (France) (Disc 4)
      @"SCES-01567" : @4, // X-Files, The (Germany) (Disc 1)
      @"SCES-11567" : @4, // X-Files, The (Germany) (Disc 2)
      @"SCES-21567" : @4, // X-Files, The (Germany) (Disc 3)
      @"SCES-31567" : @4, // X-Files, The (Germany) (Disc 4)
      @"SCES-01568" : @4, // X-Files, The (Italy) (Disc 1)
      @"SCES-11568" : @4, // X-Files, The (Italy) (Disc 2)
      @"SCES-21568" : @4, // X-Files, The (Italy) (Disc 3)
      @"SCES-31568" : @4, // X-Files, The (Italy) (Disc 4)
      @"SCES-01569" : @4, // X-Files, The (Spain) (Disc 1)
      @"SCES-11569" : @4, // X-Files, The (Spain) (Disc 2)
      @"SCES-21569" : @4, // X-Files, The (Spain) (Disc 3)
      @"SCES-31569" : @4, // X-Files, The (Spain) (Disc 4)
      @"SLUS-00915" : @4, // X-Files, The (USA) (Disc 1)
      @"SLUS-00949" : @4, // X-Files, The (USA) (Disc 2)
      @"SLUS-00950" : @4, // X-Files, The (USA) (Disc 3)
      @"SLUS-00951" : @4, // X-Files, The (USA) (Disc 4)
      @"SLPS-01160" : @2, // Xenogears (Japan) (Disc 1)
      @"SLPS-01161" : @2, // Xenogears (Japan) (Disc 2)
      @"SLUS-00664" : @2, // Xenogears (USA) (Disc 1)
      @"SLUS-00669" : @2, // Xenogears (USA) (Disc 2)
      //@"SLPS-01581" : @4, // Yamagata Digital Museum (Japan) (Disc 1) (Spring)
      //@"SLPS-01661" : @4, // Yamagata Digital Museum (Japan) (Disc 2) (Summer)
      //@"SLPS-01662" : @4, // Yamagata Digital Museum (Japan) (Disc 3) (Autumn)
      //@"SLPS-01663" : @4, // Yamagata Digital Museum (Japan) (Disc 4) (Winter)
      @"SCPS-10053" : @2, // Yarudora Series Vol. 1 - Double Cast (Japan) (Disc 1)
      @"SCPS-10054" : @2, // Yarudora Series Vol. 1 - Double Cast (Japan) (Disc 2)
      @"SCPS-10056" : @2, // Yarudora Series Vol. 2 - Kisetsu o Dakishimete (Japan) (Disc 1)
      @"SCPS-10057" : @2, // Yarudora Series Vol. 2 - Kisetsu o Dakishimete (Japan) (Disc 2)
      @"SCPS-10067" : @2, // Yarudora Series Vol. 3 - Sampaguita (Japan) (Disc 1)
      @"SCPS-10068" : @2, // Yarudora Series Vol. 3 - Sampaguita (Japan) (Disc 2)
      @"SCPS-10069" : @2, // Yarudora Series Vol. 4 - Yukiwari no Hana (Japan) (Disc 1)
      @"SCPS-10070" : @2, // Yarudora Series Vol. 4 - Yukiwari no Hana (Japan) (Disc 2)
      @"SLUS-00716" : @2, // You Don't Know Jack (USA) (Disc 1)
      @"SLUS-00762" : @2, // You Don't Know Jack (USA) (Disc 2)
      @"SLPS-00715" : @2, // Zen Nihon GT Senshuken Max Rev. (Japan) (Disc 1)
      @"SLPS-00716" : @2, // Zen Nihon GT Senshuken Max Rev. (Japan) (Disc 2)
      @"SLPS-01657" : @2, // Zen Super Robot Taisen Denshi Daihyakka (Japan) (Disc 1)
      @"SLPS-01658" : @2, // Zen Super Robot Taisen Denshi Daihyakka (Japan) (Disc 2)
      @"SLPS-01326" : @4, // Zoku Hatsukoi Monogatari - Shuugaku Ryokou (Japan) (Disc 1)
      @"SLPS-01327" : @4, // Zoku Hatsukoi Monogatari - Shuugaku Ryokou (Japan) (Disc 2)
      @"SLPS-01328" : @4, // Zoku Hatsukoi Monogatari - Shuugaku Ryokou (Japan) (Disc 3)
      @"SLPS-01329" : @4, // Zoku Hatsukoi Monogatari - Shuugaku Ryokou (Japan) (Disc 4)
      @"SLPS-02266" : @4, // Zoku Mikagura Shoujo Tanteidan - Kanketsuhen (Japan) (Disc 1)
      @"SLPS-02267" : @4, // Zoku Mikagura Shoujo Tanteidan - Kanketsuhen (Japan) (Disc 2)
      @"SLPS-02268" : @4, // Zoku Mikagura Shoujo Tanteidan - Kanketsuhen (Japan) (Disc 3)
      @"SLPS-02269" : @4, // Zoku Mikagura Shoujo Tanteidan - Kanketsuhen (Japan) (Disc 4)
      };

    // PlayStation games requiring only 1 memory card inserted
    NSArray<NSString *> *psxSingleMemoryCardGames =
    @[
      @"SCUS-94409", // Codename - Tenka (USA) (v1.0) / (v1.1)
      @"SLES-00613", // Lifeforce Tenka (Europe)
      @"SLES-00614", // Lifeforce Tenka (France)
      @"SLES-00615", // Lifeforce Tenka (Germany)
      @"SLES-00616", // Lifeforce Tenka (Italy)
      @"SLES-00617", // Lifeforce Tenka (Spain)
      ];

    // PlayStation Konami Justifier exclusive games
    NSArray<NSString *> *psxJustifierExclusiveGames =
    @[
      @"SLES-00578", // Area 51 (Europe)
      @"SLES-03783", // Area 51 (Europe) (En,Fr,De,Es) (Midway Classics)
      @"SLPS-00726", // Area 51 (Japan)
      @"SLPS-00725", // Area 51 (Japan) (Special Pack)
      @"SLUS-00164", // Area 51 (USA) / (Rev 1)
      @"SLES-00292", // Crypt Killer (Europe)
      @"SLPM-86021", // Henry Explorers (Japan)
      @"SLUS-00335", // Crypt Killer (USA)
      //@"SLES-00445", // Die Hard Trilogy (Europe)
      //@"SLPS-00585", // Die Hard Trilogy (Japan)
      //@"SLUS-00119", // Die Hard Trilogy (USA) / (Rev 1)
      @"SLES-00542", // Lethal Enforcers I & II (Europe)
      @"SLPM-86025", // Lethal Enforcers Deluxe Pack (Japan)
      @"SLUS-00293", // Lethal Enforcers I & II (USA)
      //@"", // Horned Owl (Japan) - has no serial in the dump.
      @"SLPS-00583", // Mighty Hits (Japan)
      @"SCUS-94408", // Project - Horned Owl (USA)
      //@"SLES-00654", // Star Wars - Rebel Assault II - The Hidden Empire (Europe) (Disc 1)
      //@"SLES-10654", // Star Wars - Rebel Assault II - The Hidden Empire (Europe) (Disc 2)
      //@"SLES-00656", // Star Wars - Rebel Assault II - The Hidden Empire (France) (Disc 1)
      //@"SLES-10656", // Star Wars - Rebel Assault II - The Hidden Empire (France) (Disc 2)
      //@"SLES-00584", // Star Wars - Rebel Assault II - The Hidden Empire (Germany) (Disc 1)
      //@"SLES-10584", // Star Wars - Rebel Assault II - The Hidden Empire (Germany) (Disc 2)
      //@"SLES-00643", // Star Wars - Rebel Assault II - The Hidden Empire (Italy) (Disc 1)
      //@"SLES-10643", // Star Wars - Rebel Assault II - The Hidden Empire (Italy) (Disc 2)
      //@"SLPS-00638", // Star Wars - Rebel Assault II - The Hidden Empire (Japan) (Disc 1)
      //@"SLPS-00639", // Star Wars - Rebel Assault II - The Hidden Empire (Japan) (Disc 2)
      //@"SLES-00644", // Star Wars - Rebel Assault II - The Hidden Empire (Spain) (Disc 1)
      //@"SLES-10644", // Star Wars - Rebel Assault II - The Hidden Empire (Spain) (Disc 2)
      //@"SLUS-00381", // Star Wars - Rebel Assault II - The Hidden Empire (USA) (Disc 1)
      //@"SLUS-00386", // Star Wars - Rebel Assault II - The Hidden Empire (USA) (Disc 2)
      ];

    // PlayStation GunCon supported games
    NSArray<NSString *> *psxGunConGames =
    @[
      //@"SLES-02746", // Die Hard Trilogy 2 - Viva Las Vegas (Europe)
      //@"SLES-02747", // Die Hard Trilogy 2 - Viva Las Vegas (France)
      //@"SLES-02748", // Die Hard Trilogy 2 - Viva Las Vegas (Germany)
      //@"SLES-02749", // Die Hard Trilogy 2 - Viva Las Vegas (Italy)
      //@"SLUS-01015", // Die Hard Trilogy 2 - Viva Las Vegas (USA)
      @"SLUS-00654", // Elemental Gearbolt (USA)
      @"SLES-03990", // Extreme Ghostbusters - The Ultimate Invasion (Europe)
      @"SCES-02543", // Ghoul Panic (Europe)
      @"SLPS-02680", // Oh! Bakyuuun (Japan)
      @"SCPS-10038", // Gensei Kyokou Seirei Kidoudan - Elemental Gearbolt (Japan)
      @"SLES-03689", // Gunfighter - The Legend of Jesse James (Europe)
      @"SLUS-01398", // Gunfighter - The Legend of Jesse James (USA)
      @"SLPS-01106", // Guntu - Western Front June, 1944 - Tetsu no Kioku (Japan)
      @"SLES-00755", // Judge Dredd (Europe)
      @"SLUS-00630", // Judge Dredd (USA)
      @"SLES-01001", // Maximum Force (Europe)
      @"SLUS-00503", // Maximum Force (USA)
      @"SLES-02244", // Mighty Hits Special (Europe)
      @"SLPS-02165", // Mighty Hits Special (Japan)
      @"SLES-03278", // Moorhuhn 2 - Die Jagd geht weiter (Germany)
      @"SLES-03846", // Moorhen 3 - Chicken Chase (Europe) (En,Fr,De)
      @"SLES-03898", // Moorhen 3 - Chicken Chase (Europe) (Es,It)
      @"SLES-04174", // Moorhuhn X (Germany) (En,De)
      @"SCES-00886", // Point Blank (Europe) (En,Fr,De) / (Rev 1)
      @"SLPS-00929", // GunBullet (Japan) (GunBullet + GunCon)
      @"SLPS-00930", // GunBullet (Japan) / (Rev 1)
      @"SLUS-00481", // Point Blank (USA)
      @"SCES-02180", // Point Blank 2 (Europe, Australia)
      @"SLPS-01500", // Gunbarl (Japan, Asia)
      @"SLUS-00796", // Point Blank 2 (USA)
      @"SCES-03383", // Point Blank 3 (Europe)
      @"SLPS-03100", // Gunbalina (Japan)
      @"SLUS-01354", // Point Blank 3 (USA)
      @"SCES-02569", // Rescue Shot (Europe)
      @"SLPS-02555", // Rescue Shot Bubibo (Japan)
      @"SLES-02732", // Resident Evil - Survivor (Europe)
      @"SLES-02744", // Resident Evil - Survivor (France)
      @"SLPS-02553", // Biohazard - Gun Survivor (Japan)
      @"SLPS-02474", // Simple 1500 Series Vol. 24 - The Gun Shooting (Japan)
      @"SLPM-86816", // Simple 1500 Series Vol. 63 - The Gun Shooting 2 (Japan)
      //@"SLPS-00154", // Snatcher (Japan)
      @"SCES-00657", // Time Crisis (Europe)
      @"SLPS-00635", // Time Crisis (Japan) (Time Crisis + GunCon)
      @"SLPS-00666", // Time Crisis (Japan)
      @"SLUS-00405", // Time Crisis (USA)
      @"SCES-02776", // Time Crisis - Project Titan (Europe)
      @"SLPS-03188", // Time Crisis - Project Titan (Japan)
      @"SLUS-01336", // Time Crisis - Project Titan (USA)
      ];

    // Saturn multi-disc games
    NSDictionary<NSString *, NSNumber *> *ssMultiDiscGames =
    @{
      @"T-21301G"   : @3, // 3x3 Eyes - Kyuusei Koushu S (Japan) (Disc 1 - 3)
      //@"T-21301G"   : @3, // 3x3 Eyes - Kyuusei Koushu S (Japan) (Disc 3) (Special CD-ROM)
      @"MK-8109150" : @2, // Atlantis - The Lost Tales (Europe) (En,De,Es) (Disc 1 - 2)
      @"MK-8109109" : @2, // Atlantis - The Lost Tales (France) (Disc 1 - 2)
      @"T-21512G"   : @2, // Ayakashi Ninden Kunoichiban Plus (Japan) (Disc 1 - 2)
      @"GS-9076"    : @4, // Azel - Panzer Dragoon RPG (Japan) (Disc 1 - 4)
      @"T-19907G"   : @2, // BackGuiner - Yomigaeru Yuusha-tachi - Hishou-hen - Uragiri no Senjou (Japan) (Disc 1 - 2)
      @"T-19906G"   : @2, // BackGuiner - Yomigaeru Yuusha-tachi - Kakusei-hen - Guiner Tensei (Japan) (Disc 1 - 2)
      //@"T-22402G"   : @2, // Bakuretsu Hunter (Japan) (Disc 1)
      //@"T-22402G"   : @2, // Bakuretsu Hunter (Japan) (Disc 2) (Omake CD)
      //@"T-19703G"   : @1, // Can Can Bunny Premiere 2 (Japan) (Disc 1)
      //@"T-19703G"   : @1, // Can Can Bunny Premiere 2 (Japan) (Disc 2) (Can Bani Himekuri Calendar)
      @"GS-9172"    : @2, // Chisato Moritaka - Watarase Bashi & Lala Sunshine (Japan) (Disc 1 - 2)
      @"T-23403G"   : @2, // Chou Jikuu Yousai Macross - Ai Oboete Imasu ka (Japan) (Disc 1 - 2)
      //@"T-7028H-18" : @1, // Command & Conquer - Teil 1 - Der Tiberiumkonflikt (Germany) (Disc 1) (GDI)
      //@"T-7028H-18" : @1, // Command & Conquer - Teil 1 - Der Tiberiumkonflikt (Germany) (Disc 2) (NOD)
      //@"T-7028H-50" : @1, // Command & Conquer (Europe) (En,Fr,De) (Disc 1) (GDI)
      //@"T-7028H-50" : @1, // Command & Conquer (Europe) (En,Fr,De) (Disc 2) (NOD)
      //@"T-7028H-09" : @1, // Command & Conquer (France) (Disc 1) (GDI Disc)
      //@"T-7028H-09" : @1, // Command & Conquer (France) (Disc 2) (NOD Disc)
      //@"GS-9131"    : @1, // Command & Conquer (Japan) (Disc 1) (GDI Disc)
      //@"GS-9131"    : @1, // Command & Conquer (Japan) (Disc 2) (NOD Disc)
      //@"T-7028H"    : @1, // Command & Conquer (USA) (Disc 1) (GDI Disc)
      //@"T-7028H"    : @1, // Command & Conquer (USA) (Disc 2) (NOD Disc)
      @"T-16201H"   : @2, // Corpse Killer - Graveyard Edition (USA) (Disc 1 - 2)
      @"T-1303G"    : @2, // Creature Shock (Japan) (Disc 1 - 2)
      @"T-01304H"   : @2, // Creature Shock - Special Edition (USA) (Disc 1 - 2)
      @"T-36401G"   : @2, // Cross Tantei Monogatari - Motsureta Nanatsu no Labyrinth (Japan) (Disc 1 - 2)
      @"T-8106H-50" : @2, // D (Europe) / (France) / (Germany) (Disc 1 - 2)
      @"T-8101G"    : @2, // D no Shokutaku (Japan) (Disc 1 - 2)
      @"T-8106H"    : @2, // D (USA) (Disc 1 - 2)
      @"T-18510G"   : @2, // Daisuki (Japan) (Disc 1 - 2)
      @"T-22701G"   : @3, // DeathMask (Japan) (Disc 1 - 3)
      @"MK-81804"   : @2, // Deep Fear (Europe) (Disc 1 - 2)
      @"GS-9189"    : @2, // Deep Fear (Japan) (Disc 1 - 2)
      @"T-15031G"   : @2, // Desire (Japan) (Disc 1 - 2)
      @"T-14420G"   : @2, // Devil Summoner - Soul Hackers (Japan) (Disc 1 - 2)
      @"T-16207H"   : @2, // Double Switch (USA) (Disc 1 - 2)
      @"T-20104G"   : @2, // Doukyuusei 2 (Japan) (Disc A - B)
      //@"T-1245G"    : @1, // Dungeons & Dragons Collection (Japan) (Disc 1) (Tower of Doom)
      //@"T-1245G"    : @1, // Dungeons & Dragons Collection (Japan) (Disc 2) (Shadow over Mystara)
      @"T-10309G"   : @2, // Eberouge (Japan) (Disc 1 - 2)
      //@"T-16605G"   : @2, // Elf o Karu Monotachi (Japan) (Disc 1)
      //@"T-16605G"   : @2, // Elf o Karu Monotachi (Japan) (Disc 2) (Omake Disc)
      //@"T-16610G"   : @2, // Elf o Karu Monotachi II (Japan) (Disc 1)
      //@"T-16610G"   : @2, // Elf o Karu Monotachi II (Japan) (Disc 2) (Omake Disc)
      //@"MK-81076"   : @4, // Enemy Zero (Europe) (Disc 0) (Opening Disc)
      @"MK-81076"   : @3, // Enemy Zero (Europe) / (USA) (Disc 1 - 3) (Game Disc)
      //@"T-30001G"   : @4, // Enemy Zero (Japan) (Disc 0) (Opening Disc)
      @"T-30001G"   : @3, // Enemy Zero (Japan) (Disc 1 - 3) (Game Disc)
      //@"T-30004G"   : @4, // Enemy Zero (Japan) (Disc 0) (Opening Disc) (Satakore)
      @"T-30004G"   : @3, // Enemy Zero (Japan) (Disc 1 - 3) (Game Disc) (Satakore)
      @"T-15022G"   : @4, // Eve - Burst Error (Japan) (Disc 1 - 4) (Kojiroh Disc)
      //@"T-15022G"   : @1, // Eve - Burst Error (Japan) (Disc 2) (Marina Disc)
      //@"T-15022G"   : @1, // Eve - Burst Error (Japan) (Disc 3) (Terror Disc)
      //@"T-15022G"   : @1, // Eve - Burst Error (Japan) (Disc 4) (Making Disc)
      @"T-15035G"   : @4, // Eve - The Lost One (Japan) (Disc 1 - 4) (Kyoko Disc)
      //@"T-15035G"   : @1, // Eve - The Lost One (Japan) (Disc 2) (Snake Disc)
      //@"T-15035G"   : @1, // Eve - The Lost One (Japan) (Disc 3) (Lost One Disc)
      //@"T-15035G"   : @1, // Eve - The Lost One (Japan) (Disc 4) (Extra Disc)
      //@"T-31503G"   : @1, // Falcom Classics (Japan) (Disc 1) (Game Disc)
      //@"T-31503G"   : @1, // Falcom Classics (Japan) (Disc 2) (Special CD)
      @"T-34605G"   : @2, // Find Love 2 - Rhapsody (Japan) (Disc 1 - 2)
      @"T-20109G"   : @2, // Friends - Seishun no Kagayaki (Japan) (Disc 1 - 2)
      @"T-17005G"   : @2, // Game-Ware Vol. 4 (Japan) (Disc A - B)
      @"T-17006G"   : @2, // Game-Ware Vol. 5 (Japan) (Disc A - B)
      @"GS-9056"    : @2, // Gekka Mugentan Torico (Japan) (Disc A - B) (Kyouchou-hen)
      //@"GS-9056"    : @1, // Gekka Mugentan Torico (Japan) (Disc B) (Houkai-hen)
      @"T-4507G"    : @2, // Grandia (Japan) (Disc 1 - 2)
      @"T-19904G"   : @3, // Harukaze Sentai V-Force (Japan) (Disc 1 - 3)
      @"T-21902G"   : @3, // Haunted Casino (Japan) (Disc A - C)
      //@"T-21902G"   : @1, // Haunted Casino (Japan) (Disc B)
      //@"T-21902G"   : @1, // Haunted Casino (Japan) (Disc C)
      @"T-19714G"   : @2, // Houkago Ren'ai Club - Koi no Etude (Japan) (Disc 1 - 2)
      @"T-2001G"    : @2, // Houma Hunter Lime Perfect Collection (Japan) (Disc 1 - 2)
      @"T-5705G"    : @2, // Idol Janshi Suchie-Pai II (Japan) (Disc 1 - 2)
      @"T-5716G"    : @3, // Idol Janshi Suchie-Pai Mecha Genteiban - Hatsubai 5 Shuunen Toku Package (Japan) (Disc 1 - 3)
      //@"T-20701G"   : @1, // Interactive Movie Action - Thunder Storm & Road Blaster (Japan) (Disc 1) (Thunder Storm)
      //@"T-20701G"   : @1, // Interactive Movie Action - Thunder Storm & Road Blaster (Japan) (Disc 2) (Road Blaster)
      @"T-5302G"    : @2, // J.B. Harold - Blue Chicago Blues (Japan) (Disc 1 - 2)
      //@"T-34601G"   : @1, // Jantei Battle Cos-Player (Japan) (Disc 1)
      //@"T-34601G"   : @1, // Jantei Battle Cos-Player (Japan) (Disc 2) (Making Disc)
      @"T-2103G"    : @2, // Jikuu Tantei DD (Dracula Detective) - Maboroshi no Lorelei (Japan) (Disc A - B)
      //@"T-2103G"    : @1, // Jikuu Tantei DD (Dracula Detective) - Maboroshi no Lorelei (Japan) (Disc B)
      @"T-28002G"   : @3, // Kakyuusei (Japan) (Disc 1 - 3)
      @"GS-9195"    : @2, // Kidou Senkan Nadesico - The Blank of 3 Years (Japan) (Disc 1 - 2)
      @"T-14312G"   : @2, // Koden Koureijutsu - Hyaku Monogatari - Honto ni Atta Kowai Hanashi (Japan) (Disc 1 - 2) (Joukan)
      //@"T-14312G"   : @1, // Koden Koureijutsu - Hyaku Monogatari - Honto ni Atta Kowai Hanashi (Japan) (Disc 2) (Gekan)
      @"T-14303G"   : @2, // Kuusou Kagaku Sekai Gulliver Boy (Japan) (Disc 1 - 2)
      //@"GS-9152"    : @1, // Last Bronx (Japan) (Disc 1) (Arcade Disc)
      //@"GS-9152"    : @1, // Last Bronx (Japan) (Disc 2) (Special Disc)
      @"T-26405G"   : @2, // Lifescape - Seimei 40 Okunen Haruka na Tabi (Japan) (Disc 1 - 2) (Aquasphere)
      //@"T-26405G"   : @1, // Lifescape - Seimei 40 Okunen Haruka na Tabi (Japan) (Disc 2) (Landsphere)
      @"T-14403H"   : @2, // Lunacy (USA) (Disc 1 - 2)
      @"T-27906G"   : @2, // Lunar 2 - Eternal Blue (Japan) (Disc 1 - 2)
      @"T-18804G"   : @2, // Lupin the 3rd Chronicles (Japan) (Disc 1 - 2)
      //@"T-25302G1"  : @1, // Mahjong Doukyuusei Special (Japan) (Disc 1) (Genteiban)
      //@"T-25302G2"  : @1, // Mahjong Doukyuusei Special (Japan) (Disc 2) (Genteiban) (Portrait CD)
      //@"T-25305G1"  : @1, // Mahjong Gakuensai (Japan) (Disc 1) (Genteiban)
      //@"T-25305G2"  : @1, // Mahjong Gakuensai (Japan) (Disc 2) (Seiyuu Interview Hi CD) (Genteiban)
      //@"T-2204G"    : @1, // Mahjong-kyou Jidai Cebu Island '96 (Japan) (Disc 1)
      //@"T-2204G"    : @1, // Mahjong-kyou Jidai Cebu Island '96 (Japan) (Disc 2) (Omake Disk)
      @"T-36302G"   : @2, // Maria - Kimi-tachi ga Umareta Wake (Japan) (Disc 1 - 2)
      @"T-15038G"   : @3, // MeltyLancer Re-inforce (Japan) (Disc 1 - 3)
      @"T-14414G"   : @2, // Minakata Hakudou Toujou (Japan) (Disc 1 - 2)
      @"T-9109G"    : @3, // Moon Cradle (Japan) (Disc 1 - 3)
      @"MK-81016"   : @2, // Mr. Bones (Europe) / (USA) (Disc 1 - 2)
      @"GS-9127"    : @2, // Mr. Bones (Japan) (Disc 1 - 2)
      @"T-21303G"   : @2, // My Dream - On Air ga Matenakute (Japan) (Disc 1 - 2)
      //@"T-35501G"   : @1, // Nanatsu Kaze no Shima Monogatari (Japan) (Disc 1)
      //@"T-35501G"   : @1, // Nanatsu Kaze no Shima Monogatari (Japan) (Disc 2) (Premium CD)
      @"T-7616G"    : @3, // Nanatsu no Hikan (Japan) (Disc 1 - 3)
      @"GS-9194"    : @2, // Neon Genesis - Evangelion - Koutetsu no Girlfriend (Japan) (Disc 1 - 2)
      @"T-22205G"   : @3, // Noel 3 (Japan) (Disc 1 - 3)
      @"T-27803G"   : @2, // Ojousama Express (Japan) (Disc 1 - 2)
      //@"T-21904G"   : @1, // Ousama Game (Japan) (Disc 1) (Ichigo Disc)
      //@"T-21904G"   : @1, // Ousama Game (Japan) (Disc 2) (Momo Disc)
      @"MK-81307"   : @4, // Panzer Dragoon Saga (Europe) / (USA) (Disc 1 - 4)
      @"T-36001G"   : @8, // PhantasM (Japan) (Disc 1 - 8)
      //@"T-20114G"   : @1, // Pia Carrot e Youkoso!! 2 (Japan) (Disc 1) (Game Disc)
      //@"T-20114G"   : @1, // Pia Carrot e Youkoso!! 2 (Japan) (Disc 2) (Special Disc)
      @"T-9510G"    : @3, // Policenauts (Japan) (Disc 1 - 3)
      @"T-17402G"   : @2, // QuoVadis 2 - Wakusei Kyoushuu Ovan Rei (Japan) (Disc 1 - 2)
      @"GS-9011"    : @2, // Rampo (Japan) (Disc 1 - 2)
      @"T-30002G"   : @4, // Real Sound - Kaze no Regret (Japan) (Disc 1 - 4)
      @"T-5308G"    : @2, // Refrain Love - Anata ni Aitai (Japan) (Disc 1 - 2)
      @"MK-8180145" : @4, // Riven - A Sequencia de Myst (Brazil) (Disc 1 - 4)
      @"MK-81801"   : @4, // Riven - The Sequel to Myst (Europe) (Disc 1 - 4)
      @"T-35503G"   : @4, // Riven - The Sequel to Myst (Japan) (Disc 1 - 4)
      @"T-14415G"   : @2, // Ronde (Japan) (Disc 1 - 2)
      @"T-19508G"   : @2, // Roommate W - Futari (Japan) (Disc 1 - 2)
      @"T-32602G"   : @2, // Sakura Taisen - Teigeki Graph (Japan) (Disc 1 - 2)
      @"GS-9037"    : @2, // Sakura Taisen (Japan) (Disc 1 - 2)
      @"GS-9169"    : @3, // Sakura Taisen 2 - Kimi, Shinitamou Koto Nakare (Japan) (Disc 1 - 3)
      @"GS-9160"    : @2, // Sakura Taisen Jouki Radio Show (Japan) (Disc 1 - 2)
      //@"T-14410G"   : @1, // Sengoku Blade - Sengoku Ace Episode II (Japan) (Disc 1)
      //@"T-14410G"   : @1, // Sengoku Blade - Sengoku Ace Episode II (Japan) (Disc 2) (Sengoku Kawaraban)
      //@"T-30902G"   : @1, // Senkutsu Katsuryu Taisen - Chaos Seed (Japan) (Disc 1)
      //@"T-30902G"   : @1, // Senkutsu Katsuryu Taisen - Chaos Seed (Japan) (Disc 2) (Omake CD)
      //@"T-20106G"   : @1, // Sentimental Graffiti (Japan) (Disc 1) (Game Disc)
      //@"T-20106G"   : @1, // Sentimental Graffiti (Japan) (Disc 2) (Second Window)
      @"T-14322G"   : @2, // Shiroki Majo - Mou Hitotsu no Eiyuu Densetsu (Japan) (Disc 1 - 2)
      @"GS-9182"    : @2, // Shoujo Kakumei Utena - Itsuka Kakumei Sareru Monogatari (Japan) (Disc 1 - 2)
      @"T-2205G"    : @2, // Soukuu no Tsubasa - Gotha World (Japan) (Disc 1 - 2)
      @"T-34001G"   : @2, // Sound Novel Machi (Japan) (Disc 1 - 2)
      @"T-21804G"   : @2, // Star Bowling, The (Japan) (Disc 1 - 2)
      @"T-21805G"   : @2, // Star Bowling Vol. 2, The (Japan) (Disc 1 - 2)
      //@"T-7033H-50" : @1, // Street Fighter Collection (Europe) (Disc 1)
      //@"T-7033H-50" : @1, // Street Fighter Collection (Europe) (Disc 2)
      //@"T-1223G"    : @1, // Street Fighter Collection (Japan) (Disc 1)
      //@"T-1223G"    : @1, // Street Fighter Collection (Japan) (Disc 2)
      //@"T-1222H"    : @1, // Street Fighter Collection (USA) (Disc 1)
      //@"T-1222H"    : @1, // Street Fighter Collection (USA) (Disc 2)
      @"T-1204G"    : @2, // Street Fighter II Movie (Japan) (Disc 1 - 2)
      @"T-5713G"    : @2, // Suchie-Pai Adventure - Doki Doki Nightmare (Japan) (Disc 1 - 2)
      @"T-1225G"    : @3, // Super Adventure Rockman (Japan) (Disc 1 - 3)
      @"T-21802G"   : @2, // Tenchi Muyou! Mimiri Onsen - Yukemuri no Tabi (Japan) (Disc 1 - 2)
      @"T-26103G"   : @2, // Tenchi Muyou! Toukou Muyou - Aniraji Collection (Japan) (Disc 1 - 2)
      @"T-14301G"   : @2, // Tengai Makyou - Daiyon no Mokushiroku - The Apocalypse IV (Japan) (Disc 1 - 2)
      //@"T-20702G"   : @1, // Time Gal & Ninja Hayate (Time Gal) (Japan) (Disc 1)
      //@"T-20702G"   : @1, // Time Gal & Ninja Hayate (Ninja Hayate) (Japan) (Disc 1)
      @"T-9529G"    : @2, // Tokimeki Memorial Drama Series Vol. 2 - Irodori no Love Song (Japan) (Disc 1 - 2)
      @"T-9532G"    : @2, // Tokimeki Memorial Drama Series Vol. 3 - Tabidachi no Uta (Japan) (Disc 1 - 2)
      @"T-1110G"    : @3, // Tokyo Shadow (Japan) (Disc 1 - 3)
      @"MK-81053"   : @2, // Torico (Europe) (Disc 1 - 2)
      @"T-35601G"   : @2, // Tutankhamen no Nazo - A.N.K.H (Japan) (Disc 1 - 2)
      //@"T-37301G"   : @1, // Twinkle Star Sprites (Japan) (Disc 1)
      //@"T-37301G"   : @1, // Twinkle Star Sprites (Japan) (Disc 2) (Omake CD)
      @"T-7017G"    : @3, // Unsolved, The (Japan) (Disc 1 - 3)
      //@"T-19718G"   : @1, // Virtuacall S (Japan) (Disc 1) (Game Honpen)
      //@"T-19718G"   : @1, // Virtuacall S (Japan) (Disc 2) (Shokai Gentei Yobikake-kun)
      @"T-14304G"   : @3, // Virus (Japan) (Disc 1 - 3)
      //@"T-16706G"   : @1, // Voice Fantasia S - Ushinawareta Voice Power (Japan) (Disc 1)
      //@"T-16706G"   : @1, // Voice Fantasia S - Ushinawareta Voice Power (Japan) (Disc 2) (Premium CD-ROM)
      @"T-1312G"    : @2, // Voice Idol Maniacs - Pool Bar Story (Japan) (Disc 1 - 2)
      @"GS-9007"    : @2, // WanChai Connection (Japan) (Disc 1 - 2)
      //@"T-9103G"    : @1, // Wangan Dead Heat + Real Arrange (Japan) (Disc 1)
      //@"T-9103G"    : @1, // Wangan Dead Heat + Real Arrange (Japan) (Disc 2) (Addition)
      @"T-20117G"   : @2, // With You - Mitsumeteitai (Japan) (Disc 1 - 2)
      @"T-37001G"   : @2, // Wizardry Nemesis - The Wizardry Adventure (Japan) (Disc 1 - 2)
      @"T-33005G"   : @4, // Zoku Hatsukoi Monogatari - Shuugaku Ryokou (Japan) (Disc 1 - 4)
      };

    // Saturn Multitap supported games
    NSDictionary<NSString *, NSNumber *> *ssMultiTapGames =
    @{
      @"T-6004G"    : @4, // America Oudan Ultra Quiz (Japan)
      @"T-20001G"   : @4, // Bakushou!! All Yoshimoto Quiz Ou Ketteisen DX (Japan)
      @"T-13003H50" : @4, // Blast Chamber (Europe)
      @"T-13003H"   : @4, // Blast Chamber (USA)
      @"T-16408H"   : @4, // Break Point (Europe)
      @"T-9107G"    : @4, // Break Point (Japan)
      @"T-8145H"    : @4, // Break Point Tennis (USA)
      @"T-1235G"    : @3, // Capcom Generation - Dai-4-shuu Kokou no Eiyuu (Japan)
      @"T-8111H"    : @4, // College Slam (USA)
      @"T-14316G"   : @7, // Denpa Shounenteki Game (Japan)
      @"T-14318G"   : @7, // Denpa Shounenteki Game (Japan) (Reprint)
      @"MK-81071"   : @7, // Duke Nukem 3D (Europe) / (USA) (Death Tank Zwei mini-game has 7-player support)
      @"T-10302G"   : @4, // DX Jinsei Game (Japan)
      @"T-10310G"   : @4, // DX Jinsei Game II (Japan)
      @"T-10306G"   : @5, // DX Nippon Tokkyuu Ryokou Game (Japan)
      @"T-5025H-50" : @8, // FIFA - Road to World Cup 98 (Europe) ** warning: broken multitap code **
      @"T-5025H"    : @8, // FIFA - Road to World Cup 98 (USA) ** warning: broken multitap code **
      @"T-5003H"    : @6, // FIFA Soccer 96 (Europe) / (USA)
      @"T-10606G"   : @6, // FIFA Soccer 96 (Japan)
      @"T-5017H"    : @8, // FIFA Soccer 97 (Europe) / (USA)
      @"T-4308G"    : @6, // Fire Prowrestling S - 6Men Scramble (Japan)
      @"T-14411G"   : @4, // Gouketsuji Ichizoku 3: Groove on Fight (Japan)
      @"MK-81035"   : @6, // Guardian Heroes (Europe) / (USA)
      @"GS-9031"    : @6, // Guardian Heroes (Japan)
      @"T-20902G"   : @4, // Hansha de Spark! (Japan)
      @"T-1102G"    : @4, // HatTrick Hero S (Japan)
      @"T-7015H"    : @4, // Hyper 3-D Pinball (USA) / Tilt! (Europe)
      @"T-7007G"    : @4, // Hyper 3D Pinball (Japan)
      @"T-3602G"    : @4, // J. League Go Go Goal! (Japan)
      @"T-9528G"    : @4, // J. League Jikkyou Honoo no Striker (Japan)
      @"GS-9034"    : @8, // J. League Pro Soccer Club o Tsukurou! (Japan)
      @"GS-9168"    : @8, // J. League Pro Soccer Club o Tsukurou! 2 (Japan)
      @"GS-9048"    : @4, // J. League Victory Goal '96 (Japan)
      @"GS-9140"    : @4, // J. League Victory Goal '97 (Japan)
      @"T-12003H50" : @4, // Jonah Lomu Rugby (Europe)
      @"T-12003H09" : @4, // Jonah Lomu Rugby (Europe)
      @"T-30306G"   : @4, // Keriotosse! (Japan)
      @"T-5010H"    : @8, // Madden NFL 97 (Europe) / (USA)
      @"T-5024H"    : @8, // Madden NFL 98 (Europe) / (USA)
      //@"T-11401G"   : @4, // Masters - Harukanaru Augusta 3 (Japan)
      @"MK81103-50" : @10, // NBA Action (Europe)
      @"MK-81103"   : @10, // NBA Action (USA)
      @"MK-81124"   : @10, // NBA Action 98 (Europe) / (USA)
      @"T-8120H-50" : @4, // NBA Jam Extreme (Europe)
      @"T-8122G"    : @4, // NBA Jam Extreme (Japan)
      @"T-8120H"    : @4, // NBA Jam Extreme (USA)
      @"T-8102H-50" : @4, // NBA Jam Tournament Edition (Europe)
      @"T-8102G"    : @4, // NBA Jam Tournament Edition (Japan)
      @"T-8102H"    : @4, // NBA Jam Tournament Edition (USA)
      @"T-5015H"    : @10, // NBA Live 97 (Europe) / (USA)
      @"T-5027H"    : @8, // NBA Live 98 (Europe) / (USA)
      @"MK-81111"   : @8, // NFL '97 (USA)
      @"T-8109H-50" : @12, // NFL Quarterback Club 96 (Europe)
      @"T-8105G"    : @12, // NFL Quarterback Club 96 (Japan)
      @"T-8109H"    : @12, // NFL Quarterback Club 96 (USA)
      @"T-8136H-50" : @12, // NFL Quarterback Club 97 (Europe)
      @"T-8116G"    : @12, // NFL Quarterback Club 97 (Japan)
      @"T-8136H"    : @12, // NFL Quarterback Club 97 (USA)
      @"T-5016H"    : @8, // NHL 97 (Europe) / (USA)
      @"T-10620G"   : @8, // NHL 97 (Japan)
      @"T-5026H-50" : @12, // NHL 98 (Europe)
      @"T-5026H"    : @12, // NHL 98 (USA)
      @"MK-8100250" : @12, // NHL All-Star Hockey (Europe)
      @"MK-81002"   : @12, // NHL All-Star Hockey (USA)
      @"MK-81122"   : @8, // NHL All-Star Hockey 98 (Europe) / (USA)
      @"T-7013H-50" : @6, // NHL Powerplay (Europe)
      @"T-7012G"    : @6, // NHL Powerplay '96 (Japan)
      @"T-07013H"   : @6, // NHL Powerplay '96 (USA)
      @"T-5206G"    : @4, // Noon (Japan)
      @"T-07904H50" : @4, // Olympic Soccer (Europe)
      @"T-07904H18" : @4, // Olympic Soccer (Germany)
      @"T-7304G"    : @4, // Olympic Soccer (Japan)
      @"T-07904H"   : @4, // Olympic Soccer (USA)
      //@"MK-81101"   : @4, // Pebble Beach Golf Links (Europe) / (USA)
      //@"GS-9006"    : @4, // Pebble Beach Golf Links - Stadler ni Chousen (Japan)
      //@"T-5011H"    : @4, // PGA Tour 97 (Europe) / (USA)
      //@"T-10619G"   : @4, // PGA Tour 97 (Japan)
      @"MK-81084"   : @6, // Exhumed (Europe) (Death Tank mini-game has 6-player support)
      @"T-13205H"   : @6, // Powerslave (USA) (Death Tank mini-game has 6-player support)
      @"T-18001G"   : @6, // Seireki 1999 - Pharaoh no Fukkatsu (Japan) (Death Tank mini-game has 6-player support)
      @"MK-81070"   : @10, // Saturn Bomberman (Europe) / (USA)
      @"T-14302G"   : @10, // Saturn Bomberman (Japan)
      @"T-14321G"   : @4, // Saturn Bomberman Fight!! (Japan)
      @"GS-9043"    : @4, // Sega Ages - Rouka ni Ichidanto R (Japan)
      @"MK-81105"   : @4, // Sega International Victory Goal (Europe) / Worldwide Soccer - Sega International Victory Goal Edition (USA)
      @"GS-9044"    : @4, // Sega International Victory Goal (Japan)
      @"MK-81112"   : @4, // Sega Worldwide Soccer 97 (Europe) / (USA)
      @"MK-81123"   : @4, // Sega Worldwide Soccer 98 - Club Edition (Europe) / Worldwide Soccer 98 (USA)
      @"GS-9187"    : @4, // Sega Worldwide Soccer 98 (Japan)
      @"T-15902H50" : @4, // Slam 'n Jam '96 featuring Magic & Kareem - Signature Edition (Europe)
      @"T-159056"   : @4, // Slam 'n Jam '96 featuring Magic & Kareem (Japan)
      @"T-159028H"  : @4, // Slam 'n Jam '96 featuring Magic & Kareem - Signature Edition (USA)
      @"T-8125H-50" : @6, // Space Jam (Europe)
      @"T-8119G"    : @6, // Space Jam (Japan)
      @"T-8125H"    : @6, // Space Jam (USA)
      @"T-17702H"   : @8, // Street Racer (Europe)
      @"T-17702G"   : @8, // Street Racer Extra (Japan)
      @"T-8133H-50" : @4, // Striker '96 (Europe)
      @"T-8114G"    : @4, // Striker '96 (Japan)
      @"T-8133H"    : @4, // Striker '96 (USA)
      @"T-5713G"    : @4, // Suchie-Pai Adventure - Doki Doki Nightmare (Japan) (Disc 1 - 2)
      @"MK-81033"   : @3, // Three Dirty Dwarves (Europe)
      @"GS-9137"    : @3, // Three Dirty Dwarves (Japan)
      @"T-30401H"   : @3, // Three Dirty Dwarves (USA)
      @"T-25411450" : @4, // Trash It (Europe)
      @"MK-81180"   : @4, // UEFA Euro 96 England (Europe)
      @"T-31501G"   : @6, // Vatlva (Japan)
      @"GS-9002"    : @4, // Victory Goal (Japan)
      @"GS-9112"    : @4, // Victory Goal Worldwide Edition (Japan)
      @"T-8129H-50" : @4, // Virtual Open Tennis (Europe)
      @"T-15007G"   : @4, // Virtual Open Tennis (Japan)
      @"T-8129H"    : @4, // Virtual Open Tennis (USA)
      @"MK-81129"   : @4, // Winter Heat (Europe) / (USA)
      @"GS-9177"    : @4, // Winter Heat (Japan)
      @"T-2002G"    : @4, // World Evolution Soccer (Japan)
      @"MK-81181"   : @4, // World League Soccer '98 (Europe)
      @"GS-9196"    : @4, // World Cup '98 France - Road to Win (Japan)
      @"T-8126H-50" : @4, // WWF In Your House (Europe)
      @"T-8120G"    : @4, // WWF In Your House (Japan)
      @"T-8126H"    : @4, // WWF In Your House (USA)
      };

    // Saturn 3D Control Pad supported games (including some Arcade Racer and Mission Stick)
    NSArray<NSString *> *ss3DControlPadGames =
    @[
      @"GS-9087",    // Advanced World War Sennen Teikoku no Koubou - Last of the Millennium (Japan)
      @"GS-9076",    // Azel - Panzer Dragoon RPG (Japan) (Disc 1 - 4)
      @"T-33901G",   // Baroque (Japan)
      @"T-10627G",   // Battle Garegga (Japan)
      @"T-7011H-50", // Black Fire (Europe)
      @"T-7003G",    // Black Fire (Japan)
      @"MK-81003",   // Black Fire (USA)
      @"MK-81803",   // Burning Rangers (Europe) / (USA)
      @"GS-9174",    // Burning Rangers (Japan)
      @"T-19706G",   // Can Can Bunny Extra (Japan)
      @"T-19703G",   // Can Can Bunny Premiere 2 (Japan) (Disc 1 - 2)
      @"T-10314G",   // Choro Q Park (Japan)
      @"T-23502G",   // Code R (Japan)
      @"T-9507H",    // Contra - Legacy of War (USA)
      @"610-6483",   // Christmas NiGHTS into Dreams... (Europe)
      @"610-6431",   // Christmas NiGHTS into Dreams... (Japan)
      @"MK-81067",   // Christmas NiGHTS into Dreams... (USA)
      @"T-5029H-50", // Croc - Legend of the Gobbos (Europe) / (USA)
      @"T-26410G",   // Croc! - Pau-Pau Island (Japan)
      //@"T-9509H-50", // Crypt Killer (Europe)
      //@"T-9518G",    // Henry Explorers (Japan)
      //@"T-9509H",    // Crypt Killer (USA)
      @"MK-81205",   // Cyber Speedway (Europe)
      @"MK-81204",   // Cyber Speedway (USA)
      @"GS-9022",    // Gran Chaser (Japan)
      @"T-18510G",   // Daisuki (Japan) (Disc 1 - 2)
      @"MK-81304",   // Dark Savior (Europe) / (USA)
      @"T-22101G",   // Dark Savior (Japan)
      @"MK-81213",   // Daytona USA Championship Circuit Edition (Europe) / (Korea) / (USA)
      @"GS-9100",    // Daytona USA Circuit Edition (Japan)
      @"MK-81218",   // Daytona USA C.C.E. Net Link Edition (USA)
      @"MK-81804",   // Deep Fear (Europe) (Disc 1 - 2)
      @"GS-9189",    // Deep Fear (Japan) (Disc 1 - 2)
      @"T-15019G",   // Drift King Shutokou Battle '97 - Tsuchiya Keiichi & Bandou Masaaki (Japan)
      @"MK-81071",   // Duke Nukem 3D (Europe) / (USA)
      @"T-9111G",    // Dungeon Master Nexus (Japan)
      @"MK-81076",   // Enemy Zero (Europe) / (USA) (Disc 1 - 3) (Game Disc)
      @"T-30001G",   // Enemy Zero (Japan) (Disc 1 - 3) (Game Disc)
      @"T-30004G",   // Enemy Zero (Japan) (Disc 1 - 3) (Game Disc) (Satakore)
      @"MK-81084",   // Exhumed (Europe)
      @"T-13205H",   // Powerslave (USA)
      @"T-5710G",    // Fantastep (Japan)
      @"MK-81073",   // Fighters Megamix (Europe) / (USA)
      @"GS-9126",    // Fighters Megamix (Japan)
      @"MK-81282",   // Formula Karts - Special Edition (Europe) (En,Fr,De,Es)
      @"T-21701G",   // Fuusui Sensei - Feng-Shui Master (Japan)
      //@"T-30603G",   // G Vector (Japan)
      @"GS-9003",    // Gale Racer (Japan) (En,Ja)
      @"GS-9086",    // Greatest Nine '96 (Japan)
      @"T-5714G",    // GT24 (Japan)
      @"MK-81202",   // Hang On GP '96 (Europe) / Hang-On GP (USA)
      @"GS-9032",    // Hang On GP '95 (Japan)
      @"T-12303H",   // Hardcore 4X4 (Europe)
      @"T-13703H",   // TNN Motor Sports Hardcore 4X4 (USA)
      @"T-4313G",    // Deka Yonku - Tough The Truck (Japan)
      //@"MK-81802",   // House of the Dead, The (Europe) / (USA)
      //@"GS-9173",    // House of the Dead, The (Japan)
      @"T-25503G",   // Initial D - Koudou Saisoku Densetsu (Japan)
      @"T-18008G",   // Jungle Park - Saturn Shima (Japan)
      @"T-19723G",   // Kiss yori... (Japan)
      @"MK-81065",   // Lost World - Jurassic Park, The (Europe) / (USA)
      @"GS-9162",    // Lost World - Jurassic Park, The (Japan)
      @"T-10611G",   // Magic Carpet (Japan)
      @"MK-81210",   // Manx TT Super Bike (Europe) / (USA)
      @"GS-9102",    // Manx TT Super Bike (Japan)
      @"T-13004H",   // MechWarrior 2 - 31st Century Combat (Europe) / (USA)
      @"T-23406G",   // MechWarrior 2 (Japan)
      @"MK-81300",   // Mystaria - The Realms of Lore (Europe) / (USA)
      @"MK-81303",   // Blazing Heroes (USA)
      @"GS-9021",    // Riglordsaga (Japan)
      @"MK-81020",   // NiGHTS into Dreams... (Europe) / (USA)
      @"GS-9046",    // NiGHTS into Dreams... (Japan)
      @"T-10613G",   // Nissan Presents - Over Drivin' GT-R (Japan)
      @"T-9108G",    // Ochigee Designer Tsukutte Pon! (Japan)
      @"T-9104G",    // Ooedo Renaissance (Japan)
      //@"MK-81009",   // Panzer Dragoon (Europe) / (Korea) / (USA)
      //@"GS-9015",    // Panzer Dragoon (Japan)
      @"MK-81022",   // Panzer Dragoon Zwei (Europe) / (USA)
      @"GS-9049",    // Panzer Dragoon Zwei (Japan)
      @"MK-81307",   // Panzer Dragoon Saga (Europe) / (USA) (Disc 1 - 4)
      @"T-19708G",   // Pia Carrot e Youkoso!! We've Been Waiting for You (Japan)
      @"T-18711G",   // Planet Joker (Japan)
      @"MK-081066",  // Quake (Europe) / (USA)
      @"GS-9084",    // Riglordsaga 2 (Japan)
      @"MK-81604",   // Sega Ages Volume 1 (Europe)
      @"T-12707H",   // Sega Ages (USA)
      @"GS-9109",    // Sega Ages - After Burner II (Japan)
      @"GS-9197",    // Sega Ages - Galaxy Force II (Japan)
      @"GS-9110",    // Sega Ages - OutRun (Japan)
      @"GS-9181",    // Sega Ages - Power Drift (Japan)
      //@"GS-9108",    // Sega Ages - Space Harrier (Japan)
      @"GS-9116",    // Sega Rally Championship Plus (Japan)
      @"MK-81215",   // Sega Rally Championship Plus Net Link Edition (USA)
      @"MK-81216",   // Sega Touring Car Championship (Europe) / (USA)
      @"GS-9164",    // Sega Touring Car Championship (Japan)
      @"MK-81383",   // Shining Force III (Europe) / (USA)
      @"GS-9175",    // Shining Force III - Scenario 1 - Outo no Kyoshin (Japan)
      @"GS-9188",    // Shining Force III - Scenario 2 - Nerawareta Miko (Japan)
      @"GS-9203",    // Shining Force III - Scenario 3 - Hyouheki no Jashinguu (Japan)
      @"6106979",    // Shining Force III Premium Disc (Japan)
      @"MK-81051",   // Sky Target (Europe) / (USA)
      @"GS-9103",    // Sky Target (Japan)
      @"MK-8106250", // Sonic 3D - Flickies' Island (Europe)
      @"GS-9143",    // Sonic 3D - Flickies' Island (Japan)
      @"MK-81062",   // Sonic 3D Blast (USA)
      @"MK-81800",   // Sonic R (Europe) / (USA)
      @"GS-9170",    // Sonic R (Japan)
      @"MK-81079",   // Sonic Jam (Europe) / (USA)
      @"GS-9147",    // Sonic Jam (Japan)
      @"T-10616G",   // Soukyuu Gurentai (Japan)
      @"T-10626G",   // Soukyuu Gurentai Otokuyou (Japan)
      @"T-5013H",    // Soviet Strike (Europe) / (USA)
      @"T-10621G",   // Soviet Strike (Japan)
      @"T-1105G",    // Taito Chase H.Q. + S.C.I. (Japan)
      //@"T-4801G",    // Tama - Adventurous Ball in Giddy Labyrinth (Japan)
      @"T-14412G",   // Touge King the Spirits 2 (Japan)
      //@"MK-81043",   // Virtua Cop 2 (Europe) / (Korea) / (USA)
      //@"GS-9097",    // Virtua Cop 2 (Japan)
      @"T-19718G",   // Virtuacall S (Japan) (Disc 1) (Game Honpen)
      @"T-7104G",    // Virtual Kyoutei 2 (Japan)
      @"MK-81024",   // Wing Arms (Europe) / (USA)
      @"GS-9038",    // Wing Arms (Japan)
      @"MK-81129",   // Winter Heat (Europe) / (USA)
      @"GS-9177",    // Winter Heat (Japan)
      @"T-11308H-50",// WipEout 2097 (Europe)
      @"T-18619G",   // WipEout XL (Japan)
      @"GS-9196",    // World Cup France '98 - Road to Win (Japan)
      @"MK-81181",   // World League Soccer '98 (Europe)
      @"MK-81113",   // World Series Baseball II (Europe) / (USA)
      @"GS-9120",    // World Series Baseball II (Japan)
      ];

    // Saturn Stunner / Virtua Gun supported games
    NSArray<NSString *> *ssVirtuaGunGames =
    @[
      @"T-25408H",   // Area 51 (Europe)
      @"T-18613G",   // Area 51 (Japan)
      @"T-9705H",    // Area 51 (USA)
      @"T-15102H",   // Chaos Control (Europe)
      @"T-7006G",    // Chaos Control Remix (Japan)
      @"T-9509H-50", // Crypt Killer (Europe)
      @"T-9518G",    // Henry Explorers (Japan)
      @"T-9509H",    // Crypt Killer (USA)
      @"T-23202G",   // Death Crimson (Japan)
      //@"T-16103H",   // Die Hard Trilogy (Europe) / (USA)
      //@"GS-9123",    // Die Hard Trilogy (Japan)
      @"MK-81802",   // House of the Dead, The (Europe) / (USA)
      @"GS-9173",    // House of the Dead, The (Japan)
      @"T-25417H",   // Maximum Force (Europe)
      @"T-9707H",    // Maximum Force (USA)
      @"GS-9088",    // Mechanical Violator Hakaider - Last Judgement (Japan)
      @"MK-81087",   // Mighty Hits (Europe)
      @"T-16604G",   // Mighty Hits (Japan)
      //@"T-9510G",    // Policenauts (Japan)
      @"T-30403H",   // Scud - The Disposable Assassin (USA)
      @"MK-81015",   // Virtua Cop (Europe) / (USA)
      @"GS-9060",    // Virtua Cop (Japan)
      @"MK-81043",   // Virtua Cop 2 (Europe) / (Korea) / (USA)
      @"GS-9097",    // Virtua Cop 2 (Japan)
      ];

    // TurboGrafx-16/PC Engine/CD 6-Button Pad supported games
    NSArray<NSString *> *pce6ButtonPadGames =
    @[
      // PCE
      @"0d9135be3267876bfec7f588abeda5bb", // Street Fighter II' - Champion Edition (Japan)
      @"cff035e7d00159ad0879df71e9aa25ca", // Strip Fighter II (Japan) (Unl)

      // PCE CD identified by Redump cue sheet MD5 hash for now.
      @"39b67de686bdea7f25cb17bb5dd59bf3", // Advanced V.G. (Japan)
      @"a8123121b3f3a0fc4f15f68123e300de", // Flash Hiders (Japan)
      //@"ee5429409475963c8e6d4dc1d3b8af47", // Garou Densetsu 2 - Aratanaru Tatakai (Japan) (FABT, FAET, FAFT) - cannot toggle in-game
      //@"d78a5009974e8616665a7c89568c4619", // Ryuuko no Ken (Japan) (En,Ja,Es) (FABT) - cannot toggle 2/6 button mode in-game at "key assign" options.
      //@"367a499bb93e61c36f2fdff4bea2fe5c", // Ryuuko no Ken (Japan) (En,Ja,Es) (FACT) - toggling 2/6 button mode in-game at "key assign" options breaks input, unlike "FABT" dump which does nothing.
      @"e42f62d283c5e29bf32ab5c3d1d71f05", // Ys IV - The Dawn of Ys (Japan) (Rev 3)

      // Not compatible, may need Avenue Pad 3 instead of Avenue Pad 6 / Arcade Pad 6
      // Asuka 120% Maxima - Burning Fest. Maxima (Japan)
      // Far East of Eden - Tengai Makyou - Fuun Kabuki-den (Japan)
      // Forgotten Worlds (Japan)
      // Forgotten Worlds (USA) (En,Ja)
      // Garou Densetsu Special (Japan) (FABT)
      // World Heroes 2 (Japan) - needs the Avenue Pad 3
      ];

    if ([_mednafenCoreModule isEqualToString:@"pce"])
    {
        // PCE: Check if 6 Button Pad is supported
        // Incompatible games will have broken input, so enable on a per-game basis.
        if ([pce6ButtonPadGames containsObject:self.ROMMD5.lowercaseString])
        {
            _isPCE6ButtonPadSupportedGame = YES;
        }
    }

    if ([_mednafenCoreModule isEqualToString:@"psx"])
    {
        // PSX: Check if multiple discs required
        if (psxMultiDiscGames[self.ROMSerial])
        {
            _isMultiDiscGame = YES;
            _multiDiscTotal = [psxMultiDiscGames[self.ROMSerial] intValue];
        }

        // PSX: Check if SBI file is required
        if (sbiRequiredGames[self.ROMSerial])
        {
            _isSBIRequired = YES;
        }

        // PSX: Set multitap configuration if detected
        if (psxMultiTapGames[self.ROMSerial])
        {
            _multiTapPlayerCount = [psxMultiTapGames[self.ROMSerial] intValue];

            if([psxMultiTap5PlayerPort2 containsObject:self.ROMSerial])
                MDFNI_SetSetting("psx.input.pport2.multitap", "1"); // Enable multitap on PSX port 2
            else
            {
                MDFNI_SetSetting("psx.input.pport1.multitap", "1"); // Enable multitap on PSX port 1
                if(_multiTapPlayerCount > 5)
                    MDFNI_SetSetting("psx.input.pport2.multitap", "1"); // Enable multitap on PSX port 2
            }
        }

        // PSX: Insert only 1 memory card if required
        if ([psxSingleMemoryCardGames containsObject:self.ROMSerial])
        {
            MDFNI_SetSetting("psx.input.port2.memcard", "0"); // Disable memory card on PSX port 2
        }

        // PSX: Check if Konami Justifier is supported
        if ([psxJustifierExclusiveGames containsObject:self.ROMSerial])
        {
            _isPSXJustifierSupportedGame = YES;
        }

        // PSX: Check if Namco GunCon is supported
        if ([psxGunConGames containsObject:self.ROMSerial])
        {
            _isPSXGunConSupportedGame = YES;
        }
    }

    if ([_mednafenCoreModule isEqualToString:@"ss"])
    {
        NSString *hex = self.ROMHeader;
        NSUInteger len = hex.length;

        // Ensure valid hex string
        if ((len % 2) != 0)
            return;

        // Convert header hex to ascii
        NSMutableString *ascii = [NSMutableString string];
        for(int i=0; i< len; i+=2)
        {
            NSString *byte = [hex substringWithRange:NSMakeRange(i, 2)];
            unsigned char chr = strtol(byte.UTF8String, nil, 16);
            [ascii appendFormat:@"%c", chr];
        }

        // Extract serial from header
        NSString *serial = [ascii substringWithRange:NSMakeRange(32, 10)];
        serial = [serial stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        self.ROMSerial = serial;

        // SS: Check if multiple discs required
        if (ssMultiDiscGames[self.ROMSerial])
        {
            _isMultiDiscGame = YES;
            _multiDiscTotal = [ssMultiDiscGames[self.ROMSerial] intValue];
        }

        // SS: Set multitap configuration if detected
        if (ssMultiTapGames[self.ROMSerial])
        {
            _multiTapPlayerCount = [ssMultiTapGames[self.ROMSerial] intValue];

            if(_multiTapPlayerCount < 8)
                // From the Sega Saturn 6 Player Multi-Player Adaptor manual:
                // 3-7 Player games
                MDFNI_SetSetting("ss.input.sport2.multitap", "1"); // Enable multitap on SS port 2
            else
            {
                // 8-12 Player games
                MDFNI_SetSetting("ss.input.sport1.multitap", "1"); // Enable multitap on SS port 1
                MDFNI_SetSetting("ss.input.sport2.multitap", "1"); // Enable multitap on SS port 2
            }
        }

        // SS: Check if 3D Control Pad is supported
        // Some games e.g. 3D Lemmings (Europe) / (Japan) and Chaos Control (Japan) have compat issues,
        // even when in digital mode, so enable on a per-game basis.
        if ([ss3DControlPadGames containsObject:self.ROMSerial])
        {
            _isSS3DControlPadSupportedGame = YES;
        }

        // SS: Check if Stunner / Virtua Gun is supported
        if ([ssVirtuaGunGames containsObject:self.ROMSerial])
        {
            _isSSVirtuaGunSupportedGame = YES;
        }

    }
}

- (id)init
{
    if((self = [super init]))
    {
        _current = self;

        _multiTapPlayerCount = 2;
        _allCueSheetFiles = [[NSMutableArray alloc] init];

        for(unsigned i = 0; i < 13; i++)
            _inputBuffer[i] = (uint32_t *) calloc(9, sizeof(uint32_t));
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
    for(unsigned i = 0; i < 13; i++)
        free(_inputBuffer[i]);

    delete surf;

    // Defensive: stopEmulation normally frees this; cover paths that bypass it.
    if (_cachedModule) { free(_cachedModule); _cachedModule = NULL; }
}

# pragma mark - Execution

// Look for sibling .cue/.ccd files in the same folder as `diskPath` and, if exactly `totalDiscs`
// of them exist, write a sibling .m3u listing them in localized-standard order. Returns the .m3u
// path on success, or nil if siblings can't be found / counts don't match / write fails.
//
// Naming for the generated .m3u strips a trailing "(Disc N)" / "Disc N" segment from the imported
// file's basename so multiple discs in the same folder produce a stable, shared playlist name.
- (NSString *)autogenerateMultiDiscM3UFromPath:(NSString *)diskPath totalDiscs:(NSUInteger)totalDiscs
{
    NSString *folder = diskPath.stringByDeletingLastPathComponent;
    NSError *err = nil;
    NSArray<NSString *> *folderContents = [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:&err];
    if (!folderContents) {
        NSLog(@"[Mednafen] Could not read folder for auto-m3u: %@", err);
        return nil;
    }

    NSMutableArray<NSString *> *cues = [NSMutableArray array];
    for (NSString *name in folderContents) {
        NSString *ext = name.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"cue"] || [ext isEqualToString:@"ccd"])
            [cues addObject:name];
    }
    [cues sortUsingSelector:@selector(localizedStandardCompare:)];

    if (cues.count != totalDiscs) {
        NSLog(@"[Mednafen] Auto-m3u skipped: game expects %lu discs but folder has %lu .cue/.ccd files (%@)",
              (unsigned long)totalDiscs, (unsigned long)cues.count, folder);
        return nil;
    }

    NSString *baseName = [diskPath.lastPathComponent stringByDeletingPathExtension];
    NSRegularExpression *cleanup = [NSRegularExpression regularExpressionWithPattern:@"\\s*\\(?\\s*Disc\\s*\\d+\\s*\\)?\\s*"
                                                                             options:NSRegularExpressionCaseInsensitive
                                                                               error:nil];
    NSString *cleanedBase = [cleanup stringByReplacingMatchesInString:baseName
                                                              options:0
                                                                range:NSMakeRange(0, baseName.length)
                                                         withTemplate:@""];
    cleanedBase = [cleanedBase stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (cleanedBase.length == 0)
        cleanedBase = baseName;
    NSString *m3uPath = [folder stringByAppendingPathComponent:[cleanedBase stringByAppendingPathExtension:@"m3u"]];

    if ([NSFileManager.defaultManager fileExistsAtPath:m3uPath]) {
        NSLog(@"[Mednafen] Auto-m3u already exists, reusing: %@", m3uPath);
        return m3uPath;
    }

    NSString *m3uContents = [[cues componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    NSError *writeError = nil;
    if (![m3uContents writeToFile:m3uPath atomically:YES encoding:NSUTF8StringEncoding error:&writeError]) {
        NSLog(@"[Mednafen] Failed to write auto-m3u at %@: %@", m3uPath, writeError);
        return nil;
    }

    NSLog(@"[Mednafen] Auto-generated %lu-disc m3u: %@", (unsigned long)cues.count, m3uPath);
    return m3uPath;
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    // Set the current system
    NSDictionary<NSString *, NSString *> *mednafenCoreModules =
    @{
      @"openemu.system.lynx"   : @"lynx",
      @"openemu.system.ngp"    : @"ngp",
      @"openemu.system.pce"    : @"pce",
      @"openemu.system.pcecd"  : @"pce",
      @"openemu.system.pcfx"   : @"pcfx",
      @"openemu.system.psx"    : @"psx",
      @"openemu.system.saturn" : @"ss",
      @"openemu.system.vb"     : @"vb",
      @"openemu.system.ws"     : @"wswan",
      };

    _mednafenCoreModule = mednafenCoreModules[self.systemIdentifier];
    _isSystemPCECD = [self.systemIdentifier isEqualToString:@"openemu.system.pcecd"];

    // Create battery save dir
    NSURL *batterySavesDirectory = [NSURL fileURLWithPath:self.batterySavesDirectoryPath];
    [NSFileManager.defaultManager createDirectoryAtURL:batterySavesDirectory withIntermediateDirectories:YES attributes:nil error:nil];

    // Parse number of discs in m3u
    if([path.pathExtension.lowercaseString isEqualToString:@"m3u"])
    {
        NSString *m3uString = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@".*\\.cue|.*\\.ccd" options:NSRegularExpressionCaseInsensitive error:nil];
        NSUInteger numberOfMatches = [regex numberOfMatchesInString:m3uString options:0 range:NSMakeRange(0, m3uString.length)];

        NSLog(@"[Mednafen] Loaded m3u containing %lu cue sheets or ccd", numberOfMatches);

        _maxDiscs = numberOfMatches;

        // Keep track of cue sheets for use with SBI files
        [regex enumerateMatchesInString:m3uString options:0 range:NSMakeRange(0, m3uString.length) usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
            NSRange range = result.range;
            NSString *match = [m3uString substringWithRange:range];

            if([match containsString:@".cue"])
                [_allCueSheetFiles addObject:[m3uString substringWithRange:range]];
        }];
    }
    else if([path.pathExtension.lowercaseString isEqualToString:@"cue"])
    {
        NSString *filename = path.lastPathComponent;
        [_allCueSheetFiles addObject:filename];
    }

    [self initializeMednafen];

    // Auto-generate an .m3u for multi-disc PSX games loaded via a single .cue/.ccd, when all sibling
    // discs are present in the same folder. Mednafen requires .m3u for multi-disc to keep save files
    // and disc-swap state coherent (#294).
    if ([_mednafenCoreModule isEqualToString:@"psx"]
        && _isMultiDiscGame
        && ![path.pathExtension.lowercaseString isEqualToString:@"m3u"])
    {
        NSString *autoM3UPath = [self autogenerateMultiDiscM3UFromPath:path totalDiscs:_multiDiscTotal];
        if (autoM3UPath) {
            path = autoM3UPath;
            // Re-populate _allCueSheetFiles from the new .m3u so SBI handling below sees the cue list.
            [_allCueSheetFiles removeAllObjects];
            NSString *m3uString = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
            NSRegularExpression *cueRegex = [NSRegularExpression regularExpressionWithPattern:@".*\\.cue|.*\\.ccd" options:NSRegularExpressionCaseInsensitive error:nil];
            [cueRegex enumerateMatchesInString:m3uString options:0 range:NSMakeRange(0, m3uString.length) usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
                NSString *match = [m3uString substringWithRange:result.range];
                if ([match containsString:@".cue"])
                    [_allCueSheetFiles addObject:match];
            }];
            _maxDiscs = _multiDiscTotal;
        }
    }

    game = MDFNI_LoadGame(_mednafenCoreModule.UTF8String, &::Mednafen::NVFS, path.fileSystemRepresentation);

    if(!game)
        return NO;

    if([_mednafenCoreModule isEqualToString:@"lynx"])
    {
        //_mednafenCoreAspect = OEIntSizeMake(80, 51);
        _mednafenCoreAspect = OEIntSizeMake(game->nominal_width, game->nominal_height);
        _sampleRate         = 48000;
    }
    else if([_mednafenCoreModule isEqualToString:@"ngp"])
    {
        //_mednafenCoreAspect = OEIntSizeMake(20, 19);
        _mednafenCoreAspect = OEIntSizeMake(game->nominal_width, game->nominal_height);
        _sampleRate         = 48000;
    }
    else if([_mednafenCoreModule isEqualToString:@"pce"])
    {
        _mednafenCoreAspect = OEIntSizeMake(256 * (8.0/7.0), 240);
        //_mednafenCoreAspect = OEIntSizeMake(game->nominal_width, game->nominal_height);
        _sampleRate         = 48000;
    }
    else if([_mednafenCoreModule isEqualToString:@"pcfx"])
    {
        _mednafenCoreAspect = OEIntSizeMake(game->nominal_width, game->nominal_height);
        _sampleRate         = 48000;
    }
    else if([_mednafenCoreModule isEqualToString:@"psx"])
    {
        _mednafenCoreAspect = OEIntSizeMake(game->nominal_width, game->nominal_height);
        _sampleRate         = 44100;
    }
    else if([_mednafenCoreModule isEqualToString:@"ss"])
    {
        _mednafenCoreAspect = OEIntSizeMake(game->nominal_width, game->nominal_height);
        _sampleRate         = 44100;
    }
    else if([_mednafenCoreModule isEqualToString:@"vb"])
    {
        //_mednafenCoreAspect = OEIntSizeMake(12, 7);
        _mednafenCoreAspect = OEIntSizeMake(game->nominal_width, game->nominal_height);
        _sampleRate         = 48000;
    }
    else if([_mednafenCoreModule isEqualToString:@"wswan"])
    {
        //_mednafenCoreAspect = OEIntSizeMake(14, 9);
        _mednafenCoreAspect = OEIntSizeMake(game->nominal_width, game->nominal_height);
        _sampleRate         = 48000;
    }

    _masterClock = game->MasterClock >> 32;

    if ([_mednafenCoreModule isEqualToString:@"pce"])
    {
        game->SetInput(0, "gamepad", (uint8_t *)_inputBuffer[0]);
        game->SetInput(1, "gamepad", (uint8_t *)_inputBuffer[1]);
        game->SetInput(2, "gamepad", (uint8_t *)_inputBuffer[2]);
        game->SetInput(3, "gamepad", (uint8_t *)_inputBuffer[3]);
        game->SetInput(4, "gamepad", (uint8_t *)_inputBuffer[4]);
    }
    else if ([_mednafenCoreModule isEqualToString:@"pcfx"])
    {
        game->SetInput(0, "gamepad", (uint8_t *)_inputBuffer[0]);
        game->SetInput(1, "gamepad", (uint8_t *)_inputBuffer[1]);
    }
    else if ([_mednafenCoreModule isEqualToString:@"psx"])
    {
        NSLog(@"[Mednafen] PSX serial: %@ player count: %d", self.ROMSerial, _multiTapPlayerCount);

        // Multi-disc safety net: auto-m3u above failed to find sibling discs.
        if(_isMultiDiscGame && ![path.pathExtension.lowercaseString isEqualToString:@"m3u"])
        {
            NSError *outErr = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadROMError userInfo:@{
                NSLocalizedDescriptionKey : @"Multi-disc game requires all discs in the same folder.",
                NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:@"This game has %lu discs and needs an .m3u playlist so saves and disc-swap state stay coherent. OpenEmu can write the .m3u for you when every disc's .cue (and matching .bin) is in the same folder as the file you imported.\n\nMake sure all %lu discs are in the same folder, then re-import disc 1.\n\nMore info:\nhttps://github.com/OpenEmu/OpenEmu/wiki/User-guide:-CD-based-games#q-i-have-a-multi-disc-game", _multiDiscTotal, _multiDiscTotal],
                }];

            *error = outErr;

            return NO;
        }

        // Handle required SBI files for games
        if(_isSBIRequired && _allCueSheetFiles.count && ([path.pathExtension.lowercaseString isEqualToString:@"cue"] || [path.pathExtension.lowercaseString isEqualToString:@"m3u"]))
        {
            NSURL *romPath = [NSURL fileURLWithPath:path.stringByDeletingLastPathComponent];

            BOOL missingFileStatus = NO;
            NSUInteger missingFileCount = 0;
            NSMutableString *missingFilesList = [NSMutableString string];

            // Build a path to SBI file and check if it exists
            for(NSString *cueSheetFile in _allCueSheetFiles)
            {
                NSString *extensionlessFilename = cueSheetFile.stringByDeletingPathExtension;
                NSURL *sbiFile = [romPath URLByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"sbi"]];

                // Check if the required SBI files exist
                if(![sbiFile checkResourceIsReachableAndReturnError:nil])
                {
                    missingFileStatus = YES;
                    missingFileCount++;
                    [missingFilesList appendString:[NSString stringWithFormat:@"\"%@\"\n\n", extensionlessFilename]];
                }
            }
            // Alert the user of missing SBI files that are required for the game
            if(missingFileStatus)
            {
                NSError *outErr = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadROMError userInfo:@{
                    NSLocalizedDescriptionKey : missingFileCount > 1 ? @"Required SBI files missing." : @"Required SBI file missing.",
                    NSLocalizedRecoverySuggestionErrorKey : missingFileCount > 1 ? [NSString stringWithFormat:@"To run this game you need SBI files for the discs:\n\n%@Drag and drop the required files onto the game library window and try again.\n\nFor more information, visit:\nhttps://github.com/OpenEmu/OpenEmu/wiki/User-guide:-CD-based-games#q-i-have-a-sbi-file", missingFilesList] : [NSString stringWithFormat:@"To run this game you need a SBI file for the disc:\n\n%@Drag and drop the required file onto the game library window and try again.\n\nFor more information, visit:\nhttps://github.com/OpenEmu/OpenEmu/wiki/User-guide:-CD-based-games#q-i-have-a-sbi-file", missingFilesList],
                    }];

                *error = outErr;

                return NO;
            }
        }

        for(unsigned i = 0; i < _multiTapPlayerCount; i++)
        {
            game->SetInput(i, "dualshock", (uint8_t *)_inputBuffer[i]);

            //Center the analog inputs
            uint8_t *buf = (uint8_t *)_inputBuffer[i];
            MDFN_en16lsb(&buf[3], 32767);
            MDFN_en16lsb(&buf[5], 32767);
            MDFN_en16lsb(&buf[7], 32767);
            MDFN_en16lsb(&buf[9], 32767);
        }

        if(_isPSXJustifierSupportedGame)
        {
            // Force Justifier to Port 1 and Gamepad to Port 2
            game->SetInput(0, "justifier", (uint8_t *)_inputBuffer[0]);
            game->SetInput(1, "dualshock", (uint8_t *)_inputBuffer[1]);

            // Clear mouse inputs
            uint8_t *buf = (uint8_t *)_inputBuffer[0];
            MDFN_enlsb<uint8_t>(&buf[4], 0);
        }
        else if(_isPSXGunConSupportedGame)
        {
            // Force GunCon to Port 1 and Gamepad to Port 2
            game->SetInput(0, "guncon", (uint8_t *)_inputBuffer[0]);
            game->SetInput(1, "dualshock", (uint8_t *)_inputBuffer[1]);

            // Clear mouse inputs
            uint8_t *buf = (uint8_t *)_inputBuffer[0];
            MDFN_enlsb<uint8_t>(&buf[4], 0);
        }
    }
    else if ([_mednafenCoreModule isEqualToString:@"ss"])
    {
        NSLog(@"[Mednafen] SS serial: %@ player count: %d", self.ROMSerial, _multiTapPlayerCount);

        // Check if loading a multi-disc game without m3u
        if(_isMultiDiscGame && ![path.pathExtension.lowercaseString isEqualToString:@"m3u"])
        {
            NSError *outErr = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadROMError userInfo:@{
                NSLocalizedDescriptionKey : @"Required m3u file missing.",
                NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:@"This game requires multiple discs and must be loaded using a m3u file with all %lu discs.\n\nTo enable disc switching and ensure save files load across discs, it cannot be loaded as a single disc.\n\nFor more information, visit:\nhttps://github.com/OpenEmu/OpenEmu/wiki/User-guide:-CD-based-games#q-i-have-a-multi-disc-game", _multiDiscTotal],
                }];

            *error = outErr;

            return NO;
        }

        for(unsigned i = 0; i < _multiTapPlayerCount; i++)
        {
            if(_isSS3DControlPadSupportedGame)
            {
                game->SetInput(i, "3dpad", (uint8_t *)_inputBuffer[i]);
                // Toggle default position of analog mode switch to Analog(○)
                // "Analog mode is not compatible with all games.  For some compatible games, analog mode reportedly must be enabled before the game boots up for the game to recognize it properly."
                //*_inputBuffer[i] |= 1 << SS3DMap[OESaturnButtonAnalogMode];

                //Center the analog axis inputs
                uint8_t *buf = (uint8_t *)_inputBuffer[i];
                MDFN_en16lsb(&buf[2], 32767);
                MDFN_en16lsb(&buf[4], 32767);
            }
            else if(_isSSVirtuaGunSupportedGame)
            {
                // Force Stunner / Virtua Gun to Port 1 and Gamepad to Port 2
                game->SetInput(0, "gun", (uint8_t *)_inputBuffer[0]);
                game->SetInput(1, "gamepad", (uint8_t *)_inputBuffer[1]);

                // Clear mouse inputs
                uint8_t *buf = (uint8_t *)_inputBuffer[0];
                MDFN_enlsb<uint8_t>(&buf[4], 0);
            }
            else
            {
                game->SetInput(i, "gamepad", (uint8_t *)_inputBuffer[i]);
            }
        }

        game->SetInput(12, "builtin", (uint8_t *)_inputBuffer[12]); // reset button status
    }
    else if ([_mednafenCoreModule isEqualToString:@"vb"])
    {
        game->SetInput(0, "gamepad", (uint8_t *)_inputBuffer[0]);
        game->SetInput(1, "misc", (uint8_t *)_inputBuffer[1]); // low battery sensor bit, unused currently
    }
    else
    {
        game->SetInput(0, "gamepad", (uint8_t *)_inputBuffer[0]);
    }

    MDFNI_SetMedia(0, 2, 0, 0); // Disc selection API

    // Only temporary, so core doesn't crash on an older OpenEmu version
    if ([self respondsToSelector:@selector(displayModeInfo)]) {
        [self loadDisplayModeOptions];
    }

    // RetroAchievements: only verified systems are enabled.
    _rcConsole = -1;
    if ([_mednafenCoreModule isEqualToString:@"psx"])   _rcConsole = RC_CONSOLE_PLAYSTATION;
    else if ([_mednafenCoreModule isEqualToString:@"ss"])     _rcConsole = RC_CONSOLE_SATURN;
    else if ([_mednafenCoreModule isEqualToString:@"lynx"])   _rcConsole = RC_CONSOLE_ATARI_LYNX;
    else if ([_mednafenCoreModule isEqualToString:@"ngp"])    _rcConsole = RC_CONSOLE_NEOGEO_POCKET;
    else if ([_mednafenCoreModule isEqualToString:@"pce"] && !_isSystemPCECD)  _rcConsole = RC_CONSOLE_PC_ENGINE;
    else if ([_mednafenCoreModule isEqualToString:@"pce"] && _isSystemPCECD)   _rcConsole = RC_CONSOLE_PC_ENGINE_CD;
    else if ([_mednafenCoreModule isEqualToString:@"pcfx"])   _rcConsole = RC_CONSOLE_PCFX;
    else if ([_mednafenCoreModule isEqualToString:@"vb"])     _rcConsole = RC_CONSOLE_VIRTUAL_BOY;
    else if ([_mednafenCoreModule isEqualToString:@"wswan"])  _rcConsole = RC_CONSOLE_WONDERSWAN;

    if (_rcConsole > 0) {
        _romPath = path;
        _lynxFrameCount = 0;
        const char *modCStr = _mednafenCoreModule.UTF8String;
        if (modCStr) { _cachedModule = strdup(modCStr); }
        _raBridge = [[OERetroAchievementsBridge alloc] initWithGameCore:self
                                                            memoryReader:mednafen_rc_read_memory
                                                               consoleID:(uint32_t)_rcConsole];
        [_raBridge startWithROMPath:path];
        [_raBridge markROMReady];
    }

    return YES;
}

- (void)executeFrame
{
    static int16_t sound_buf[0x10000];
    int32 rects[game->fb_height];

    memset(rects, 0, game->fb_height*sizeof(int32));
    rects[0] = ~0;
    EmulateSpecStruct spec;
    spec.surface = surf;
    spec.SoundRate = _sampleRate;
    spec.SoundBuf = sound_buf;
    spec.LineWidths = rects;
    spec.SoundBufMaxSize = sizeof(sound_buf) / 2;
    spec.SoundVolume = 1.0;
    spec.soundmultiplier = 1.0;

    // PS1 Justifier and GunCon: need to refresh X/Y coords before MDFNI_Emulate()
    // See TransformInput() and GPU_GetGunXTranslation()
    if (_isPSXJustifierSupportedGame || _isPSXGunConSupportedGame)
    {
        uint8_t *buf = (uint8_t *)_inputBuffer[0];
        MDFN_en16lsb(&buf[0], _mouseScaledX); // X coord
        MDFN_en16lsb(&buf[2], _mouseScaledY); // Y coord
    }

    MDFNI_Emulate(&spec);

    if (_rcConsole == RC_CONSOLE_ATARI_LYNX && _lynxFrameCount < kLynxRAWarmupFrames)
        _lynxFrameCount++;
    [_raBridge doFrame];

    _mednafenCoreTiming = _masterClock / spec.MasterCycles;

    _videoOffsetX = spec.DisplayRect.x;
    _videoOffsetY = spec.DisplayRect.y;
    if(game->multires) {
        _videoWidth = rects[spec.DisplayRect.y];
    }
    else {
        _videoWidth = spec.DisplayRect.w ?: rects[spec.DisplayRect.y];
    }
    _videoHeight  = spec.DisplayRect.h;

    [[self ringBufferAtIndex:0] write:spec.SoundBuf maxLength:spec.SoundBufSize * self.channelCount * 2];
}

- (void)resetEmulation
{
    if ([_mednafenCoreModule isEqualToString:@"ss"])
    {
        *_inputBuffer[12] = 1;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            *_inputBuffer[12] = 0;
        });
    }

    MDFNI_Reset();
    [_raBridge reset];
}

- (void)stopEmulation
{
    [_raBridge shutdown];
    _raBridge = nil;
    if (_cachedModule) { free(_cachedModule); _cachedModule = NULL; }
    MDFNI_CloseGame();

    [super stopEmulation];
}

- (NSTimeInterval)frameInterval
{
    return _mednafenCoreTiming ?: 60;
}

# pragma mark - Video

- (OEIntRect)screenRect
{
    return OEIntRectMake(_videoOffsetX, _videoOffsetY, _videoWidth, _videoHeight);
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(game->fb_width, game->fb_height);
}

- (OEIntSize)aspectSize
{
    return _mednafenCoreAspect;
}

- (const void *)getVideoBufferWithHint:(void *)hint
{
    if (!surf) {
        // BGRA pixel format
        MDFN_PixelFormat pix_fmt(MDFN_COLORSPACE_RGB, 16, 8, 0, 24);
        surf = new MDFN_Surface(hint, game->fb_width, game->fb_height, game->fb_width, pix_fmt);
    }

    return surf->pixels;
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
    return _sampleRate ? _sampleRate : 48000;
}

- (NSUInteger)channelCount
{
    return game->soundchan;
}

# pragma mark - Save States

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    block(MDFNI_SaveState(fileName.fileSystemRepresentation, "", NULL, NULL, NULL), nil);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    BOOL ok = MDFNI_LoadState(fileName.fileSystemRepresentation, "");
    if (ok) {
        [_raBridge reset];
    }
    block(ok, nil);
}

- (NSData *)serializeStateWithError:(NSError **)outError
{
    MemoryStream stream(65536, false);
    MDFNSS_SaveSM(&stream, true);
    size_t length = stream.map_size();
    void *bytes = stream.map();

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
    NSError *error;
    const void *bytes = state.bytes;
    size_t length = state.length;

    MemoryStream stream(length, -1);
    memcpy(stream.map(), bytes, length);
    MDFNSS_LoadSM(&stream, true);
    size_t serialSize = stream.map_size();

    if(serialSize != length)
    {
        error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                    code:OEGameCoreStateHasWrongSizeError
                                userInfo:@{
                                           NSLocalizedDescriptionKey : @"Save state has wrong file size.",
                                           NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:@"The size of the save state does not have the right size, %lu expected, got: %ld.", serialSize, state.length],
                                        }];
    }

    if(error)
    {
        if(outError)
        {
            *outError = error;
        }
        return false;
    }
    else
    {
        [_raBridge reset];
        return true;
    }
}

# pragma mark - Input

// Map OE button order to Mednafen button order
const int LynxMap[] = { 6, 7, 4, 5, 0, 1, 3, 2 };
const int NGPMap[]  = { 0, 1, 2, 3, 4, 5, 6 };
const int PCEMap[]  = { 4, 6, 7, 5, 0, 1, 8, 9, 10, 11, 3, 2, 12 };
const int PCFXMap[] = { 8, 10, 11, 9, 0, 1, 2, 3, 4, 5, 7, 6 };
const int PSXMap[]  = { 4, 6, 7, 5, 12, 13, 14, 15, 10, 8, 1, 11, 9, 2, 3, 0, 16, 23, 23, 21, 21, 19, 19, 17, 17 };
const int SSMap[]   = { 4, 5, 6, 7, 10, 8, 9, 2, 1, 0, 15, 3, 11 };
const int SS3DMap[] = { 0, 1, 2, 3, 6, 4, 5, 10, 9, 8, 20, 18, 7, 12, 15, 15, 13, 13, 20, 18};
const int VBMap[]   = { 9, 8, 7, 6, 4, 13, 12, 5, 3, 2, 0, 1, 10, 11 };
const int WSMap[]   = { 0, 2, 3, 1, 4, 6, 7, 5, 9, 10, 8, 11 };

- (oneway void)didPushLynxButton:(OELynxButton)button forPlayer:(NSUInteger)player
{
    *_inputBuffer[player-1] |= 1 << LynxMap[button];
}

- (oneway void)didReleaseLynxButton:(OELynxButton)button forPlayer:(NSUInteger)player
{
    *_inputBuffer[player-1] &= ~(1 << LynxMap[button]);
}

- (oneway void)didPushNGPButton:(OENGPButton)button
{
    *_inputBuffer[0] |= 1 << NGPMap[button];
}

- (oneway void)didReleaseNGPButton:(OENGPButton)button
{
    *_inputBuffer[0] &= ~(1 << NGPMap[button]);
}

- (oneway void)didPushPCEButton:(OEPCEButton)button forPlayer:(NSUInteger)player
{
    if (!_isPCE6ButtonPadSupportedGame && button == OEPCEButtonMode)
        return;

    if (button != OEPCEButtonMode) // Check for six button mode toggle
        *_inputBuffer[player-1] |= 1 << PCEMap[button];
    else
        *_inputBuffer[player-1] ^= 1 << PCEMap[button];
}

- (oneway void)didReleasePCEButton:(OEPCEButton)button forPlayer:(NSUInteger)player
{
    if (button != OEPCEButtonMode)
        *_inputBuffer[player-1] &= ~(1 << PCEMap[button]);
}

- (oneway void)didPushPCECDButton:(OEPCECDButton)button forPlayer:(NSUInteger)player
{
    if (!_isPCE6ButtonPadSupportedGame && button == OEPCECDButtonMode)
        return;

    if (button != OEPCECDButtonMode) // Check for six button mode toggle
        *_inputBuffer[player-1] |= 1 << PCEMap[button];
    else
        *_inputBuffer[player-1] ^= 1 << PCEMap[button];
}

- (oneway void)didReleasePCECDButton:(OEPCECDButton)button forPlayer:(NSUInteger)player
{
    if (button != OEPCECDButtonMode)
        *_inputBuffer[player-1] &= ~(1 << PCEMap[button]);
}

- (oneway void)didPushPCFXButton:(OEPCFXButton)button forPlayer:(NSUInteger)player
{
    *_inputBuffer[player-1] |= 1 << PCFXMap[button];
}

- (oneway void)didReleasePCFXButton:(OEPCFXButton)button forPlayer:(NSUInteger)player
{
    *_inputBuffer[player-1] &= ~(1 << PCFXMap[button]);
}

- (oneway void)didPushSaturnButton:(OESaturnButton)button forPlayer:(NSUInteger)player
{
    if(_isSS3DControlPadSupportedGame)
    {
        // Handle L and R when in digital mode
        if (button == OESaturnButtonL) [self didMoveSaturnJoystickDirection:OESaturnAnalogL withValue:1.0 forPlayer:player];
        if (button == OESaturnButtonR) [self didMoveSaturnJoystickDirection:OESaturnAnalogR withValue:1.0 forPlayer:player];

        if (button != OESaturnButtonAnalogMode) // Check for mode toggle
            *_inputBuffer[player-1] |= 1 << SS3DMap[button];
        else
            *_inputBuffer[player-1] ^= 1 << SS3DMap[button];
    }
    else if(_isSSVirtuaGunSupportedGame && player == 1)
    {
        // Handle START for player 1 Stunner / Virtua Gun
        if (button == OESaturnButtonStart)
        {
            uint8_t *buf = (uint8_t *)_inputBuffer[0];
            MDFN_enlsb<uint8_t>(&buf[4], 1 << 1); // START
        }
    }
    else
        *_inputBuffer[player-1] |= 1 << SSMap[button];

}

- (oneway void)didReleaseSaturnButton:(OESaturnButton)button forPlayer:(NSUInteger)player
{
    if(_isSS3DControlPadSupportedGame)
    {
        if (button == OESaturnButtonL) [self didMoveSaturnJoystickDirection:OESaturnAnalogL withValue:0.0 forPlayer:player];
        if (button == OESaturnButtonR) [self didMoveSaturnJoystickDirection:OESaturnAnalogR withValue:0.0 forPlayer:player];

        if (button != OESaturnButtonAnalogMode)
            *_inputBuffer[player-1] &= ~(1 << SS3DMap[button]);
    }
    else if(_isSSVirtuaGunSupportedGame && player == 1)
    {
        // Handle START for player 1 Stunner / Virtua Gun
        if (button == OESaturnButtonStart)
        {
            uint8_t *buf = (uint8_t *)_inputBuffer[0];
            MDFN_enlsb<uint8_t>(&buf[4], 0); // release
        }
    }
    else
        *_inputBuffer[player-1] &= ~(1 << SSMap[button]);
}

- (oneway void)didPushVBButton:(OEVBButton)button forPlayer:(NSUInteger)player
{
    *_inputBuffer[player-1] |= 1 << VBMap[button];
}

- (oneway void)didReleaseVBButton:(OEVBButton)button forPlayer:(NSUInteger)player
{
    *_inputBuffer[player-1] &= ~(1 << VBMap[button]);
}

- (oneway void)didPushWSButton:(OEWSButton)button forPlayer:(NSUInteger)player
{
    *_inputBuffer[player-1] |= 1 << WSMap[button];
}

- (oneway void)didReleaseWSButton:(OEWSButton)button forPlayer:(NSUInteger)player
{
    *_inputBuffer[player-1] &= ~(1 << WSMap[button]);
}

- (oneway void)didPushPSXButton:(OEPSXButton)button forPlayer:(NSUInteger)player
{
    if((_isPSXJustifierSupportedGame || _isPSXGunConSupportedGame) && player == 1)
    {
        if (button == OEPSXButtonSquare || button == OEPSXButtonCircle)
        {
            uint8_t *buf = (uint8_t *)_inputBuffer[0];
            MDFN_enlsb<uint8_t>(&buf[4], buf[4] |= 1 << 1); // GunCon "A" button or Justifier rear "auxiliary" button
        }
        else if (button == OEPSXButtonCross || button == OEPSXButtonTriangle || button == OEPSXButtonStart)
        {
            uint8_t *buf = (uint8_t *)_inputBuffer[0];
            MDFN_enlsb<uint8_t>(&buf[4], buf[4] |= 1 << 2); // GunCon "B" button or Justifier START button
        }
    }
    else
        *_inputBuffer[player-1] |= 1 << PSXMap[button];
}

- (oneway void)didReleasePSXButton:(OEPSXButton)button forPlayer:(NSUInteger)player
{
    if((_isPSXJustifierSupportedGame || _isPSXGunConSupportedGame) && player == 1)
    {
        if (button == OEPSXButtonSquare || button == OEPSXButtonCircle)
        {
            uint8_t *buf = (uint8_t *)_inputBuffer[0];
            MDFN_enlsb<uint8_t>(&buf[4], buf[4] &= ~(1 << 1)); // Release GunCon "A" button or Justifier rear "auxiliary" button
        }
        else if (button == OEPSXButtonCross || button == OEPSXButtonTriangle || button == OEPSXButtonStart)
        {
            uint8_t *buf = (uint8_t *)_inputBuffer[0];
            MDFN_enlsb<uint8_t>(&buf[4], buf[4] &= ~(1 << 2)); // Release GunCon "B" button or Justifier START button
        }
    }
    else
        *_inputBuffer[player-1] &= ~(1 << PSXMap[button]);
}

- (oneway void)didMovePSXJoystickDirection:(OEPSXButton)button withValue:(CGFloat)value forPlayer:(NSUInteger)player
{
    // Fix the analog circle-to-square axis range conversion by scaling between a value of 1.00 and 1.50
    // We cannot use MDFNI_SetSetting("psx.input.port1.dualshock.axis_scale", "1.33") directly.
    // Background: https://mednafen.github.io/documentation/psx.html#Section_analog_range
    value *= 32767 ; // de-normalize
    double scaledValue = MIN(floor(0.5 + value * 1.33), 32767); // 30712 / cos(2*pi/8) / 32767 = 1.33
    
    if (button == OEPSXLeftAnalogLeft || button == OEPSXLeftAnalogUp || button == OEPSXRightAnalogLeft || button == OEPSXRightAnalogUp)
        scaledValue *= -1;
    
    int analogNumber = PSXMap[button] - 17;
    uint8_t *buf = (uint8_t *)_inputBuffer[player-1];
    MDFN_en16lsb(&buf[3 + analogNumber], scaledValue + 32767);
}

- (oneway void)didMoveSaturnJoystickDirection:(OESaturnButton)button withValue:(CGFloat)value forPlayer:(NSUInteger)player
{
    value *= 32767 ; // de-normalize
    
    int analogNumber = SS3DMap[button] - 13;
   
    if (button == OESaturnLeftAnalogLeft || button == OESaturnLeftAnalogUp)
        value *= -1;
    
    if (!(button == OESaturnAnalogL || button == OESaturnAnalogR)) {
        //Adjust all axis but Trigger buttons
        value += 32767;
    }
    
    uint8_t *buf = (uint8_t *)_inputBuffer[player-1];
    MDFN_en16lsb(&buf[2 + analogNumber], value);
}

- (oneway void)mouseMovedAtPoint:(OEIntPoint)point
{
    if(_isSSVirtuaGunSupportedGame || _isPSXJustifierSupportedGame || _isPSXGunConSupportedGame)
    {
        [self scaleMouseCoordsAtPoint:point];
        _mouseScaledX = (_mouseScaledX + game->mouse_offs_x) * (game->mouse_scale_x / game->nominal_width);
        _mouseScaledY = (_mouseScaledY + game->mouse_offs_y) * (game->mouse_scale_y / game->nominal_height);

        uint8_t *buf = (uint8_t *)_inputBuffer[0];
        MDFN_en16lsb(&buf[0], _mouseScaledX); // X coord
        MDFN_en16lsb(&buf[2], _mouseScaledY); // Y coord
    }
}

- (oneway void)leftMouseDownAtPoint:(OEIntPoint)point
{
    if(_isSSVirtuaGunSupportedGame || _isPSXJustifierSupportedGame || _isPSXGunConSupportedGame)
    {
        [self mouseMovedAtPoint:point];

        uint8_t *buf = (uint8_t *)_inputBuffer[0];
        MDFN_enlsb<uint8_t>(&buf[4], buf[4] |= 1 << 0); // TRIGGER
    }
}

- (oneway void)leftMouseUp
{
    if(_isSSVirtuaGunSupportedGame || _isPSXJustifierSupportedGame || _isPSXGunConSupportedGame)
    {
        uint8_t *buf = (uint8_t *)_inputBuffer[0];
        MDFN_enlsb<uint8_t>(&buf[4], buf[4] &= ~(1 << 0)); // release TRIGGER
    }
}

- (oneway void)rightMouseDownAtPoint:(OEIntPoint)point
{
    if(_isSSVirtuaGunSupportedGame)
    {
        uint8_t *buf = (uint8_t *)_inputBuffer[0];
        MDFN_enlsb<uint8_t>(&buf[4], buf[4] |= 1 << 2); // Offscreen Shot aka RELOAD
    }
    else if(_isPSXJustifierSupportedGame || _isPSXGunConSupportedGame)
    {
        uint8_t *buf = (uint8_t *)_inputBuffer[0];
        MDFN_enlsb<uint8_t>(&buf[4], buf[4] |= 1 << 3); // Offscreen Shot aka RELOAD
    }
}

- (oneway void)rightMouseUp
{
    if(_isSSVirtuaGunSupportedGame)
    {
        uint8_t *buf = (uint8_t *)_inputBuffer[0];
        MDFN_enlsb<uint8_t>(&buf[4], buf[4] &= ~(1 << 2)); // release Offscreen Shot aka RELOAD
    }
    else if(_isPSXJustifierSupportedGame || _isPSXGunConSupportedGame)
    {
        uint8_t *buf = (uint8_t *)_inputBuffer[0];
        MDFN_enlsb<uint8_t>(&buf[4], buf[4] &= ~(1 << 3)); // release Offscreen Shot aka RELOAD
    }
}

# pragma mark - Display Mode

- (NSArray <NSDictionary <NSString *, id> *> *)displayModes
{
    if(![_mednafenCoreModule isEqualToString:@"vb"])
        return nil;

    if (_availableDisplayModes.count == 0)
    {
        _availableDisplayModes = [NSMutableArray array];

        NSArray <NSDictionary <NSString *, id> *> *availableModesWithDefault =
        @[
          Label(@"Palette"),
          OptionDefault(@"Red/Black (2D)", @"vbPalette"),
          Option(@"White/Black (2D)", @"vbPalette"),
          Option(@"Magenta/Black (2D)", @"vbPalette"),
          SeparatorItem(),
          Option(@"Red/Blue", @"vbPalette"),
          Option(@"Red/Cyan", @"vbPalette"),
          Option(@"Red/Electric Cyan", @"vbPalette"),
          Option(@"Red/Green", @"vbPalette"),
          Option(@"Green/Magenta", @"vbPalette"),
          Option(@"Yellow/Blue", @"vbPalette"),
          ];

        // Deep mutable copy
        _availableDisplayModes = (NSMutableArray *)CFBridgingRelease(CFPropertyListCreateDeepCopy(kCFAllocatorDefault, (CFArrayRef)availableModesWithDefault, kCFPropertyListMutableContainers));
    }

    return [_availableDisplayModes copy];
}

- (void)changeDisplayWithMode:(NSString *)displayMode
{
    if (_availableDisplayModes.count == 0)
        [self displayModes];

    // First check if 'displayMode' is valid
    BOOL isValidDisplayMode = NO;

    for (NSDictionary *modeDict in _availableDisplayModes) {
        if ([modeDict[OEGameCoreDisplayModeNameKey] isEqualToString:displayMode]) {
            isValidDisplayMode = YES;
            break;
        }
    }

    // Disallow a 'displayMode' not found in _availableDisplayModes
    if (!isValidDisplayMode)
        return;

    // Handle option state changes
    for (NSMutableDictionary *optionDict in _availableDisplayModes) {
        if (!optionDict[OEGameCoreDisplayModeNameKey])
            continue;
        // Mutually exclusive option state change
        else if ([optionDict[OEGameCoreDisplayModeNameKey] isEqualToString:displayMode])
            optionDict[OEGameCoreDisplayModeStateKey] = @YES;
        // Reset
        else
            optionDict[OEGameCoreDisplayModeStateKey] = @NO;
    }

    if ([displayMode isEqualToString:@"Red/Black (2D)"]) {
        MDFN_IEN_VB::VIP_SetAnaglyphColors(0xFF0000, 0x000000);
        MDFN_IEN_VB::VIP_SetParallaxDisable(true);
    }
    else if ([displayMode isEqualToString:@"White/Black (2D)"]) {
        MDFN_IEN_VB::VIP_SetAnaglyphColors(0xFFFFFF, 0x000000);
        MDFN_IEN_VB::VIP_SetParallaxDisable(true);
    }
    else if ([displayMode isEqualToString:@"Magenta/Black (2D)"]) {
        MDFN_IEN_VB::VIP_SetAnaglyphColors(0xFF00FF, 0x000000);
        MDFN_IEN_VB::VIP_SetParallaxDisable(true);
    }
    else if ([displayMode isEqualToString:@"Red/Blue"]) {
        MDFN_IEN_VB::VIP_SetAnaglyphColors(0xFF0000, 0x0000FF);
        MDFN_IEN_VB::VIP_SetParallaxDisable(false);
    }
    else if ([displayMode isEqualToString:@"Red/Cyan"]) {
        MDFN_IEN_VB::VIP_SetAnaglyphColors(0xFF0000, 0x00B7EB);
        MDFN_IEN_VB::VIP_SetParallaxDisable(false);
    }
    else if ([displayMode isEqualToString:@"Red/Electric Cyan"]) {
        MDFN_IEN_VB::VIP_SetAnaglyphColors(0xFF0000, 0x00FFFF);
        MDFN_IEN_VB::VIP_SetParallaxDisable(false);
    }
    else if ([displayMode isEqualToString:@"Red/Green"]) {
        MDFN_IEN_VB::VIP_SetAnaglyphColors(0xFF0000, 0x00FF00);
        MDFN_IEN_VB::VIP_SetParallaxDisable(false);
    }
    else if ([displayMode isEqualToString:@"Green/Magenta"]) {
        MDFN_IEN_VB::VIP_SetAnaglyphColors(0x00FF00, 0xFF00FF);
        MDFN_IEN_VB::VIP_SetParallaxDisable(false);
    }
    else if ([displayMode isEqualToString:@"Yellow/Blue"]) {
        MDFN_IEN_VB::VIP_SetAnaglyphColors(0xFFFF00, 0x0000FF);
        MDFN_IEN_VB::VIP_SetParallaxDisable(false);
    }
}

- (void)loadDisplayModeOptions
{
    if(![_mednafenCoreModule isEqualToString:@"vb"])
        return;

    // Restore palette
    NSString *lastPalette = self.displayModeInfo[@"vbPalette"];
    if (lastPalette && ![lastPalette isEqualToString:@"Red/Black (2D)"]) {
        [self changeDisplayWithMode:lastPalette];
    }
}

#pragma mark - Discs

- (void)setDisc:(NSUInteger)discNumber
{
    uint32_t index = (uint32_t)discNumber - 1; // 0-based index
    MDFNI_SetMedia(0, 0, 0, 0); // open drive/eject disc

    // Open/eject needs a bit of delay, so wait 1 second until inserting new disc
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        MDFNI_SetMedia(0, 2, index, 0); // close drive/insert disc (2 = close)
    });
}

- (NSUInteger)discCount
{
    return _maxDiscs ? _maxDiscs : 1;
}

// MARK: - Utility

- (void)scaleMouseCoordsAtPoint:(OEIntPoint)aPoint
{
    // Calculate aspect ratio used by front end method -[OEGameLayerView correctScreenSize:forAspectSize:]
    CGFloat wr = (CGFloat) game->nominal_width / _videoWidth;
    CGFloat hr = (CGFloat) game->nominal_height / _videoHeight;
    CGFloat ratio = MAX(hr, wr);
    NSSize scaled = NSMakeSize((wr / ratio), (hr / ratio));

    CGFloat halfw = scaled.width;
    CGFloat halfh = scaled.height;

    // Resized 1x window resolution based on values of -[OEGameCore aspectSize]
    NSSize scaledWindow;
    scaledWindow = _videoWidth <= game->nominal_width ?
    NSMakeSize(_videoWidth / halfh, _videoHeight / halfw) :
    NSMakeSize(_videoWidth * halfw, _videoHeight * halfh);

    // Scale mouse X/Y coords by ratios
    NSSize scaledRatio =
    NSMakeSize((CGFloat)game->nominal_width  / scaledWindow.width,
               (CGFloat)game->nominal_height / scaledWindow.height);

    _mouseScaledX = aPoint.x * (CGFloat)scaledRatio.width;
    _mouseScaledY = aPoint.y * (CGFloat)scaledRatio.height;
}

#pragma mark - Cheats

namespace Mednafen { void MDFN_FlushGameCheats(int nosave); }

- (void)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled
{
    code = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    code = [code stringByReplacingOccurrencesOfString:@" " withString:@""];

    if (!_cheatList)
        _cheatList = [NSMutableDictionary dictionary];

    if (enabled) {
        _cheatList[code] = @YES;
    } else {
        [_cheatList removeObjectForKey:code];

        // ROM patches persist in wsCartROM until reverted here; unlike RAM 'R' patches, simply
        // no longer re-asserting them (via MDFN_FlushGameCheats below) doesn't undo them.
        NSMutableDictionary<NSNumber *, NSNumber *> *romBackups = _romPatchBackups[code];
        if (romBackups) {
            uint8_t *rom = MDFNWS_GetROMPointer();
            if (rom) {
                for (NSNumber *offsetKey in romBackups)
                    rom[offsetKey.unsignedIntValue] = romBackups[offsetKey].unsignedCharValue;
            }
            [_romPatchBackups removeObjectForKey:code];
        }
    }

    Mednafen::MDFN_FlushGameCheats(1);

    for (NSString *key in _cheatList) {
        if (![_cheatList[key] boolValue]) continue;
        NSArray<NSString *> *parts = [key componentsSeparatedByString:@"+"];
        for (NSString *singleCode in parts) {
            Mednafen::MemoryPatch patch;
            patch.status = true;
            patch.type = 'R';
            patch.bigendian = false;

            NSRange colonRange = [singleCode rangeOfString:@":"];
            if (colonRange.location != NSNotFound) {
                NSString *addrPart = [singleCode substringToIndex:colonRange.location];
                unsigned int addr = 0, val = 0;

                if (![[NSScanner scannerWithString:addrPart] scanHexInt:&addr]) continue;
                if (![[NSScanner scannerWithString:[singleCode substringFromIndex:colonRange.location + 1]] scanHexInt:&val]) continue;

                // NGP RAM is registered at 0x4000 in Mednafen's mempatcher
                if ([_mednafenCoreModule isEqualToString:@"ngp"]) {
                    addr += 0x4000;
                }

                // PCE Physical Address format (e.g. F82DB1 = page F8, offset 0xDB1).
                // Convert to 21-bit physical address for the mempatcher.
                if ([_mednafenCoreModule isEqualToString:@"pce"] && addr > 0x1FFFFF) {
                    uint32_t page = (addr >> 16) & 0xFF;
                    uint32_t offset = addr & 0x1FFF;
                    addr = (page << 13) | offset;
                }

                // WonderSwan ROM code patch (GameHacking.org convention: 0x4000000 | ROM file offset).
                // wsCartROM isn't a mempatcher page, so this bypasses MDFNI_AddCheat and writes the
                // buffer directly; see the disable branch above for the revert side.
                if ([_mednafenCoreModule isEqualToString:@"wswan"] && (addr & 0x04000000)) {
                    uint32_t romOffset = addr & 0x03FFFFFF;
                    uint8_t *rom = MDFNWS_GetROMPointer();
                    uint32_t romSize = MDFNWS_GetROMSize();
                    if (rom && romOffset < romSize) {
                        if (!_romPatchBackups)
                            _romPatchBackups = [NSMutableDictionary dictionary];
                        NSMutableDictionary<NSNumber *, NSNumber *> *backups = _romPatchBackups[key];
                        if (!backups) {
                            backups = [NSMutableDictionary dictionary];
                            _romPatchBackups[key] = backups;
                        }
                        NSNumber *offsetKey = @(romOffset);
                        if (!backups[offsetKey])
                            backups[offsetKey] = @(rom[romOffset]);
                        rom[romOffset] = (uint8_t)(val & 0xFF);
                    }
                    continue;
                }

                patch.addr = addr;
                patch.val = val;
                patch.length = 1;

                Mednafen::MDFNI_AddCheat(patch);
            } else if (singleCode.length == 12 && [_mednafenCoreModule isEqualToString:@"ss"]) {
                // Saturn AR format: TAAAAAAA VVVV (T=1 word, T=3 byte)
                unsigned int fullCode = 0;
                if (![[NSScanner scannerWithString:[singleCode substringToIndex:8]] scanHexInt:&fullCode]) continue;
                uint8_t satType = (fullCode >> 28) & 0xF;
                uint32_t addr = fullCode & 0x0FFFFFFF;
                unsigned int val = 0;
                if (![[NSScanner scannerWithString:[singleCode substringFromIndex:8]] scanHexInt:&val]) continue;
                patch.addr = addr;
                patch.bigendian = true;
                if (satType == 3) {
                    patch.val = val & 0xFF;
                    patch.length = 1;
                } else {
                    patch.val = val & 0xFFFF;
                    patch.length = 2;
                }
                Mednafen::MDFNI_AddCheat(patch);
            } else if (singleCode.length == 12) {
                unsigned long long raw = strtoull(singleCode.UTF8String, NULL, 16);
                uint8_t codeType = (raw >> 40) & 0xFF;
                uint32_t addr = (raw >> 16) & 0xFFFFFF;
                uint16_t val = raw & 0xFFFF;
                patch.addr = addr;
                if (codeType == 0x30) {
                    patch.val = val & 0xFF;
                    patch.length = 1;
                } else {
                    patch.val = val;
                    patch.length = 2;
                }
                Mednafen::MDFNI_AddCheat(patch);
            }
        }
    }
}

#pragma mark - Cheat Search

- (NSArray<OEMemoryRegionDescriptor *> *)readableMemoryRegions
{
    if ([_mednafenCoreModule isEqualToString:@"psx"]) {
        NSData *data = [NSData dataWithBytes:MDFN_IEN_PSX::MainRAM.data8 length:2 * 1024 * 1024];
        return @[[OEMemoryRegionDescriptor descriptorWithName:@"Main RAM"
                                                     address:0x80000000
                                                addressBytes:4
                                                        data:data]];
    }

    if ([_mednafenCoreModule isEqualToString:@"ss"]) {
        const uint8 *workL = MDFN_IEN_SS::SS_GetWorkRAML();
        const uint8 *workH = MDFN_IEN_SS::SS_GetWorkRAMH();
        if (!workL || !workH) return @[];

        NSData *dataL = [NSData dataWithBytes:workL length:1024 * 1024];
        NSData *dataH = [NSData dataWithBytes:workH length:1024 * 1024];

        return @[
            [OEMemoryRegionDescriptor descriptorWithName:@"Low Work RAM"
                                                address:0x00200000
                                           addressBytes:4
                                           minDataBytes:2
                                                   data:dataL],
            [OEMemoryRegionDescriptor descriptorWithName:@"High Work RAM"
                                                address:0x06000000
                                           addressBytes:4
                                           minDataBytes:2
                                                   data:dataH],
        ];
    }

    if ([_mednafenCoreModule isEqualToString:@"lynx"]) {
        uint8_t *ram = MDFNLynx_GetRAMPointer();
        if (!ram) return @[];
        NSData *data = [NSData dataWithBytes:ram length:0x10000];
        return @[[OEMemoryRegionDescriptor descriptorWithName:@"System RAM"
                                                     address:0x0000
                                                addressBytes:2
                                                        data:data]];
    }

    if ([_mednafenCoreModule isEqualToString:@"pcfx"]) {
        uint8_t *ram = MDFNPCFX_GetRAMPointer();
        if (!ram) return @[];
        NSData *data = [NSData dataWithBytes:ram length:2 * 1024 * 1024];
        return @[[OEMemoryRegionDescriptor descriptorWithName:@"Main RAM"
                                                     address:0x00000000
                                                addressBytes:4
                                                        data:data]];
    }

    if ([_mednafenCoreModule isEqualToString:@"vb"]) {
        uint8_t *wram = MDFNVB_GetWRAMPointer();
        if (!wram) return @[];
        NSMutableArray *regions = [NSMutableArray array];
        NSData *wramData = [NSData dataWithBytes:wram length:65536];
        [regions addObject:[OEMemoryRegionDescriptor descriptorWithName:@"System RAM"
                                                               address:0x05000000
                                                          addressBytes:4
                                                                  data:wramData]];
        uint8_t *gpram = MDFNVB_GetGPRAMPointer();
        uint32_t gpramSize = MDFNVB_GetGPRAMSize();
        if (gpram && gpramSize > 0) {
            NSData *gpData = [NSData dataWithBytes:gpram length:gpramSize];
            [regions addObject:[OEMemoryRegionDescriptor descriptorWithName:@"Cartridge RAM"
                                                                   address:0x06000000
                                                              addressBytes:4
                                                                      data:gpData]];
        }
        return regions;
    }

    if ([_mednafenCoreModule isEqualToString:@"ngp"]) {
        uint8_t *ram = MDFNNGP_GetRAMPointer();
        if (!ram) return @[];
        NSData *data = [NSData dataWithBytes:ram length:0x4000];
        return @[[OEMemoryRegionDescriptor descriptorWithName:@"System RAM"
                                                     address:0x0000
                                                addressBytes:2
                                                        data:data]];
    }

    if ([_mednafenCoreModule isEqualToString:@"wswan"]) {
        uint8_t *ram = MDFNWS_GetRAMPointer();
        if (!ram) return @[];
        uint32_t size = MDFNWS_GetRAMSize();
        NSData *data = [NSData dataWithBytes:ram length:size];
        return @[[OEMemoryRegionDescriptor descriptorWithName:@"System RAM"
                                                     address:0x0000
                                                addressBytes:2
                                                        data:data]];
    }

    if ([_mednafenCoreModule isEqualToString:@"pce"] && !_isSystemPCECD) {
        uint8_t *ram = MDFNPCE_GetMainRAMPointer();
        if (!ram) return @[];
        uint32_t size = MDFNPCE_GetMainRAMSize();
        // Display using official PCE cheat format: page (F8+) + slot 1 base (0x2000)
        if (size <= 8192) {
            NSData *data = [NSData dataWithBytes:ram length:size];
            return @[[OEMemoryRegionDescriptor descriptorWithName:@"System RAM"
                                                         address:0xF82000
                                                    addressBytes:3
                                                            data:data]];
        }
        // SGX: 32KB split across pages F8-FB for correct address conversion
        NSMutableArray *regions = [NSMutableArray array];
        for (uint32_t i = 0; i < size / 8192; i++) {
            NSData *pageData = [NSData dataWithBytes:ram + i * 8192 length:8192];
            uint32_t pageAddr = ((0xF8 + i) << 16) | 0x2000;
            [regions addObject:[OEMemoryRegionDescriptor descriptorWithName:[NSString stringWithFormat:@"RAM (page %02X)", 0xF8 + i]
                                                                   address:pageAddr
                                                              addressBytes:3
                                                                      data:pageData]];
        }
        return regions;
    }

    if ([_mednafenCoreModule isEqualToString:@"pce"] && _isSystemPCECD) {
        uint8_t *ram = MDFNPCE_GetMainRAMPointer();
        if (!ram) return @[];
        NSMutableArray *regions = [NSMutableArray array];

        NSData *mainData = [NSData dataWithBytes:ram length:8192];
        [regions addObject:[OEMemoryRegionDescriptor descriptorWithName:@"System RAM"
                                                               address:0xF82000
                                                          addressBytes:3
                                                                  data:mainData]];

        uint8_t *cdram = MDFNPCE_GetCDRAMPointer();
        if (cdram) {
            NSData *cdData = [NSData dataWithBytes:cdram length:64 * 1024];
            [regions addObject:[OEMemoryRegionDescriptor descriptorWithName:@"CD RAM"
                                                                   address:0x100000
                                                              addressBytes:3
                                                                      data:cdData]];
        }

        uint8_t *syscard = MDFNPCE_GetSysCardRAMPointer();
        if (syscard) {
            NSData *sysData = [NSData dataWithBytes:syscard length:192 * 1024];
            [regions addObject:[OEMemoryRegionDescriptor descriptorWithName:@"Super System Card RAM"
                                                                   address:0x0D0000
                                                              addressBytes:3
                                                                      data:sysData]];
        }

        uint8_t *saveram = MDFNPCE_GetSaveRAMPointer();
        if (saveram) {
            NSData *saveData = [NSData dataWithBytes:saveram length:2048];
            [regions addObject:[OEMemoryRegionDescriptor descriptorWithName:@"Save RAM"
                                                                   address:0x1EE000
                                                              addressBytes:3
                                                                      data:saveData]];
        }

        return regions;
    }

    return @[];
}

@end
