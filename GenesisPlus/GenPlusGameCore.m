/*
 Copyright (c) 2022, OpenEmu Team
 
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

#import "GenPlusGameCore.h"
#import <OpenEmuBase/OERingBuffer.h>
#import <OpenEmuBase/OEMemoryRegionDescriptor.h>
#import "OESMSSystemResponderClient.h"
#import "OEGGSystemResponderClient.h"
#import "OESG1000SystemResponderClient.h"
#import "OEGenesisSystemResponderClient.h"
#import "OESegaCDSystemResponderClient.h"
#import <OpenGL/gl.h>

#include "shared.h"

#define RC_CLIENT_SUPPORTS_HASH 1
#include <rc_client.h>
#include <rc_consoles.h>
#import "OERetroAchievementsTransport.h"

#define OptionDefault(_NAME_, _PREFKEY_) @{ OEGameCoreDisplayModeNameKey : _NAME_, OEGameCoreDisplayModePrefKeyNameKey : _PREFKEY_, OEGameCoreDisplayModeStateKey : @YES, }
#define Option(_NAME_, _PREFKEY_) @{ OEGameCoreDisplayModeNameKey : _NAME_, OEGameCoreDisplayModePrefKeyNameKey : _PREFKEY_, OEGameCoreDisplayModeStateKey : @NO, }
#define OptionIndented(_NAME_, _PREFKEY_) @{ OEGameCoreDisplayModeNameKey : _NAME_, OEGameCoreDisplayModePrefKeyNameKey : _PREFKEY_, OEGameCoreDisplayModeStateKey : @NO, OEGameCoreDisplayModeIndentationLevelKey : @(1), }
#define OptionToggleable(_NAME_, _PREFKEY_) @{ OEGameCoreDisplayModeNameKey : _NAME_, OEGameCoreDisplayModePrefKeyNameKey : _PREFKEY_, OEGameCoreDisplayModeStateKey : @NO, OEGameCoreDisplayModeAllowsToggleKey : @YES, }
#define OptionToggleableNoSave(_NAME_, _PREFKEY_) @{ OEGameCoreDisplayModeNameKey : _NAME_, OEGameCoreDisplayModePrefKeyNameKey : _PREFKEY_, OEGameCoreDisplayModeStateKey : @NO, OEGameCoreDisplayModeAllowsToggleKey : @YES, OEGameCoreDisplayModeDisallowPrefSaveKey : @YES, }
#define Label(_NAME_) @{ OEGameCoreDisplayModeLabelKey : _NAME_, }
#define SeparatorItem() @{ OEGameCoreDisplayModeSeparatorItemKey : @"",}

static const double pal_fps = 53203424.0 / (3420.0 * 313.0);
static const double ntsc_fps = 53693175.0 / (3420.0 * 262.0);

t_config config;

char GG_ROM[256];
char AR_ROM[256];
char SK_ROM[256];
char SK_UPMEM[256];
char MD_BIOS[256];
char GG_BIOS[256];
char MS_BIOS_EU[256];
char MS_BIOS_JP[256];
char MS_BIOS_US[256];
char CD_BIOS_EU[256];
char CD_BIOS_US[256];
char CD_BIOS_JP[256];
char CD_BRAM_JP[256];
char CD_BRAM_US[256];
char CD_BRAM_EU[256];
char CART_BRAM[256];

// Mega CD backup RAM stuff
static uint32_t brm_crc[2];
static uint8_t brm_format[0x40] =
{
    0x5f,0x5f,0x5f,0x5f,0x5f,0x5f,0x5f,0x5f,0x5f,0x5f,0x5f,0x00,0x00,0x00,0x00,0x40,
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    0x53,0x45,0x47,0x41,0x5f,0x43,0x44,0x5f,0x52,0x4f,0x4d,0x00,0x01,0x00,0x00,0x00,
    0x52,0x41,0x4d,0x5f,0x43,0x41,0x52,0x54,0x52,0x49,0x44,0x47,0x45,0x5f,0x5f,0x5f
};

// Cheat Support
#define MAX_CHEATS (150)
#define MAX_DESC_LENGTH (63)

typedef struct
{
    char code[12];
    char text[MAX_DESC_LENGTH];
    uint8_t enable;
    uint16_t data;
    uint16_t old;
    uint32_t address;
    uint8_t *prev;
} CHEATENTRY;

static int maxcheats = 0;
static int maxROMcheats = 0;
static int maxRAMcheats = 0;
static CHEATENTRY cheatlist[MAX_CHEATS];
static uint8_t cheatIndexes[MAX_CHEATS];
static char ggvalidchars[] = "ABCDEFGHJKLMNPRSTVWXYZ0123456789";
static char arvalidchars[] = "0123456789ABCDEF";

typedef NS_ENUM(NSInteger, MultiTapType)
{
    MultiTapTypeNone,
    TeamPlayerPort1,                // 1-4 players: TeamPlayer in Port 1
    GamepadPort1TeamPlayerPort2,    // 1-4 players: Gamepad Port 1, TeamPlayer Port 2
    TeamPlayerPort1TeamPlayerPort2, // 1-8 players: TeamPlayer in Port 1, TeamPlayer Port 2
    EA4WayPlay                      // 1-4 players: EA 4-Way Play
};

@interface GenPlusGameCore () <OEGenesisSystemResponderClient, OESegaCDSystemResponderClient>
{
    uint8_t *_videoBuffer;
    int16_t *_soundBuffer;
    NSMutableDictionary<NSString *, NSNumber *> *_cheatList;
    NSMutableArray <NSMutableDictionary <NSString *, id> *> *_availableDisplayModes;
    NSURL *_romFile;
    MultiTapType _multiTapType;
    rc_client_t *_rcClient;
    id _raTokenObserver;
    BOOL _raHardcoreEnabled;
    id _raHardcoreObserver;
    int _rcConsole;
}
- (void)applyCheat:(NSString *)code;
- (void)resetCheats;
- (void)configureOptions;
- (void)configureInput;
- (void)_beginLoadGame;
- (void)_postRetroAchievementsSessionSnapshot;
@end

// rcheevos memory callback.
//
// rcheevos uses a normalized address space, not the 68000/Z80 bus addresses.
// Mapping (from Vendor/rcheevos/src/rcheevos/consoleinfo.c):
//
//   Genesis            — RC 0x000000–0x00FFFF → work_ram[] (64 KB 68K RAM)
//   Mega CD / Sega CD  — RC 0x000000–0x00FFFF → work_ram[] (64 KB 68K RAM)
//                        RC 0x010000–0x08FFFF → scd.prg_ram[] (512 KB CD PRG RAM)
//                        RC 0x090000–0x0AFFFF → Word RAM (128 KB, as mapped at $200000)
//   SMS / GG / SG-1000 — RC 0x000000–0x001FFF → work_ram[] (8 KB RAM at real C000)
//
static uint32_t genplus_rc_read_memory(uint32_t address, uint8_t *buffer,
                                        uint32_t num_bytes, rc_client_t *client)
{
    for (uint32_t i = 0; i < num_bytes; i++) {
        uint32_t addr = address + i;
        if (system_hw == SYSTEM_MCD) {
            if (addr <= 0x00FFFF) {
                buffer[i] = work_ram[addr];
            } else if (addr <= 0x08FFFF) {
                buffer[i] = scd.prg_ram[addr - 0x010000];
            } else if (addr <= 0x0AFFFF) {
                // Word RAM is banked (1M mode) or linear (2M mode); read it through the
                // main 68K's own memory map so the view matches what the game sees.
                uint32_t offset = addr - 0x090000;
                const uint8_t *base = m68k.memory_map[scd.cartridge.boot + 0x20 + (offset >> 16)].base;
                if (base == NULL)
                    return i;
                buffer[i] = base[offset & 0xFFFF];
            } else {
                return i;
            }
        } else if ((system_hw & SYSTEM_PBC) == SYSTEM_MD) {
            if (addr <= 0x00FFFF)
                buffer[i] = work_ram[addr];
            else
                return i;
        } else {
            if (addr <= 0x001FFF)
                buffer[i] = work_ram[addr];
            else
                return i;
        }
    }
    return num_bytes;
}

static void genplus_rc_log(const char *message, const rc_client_t *client)
{
    NSLog(@"[rcheevos] %s", message);
}

static void genplus_rc_load_game_callback(int result, const char *error_message,
                                           rc_client_t *client, void *userdata)
{
    GenPlusGameCore *self = (__bridge GenPlusGameCore *)userdata;
    if (result != RC_OK) {
        NSLog(@"[RA-GenPlus] game load failed — result=%d error=%s", result, error_message ?: "(none)");
        oeRetroAchievementsPostSessionLoadFailure(result, error_message);
        return;
    }
    [self _postRetroAchievementsSessionSnapshot];
}

static void genplus_rc_login_callback(int result, const char *error_message,
                                       rc_client_t *client, void *userdata)
{
    GenPlusGameCore *s = (__bridge GenPlusGameCore *)userdata;
    if (result == RC_OK) {
        [s _beginLoadGame];
    } else {
        oeRetroAchievementsPostLoginFailure(result, error_message);
        NSLog(@"[RA-GenPlus] login failed — result=%d error=%s", result, error_message ?: "(none)");
    }
}

static void genplus_rc_event_handler(const rc_client_event_t *event, rc_client_t *client)
{
    oeRetroAchievementsPostEventNotification(event, client);
    if (event->type != RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED) { return; }
    const rc_client_achievement_t *ach = event->achievement;
    if (!ach) { return; }

    NSDictionary *info = @{
        OEAchievementIDKey:          @(ach->id),
        OEAchievementTitleKey:       @(ach->title       ?: ""),
        OEAchievementDescriptionKey: @(ach->description ?: ""),
        OEAchievementBadgeURLKey:    @(ach->badge_url   ?: ""),
        OEAchievementPointsKey:      @(ach->points),
    };
    [[NSNotificationCenter defaultCenter]
        postNotificationName:OEAchievementUnlockedNotification
                      object:nil
                    userInfo:info];
    GenPlusGameCore *core = (__bridge GenPlusGameCore *)rc_client_get_userdata(client);
    [core _postRetroAchievementsSessionSnapshot];
}

@implementation GenPlusGameCore

static __weak GenPlusGameCore *_current;

- (void)_beginLoadGame
{
    if (!_rcClient || !_romFile) { return; }
    rc_client_begin_identify_and_load_game(_rcClient,
                                           (uint32_t)_rcConsole,
                                           _romFile.fileSystemRepresentation,
                                           NULL, 0,
                                           genplus_rc_load_game_callback,
                                           (__bridge void *)self);
}

- (void)_postRetroAchievementsSessionSnapshot
{
    if (!_rcClient || !rc_client_is_game_loaded(_rcClient)) { return; }
    const rc_client_game_t *game = rc_client_get_game_info(_rcClient);
    if (!game || game->id == 0) { return; }

    rc_client_user_game_summary_t summary;
    memset(&summary, 0, sizeof(summary));
    rc_client_get_user_game_summary(_rcClient, &summary);

    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[OERAGameIDKey] = @(game->id);
    payload[OERAGameTitleKey] = [NSString stringWithUTF8String:game->title ?: ""];
    payload[OERAGameHashKey] = [NSString stringWithUTF8String:game->hash ?: ""];
    payload[OERAUnlockedCountKey] = @(summary.num_unlocked_achievements);
    payload[OERAAchievementCountKey] = @(summary.num_core_achievements);
    payload[OERAUnlockedPointsKey] = @(summary.points_unlocked);
    payload[OERATotalPointsKey] = @(summary.points_core);

    char gameImageURL[512];
    if (rc_client_game_get_image_url(game, gameImageURL, sizeof(gameImageURL)) == RC_OK)
        payload[OERAGameBadgeURLKey] = [NSString stringWithUTF8String:gameImageURL];

    NSMutableArray *sets = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, NSString *> *setTitlesByID = [NSMutableDictionary dictionary];
    rc_client_subset_list_t *subsetList = rc_client_create_subset_list(_rcClient);
    if (subsetList) {
        for (uint32_t i = 0; i < subsetList->num_subsets; i++) {
            const rc_client_subset_t *subset = subsetList->subsets[i];
            if (!subset) { continue; }
            NSString *subsetTitle = [NSString stringWithUTF8String:subset->title ?: "Achievement Set"];
            NSNumber *subsetID = @(subset->id);
            setTitlesByID[subsetID] = subsetTitle;
            NSMutableDictionary *setInfo = [NSMutableDictionary dictionary];
            setInfo[OERASetIDKey] = subsetID;
            setInfo[OERASetTitleKey] = subsetTitle;
            setInfo[OERASetAchievementCountKey] = @(subset->num_achievements);
            setInfo[OERASetLeaderboardCountKey] = @(subset->num_leaderboards);
            if (subset->badge_url)
                setInfo[OERASetBadgeURLKey] = [NSString stringWithUTF8String:subset->badge_url];
            [sets addObject:setInfo];
        }
        rc_client_destroy_subset_list(subsetList);
    }
    if (sets.count == 0) {
        NSNumber *gameID = @(game->id);
        NSString *gameTitle = [NSString stringWithUTF8String:game->title ?: "Achievement Set"];
        setTitlesByID[gameID] = gameTitle;
        [sets addObject:@{
            OERASetIDKey: gameID, OERASetTitleKey: gameTitle,
            OERASetAchievementCountKey: @(summary.num_core_achievements),
            OERASetLeaderboardCountKey: @0,
        }];
    }
    payload[OERASetsKey] = sets;

    NSMutableArray *achievements = [NSMutableArray array];
    rc_client_achievement_list_t *list = rc_client_create_achievement_list(
        _rcClient, RC_CLIENT_ACHIEVEMENT_CATEGORY_CORE,
        RC_CLIENT_ACHIEVEMENT_LIST_GROUPING_LOCK_STATE);
    if (list) {
        for (uint32_t b = 0; b < list->num_buckets; b++) {
            const rc_client_achievement_bucket_t bucket = list->buckets[b];
            NSString *bucketTitle = [NSString stringWithUTF8String:bucket.label ?: "Achievements"];
            for (uint32_t a = 0; a < bucket.num_achievements; a++) {
                const rc_client_achievement_t *ach = bucket.achievements[a];
                if (!ach) { continue; }
                NSNumber *subsetID = @(bucket.subset_id);
                NSMutableDictionary *entry = [NSMutableDictionary dictionary];
                entry[OERASetIDKey] = subsetID;
                entry[OERASetTitleKey] = setTitlesByID[subsetID] ?: [NSString stringWithUTF8String:game->title ?: "Achievement Set"];
                entry[OERABucketTitleKey] = bucketTitle;
                entry[OERABucketTypeKey] = @(bucket.bucket_type);
                entry[OEAchievementIDKey] = @(ach->id);
                entry[OEAchievementTitleKey] = [NSString stringWithUTF8String:ach->title ?: ""];
                entry[OEAchievementDescriptionKey] = [NSString stringWithUTF8String:ach->description ?: ""];
                entry[OEAchievementPointsKey] = @(ach->points);
                entry[OERAStateKey] = @(ach->state);
                entry[OERATypeKey] = @(ach->type);
                entry[OERAUnlockedKey] = @(ach->unlocked);
                entry[OERARarityKey] = @(ach->rarity);
                entry[OERAHardcoreRarityKey] = @(ach->rarity_hardcore);
                entry[OERAMeasuredPercentKey] = @(ach->measured_percent);
                entry[OERAMeasuredProgressKey] = [NSString stringWithUTF8String:ach->measured_progress];
                if (ach->badge_url)
                    entry[OEAchievementBadgeURLKey] = [NSString stringWithUTF8String:ach->badge_url];
                if (ach->badge_locked_url)
                    entry[OERABadgeLockedURLKey] = [NSString stringWithUTF8String:ach->badge_locked_url];
                [achievements addObject:entry];
            }
        }
        rc_client_destroy_achievement_list(list);
    }
    payload[OERAAchievementsKey] = achievements;
    [[NSNotificationCenter defaultCenter] postNotificationName:OERASessionUpdatedNotification
                                                        object:nil
                                                      userInfo:payload];
}

- (id)init
{
    if((self = [super init]))
    {
        _videoBuffer = (uint8_t *)malloc(720 * 576 * sizeof(uint32_t));
        _soundBuffer = (int16_t *)malloc(2048 * 2 * sizeof(int16_t));
        _cheatList = [NSMutableDictionary dictionary];
    }

	_current = self;

	return self;
}


- (void)retroAchievementsIdle
{
    if (_rcClient) {
        rc_client_idle(_rcClient);
    }
}

- (BOOL)canPauseRetroAchievementsHardcoreWithFramesRemaining:(uint32_t *)framesRemaining
{
    if (!_rcClient) { return YES; }
    return rc_client_can_pause(_rcClient, framesRemaining) != 0;
}

- (NSData *)retroAchievementsSerializedProgress {
    if (!_rcClient) return nil;
    size_t size = rc_client_progress_size(_rcClient);
    if (size == 0) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:size];
    rc_client_serialize_progress(_rcClient, data.mutableBytes);
    return data;
}

- (void)retroAchievementsDeserializeProgress:(NSData *)data {
    if (!_rcClient) return;
    rc_client_deserialize_progress(_rcClient, data ? data.bytes : NULL);
}

- (void)dealloc
{
    free(_videoBuffer);
    free(_soundBuffer);
}

# pragma mark - Execution

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    _romFile = [NSURL fileURLWithPath:path];

    // Set CD BIOS and BRAM/RAM Cart paths
    snprintf(CD_BIOS_EU, sizeof(CD_BIOS_EU), "%s%sbios_CD_E.bin", self.biosDirectoryPath.fileSystemRepresentation, "/");
    snprintf(CD_BIOS_US, sizeof(CD_BIOS_US), "%s%sbios_CD_U.bin", self.biosDirectoryPath.fileSystemRepresentation, "/");
    snprintf(CD_BIOS_JP, sizeof(CD_BIOS_JP), "%s%sbios_CD_J.bin", self.biosDirectoryPath.fileSystemRepresentation, "/");
    snprintf(CD_BRAM_EU, sizeof(CD_BRAM_EU), "%s%sscd_E.brm", self.batterySavesDirectoryPath.fileSystemRepresentation, "/");
    snprintf(CD_BRAM_US, sizeof(CD_BRAM_US), "%s%sscd_U.brm", self.batterySavesDirectoryPath.fileSystemRepresentation, "/");
    snprintf(CD_BRAM_JP, sizeof(CD_BRAM_JP), "%s%sscd_J.brm", self.batterySavesDirectoryPath.fileSystemRepresentation, "/");
    snprintf(CART_BRAM, sizeof(CART_BRAM), "%s%scart.brm", self.batterySavesDirectoryPath.fileSystemRepresentation, "/");

    [self configureOptions];

    if (self.lockOnRomURL != nil && [self.systemIdentifier isEqualToString:@"openemu.system.sg"])
    {
        config.lock_on = TYPE_SK;
        snprintf(SK_ROM, sizeof(SK_ROM), "%s", self.lockOnRomURL.path.fileSystemRepresentation);
        if (self.lockOnUpmemURL != nil)
        {
            snprintf(SK_UPMEM, sizeof(SK_UPMEM), "%s", self.lockOnUpmemURL.path.fileSystemRepresentation);
        }
        else
        {
            NSArray<NSString *> *candidateNames = @[@"sk_upmem.bin", @"Sonic & Knuckles (World) (Lock-on).bin"];
            SK_UPMEM[0] = '\0';
            for (NSString *candidateName in candidateNames)
            {
                NSString *candidatePath = [self.biosDirectoryPath stringByAppendingPathComponent:candidateName];
                if ([NSFileManager.defaultManager isReadableFileAtPath:candidatePath])
                {
                    snprintf(SK_UPMEM, sizeof(SK_UPMEM), "%s", candidatePath.fileSystemRepresentation);
                    break;
                }
            }
        }
    }
    else
    {
        SK_ROM[0] = '\0';
        SK_UPMEM[0] = '\0';
    }

    if (!load_rom((char *)path.fileSystemRepresentation))
        return NO;

    if([self.systemIdentifier isEqualToString:@"openemu.system.sg"] || [self.systemIdentifier isEqualToString:@"openemu.system.scd"] || [self.systemIdentifier isEqualToString:@"openemu.system.sms"])
    {
        // Force system region to Japan if user locale is Japan and the cart appears to be world/multi-region
        if((strstr((const char*)rominfo.country, "EJ") ||
            strstr((const char*)rominfo.country, "JE") ||
            strstr((const char*)rominfo.country, "JU") ||
            strstr((const char*)rominfo.country, "UJ") ||
            strstr(rominfo.country, "SMS Export") != NULL)
           && [self.systemRegion isEqualToString: @"Japan"])
        {
            config.region_detect = 3;
            region_code = REGION_JAPAN_NTSC;
            NSLog(@"[Genesis Plus GX] Forcing region to Japan for multi-region cart");
        }
    }

    [self configureInput];
    audio_init(48000, vdp_pal ? pal_fps : ntsc_fps);

    system_init();
    system_reset();

    if (system_hw == SYSTEM_MCD)
        bram_load();

    // Determine RA console from the system this ROM was identified as.
    // NOTE: openemu.system.sg is Genesis/Mega Drive; openemu.system.sg1000 is the SG-1000.
    // The names are misleading — see oecores.xml — so map both explicitly.
    if ([self.systemIdentifier isEqualToString:@"openemu.system.sms"])
        _rcConsole = RC_CONSOLE_MASTER_SYSTEM;
    else if ([self.systemIdentifier isEqualToString:@"openemu.system.gg"])
        _rcConsole = RC_CONSOLE_GAME_GEAR;
    else if ([self.systemIdentifier isEqualToString:@"openemu.system.sg1000"])
        _rcConsole = RC_CONSOLE_SG1000;
    else if ([self.systemIdentifier isEqualToString:@"openemu.system.scd"])
        _rcConsole = RC_CONSOLE_SEGA_CD;
    else
        _rcConsole = RC_CONSOLE_MEGA_DRIVE;

    _rcClient = rc_client_create(genplus_rc_read_memory, oeRetroAchievementsServerCall);
    if (_rcClient) {
        rc_client_set_userdata(_rcClient, (__bridge void *)self);
        rc_client_set_event_handler(_rcClient, genplus_rc_event_handler);
        _raHardcoreEnabled = YES;
        rc_client_set_hardcore_enabled(_rcClient, _raHardcoreEnabled ? 1 : 0);
        rc_client_set_allow_background_memory_reads(_rcClient, 0);
        rc_client_enable_logging(_rcClient, RC_CLIENT_LOG_LEVEL_INFO, genplus_rc_log);

        __weak GenPlusGameCore *weakSelf = self;
        _raTokenObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:OERetroAchievementsTokenDidChangeNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
            GenPlusGameCore *s = weakSelf;
            if (!s || !s->_rcClient) { return; }
            NSString *token    = note.userInfo[OERetroAchievementsTokenKey];
            NSString *username = note.userInfo[OERetroAchievementsUsernameKey];
            if (token && username) {
                rc_client_begin_login_with_token(s->_rcClient,
                                                 username.UTF8String,
                                                 token.UTF8String,
                                                 genplus_rc_login_callback,
                                                 (__bridge void *)s);
            } else {
                rc_client_logout(s->_rcClient);
            }
        }];

        _raHardcoreObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:OEHardcoreModeDidChangeNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
            NSNumber *enabled = note.userInfo[OEHardcoreEnabledKey];
            if (enabled) {
                self->_raHardcoreEnabled = enabled.boolValue;
                if (self->_rcClient) {
                    rc_client_set_hardcore_enabled(self->_rcClient, self->_raHardcoreEnabled ? 1 : 0);
                }
            }
        }];
    }

    // Set battery saves dir and load sram
    NSString *extensionlessFilename = _romFile.lastPathComponent.stringByDeletingPathExtension;
    NSURL *batterySavesDirectory = [NSURL fileURLWithPath:self.batterySavesDirectoryPath];
    [NSFileManager.defaultManager createDirectoryAtURL:batterySavesDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *saveFile = [batterySavesDirectory URLByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"sav"]];

    if ([saveFile checkResourceIsReachableAndReturnError:nil])
    {
        NSData *saveData = [NSData dataWithContentsOfURL:saveFile];
        memcpy(sram.sram, saveData.bytes, 0x10000);
        sram.crc = crc32(0, sram.sram, 0x10000);
        NSLog(@"[Genesis Plus GX] Loaded sram");
    }

    if([self.systemIdentifier isEqualToString:@"openemu.system.sg"] || [self.systemIdentifier isEqualToString:@"openemu.system.scd"])
    {
        // Set initial viewport size because the system briefly outputs 256x192 when it boots
        bitmap.viewport.w = 292;
        bitmap.viewport.h = 224;
    }

    return YES;
}

- (void)executeFrame
{
    if (system_hw == SYSTEM_MCD)
        system_frame_scd(0);
    else if ((system_hw & SYSTEM_PBC) == SYSTEM_MD)
        system_frame_gen(0);
    else
        system_frame_sms(0);

    if (_rcClient)
        rc_client_do_frame(_rcClient);

    int samples = audio_update(_soundBuffer);
    [[self audioBufferAtIndex:0] write:_soundBuffer maxLength:samples << 2];
}

- (void)resetEmulation
{
    if (_rcClient)
        rc_client_reset(_rcClient);
    system_reset();
}

- (void)stopEmulation
{
    if (sram.on)
    {
        // max. supported SRAM size
        unsigned long filesize = 0x10000;

        // only save modified SRAM size
        do
        {
            if (sram.sram[filesize-1] != 0xff)
                break;
        }
        while (--filesize > 0);

        // only save if SRAM has been modified
        if ((filesize != 0) || (crc32(0, &sram.sram[0], 0x10000) != sram.crc))
        {
            NSError *error = nil;
            NSString *extensionlessFilename = _romFile.lastPathComponent.stringByDeletingPathExtension;
            NSURL *batterySavesDirectory = [NSURL fileURLWithPath:self.batterySavesDirectoryPath];
            NSURL *saveFile = [batterySavesDirectory URLByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"sav"]];

            // copy SRAM data
            NSData *saveData = [NSData dataWithBytes:sram.sram length:filesize];
            [saveData writeToURL:saveFile options:NSDataWritingAtomic error:&error];

            // update CRC
            sram.crc = crc32(0, sram.sram, 0x10000);

            if (error)
                NSLog(@"[Genesis Plus GX] Error writing sram file: %@", error);
            else
                NSLog(@"[Genesis Plus GX] Saved sram file: %@", saveFile);
        }
    }

    if (system_hw == SYSTEM_MCD)
        bram_save();

    audio_shutdown();

    if (_raTokenObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_raTokenObserver];
        _raTokenObserver = nil;
    }
    if (_raHardcoreObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_raHardcoreObserver];
        _raHardcoreObserver = nil;
    }
    if (_rcClient) {
        rc_client_unload_game(_rcClient);
        rc_client_destroy(_rcClient);
        _rcClient = NULL;
    }

    [super stopEmulation];
}

- (NSTimeInterval)frameInterval
{
    return vdp_pal ? pal_fps : ntsc_fps;
}

# pragma mark - Video

- (const void *)getVideoBufferWithHint:(void *)hint
{
    if (!hint) {
        hint = _videoBuffer;
    }

    return bitmap.data = (uint8_t*)hint;
}

- (OEIntRect)screenRect
{
    if([self.systemIdentifier isEqualToString:@"openemu.system.gg"])
    {
        return OEIntRectMake(0, 0, 160, 144);
    }
    else
    {
        return OEIntRectMake(bitmap.viewport.x, bitmap.viewport.y, bitmap.viewport.w, bitmap.viewport.h);
    }
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(bitmap.width, bitmap.height);
}

- (OEIntSize)aspectSize
{
    if([self.systemIdentifier isEqualToString:@"openemu.system.gg"])
    {
        return OEIntSizeMake(160, 144);
    }
    else if([self.systemIdentifier isEqualToString:@"openemu.system.sms"] || [self.systemIdentifier isEqualToString:@"openemu.system.sg1000"])
    {
        return OEIntSizeMake(256 * (8.0/7.0), 192);
    }
    else
    {
        // H32 mode (256px * 8:7 PAR)
        // H40 mode (320px * 32:35 PAR)
        return OEIntSizeMake(292, 224);
    }
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
    return 48000;
}

- (NSUInteger)channelCount
{
    return 2;
}

# pragma mark - Save States

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    int serial_size = STATE_SIZE;
    NSMutableData *stateData = [NSMutableData dataWithLength:serial_size];

    if(!state_save(stateData.mutableBytes))
    {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotSaveStateError userInfo:@{
            NSLocalizedDescriptionKey : @"Save state data could not be written",
            NSLocalizedRecoverySuggestionErrorKey : @"The emulator could not write the state data."
        }];
        block(NO, error);
        return;
    }

    __autoreleasing NSError *error = nil;
    BOOL success = [stateData writeToFile:fileName options:NSDataWritingAtomic error:&error];

    block(success, success ? nil : error);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    __autoreleasing NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:fileName options:NSDataReadingMappedIfSafe | NSDataReadingUncached error:&error];

    if(data == nil)
    {
        block(NO, error);
        return;
    }

    int serial_size = STATE_SIZE;
    if(serial_size != data.length)
    {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreStateHasWrongSizeError userInfo:@{
            NSLocalizedDescriptionKey : @"Save state has wrong file size.",
            NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:@"The size of the file %@ does not have the right size, %d expected, got: %ld.", fileName, serial_size, data.length],
        }];
        block(NO, error);
        return;
    }

    if(!state_load((uint8_t *)data.bytes))
    {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadStateError userInfo:@{
            NSLocalizedDescriptionKey : @"The save state data could not be read",
            NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:@"Could not read the file state in %@.", fileName]
        }];
        block(NO, error);
        return;
    }

    if (_rcClient)
        rc_client_reset(_rcClient);

    block(YES, nil);
}

- (NSData *)serializeStateWithError:(NSError **)outError
{
    size_t length = STATE_SIZE;
    NSMutableData *data = [NSMutableData dataWithLength:length];

    if(state_save(data.mutableBytes))
        return data;

    if (outError) {
        *outError = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotSaveStateError userInfo:@{
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
    size_t serialSize = STATE_SIZE;

    if(serialSize != length) {
        if (outError) {
            *outError = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreStateHasWrongSizeError userInfo:@{
                NSLocalizedDescriptionKey : @"Save state has wrong file size.",
                NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:@"The size of the save state does not have the right size, %lu expected, got: %ld.", serialSize, state.length],
            }];
        }

        return NO;
    }

    if(state_load((uint8_t *)bytes))
        return YES;

    if (outError) {
        *outError = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadStateError userInfo:@{
            NSLocalizedDescriptionKey : @"The save state data could not be read",
            NSLocalizedRecoverySuggestionErrorKey : @"Could not load data from the save state"
        }];
    }

    return NO;
}

# pragma mark - Input

const int GenesisMap[] = {INPUT_UP, INPUT_DOWN, INPUT_LEFT, INPUT_RIGHT, INPUT_A, INPUT_B, INPUT_C, INPUT_X, INPUT_Y, INPUT_Z, INPUT_START, INPUT_MODE};
const int GameGearMap[] = {INPUT_UP, INPUT_DOWN, INPUT_LEFT, INPUT_RIGHT, INPUT_B, INPUT_C, INPUT_START};
const int MasterSystemMap[] = {INPUT_UP, INPUT_DOWN, INPUT_LEFT, INPUT_RIGHT, INPUT_BUTTON1, INPUT_BUTTON2, INPUT_START};

- (oneway void)didPushGenesisButton:(OEGenesisButton)button forPlayer:(NSUInteger)player
{
    if (_multiTapType == GamepadPort1TeamPlayerPort2 || cart.special & HW_J_CART)
    {
        NSUInteger offset = (player == 1) ? 0 : player + 2;
        input.pad[offset] |= GenesisMap[button];
    }
    else if (_multiTapType == TeamPlayerPort1 || _multiTapType == TeamPlayerPort1TeamPlayerPort2 || _multiTapType == EA4WayPlay)
    {
        input.pad[player-1] |= GenesisMap[button];
    }
    else
    {
        input.pad[(player-1) * 4] |= GenesisMap[button];
    }
}

- (oneway void)didReleaseGenesisButton:(OEGenesisButton)button forPlayer:(NSUInteger)player
{
    if (_multiTapType == GamepadPort1TeamPlayerPort2 || cart.special & HW_J_CART)
    {
        NSUInteger offset = (player == 1) ? 0 : player + 2;
        input.pad[offset] &= ~GenesisMap[button];
    }
    else if (_multiTapType == TeamPlayerPort1 || _multiTapType == TeamPlayerPort1TeamPlayerPort2 || _multiTapType == EA4WayPlay)
    {
        input.pad[player-1] &= ~GenesisMap[button];
    }
    else
        input.pad[(player-1) * 4] &= ~GenesisMap[button];
}

- (oneway void)didPushSegaCDButton:(OESegaCDButton)button forPlayer:(NSUInteger)player
{
    if (_multiTapType == GamepadPort1TeamPlayerPort2)
    {
        NSUInteger offset = (player == 1) ? 0 : player + 2;
        input.pad[offset] |= GenesisMap[button];
    }
    else if (_multiTapType == TeamPlayerPort1 || _multiTapType == TeamPlayerPort1TeamPlayerPort2 || _multiTapType == EA4WayPlay)
    {
        input.pad[player-1] |= GenesisMap[button];
    }
    else
        input.pad[(player-1) * 4] |= GenesisMap[button];
}

- (oneway void)didReleaseSegaCDButton:(OESegaCDButton)button forPlayer:(NSUInteger)player
{
    if (_multiTapType == GamepadPort1TeamPlayerPort2)
    {
        NSUInteger offset = (player == 1) ? 0 : player + 2;
        input.pad[offset] &= ~GenesisMap[button];
    }
    else if (_multiTapType == TeamPlayerPort1 || _multiTapType == TeamPlayerPort1TeamPlayerPort2 || _multiTapType == EA4WayPlay)
    {
        input.pad[player-1] &= ~GenesisMap[button];
    }
    else
        input.pad[(player-1) * 4] &= ~GenesisMap[button];
}

- (oneway void)didPushGGButton:(OEGGButton)button
{
     input.pad[0] |= GameGearMap[button];
}

- (oneway void)didReleaseGGButton:(OEGGButton)button
{
    input.pad[0] &= ~GameGearMap[button];
}

- (oneway void)didPushSMSButton:(OESMSButton)button forPlayer:(NSUInteger)player
{
    input.pad[(player-1) * 4] |= MasterSystemMap[button];
}

- (oneway void)didReleaseSMSButton:(OESMSButton)button forPlayer:(NSUInteger)player
{
    input.pad[(player-1) * 4] &= ~MasterSystemMap[button];
}

- (oneway void)didPushSMSStartButton
{
    [self didPushSMSButton:OESMSButtonStart forPlayer:1];
}

- (oneway void)didReleaseSMSStartButton
{
    [self didReleaseSMSButton:OESMSButtonStart forPlayer:1];
}

- (oneway void)didPushSMSResetButton
{

}

- (oneway void)didReleaseSMSResetButton
{

}

- (oneway void)didPushSG1000Button:(OESG1000Button)button forPlayer:(NSUInteger)player
{
    input.pad[(player-1) * 4] |= MasterSystemMap[button];
}

- (oneway void)didReleaseSG1000Button:(OESG1000Button)button forPlayer:(NSUInteger)player
{
    input.pad[(player-1) * 4] &= ~MasterSystemMap[button];
}

- (oneway void)mouseMovedAtPoint:(OEIntPoint)aPoint
{
    // TODO handle Sega Mouse

    if (input.dev[4] == DEVICE_LIGHTGUN)
    {
        // Handle screen resolution changes
        if (bitmap.viewport.w == 320)
        {
            input.analog[4][0] = aPoint.x;
            input.analog[4][1] = aPoint.y * 0.912500;
        }
        else // w == 256
        {
            input.analog[4][0] = aPoint.x * 0.876712;
            input.analog[4][1] = aPoint.y;
        }
    }
    else if (input.system[0] == SYSTEM_LIGHTPHASER)
    {
        input.analog[0][0] = aPoint.x * 0.876712;
        input.analog[0][1] = aPoint.y;
    }
}

- (oneway void)leftMouseDownAtPoint:(OEIntPoint)aPoint
{
    if (input.dev[4] == DEVICE_LIGHTGUN)
    {
        [self mouseMovedAtPoint:aPoint];
        input.pad[4] |= INPUT_A; // menacer button A / justifier trigger
    }
    else if (input.system[0] == SYSTEM_LIGHTPHASER)
    {
        [self mouseMovedAtPoint:aPoint];
        input.pad[0] |= INPUT_A; // light phaser trigger
    }
}

- (oneway void)leftMouseUp
{
    if (input.dev[4] == DEVICE_LIGHTGUN)
    {
        input.pad[4] &= ~INPUT_A; // menacer button A / justifier trigger
    }
    else if (input.system[0] == SYSTEM_LIGHTPHASER)
    {
        input.pad[0] &= ~INPUT_A; // light phaser trigger
    }
}

- (oneway void)rightMouseDownAtPoint:(OEIntPoint)aPoint
{
    if (input.dev[4] == DEVICE_LIGHTGUN)
    {
        [self mouseMovedAtPoint:aPoint];

        if (input.system[1] == SYSTEM_MENACER)
            input.pad[4] |= INPUT_B; // menacer button B
        else
            input.pad[4] |= INPUT_START; // justifier start
    }
}

- (oneway void)rightMouseUp
{
    if (input.dev[4] == DEVICE_LIGHTGUN)
    {
        if (input.system[1] == SYSTEM_MENACER)
            input.pad[4] &= ~INPUT_B; // menacer button B
        else
            input.pad[4] &= ~INPUT_START; // justifier start
    }
}

#pragma mark - Cheats

- (void)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled
{
    // Sanitize
    code = [code stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];

    // Genesis Plus GX expects cheats UPPERCASE
    code = code.uppercaseString;

    // Remove any spaces
    code = [code stringByReplacingOccurrencesOfString:@" " withString:@""];

    if (enabled)
        _cheatList[code] = @YES;
    else
        [_cheatList removeObjectForKey:code];

    [self resetCheats];

    NSArray<NSString *> *multipleCodes = [NSArray array];

    // Apply enabled cheats found in dictionary
    for (NSString *key in _cheatList)
    {
        if ([_cheatList[key] boolValue])
        {
            // Handle multi-line cheats
            multipleCodes = [key componentsSeparatedByString:@"+"];

            for (NSString *singleCode in multipleCodes) {
                [self applyCheat:singleCode];
            }
        }
    }
}

# pragma mark - Display Mode

- (NSArray <NSDictionary <NSString *, id> *> *)displayModes
{
    if (![self.systemIdentifier isEqualToString:@"openemu.system.gg"])
        return nil;

    if (_availableDisplayModes.count == 0)
    {
        _availableDisplayModes = [NSMutableArray array];

        NSArray <NSDictionary <NSString *, id> *> *availableModesWithDefault =
        @[
          Label(@"Screen"),
          OptionToggleable(@"LCD Ghosting", @"ggLCDFilter"),
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
    BOOL isDisplayModeToggleable = NO;
    BOOL isValidDisplayMode = NO;
    BOOL displayModeState = NO;
    NSString *displayModePrefKey;

    for (NSDictionary *modeDict in _availableDisplayModes) {
        if ([modeDict[OEGameCoreDisplayModeNameKey] isEqualToString:displayMode]) {
            displayModeState = [modeDict[OEGameCoreDisplayModeStateKey] boolValue];
            displayModePrefKey = modeDict[OEGameCoreDisplayModePrefKeyNameKey];
            isDisplayModeToggleable = [modeDict[OEGameCoreDisplayModeAllowsToggleKey] boolValue];
            isValidDisplayMode = YES;
            break;
        }
    }

    // Disallow a 'displayMode' not found in _availableDisplayModes
    if (!isValidDisplayMode)
        return;

    // Handle option state changes
    for (NSMutableDictionary *optionDict in _availableDisplayModes) {
        NSString *modeName = optionDict[OEGameCoreDisplayModeNameKey];
        NSString *prefKey  = optionDict[OEGameCoreDisplayModePrefKeyNameKey];

        if (!modeName)
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
    }

    // Game Gear: LCD ghosting / motion blur
    // Required for proper display of some effects in a few games (James Pond 3, Power Drift, Super Monaco GP II)
    if ([displayMode isEqualToString:@"LCD Ghosting"])
    {
        if (!displayModeState)
            config.lcd = (uint8)(0.80 * 256);
        else
            config.lcd = 0;
    }
}

# pragma mark - Misc Helper Methods

- (void)applyCheat:(NSString *)code
{
    /* clear existing ROM patches */
    clear_cheats();

    /* interpret code and give it an index */
    decode_cheat((char *)code.UTF8String, maxcheats);

    // Enable the cheat by default
    cheatlist[maxcheats].enable = 1;

    /* increment cheat count */
    maxcheats++;

    /* apply ROM patches */
    apply_cheats();
}

- (void)resetCheats
{
    /* clear existing ROM patches */
    clear_cheats();

    /* delete all cheats */
    maxcheats = maxROMcheats = maxRAMcheats = 0;
    memset(cheatlist, 0, sizeof(cheatlist));
}

- (void)configureOptions
{
    /* sound options */
    config.psg_preamp     = 150;
    config.fm_preamp      = 100;
    config.cdda_volume    = 100;
    config.pcm_volume     = 100;
    config.hq_fm          = 1; /* high-quality FM resampling (slower) */
    config.hq_psg         = 1; /* high-quality PSG resampling (slower) */
    config.filter         = 1; /* single-pole low-pass filter (6 dB/octave) */
    config.lp_range       = 0x9999; /* 0.6 in 0.16 fixed point */
    config.low_freq       = 880;  // 200
    config.high_freq      = 5000; // 8000
    config.lg             = 100;
    config.mg             = 100;
    config.hg             = 100;
    config.ym2612         = YM2612_DISCRETE;
    config.ym2413         = 2; /* AUTO */
    config.mono           = 0; /* STEREO output */
#ifdef HAVE_YM3438_CORE
    config.ym3438         = 0;
#endif
#ifdef HAVE_OPLL_CORE
   config.opll            = 0;
#endif

    /* system options */
    config.system         = 0; /* AUTO */
    config.region_detect  = 0; /* AUTO */
    config.vdp_mode       = 0; /* AUTO */
    config.master_clock   = 0; /* AUTO */
    config.force_dtack    = 0;
    config.addr_error     = 1;
    config.bios           = 0;
    config.lock_on        = 0; 
    config.add_on         = 0; /* = HW_ADDON_AUTO (or HW_ADDON_MEGACD, HW_ADDON_MEGASD & HW_ADDON_NONE) */
    config.cd_latency     = 1;

    /* video options */
    config.overscan = 0; /* 3 == FULL */
    config.gg_extra = 0; /* 1 = show extended Game Gear screen (256x192) */
    config.ntsc     = 0;

    // Only temporary, so core doesn't crash on an older OpenEmu version
    if ([self respondsToSelector:@selector(displayModeInfo)]) {
        BOOL isLCDFilterEnabled = [self.displayModeInfo[@"ggLCDFilter"] boolValue];
        if (isLCDFilterEnabled)
            [self changeDisplayWithMode:@"LCD Ghosting"];
        else
            config.lcd = 0; /* 0.8 fixed point */

    }
    else
        config.lcd  = 0;

    config.render   = 0; /* 1 = double resolution output (only when interlaced mode 2 is enabled) */
    config.enhanced_vscroll = 0;
    config.enhanced_vscroll_limit = 8;

    /* initialize bitmap */
    memset(&bitmap, 0, sizeof(bitmap));
    bitmap.width      = 720;
    bitmap.height     = 576;
    bitmap.pitch      = bitmap.width * sizeof(uint32_t);
    bitmap.data       = (uint8_t *)_videoBuffer;
}

- (void)configureInput
{
    _multiTapType = MultiTapTypeNone;

    // Overrides: Six button controller-supported games missing '6' byte in cart header, so they cannot be auto-detected
    NSArray<NSString *> *pad6Buttons = @[
                             @"b04c06df1009c60182df902a4ec7c959", // Batman Forever (World)
                             @"7b144947f6e8842dd4419d5166cddff6", // Boogerman - A Pick and Flick Adventure (Europe)
                             @"265a10bf2ea2d1ee30e6cde631d54474", // Boogerman - A Pick and Flick Adventure (USA)
                             @"ac51f4585a42cba91d04f667dd1fd60a", // Coach K College Basketball (USA)
                             @"e68281bee6a4e9620d306b197860a506", // Comix Zone (USA) (Beta)
                             @"a9b4642a5b5d22f565222d2d8a4e04f9", // Davis Cup Tennis ~ Davis Cup World Tour (USA, Europe) (June 1993)
                             @"d1acc657850f56f19d0a027e8ea54a75", // Davis Cup Tennis ~ Davis Cup World Tour (USA, Europe) (July 1993)
                             @"c2789976bfa41f1e617589db9043e3a2", // Davis Cup II (USA) (Proto)
                             @"ae9347eeea41c1a02565a187a4bf28f7", // Dragon Ball Z - Buyuu Retsuden (Japan)
                             @"9386f82fc9ab95294ca35961db80d0b9", // Dragon Ball Z - L'Appel du Destin (France)
                             @"5093ad6641abb0c3757d24da094a51e6", // Duke Nukem 3D (Brazil)
                             @"6ba9e256579f0cbfa18abb96acc5b24d", // Greatest Heavyweights (Europe)
                             @"8662fc03ecb681fb5a463a2e9bb2ae41", // Greatest Heavyweights (Japan)
                             @"a2319592a31d22d9ec4501ce4c188152", // Greatest Heavyweights (USA)
                             @"a8dcb5476855a83702e2f49ebd4e2d57", // Lost Vikings, The (USA) (November, 1993)
                             @"8335ca918a503047fc9cde6a0b082308", // Lost Vikings, The (USA) (October, 1995)
                             @"7914adf64ff1156c767ae550334c44b5", // Marsupilami (Europe) (En,Fr,De,Es,It)
                             @"9cf141681e68407d1e5279f7a35d6d53", // Marsupilami (USA) (En,Fr,De,Es,It)
                             @"a1dd8a3e4b8c98dee49d5e90d6b87903", // Mortal Kombat (World)
                             @"e0bb4d00ea95b75aac52851fb4d8ee47", // Mortal Kombat (World) (v1.1)
                             @"697fe71f7c6601b80ff486297124d301", // Nightmare Circus (Brazil)
                             @"6e325bc3fe03b2bbcd39e667cf0b567a", // Nightmare Circus (Brazil) (Beta)
                             @"72b5848612f80d14bc51807f8c7e239e", // Shaq-Fu (USA, Europe)
                             @"5a8f7c6437d239690b4a15287d841c26", // Shinobi III - Return of the Ninja Master (Europe)
                             @"691eeff9c5741724a8751ec0fa9cfbf0", // Shinobi III - Return of the Ninja Master (USA)
                             @"6ce59f3e7ee52dc8c6df7b4d8a166826", // Super Shinobi II, The (Japan, Korea)
                             @"7ded2700acc1715153f630fa266e0e89", // Skeleton Krew (Europe)
                             @"7e9a79a887c4edf56574d7a1cd72c5fd", // Skeleton Krew (USA)
                             @"c2967c23e72387743911bb28beb6f144", // Street Racer (Europe)
                             @"4cd30f3ad42b0354659d128bdcd61a6c", // TechnoClash (USA, Europe)
                             @"0f0be2db4084822d5514f8e34a0d1488", // Urban Strike (USA, Europe)
                             @"8d83131da5dfe5a1e83e4390e7777064", // WWF Royal Rumble (World)
                             ];

    // Different port configurations and multitap devices are used depending on the game
    // NOTE: J-Cart games are automatically handled.
    // TODO: Identify supported Sega CD games by rominfo.domestic/rominfo.international?
    NSDictionary<NSString *, NSNumber *> *multiTapGames =
    @{
      //@"3cc6df243e714097f1599cf618f94d0b" : @(TeamPlayerPort1), // Aq Renkan Awa (Taiwan) (Unl)
      @"2b27a61cdae4492044bd273c5807de75" : @(TeamPlayerPort1), // Barkley Shut Up and Jam! (USA, Europe)
      @"952e40844509c5739f1e84ea7f9dfd90" : @(TeamPlayerPort1), // Barkley Shut Up and Jam 2 (USA)
      @"76aab0e8bc8e670a347676aaf0a0aea3" : @(TeamPlayerPort1), // College Football's National Championship (USA)
      @"d608a160eda8597113b3cdf92941a048" : @(TeamPlayerPort1), // College Football's National Championship II (USA)
      @"a279a2fa2317f9081ba02226cce6b1ed" : @(TeamPlayerPort1), // Dragon - The Bruce Lee Story (Europe)
      @"94ebb9a19bbb7b5749bf07ab3ce8fbb9" : @(TeamPlayerPort1), // Dragon - The Bruce Lee Story (USA)
      @"817fceb36d9a454c59253be990779f99" : @(TeamPlayerPort1), // From TV Animation Slam Dunk - Kyougou Makkou Taiketsu! (Japan)
      @"9aad96cc5364d2289f470b75c59907a5" : @(TeamPlayerPort1), // Gauntlet (Japan) (En,Ja)
      @"5e8ec4c047ef4af15027e93b5358858f" : @(TeamPlayerPort1), // Gauntlet IV (Japan) (En,Ja)
      @"840f9f6fd4f22686b89cfd9a9ade105a" : @(TeamPlayerPort1), // Gauntlet IV (USA, Europe) (En,Ja)
      @"1f8e7897522b6e645f4b8123bff23654" : @(TeamPlayerPort1), // J. League Pro Striker Final Stage (Japan)
      @"44752b050421c4e51d1bee96b3fed44e" : @(TeamPlayerPort1), // Lost Vikings, The (Europe)
      @"a8dcb5476855a83702e2f49ebd4e2d57" : @(TeamPlayerPort1), // Lost Vikings, The (USA) (November, 1993)
      @"8335ca918a503047fc9cde6a0b082308" : @(TeamPlayerPort1), // Lost Vikings, The (USA) (October, 1995)
      @"5a94b1e8792bb3572db92c2019d99377" : @(TeamPlayerPort1), // Mega Bomberman (Europe, Korea) (En)
      @"514f6cad98f5f632d680983a050fffc4" : @(TeamPlayerPort1), // Mega Bomberman (USA)
      @"f9a4e85931dcaaceded19c0c2a7aace1" : @(TeamPlayerPort1), // NBA Hang Time (Europe)
      @"a2dddb13539df45f45ff4061cd6caacd" : @(TeamPlayerPort1), // NBA Hang Time (USA)
      @"d72f13bc94ad76c90deef86d5a138ff6" : @(TeamPlayerPort1), // NBA Jam (Japan)
      @"234bf02f7f7b6fdad65890424d3a8a8f" : @(TeamPlayerPort1), // NBA Jam (USA, Europe) (Rev 1)
      @"338b8ed45e02d96f1ed31eaab59eaf43" : @(TeamPlayerPort1), // NBA Jam (USA, Europe)
      @"edeb01f0aa8aed3868db1179670db22f" : @(TeamPlayerPort1), // NBA Jam - Tournament Edition (World)
      //@"b465081da2e268a1c045c1b0615bed75" : @(TeamPlayerPort1), // NBA Pro Basketball '94 (Japan)
      @"3d3c4c2dcc8631373b73cf11170dd4d7" : @(TeamPlayerPort1), // NCAA Final Four Basketball (USA)
      @"6e38acfb80ed7e0b1343fa4ffdc6477d" : @(TeamPlayerPort1), // NCAA Football (USA)
      @"035283320f792caa2b55129db21f0265" : @(TeamPlayerPort1), // NFL '95 (USA, Europe)
      @"80652330e1b3e2892785e27413691e4e" : @(TeamPlayerPort1), // NFL 98 (USA)
      @"0faab2309047b85de82a62e0230ec9f4" : @(TeamPlayerPort1), // Pele II - World Tournament Soccer (USA, Europe)
      @"15a8114b96afcabcb2bd08acbc7a11c0" : @(TeamPlayerPort1), // Prime Time NFL Starring Deion Sanders (USA)
      @"a0003ccd281f9cc74aa2ef97fe23c2fc" : @(TeamPlayerPort1), // Puzzle & Action - Ichidanto-R (Japan)
      @"15ee1db49894b798155ae60eaa2dd961" : @(TeamPlayerPort1), // Puzzle & Action - Ichidanto-R (World) (Ja) (Sega Ages)
      @"16b0f48a07baf1fa0df27453b7f008d4" : @(TeamPlayerPort1), // Puzzle & Action - Tanto-R (Japan)
      //@"4abb0405b270695261494720a2af0783" : @(TeamPlayerPort1), // Shi Jie Zhi Bang Zheng Ba Zhan - World Pro Baseball 94 (Taiwan) (Unl)
      @"abddd42b2548e9b708991f689d726c9a" : @(TeamPlayerPort1), // Tiny Toon Adventures - Acme All-Stars (Europe)
      @"1def1d7dbe4ab6b9e1fc90093292de6a" : @(TeamPlayerPort1), // Tiny Toon Adventures - Acme All-Stars (USA, Korea)
      @"f314fe624d288b4e1228ae759bae1d86" : @(TeamPlayerPort1), // Unnecessary Roughness '95 (USA)
      @"8be67519c2417d36ca51576ff1ab043b" : @(TeamPlayerPort1), // World Championship Soccer II (Europe)
      @"d0686cf7c1851ebc960c08c9f9908a31" : @(TeamPlayerPort1), // World Championship Soccer II (USA)
      @"d97666f8f935e50284026d442d9c5e6e" : @(TeamPlayerPort1), // World Cup USA 94 (USA, Europe)
      @"296f057959c1c545178cc5c07f64877c" : @(TeamPlayerPort1), // WWF Raw (World)
      @"8130283788f82677ec583b7f627dbf0c" : @(TeamPlayerPort1), // Yu Yu Hakusho - Makyou Toitsusen (Japan)
      @"2a2165b2be91810f5b97e8d7d2f76ad5" : @(TeamPlayerPort1), // YuYu Hakusho - Sunset Fighters (Brazil)

      // 1-4 Players
      @"2dbad2e514d043d27340d640d9b138ac" : @(GamepadPort1TeamPlayerPort2), // ATP Tour (Europe)
      @"723db55d679ef169b8210764a5f76c4d" : @(GamepadPort1TeamPlayerPort2), // ATP Tour Championship Tennis (USA)
      @"5481f0cbab22ca071dad31dd3ca4f884" : @(GamepadPort1TeamPlayerPort2), // College Slam (USA)
      @"6a492e2983b2bc306eec905411ee24a8" : @(GamepadPort1TeamPlayerPort2), // Dino Dini's Soccer (Europe)
      @"dea9dd7a01d774ccdfe68c835fe55a8a" : @(GamepadPort1TeamPlayerPort2), // J. League Pro Striker (Japan)
      @"f5f52249a5dc851864254935e185ea72" : @(GamepadPort1TeamPlayerPort2), // J. League Pro Striker (Japan) (v1.3)
      @"ada241db25d7832866b1e58af2038bc6" : @(GamepadPort1TeamPlayerPort2), // J. League Pro Striker 2 (Japan)
      @"a7046120d2a4b40949994c71177aec3c" : @(GamepadPort1TeamPlayerPort2), // J. League Pro Striker Perfect (Japan)
      @"6f8cddb3775b588b49d13e7c62d08e86" : @(GamepadPort1TeamPlayerPort2), // Pepenga Pengo (Japan)
      @"61c6f43629f218f75e9e78ff2e59bf55" : @(GamepadPort1TeamPlayerPort2), // Sega Sports 1 (Europe)
      @"7bb99ff11b04544600ffe56dc79d72b3" : @(GamepadPort1TeamPlayerPort2), // Wimbledon Championship Tennis (Europe)
      @"dd43c4cfd5958baeb9b4ddd5619f7255" : @(GamepadPort1TeamPlayerPort2), // Wimbledon Championship Tennis (Japan)
      @"7978bb18dc7c6269f6b5c2178b93b407" : @(GamepadPort1TeamPlayerPort2), // Wimbledon Championship Tennis (USA)

      // 1-5 Players
      @"441b7e9c9811e22458660eb73975569c" : @(GamepadPort1TeamPlayerPort2), // Columns III (USA)
      @"eeb557cd38ad00d6b4df48585098269a" : @(GamepadPort1TeamPlayerPort2), // Columns III - Taiketsu! Columns World (Japan, Korea)
      @"b3ed61c2da404c31d2a5b6f6ada7b7ff" : @(GamepadPort1TeamPlayerPort2), // NBA Action '94 (USA)
      @"dc9117965c0c3fcb9d28eb826082b223" : @(GamepadPort1TeamPlayerPort2), // NBA Action '95 Starring David Robinson (USA, Europe)
      @"8147342e86d065fc240f09c803eb81b9" : @(TeamPlayerPort1TeamPlayerPort2), // NFL Quarterback Club (World)
      @"8b99a84e9e661dccf4f79dbd7b149953" : @(TeamPlayerPort1TeamPlayerPort2), // NFL Quarterback Club 96 (USA, Europe)
      @"b21b69f718115b502d10481e1f6ecc0b" : @(GamepadPort1TeamPlayerPort2), // Party Quiz Mega Q (Japan)

      // 1-8 Players
      @"a2b23303055f28e68afce7b7e2ea9edf" : @(TeamPlayerPort1TeamPlayerPort2), // Double Dribble - The Playoff Edition (USA)
      @"a4a4e29f3540d3a11cdd8ee391069841" : @(TeamPlayerPort1TeamPlayerPort2), // Fever Pitch Soccer (Europe) (En,Fr,De,Es,It)
      @"fb303d5d08b2ea748fe7aced9c0100fd" : @(TeamPlayerPort1TeamPlayerPort2), // Head-On Soccer (USA)
      @"8bc39c10ed8d26d53a0f24f5daca81c8" : @(TeamPlayerPort1TeamPlayerPort2), // Hyper Dunk (Europe)
      @"008bcd6a3fc35015df0851e996ce80b4" : @(TeamPlayerPort1TeamPlayerPort2), // Hyper Dunk - The Playoff Edition (Japan)
      @"494d00e7c0a3ee5448e6b82fa091bac8" : @(TeamPlayerPort1TeamPlayerPort2), // International Superstar Soccer Deluxe (Europe)
      @"e4392bd5e77321e8ec6e76a142e9536b" : @(TeamPlayerPort1TeamPlayerPort2), // Mega Bomberman - Special 8-Player-Demo (Europe) (Proto)
      @"3426fc8802e1a385dc227b9dde59cbe4" : @(TeamPlayerPort1TeamPlayerPort2), // Ultimate Soccer (Europe) (En,Fr,De,Es,It)

      // 1-4 Players EA 4-Way Play
      @"29d948108a1c768c20af6796ab9ffc47" : @(EA4WayPlay), // Australian Rugby League (Europe)
      @"1d51bbd116b76c6fdd6b7dd4c80e4957" : @(EA4WayPlay), // Bill Walsh College Football (USA, Europe)
      @"585030d462ab6de4c79dc434141d16e2" : @(EA4WayPlay), // Bill Walsh College Football 95 (USA)
      @"ac51f4585a42cba91d04f667dd1fd60a" : @(EA4WayPlay), // Coach K College Basketball (USA)
      @"f54889e7ce17227d398669f9f4e7881d" : @(EA4WayPlay), // College Football USA 96 (USA)
      @"dcb35bb9064171f07bb8b49d43c24d5b" : @(EA4WayPlay), // College Football USA 97 (USA)
      @"64c2a99aba71e7796fd12546071592cc" : @(EA4WayPlay), // Elitserien 95 (Sweden)
      @"add607e0dd5b9f294bb5a246d8946aed" : @(EA4WayPlay), // Elitserien 96 (Sweden)
      @"22db8020749dd63b14c382b198ee1422" : @(EA4WayPlay), // ESPN National Hockey Night (USA)
      @"3c7380bea3c1d479e5604006eab86961" : @(EA4WayPlay), // FIFA 98 - Road to World Cup (Europe) (En,Fr,Es,It,Sv)
      @"a1546250206aafa61536b434e31cd568" : @(EA4WayPlay), // FIFA International Soccer (Japan) (En,Ja)
      @"8a53e4db0da7ee312c1e89d449eb7b1e" : @(EA4WayPlay), // FIFA International Soccer (USA, Europe) (En,Fr,De,Es)
      @"698a2fcf165e8c9bc5166aecf23771d2" : @(EA4WayPlay), // FIFA Soccer 95 (Korea) (En,Fr,De,Es)
      @"26ac4f884df64349dcf46344db85812b" : @(EA4WayPlay), // FIFA Soccer 95 (USA, Europe) (En,Fr,De,Es)
      @"545b07c1c599f49ea93a4b7b2c7c3782" : @(EA4WayPlay), // FIFA Soccer 96 (USA, Europe) (En,Fr,De,Es,It,Sv)
      @"f4a8436b5218a201a08401bedbfcd065" : @(EA4WayPlay), // FIFA Soccer 97 (USA, Europe) (En,Fr,De,Es,It,Sv)
      @"955622a63dc3b06c13823fb352f50912" : @(EA4WayPlay), // General Chaos (USA, Europe)
      @"9ff0afe64a5765a1e2bc1f40bcd2e554" : @(EA4WayPlay), // General Chaos Daikonsen (Japan)
      @"f0ecb410ac43c503f1321098e4203785" : @(EA4WayPlay), // IMG International Tour Tennis (USA, Europe)
      @"9ca0c88961d110eaef383a0d8e3f22f6" : @(EA4WayPlay), // Madden NFL '94 (USA, Europe)
      @"52b7e1ce6ae02a5b5c178d4df865b1dd" : @(EA4WayPlay), // Madden NFL 95 (USA, Europe)
      @"f997e2088e3728941cbe3bf491b3496e" : @(EA4WayPlay), // Madden NFL 96 (USA, Europe)
      @"c5e4b901ca41524c182e576bedb13981" : @(EA4WayPlay), // Madden NFL 97 (USA, Europe)
      @"e3044f5de786cfa13f2d689e427f62e3" : @(EA4WayPlay), // Madden NFL 98 (USA)
      @"87fd7645d1d8f2539a341285fc697aa7" : @(EA4WayPlay), // MLBPA Baseball (USA)
      @"6a685a81ae70e8724c376779e3a812e4" : @(EA4WayPlay), // Mutant League Hockey (USA, Europe)
      @"dbe3cb8f486debb2efb94b51ab33ae58" : @(EA4WayPlay), // NBA Live 95 (Korea)
      @"c997ae89f3417f5b3e702c84cf1275c4" : @(EA4WayPlay), // NBA Live 95 (USA, Europe)
      @"3a3399aba2f0c9eb693e9d2acc4f673b" : @(EA4WayPlay), // NBA Live 96 (USA, Europe)
      @"2c11f642effca640c92a3031f6c2cbb1" : @(EA4WayPlay), // NBA Live 97 (USA, Europe)
      @"3817138d9054d91675f7378684744a4d" : @(EA4WayPlay), // NBA Live 98 (USA)
      @"9c3aeaa26c74dfae329602ee27d0c1f9" : @(EA4WayPlay), // NBA Showdown '94 (USA, Europe)
      @"8356b3f0d091b9cc441e2ff8721ad063" : @(EA4WayPlay), // NHL '94 (USA, Europe)
      @"a1dd079f6b1ae80e90dc08839de4d3d4" : @(EA4WayPlay), // NHL '94 (USA, Europe) (Re-release)
      @"94d3518a8e592563c78cf4da84d163c8" : @(EA4WayPlay), // NHL 95 (USA, Europe)
      @"89e7e0fbe8db82b1f2dd7beafcc4e7fb" : @(EA4WayPlay), // NHL 96 (USA, Europe)
      @"4ddc912038388de3818623c046890606" : @(EA4WayPlay), // NHL 97 (USA, Europe)
      @"a2c92c09d420cf7c2d2e55e8777f3a31" : @(EA4WayPlay), // NHL 98 (USA)
      @"d8575831aa3a753221a43aa574dd473b" : @(EA4WayPlay), // PGA European Tour (USA, Europe)
      @"f65dc2d83128232e2da5cf569669083b" : @(EA4WayPlay), // PGA Tour 96 (USA, Europe)
      @"96b3768461d6fef3c6ffa0a59e8de7b0" : @(EA4WayPlay), // PGA Tour Golf III (USA, Europe)
      @"639c7a9083aba418f6cd38d7d68eddf0" : @(EA4WayPlay), // Rugby World Cup 95 (USA, Europe) (En,Fr,It)
      @"c2967c23e72387743911bb28beb6f144" : @(EA4WayPlay), // Street Racer (Europe)
      @"12ba891983dab9749bdaeb7dc8491de8" : @(EA4WayPlay), // Triple Play - Gold Edition (USA)
      @"a214cbc398eb4e6962186bbd69144d9e" : @(EA4WayPlay), // Triple Play 96 (USA)
      @"7841791f8e0d6cb6d776f7fcb338377f" : @(EA4WayPlay), // Wayne Gretzky and the NHLPA All-Stars (USA, Europe)
      };

    // Set six button controller override if needed
    uint8_t pad;
    if([pad6Buttons containsObject:self.ROMMD5.lowercaseString])
        pad = DEVICE_PAD6B; // Force six button controller
    else
        pad = DEVICE_PAD2B | DEVICE_PAD3B | DEVICE_PAD6B; // Auto-detects by presence of '6' byte in the cart header (rominfo.peripherals & 2)

    // Set multitap type configuration if detected
    if (multiTapGames[self.ROMMD5.lowercaseString])
    {
        _multiTapType = [multiTapGames[self.ROMMD5.lowercaseString] integerValue];

        // 1-4 players: TeamPlayer in Port 1
        if (_multiTapType == TeamPlayerPort1)
        {
            input.system[0] = SYSTEM_TEAMPLAYER;
            for (int i = 0; i < 4; i++)
            {
                config.input[i].padtype = pad;
            }
        }
        // 1-4 players: Gamepad Port 1, TeamPlayer Port 2
        else if (_multiTapType == GamepadPort1TeamPlayerPort2)
        {
            int port = 1; // Port 2
            input.system[0] = SYSTEM_GAMEPAD;
            input.system[1] = SYSTEM_TEAMPLAYER;
            config.input[0].padtype = pad;
            for (int i = 0; i < 4; i++)
            {
                config.input[port*4 + i].padtype = pad;
            }
        }
        // 1-8 players: TeamPlayer in Port 1, TeamPlayer Port 2
        else if (_multiTapType == TeamPlayerPort1TeamPlayerPort2)
        {
            input.system[0] = SYSTEM_TEAMPLAYER;
            input.system[1] = SYSTEM_TEAMPLAYER;
            for (int i = 0; i < MAX_INPUTS; i++)
            {
                config.input[i].padtype = pad;
            }
        }
        // 1-4 players: EA 4-Way Play
        else if(_multiTapType == EA4WayPlay)
        {
            input.system[0] = input.system[1] = SYSTEM_WAYPLAY;
            for (int i = 0; i < 4; i++)
            {
                config.input[i].padtype = pad;
            }
        }
    }
    else if(input.system[1] != SYSTEM_MENACER && input.system[1] != SYSTEM_JUSTIFIER)
    {
        input.system[0] = SYSTEM_GAMEPAD;
        input.system[1] = SYSTEM_GAMEPAD;
        for (unsigned i = 0; i < 2; i++)
        {
            config.input[i].padtype = pad;
        }
    }
}

/************************************
 * Genesis Plus implementation
 ************************************/
#define CHUNKSIZE   (0x10000)

int load_archive(char *filename, unsigned char *buffer, int maxsize, char *extension)
{
    int size, left;

    /* Open file */
    FILE *fd = fopen(filename, "rb");

    if (!fd)
    {
        /* Master System & Game Gear BIOS are optional files */
        if (!strcmp(filename,MS_BIOS_US) || !strcmp(filename,MS_BIOS_EU) || !strcmp(filename,MS_BIOS_JP) || !strcmp(filename,GG_BIOS))
        {
            return 0;
        }

        /* Mega CD BIOS are required files */
        if (!strcmp(filename,CD_BIOS_US) || !strcmp(filename,CD_BIOS_EU) || !strcmp(filename,CD_BIOS_JP))
        {
            fprintf(stderr, "ERROR - Unable to open CD BIOS: %s.\n", filename);
            return 0;
        }

        fprintf(stderr, "ERROR - Unable to open file.\n");
        return 0;
    }

    /* Get file size */
    fseek(fd, 0, SEEK_END);
    size = ftell(fd);

    /* size limit */
    if(size > maxsize)
    {
        fclose(fd);
        fprintf(stderr, "ERROR - File is too large.\n");
        return 0;
    }

    fprintf(stderr, "INFORMATION - Loading %d bytes ...\n", size);

    /* filename extension */
    if (extension)
    {
        memcpy(extension, &filename[strlen(filename) - 3], 3);
        extension[3] = 0;
    }

    /* Read into buffer */
    left = size;
    fseek(fd, 0, SEEK_SET);
    while (left > CHUNKSIZE)
    {
        fread(buffer, CHUNKSIZE, 1, fd);
        buffer += CHUNKSIZE;
        left -= CHUNKSIZE;
    }

    /* Read remaining bytes */
    fread(buffer, left, 1, fd);

    /* Close file */
    fclose(fd);

    /* Return loaded ROM size */
    return size;
}

void osd_input_update(void)
{
    /* Update RAM patches */
    RAMCheatUpdate();
}

/* Mega CD backup RAM specific */
static void bram_load(void)
{
    FILE *fp;

    /* automatically load internal backup RAM */
    switch (region_code)
    {
        case REGION_JAPAN_NTSC:
            fp = fopen(CD_BRAM_JP, "rb");
            break;
        case REGION_EUROPE:
            fp = fopen(CD_BRAM_EU, "rb");
            break;
        case REGION_USA:
            fp = fopen(CD_BRAM_US, "rb");
            break;
        default:
            return;
    }

    if (fp != NULL)
    {
        fread(scd.bram, 0x2000, 1, fp);
        fclose(fp);

        /* update CRC */
        brm_crc[0] = crc32(0, scd.bram, 0x2000);
    }
    else
    {
        /* force internal backup RAM format (does not use previous region backup RAM) */
        scd.bram[0x1fff] = 0;
    }

    /* check if internal backup RAM is correctly formatted */
    if (memcmp(scd.bram + 0x2000 - 0x20, brm_format + 0x20, 0x20))
    {
        /* clear internal backup RAM */
        memset(scd.bram, 0x00, 0x2000 - 0x40);

        /* internal Backup RAM size fields */
        brm_format[0x10] = brm_format[0x12] = brm_format[0x14] = brm_format[0x16] = 0x00;
        brm_format[0x11] = brm_format[0x13] = brm_format[0x15] = brm_format[0x17] = (sizeof(scd.bram) / 64) - 3;

        /* format internal backup RAM */
        memcpy(scd.bram + 0x2000 - 0x40, brm_format, 0x40);

        /* clear CRC to force file saving (in case previous region backup RAM was also formatted) */
        brm_crc[0] = 0;
    }

    /* automatically load cartridge backup RAM (if enabled) */
    if (scd.cartridge.id)
    {
        fp = fopen(CART_BRAM, "rb");
        if (fp != NULL)
        {
            int filesize = scd.cartridge.mask + 1;
            int done = 0;

            /* Read into buffer (2k blocks) */
            while (filesize > CHUNKSIZE)
            {
                fread(scd.cartridge.area + done, CHUNKSIZE, 1, fp);
                done += CHUNKSIZE;
                filesize -= CHUNKSIZE;
            }

            /* Read remaining bytes */
            if (filesize)
            {
                fread(scd.cartridge.area + done, filesize, 1, fp);
            }

            /* close file */
            fclose(fp);

            /* update CRC */
            brm_crc[1] = crc32(0, scd.cartridge.area, scd.cartridge.mask + 1);
        }

        /* check if cartridge backup RAM is correctly formatted */
        if (memcmp(scd.cartridge.area + scd.cartridge.mask + 1 - 0x20, brm_format + 0x20, 0x20))
        {
            /* clear cartridge backup RAM */
            memset(scd.cartridge.area, 0x00, scd.cartridge.mask + 1);

            /* Cartridge Backup RAM size fields */
            brm_format[0x10] = brm_format[0x12] = brm_format[0x14] = brm_format[0x16] = (((scd.cartridge.mask + 1) / 64) - 3) >> 8;
            brm_format[0x11] = brm_format[0x13] = brm_format[0x15] = brm_format[0x17] = (((scd.cartridge.mask + 1) / 64) - 3) & 0xff;

            /* format cartridge backup RAM */
            memcpy(scd.cartridge.area + scd.cartridge.mask + 1 - 0x40, brm_format, 0x40);
        }
    }
}

static void bram_save(void)
{
    FILE *fp;

    /* verify that internal backup RAM has been modified */
    if (crc32(0, scd.bram, 0x2000) != brm_crc[0])
    {
        /* check if it is correctly formatted before saving */
        if (!memcmp(scd.bram + 0x2000 - 0x20, brm_format + 0x20, 0x20))
        {
            switch (region_code)
            {
                case REGION_JAPAN_NTSC:
                    fp = fopen(CD_BRAM_JP, "wb");
                    break;
                case REGION_EUROPE:
                    fp = fopen(CD_BRAM_EU, "wb");
                    break;
                case REGION_USA:
                    fp = fopen(CD_BRAM_US, "wb");
                    break;
                default:
                    return;
            }

            if (fp != NULL)
            {
                fwrite(scd.bram, 0x2000, 1, fp);
                fclose(fp);

                /* update CRC */
                brm_crc[0] = crc32(0, scd.bram, 0x2000);
            }
        }
    }

    /* verify that cartridge backup RAM has been modified */
    if (scd.cartridge.id && (crc32(0, scd.cartridge.area, scd.cartridge.mask + 1) != brm_crc[1]))
    {
        /* check if it is correctly formatted before saving */
        if (!memcmp(scd.cartridge.area + scd.cartridge.mask + 1 - 0x20, brm_format + 0x20, 0x20))
        {
            fp = fopen(CART_BRAM, "wb");
            if (fp != NULL)
            {
                int filesize = scd.cartridge.mask + 1;
                int done = 0;

                /* Write to file (2k blocks) */
                while (filesize > CHUNKSIZE)
                {
                    fwrite(scd.cartridge.area + done, CHUNKSIZE, 1, fp);
                    done += CHUNKSIZE;
                    filesize -= CHUNKSIZE;
                }

                /* Write remaining bytes */
                if (filesize)
                {
                    fwrite(scd.cartridge.area + done, filesize, 1, fp);
                }

                /* Close file */
                fclose(fp);

                /* update CRC */
                brm_crc[1] = crc32(0, scd.cartridge.area, scd.cartridge.mask + 1);
            }
        }
    }
}

/* Cheat Support */
static uint32_t decode_cheat(char *string, int index)
{
    char *p;
    int i,n;
    uint32_t len = 0;
    uint32_t address = 0;
    uint16_t data = 0;
    uint8_t ref = 0;

    if ((system_hw & SYSTEM_PBC) == SYSTEM_MD){
        /*If system is Genesis-based*/

        /*Game-Genie*/
        if ((strlen(string) >= 9) && (string[4] == '-'))
        {
            for (i = 0; i < 8; i++)
            {
                if (i == 4) string++;
                p = strchr (ggvalidchars, *string++);
                if (!p)
                    return 0;
                n = p - ggvalidchars;
                switch (i)
                {
                    case 0:
                        data |= n << 3;
                        break;
                    case 1:
                        data |= n >> 2;
                        address |= (n & 3) << 14;
                        break;
                    case 2:
                        address |= n << 9;
                        break;
                    case 3:
                        address |= (n & 0xF) << 20 | (n >> 4) << 8;
                        break;
                    case 4:
                        data |= (n & 1) << 12;
                        address |= (n >> 1) << 16;
                        break;
                    case 5:
                        data |= (n & 1) << 15 | (n >> 1) << 8;
                        break;
                    case 6:
                        data |= (n >> 3) << 13;
                        address |= (n & 7) << 5;
                        break;
                    case 7:
                        address |= n;
                        break;
                }
            }
            /* code length */
            len = 9;
        }

        /*Patch and PAR*/
        else if ((strlen(string) >=9) && (string[6] == ':'))
        {
            /* decode 24-bit address */
            for (i=0; i<6; i++)
            {
                p = strchr (arvalidchars, *string++);
                if (!p)
                    return 0;
                n = (p - arvalidchars) & 0xF;
                address |= (n << ((5 - i) * 4));
            }
            /* decode 16-bit data */
            string++;
            for (i=0; i<4; i++)
            {
                p = strchr (arvalidchars, *string++);
                if (!p)
                    break;
                n = (p - arvalidchars) & 0xF;
                data |= (n << ((3 - i) * 4));
            }
            /* code length */
            len = 11;
        }
    } else {
        /*If System is Master-based*/

        /*Game Genie*/
        if ((strlen(string) >=7) && (string[3] == '-'))
        {
            /* decode 8-bit data */
            for (i=0; i<2; i++)
            {
                p = strchr (arvalidchars, *string++);
                if (!p)
                    return 0;
                n = (p - arvalidchars) & 0xF;
                data |= (n << ((1 - i) * 4));
            }

            /* decode 16-bit address (low 12-bits) */
            for (i=0; i<3; i++)
            {
                if (i==1) string++; /* skip separator */
                p = strchr (arvalidchars, *string++);
                if (!p)
                    return 0;
                n = (p - arvalidchars) & 0xF;
                address |= (n << ((2 - i) * 4));
            }
            /* decode 16-bit address (high 4-bits) */
            p = strchr (arvalidchars, *string++);
            if (!p)
                return 0;
            n = (p - arvalidchars) & 0xF;
            n ^= 0xF; /* bits inversion */
            address |= (n << 12);
            /* Optional: decode reference 8-bit data */
            if (*string=='-')
            {
                for (i=0; i<2; i++)
                {
                    string++; /* skip separator and 2nd digit */
                    p = strchr (arvalidchars, *string++);
                    if (!p)
                        return 0;
                    n = (p - arvalidchars) & 0xF;
                    ref |= (n << ((1 - i) * 4));
                }
                ref = (ref >> 2) | ((ref & 0x03) << 6); /* 2-bit right rotation */
                ref ^= 0xBA; /* XOR */
                /* code length */
                len = 11;
            }
            else
            {
                /* code length */
                len = 7;
            }
        }

        /*Action Replay*/
        else if ((strlen(string) >=9) && (string[4] == '-')){
            string+=2;
            /* decode 16-bit address */
            for (i=0; i<4; i++)
            {
                p = strchr (arvalidchars, *string++);
                if (!p)
                    return 0;
                n = (p - arvalidchars) & 0xF;
                address |= (n << ((3 - i) * 4));
                if (i==1) string++;
            }
            /* decode 8-bit data */
            for (i=0; i<2; i++)
            {
                p = strchr (arvalidchars, *string++);
                if (!p)
                    return 0;
                n = (p - arvalidchars) & 0xF;
                data |= (n << ((1 - i) * 4));
            }
            /* code length */
            len = 9;
        }

        /*Fusion RAM*/
        else if ((strlen(string) >=7) && (string[4] == ':'))
        {
            /* decode 16-bit address */
            for (i=0; i<4; i++)
            {
                p = strchr (arvalidchars, *string++);
                if (!p)
                    return 0;
                n = (p - arvalidchars) & 0xF;
                address |= (n << ((3 - i) * 4));
            }
            /* decode 8-bit data */
            string++;
            for (i=0; i<2; i++)
            {
                p = strchr (arvalidchars, *string++);
                if (!p)
                    return 0;
                n = (p - arvalidchars) & 0xF;
                data |= (n << ((1 - i) * 4));
            }
            /* code length */
            len = 7;
        }

        /*Fusion ROM*/
        else if ((strlen(string) >=9) && (string[6] == ':'))
        {
            /* decode reference 8-bit data */
            for (i=0; i<2; i++)
            {
                p = strchr (arvalidchars, *string++);
                if (!p)
                    return 0;
                n = (p - arvalidchars) & 0xF;
                ref |= (n << ((1 - i) * 4));
            }
            /* decode 16-bit address */
            for (i=0; i<4; i++)
            {
                p = strchr (arvalidchars, *string++);
                if (!p)
                    return 0;
                n = (p - arvalidchars) & 0xF;
                address |= (n << ((3 - i) * 4));
            }
            /* decode 8-bit data */
            string++;
            for (i=0; i<2; i++)
            {
                p = strchr (arvalidchars, *string++);
                if (!p)
                    return 0;
                n = (p - arvalidchars) & 0xF;
                data |= (n << ((1 - i) * 4));
            }
            /* code length */
            len = 9;
        }
        /* convert to 24-bit Work RAM address */
        if (address >= 0xC000)
            address = 0xFF0000 | (address & 0x1FFF);
    }
    /* Valid code found ? */
    if (len)
    {
        /* update cheat address & data values */
        cheatlist[index].address = address;
        cheatlist[index].data = data;
        cheatlist[index].old = ref;
    }
    /* return code length (0 = invalid) */
    return len;
}

static void apply_cheats(void)
{
    uint8_t *ptr;
    int i;
    /* clear ROM&RAM patches counter */
    maxROMcheats = maxRAMcheats = 0;

    for (i = 0; i < maxcheats; i++)
    {
        if (cheatlist[i].enable)
        {
            /* detect Work RAM patch */
            if (cheatlist[i].address >= 0xFF0000)
            {
                /* add RAM patch */
                cheatIndexes[maxRAMcheats++] = i;
            }

            /* check if Mega-CD game is running */
            else if ((system_hw == SYSTEM_MCD) && !scd.cartridge.boot)
            {
                /* detect PRG-RAM patch (Sub-CPU side) */
                if (cheatlist[i].address < 0x80000)
                {
                    /* add RAM patch */
                    cheatIndexes[maxRAMcheats++] = i;
                }

                /* detect Word-RAM patch (Main-CPU side)*/
                else if ((cheatlist[i].address >= 0x200000) && (cheatlist[i].address < 0x240000))
                {
                    /* add RAM patch */
                    cheatIndexes[maxRAMcheats++] = i;
                }
            }

            /* detect cartridge ROM patch */
            else if (cheatlist[i].address < cart.romsize)
            {
                if ((system_hw & SYSTEM_PBC) == SYSTEM_MD)
                {
                    /* patch ROM data */
                    cheatlist[i].old = *(uint16_t *)(cart.rom + (cheatlist[i].address & 0xFFFFFE));
                    *(uint16_t *)(cart.rom + (cheatlist[i].address & 0xFFFFFE)) = cheatlist[i].data;
                }
                else
                {
                    /* add ROM patch */
                    maxROMcheats++;
                    cheatIndexes[MAX_CHEATS - maxROMcheats] = i;
                    /* get current banked ROM address */
                    ptr = &z80_readmap[(cheatlist[i].address) >> 10][cheatlist[i].address & 0x03FF];
                    /* check if reference matches original ROM data */
                    if (((uint8_t)cheatlist[i].old) == *ptr)
                    {
                        /* patch data */
                        *ptr = cheatlist[i].data;
                        /* save patched ROM address */
                        cheatlist[i].prev = ptr;
                    }
                    else
                    {
                        /* no patched ROM address yet */
                        cheatlist[i].prev = NULL;
                    }
                }
            }
        }
    }
}

static void clear_cheats(void)
{
    int i;

    /* no ROM patches with Mega-CD games */
    if ((system_hw == SYSTEM_MCD) && !scd.cartridge.boot)
        return;

    /* disable cheats in reversed order in case the same address is used by multiple ROM patches */
    i = maxcheats;
    while (i > 0)
    {
        if (cheatlist[i-1].enable)
        {
            if (cheatlist[i-1].address < cart.romsize)
            {
                if ((system_hw & SYSTEM_PBC) == SYSTEM_MD)
                {
                    /* restore original ROM data */
                    *(uint16_t *)(cart.rom + (cheatlist[i-1].address & 0xFFFFFE)) = cheatlist[i-1].old;
                }
                else
                {
                    /* check if previous banked ROM address has been patched */
                    if (cheatlist[i-1].prev != NULL)
                    {
                        /* restore original data */
                        *cheatlist[i-1].prev = cheatlist[i-1].old;
                        /* no more patched ROM address */
                        cheatlist[i-1].prev = NULL;
                    }
                }
            }
        }
        i--;
    }
}

/****************************************************************************
 * RAMCheatUpdate
 *
 * Apply RAM patches (this should be called once per frame)
 *
 ****************************************************************************/
static void RAMCheatUpdate(void)
{
    uint8_t *base;
    uint32_t mask;
    int index, cnt = maxRAMcheats;

    while (cnt)
    {
        /* get cheat index */
        index = cheatIndexes[--cnt];

        /* detect destination RAM */
        switch ((cheatlist[index].address >> 20) & 0xf)
        {
            case 0x0: /* Mega-CD PRG-RAM (512 KB) */
                base = scd.prg_ram;
                mask = 0x7fffe;
                break;

            case 0x2: /* Mega-CD 2M Word-RAM (256 KB) */
                base = scd.word_ram_2M;
                mask = 0x3fffe;
                break;

            default: /* Work-RAM (64 KB) */
                base = work_ram;
                mask = 0xfffe;
                break;
        }

        /* apply RAM patch */
        // TODO: Investigate. Some PAR cheats for Genesis don't work otherwise.
        // e.g. Sonic The Hedgehog 2 (World) (Rev A).md (MD5 9feeb724052c39982d432a7851c98d3e) using Invincibility (Sonic only) code FFB02B:0002
        // Fixes possible endianness issue, also does not invoke pointer typecasting UB
        bool isSega16bit = ((system_hw & SYSTEM_PBC) == SYSTEM_MD) || (system_hw == SYSTEM_MCD);
        //if (cheatlist[index].data & 0xFF00)
        if (isSega16bit ? cheatlist[index].data & 0x00FF : cheatlist[index].data & 0xFF00)
        {
            /* word patch */
            unsigned addr = cheatlist[index].address & mask;
            base[addr] = cheatlist[index].data & 0xFF;
            base[addr + 1] = (cheatlist[index].data & 0xFF00) >> 8;
            //*(uint16_t *)(base + (cheatlist[index].address & mask)) = cheatlist[index].data;
        }
        else
        {
            /* byte patch */
            mask |= 1;
            base[cheatlist[index].address & mask] = cheatlist[index].data;
        }
    }
}

/****************************************************************************
 * ROMCheatUpdate
 *
 * Apply ROM patches (this should be called each time banking is changed)
 *
 ****************************************************************************/
void ROMCheatUpdate(void)
{
    int index, cnt = maxROMcheats;
    uint8_t *ptr;

    while (cnt)
    {
        /* get cheat index */
        index = cheatIndexes[MAX_CHEATS - cnt];

        /* check if previous banked ROM address was patched */
        if (cheatlist[index].prev != NULL)
        {
            /* restore original data */
            *cheatlist[index].prev = cheatlist[index].old;

            /* no more patched ROM address */
            cheatlist[index].prev = NULL;
        }

        /* get current banked ROM address */
        ptr = &z80_readmap[(cheatlist[index].address) >> 10][cheatlist[index].address & 0x03FF];

        /* check if reference exists and matches original ROM data */
        if (!cheatlist[index].old || ((uint8_t)cheatlist[index].old) == *ptr)
        {
            /* patch data */
            *ptr = cheatlist[index].data;

            /* save patched ROM address */
            cheatlist[index].prev = ptr;
        }

        /* next ROM patch */
        cnt--;
    }
}

- (NSArray<OEMemoryRegionDescriptor *> *)readableMemoryRegions
{
    if (cart.romsize == 0) return @[];
    if ((system_hw & SYSTEM_PBC) == SYSTEM_MD) {
        NSData *data = [NSData dataWithBytes:work_ram length:0x10000];
        OEMemoryRegionDescriptor *descriptor = [OEMemoryRegionDescriptor descriptorWithName:@"Work RAM"
                                                                                  address:0xFF0000
                                                                             addressBytes:3
                                                                             minDataBytes:2
                                                                                     data:data];
        return @[descriptor];
    } else {
        NSData *data = [NSData dataWithBytes:work_ram length:0x2000];
        OEMemoryRegionDescriptor *descriptor = [OEMemoryRegionDescriptor descriptorWithName:@"RAM"
                                                                                  address:0xC000
                                                                             addressBytes:2
                                                                                     data:data];
        return @[descriptor];
    }
}

@end
