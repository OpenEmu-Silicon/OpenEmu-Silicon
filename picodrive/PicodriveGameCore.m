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

#import "PicodriveGameCore.h"
#import <OpenEmuBase/OERingBuffer.h>
#import "OESega32XSystemResponderClient.h"
#import <OpenGL/gl.h>

#include <sys/mman.h>
#include "pico/pico_int.h"
#include "pico/state.h"
#include "pico/patch.h"
#include "../common/input_pico.h"

static int16_t ALIGNED(4) soundBuffer[2 * 44100 / 50];

@interface PicodriveGameCore () <OESega32XSystemResponderClient>
{
    uint16_t *_videoBuffer;
    int _videoWidth;
    NSURL *_romFile;
    NSMutableDictionary<NSString *, NSNumber *> *_cheatList;
}

@end

static __weak PicodriveGameCore *_current;

@implementation PicodriveGameCore

- (id)init
{
    if((self = [super init]))
    {
        _videoBuffer = (uint16_t *)malloc(320 * 240 * sizeof(uint16_t));
        _videoWidth = 292; // initial viewport width
        _cheatList = [[NSMutableDictionary alloc] init];
    }

	_current = self;

	return self;
}

- (void)dealloc
{
    free(_videoBuffer);
}

// MARK: - Execution

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    _romFile = [NSURL fileURLWithPath:path];

    // Picodrive defaults - not sure what all is truly needed for just 32X
    PicoIn.opt = POPT_EN_STEREO|POPT_EN_FM|POPT_EN_PSG|POPT_EN_Z80
    | POPT_EN_MCD_PCM|POPT_EN_MCD_CDDA|POPT_EN_MCD_GFX
    | POPT_EN_32X|POPT_EN_PWM
    | POPT_ACC_SPRITES|POPT_DIS_32C_BORDER;

    PicoIn.sndRate = 44100;
    PicoIn.autoRgnOrder = 0x184; // US, EU, JP

    PicoInit();
    PicoDrawSetOutFormat(PDF_RGB555, 0);
    PicoDrawSetOutBuf(_videoBuffer, 320 * 2);

    PicoSetInputDevice(0, PICO_INPUT_PAD_6BTN);
    PicoSetInputDevice(1, PICO_INPUT_PAD_6BTN);

    enum media_type_e media_type;
    media_type = PicoLoadMedia(path.fileSystemRepresentation, NULL, NULL, NULL);

    switch (media_type) {
    case PM_BAD_DETECT:
       // Failed to detect ROM image type.
       return NO;
    case PM_ERROR:
       // Load error
       return NO;
    default:
       break;
    }

    PicoLoopPrepare();

    PicoIn.writeSound = sound_write;
    memset(soundBuffer, 0, sizeof(soundBuffer));
    PicoIn.sndOut = soundBuffer;
    PsndRerate(0);

    // Set battery saves dir and load SRAM
    NSString *extensionlessFilename = _romFile.lastPathComponent.stringByDeletingPathExtension;
    NSURL *batterySavesDirectory = [NSURL fileURLWithPath:self.batterySavesDirectoryPath];
    [NSFileManager.defaultManager createDirectoryAtURL:batterySavesDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *saveFile = [batterySavesDirectory URLByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"sav2"]];

    if ([saveFile checkResourceIsReachableAndReturnError:nil])
    {
        NSData *saveData = [NSData dataWithContentsOfURL:saveFile];
        memcpy(Pico.sv.data, saveData.bytes, Pico.sv.size);
        NSLog(@"[Picodrive] Loaded sram");
    }

    return YES;
}

- (void)executeFrame
{
    //PicoPatchApply();
    PicoFrame();
}

- (void)resetEmulation
{
    PicoReset();
}

// MARK: - Cheats

- (void)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled
{
    // Sanitize: trim, drop spaces, and uppercase (PicoDrive's decoder expects uppercase
    // for both the hex "XXXXXX:XXXX" and the Game Genie "XXXX-XXXX" alphabets).
    code = [code stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    code = [code stringByReplacingOccurrencesOfString:@" " withString:@""];
    if (code.length == 0)
        return;
    code = code.uppercaseString;

    if (enabled)
        _cheatList[code] = @YES;
    else
        [_cheatList removeObjectForKey:code];

    [self applyCheats];
}

- (void)applyCheats
{
    // Rebuild PicoDrive's patch list from scratch: restore any ROM writes, then re-add
    // every enabled code. executeFrame re-applies them each frame.
    PicoPatchResetAll();

    for (NSString *code in _cheatList)
    {
        if (![_cheatList[code] boolValue])
            continue;

        // Multi-line cheats are joined with '+'
        for (NSString *singleCode in [code componentsSeparatedByString:@"+"])
        {
            if (singleCode.length == 0)
                continue;
            PicoPatchAdd(singleCode.UTF8String, 1);
        }
    }

    PicoPatchApply();
}

- (void)stopEmulation
{
    // Only save if SRAM has been modified
    int sram_size = Pico.sv.size;
    uint8_t *sram_data = Pico.sv.data;

    // sram save needs some special processing
    // see if we have anything to save
    for (; sram_size > 0; sram_size--)
        if (sram_data[sram_size-1]) break;

    if (sram_size && Pico.sv.changed)
    {
        NSError *error = nil;
        NSString *extensionlessFilename = _romFile.lastPathComponent.stringByDeletingPathExtension;
        NSURL *batterySavesDirectory = [NSURL fileURLWithPath:self.batterySavesDirectoryPath];
        NSURL *saveFile = [batterySavesDirectory URLByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"sav2"]];

        // copy SRAM data
        NSData *saveData = [NSData dataWithBytes:sram_data length:sram_size];
        [saveData writeToURL:saveFile options:NSDataWritingAtomic error:&error];

        if (error)
            NSLog(@"[Picodrive] Error writing sram file: %@", error);
        else
            NSLog(@"[Picodrive] Saved sram file: %@", saveFile);
    }

    PicoExit();

    [super stopEmulation];
}

- (NSTimeInterval)frameInterval
{
    return Pico.m.pal ? 50 : 60;
}

// MARK: - Video

- (const void *)getVideoBufferWithHint:(void *)hint
{
    return (uint16_t *)_videoBuffer;
}

- (OEIntRect)screenRect
{
    return OEIntRectMake(0, 8, _videoWidth, 224);
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(320, 240);
}

- (OEIntSize)aspectSize
{
    // H32 mode (256px * 8:7 PAR)
    // H40 mode (320px * 32:35 PAR)
    return OEIntSizeMake(292, 224);
}

- (GLenum)pixelFormat
{
    return GL_RGB;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_SHORT_5_6_5;
}

// MARK: - Audio

- (double)audioSampleRate
{
    return 44100;
}

- (NSUInteger)channelCount
{
    return 2;
}

// MARK: - Save States

- (NSData *)serializeStateWithError:(NSError **)outError
{
    size_t length = picodrive_serialize_size();
    void *bytes = malloc(length);

    if(picodrive_serialize(bytes, length))
        return [NSData dataWithBytesNoCopy:bytes length:length];

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
    size_t serial_size = picodrive_serialize_size();
    if(serial_size != state.length) {
        if(outError) {
            *outError = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreStateHasWrongSizeError userInfo:@{
                NSLocalizedDescriptionKey : @"Save state has wrong file size.",
                NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:@"The save state does not have the right size, %ld expected, got: %ld.", serial_size, state.length]
            }];
        }

        return NO;
    }

    if(picodrive_unserialize(state.bytes, state.length))
        return YES;

    if(outError) {
        *outError = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadStateError userInfo:@{
            NSLocalizedDescriptionKey : @"The save state data could not be read"
        }];
    }

    return NO;
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    size_t serial_size = picodrive_serialize_size();
    NSMutableData *stateData = [NSMutableData dataWithLength:serial_size];

    if(!picodrive_serialize(stateData.mutableBytes, serial_size)) {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotSaveStateError userInfo:@{
            NSLocalizedDescriptionKey : @"Save state data could not be written",
            NSLocalizedRecoverySuggestionErrorKey : @"The emulator could not write the state data."
        }];
        block(NO, error);
        return;
    }

    NSError *error = nil;
    BOOL success = [stateData writeToFile:fileName options:NSDataWritingAtomic error:&error];
    block(success, success ? nil : error);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:fileName options:NSDataReadingMappedIfSafe | NSDataReadingUncached error:&error];
    if(data == nil)  {
        block(NO, error);
        return;
    }

    int serial_size = 678514;
    if(serial_size != data.length) {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreStateHasWrongSizeError userInfo:@{
            NSLocalizedDescriptionKey : @"Save state has wrong file size.",
            NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:@"The size of the file %@ does not have the right size, %d expected, got: %ld.", fileName, serial_size, data.length],
        }];
        block(NO, error);
        return;
    }

    if(!picodrive_unserialize(data.bytes, serial_size)) {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadStateError userInfo:@{
            NSLocalizedDescriptionKey : @"The save state data could not be read",
            NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:@"Could not read the file state in %@.", fileName]
        }];
        block(NO, error);
        return;
    }

    block(YES, nil);
}

// MARK: - Input

const int Sega32XMap[] = {1 << GBTN_UP, 1 << GBTN_DOWN, 1 << GBTN_LEFT, 1 << GBTN_RIGHT, 1 << GBTN_A, 1 << GBTN_B, 1 << GBTN_C, 1 << GBTN_X, 1 << GBTN_Y, 1 << GBTN_Z, 1 << GBTN_START, 1 << GBTN_MODE};
- (oneway void)didPushSega32XButton:(OESega32XButton)button forPlayer:(NSUInteger)player
{
    PicoIn.pad[player-1] |= Sega32XMap[button];
}

- (oneway void)didReleaseSega32XButton:(OESega32XButton)button forPlayer:(NSUInteger)player
{
    PicoIn.pad[player-1] &= ~Sega32XMap[button];
}

// MARK: - Callbacks and Misc Helper Methods

static void sound_write(int len)
{
    if (!len)
        return;

    [[_current ringBufferAtIndex:0] write:PicoIn.sndOut maxLength:len];
}

void emu_video_mode_change(int start_line, int line_count, int is_32cols)
{
    GET_CURRENT_OR_RETURN();
    current->_videoWidth = is_32cols ? 256 : 320;
}

void emu_32x_startup(void)
{
}

void lprintf(const char *fmt, ...)
{
//    char buffer[256];
//    va_list ap;
//    va_start(ap, fmt);
//    vsprintf(buffer, fmt, ap);
//    NSLog(@"[Picodrive] %s", buffer);
//    va_end(ap);
}

void *plat_mmap(unsigned long addr, size_t size, int need_exec, int is_fixed)
{
    int flags = MAP_PRIVATE | MAP_ANONYMOUS;
    void *req, *ret;

    req = (void *)(uintptr_t)addr;
    ret = mmap(req, size, PROT_READ | PROT_WRITE, flags, -1, 0);
    if (ret == MAP_FAILED) {
        NSLog(@"[Picodrive] mmap(%08lx, %zd) failed", addr, size);
        return NULL;
    }

    if (addr != 0 && ret != (void *)(uintptr_t)addr) {
        NSLog(@"[Picodrive] warning: wanted to map @%08lx, got %p", addr, ret);

        if (is_fixed) {
            munmap(ret, size);
            return NULL;
        }
    }
    return ret;
}

void plat_munmap(void *ptr, size_t size)
{
    if (ptr != NULL)
        munmap(ptr, size);
}

// Not using carthw.cfg so this is probably never called.
void *plat_mremap(void *ptr, size_t oldsize, size_t newsize)
{
#ifdef __linux__
    void *ret = mremap(ptr, oldsize, newsize, 0);
    if (ret == MAP_FAILED)
        return NULL;

    return ret;
#else
    void *tmp, *ret;
    size_t preserve_size;

    preserve_size = oldsize;
    if (preserve_size > newsize)
        preserve_size = newsize;
    tmp = malloc(preserve_size);
    if (tmp == NULL)
        return NULL;
    memcpy(tmp, ptr, preserve_size);

    munmap(ptr, oldsize);
    ret = mmap(ptr, newsize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (ret == MAP_FAILED) {
        free(tmp);
        return NULL;
    }
    memcpy(ret, tmp, preserve_size);
    free(tmp);
    return ret;
#endif
}

size_t picodrive_serialize_size(void)
{
    struct savestate_state state = { 0, };
    int ret;

    ret = PicoStateFP(&state, 1, NULL, state_skip, NULL, state_fseek);
    if (ret != 0)
        return 0;

    return state.pos;
}

bool picodrive_serialize(void *data, size_t size)
{
    struct savestate_state state = { 0, };
    int ret;

    state.save_buf = data;
    state.size = size;
    state.pos = 0;

    ret = PicoStateFP(&state, 1, NULL, state_write, NULL, state_fseek);
    return ret == 0;
}

bool picodrive_unserialize(const void *data, size_t size)
{
    struct savestate_state state = { 0, };
    int ret;

    state.load_buf = data;
    state.size = size;
    state.pos = 0;

    ret = PicoStateFP(&state, 0, state_read, NULL, state_eof, state_fseek);
    return ret == 0;
}

struct savestate_state {
    const char *load_buf;
    char *save_buf;
    size_t size;
    size_t pos;
};

size_t state_read(void *p, size_t size, size_t nmemb, void *file)
{
    struct savestate_state *state = file;
    size_t bsize = size * nmemb;

    if (state->pos + bsize > state->size) {
        NSLog(@"[Picodrive] savestate read error: %lu/%zu", state->pos + bsize, state->size);
        bsize = state->size - state->pos;
        if ((int)bsize <= 0)
            return 0;
    }

    memcpy(p, state->load_buf + state->pos, bsize);
    state->pos += bsize;
    return bsize;
}

size_t state_write(void *p, size_t size, size_t nmemb, void *file)
{
    struct savestate_state *state = file;
    size_t bsize = size * nmemb;

    if (state->pos + bsize > state->size) {
        NSLog(@"[Picodrive] savestate write error: %lu/%zu", state->pos + bsize, state->size);
        bsize = state->size - state->pos;
        if ((int)bsize <= 0)
            return 0;
    }

    memcpy(state->save_buf + state->pos, p, bsize);
    state->pos += bsize;
    return bsize;
}

size_t state_skip(void *p, size_t size, size_t nmemb, void *file)
{
    struct savestate_state *state = file;
    size_t bsize = size * nmemb;

    state->pos += bsize;
    return bsize;
}

size_t state_eof(void *file)
{
    struct savestate_state *state = file;

    return state->pos >= state->size;
}

int state_fseek(void *file, long offset, int whence)
{
    struct savestate_state *state = file;

    switch (whence) {
    case SEEK_SET:
        state->pos = offset;
        break;
    case SEEK_CUR:
        state->pos += offset;
        break;
    case SEEK_END:
        state->pos = state->size + offset;
        break;
    }
    return (int)state->pos;
}

@end
