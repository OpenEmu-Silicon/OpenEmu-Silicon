// oe-headless: loads an installed OpenEmu core and a ROM with no window, runs frames, and reports
// what the core produced. Built and driven by Scripts/headless/run.sh.
//
// Usage:
//   oe-headless --core <X.oecoreplugin> --rom <file> --frames N [--input FRAME:SELECTOR:INT ...]
//               [--hash-at FRAME ...] [--save-state-at FRAME] [--load-state-at FRAME] [--audio]
//               [--search-byte FRAME:HEXVALUE ...] [--cheat-at FRAME:CODE ...] [--reset-at FRAME ...]
//               [--buffer-once] [--save-file-at FRAME:PATH ...] [--load-file-at FRAME:PATH ...]
//
// --buffer-once asks the core for its video buffer only before the first frame, the way Release builds
// of the app do (Debug builds ask again every frame from an assert), so a core that loses the buffer
// shows up as a picture that stops changing.
//
// Output is one line per event, easy to grep:
//   core-loaded <class>
//   rom-loaded
//   frame <n> video=<hash> audio=<hash>    (for every --hash-at frame, and the last frame)
//   state-saved <bytes>
//   state-loaded
//   cheat-set <code>
//   reset
//   file-saved ok|failed exists=yes|no [<error>]   (for --save-file-at: what the core reported, and
//                                                   whether the file is really there afterwards)
//   file-loaded ok|failed [<error>]                 (for --load-file-at)
//   region <name> address=<hex> bytes=<n>  (for --search-byte, once per readable memory region)
//   hit <hex address>                      (for --search-byte, every byte equal to the value, addressed
//                                           the way the cheat search window addresses it)
//   done frames=<n>
// Any failure prints "error: <reason>" and exits non-zero.

#import <Foundation/Foundation.h>
#import <OpenEmuBase/OpenEmuBase.h>
#import <CommonCrypto/CommonDigest.h>

// Points the core's support and BIOS folders at a throwaway directory so a run never touches the real library.
@interface HeadlessController : OEGameCoreController
@property(nonatomic, copy) NSURL *sandbox;
@end

@implementation HeadlessController
- (NSURL *)supportDirectory { return [self.sandbox URLByAppendingPathComponent:@"Support"]; }
- (NSURL *)biosDirectory { return [self.sandbox URLByAppendingPathComponent:@"BIOS"]; }
- (NSString *)supportDirectoryPath { return self.supportDirectory.path; }
- (NSString *)biosDirectoryPath { return self.biosDirectory.path; }
@end

static NSString *HashOfBytes(const void *bytes, size_t length)
{
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes, (CC_LONG)length, digest);
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < 8; i++) [s appendFormat:@"%02x", digest[i]];
    return s;
}

static NSString *VideoHash(OEGameCore *core, const void *buffer)
{
    if (!buffer) return @"none";
    OEIntSize size = core.bufferSize;
    NSInteger rowBytes = core.bytesPerRow;
    // Hash only the visible part so padding in the buffer cannot change the result.
    OEIntRect screen = core.screenRect;
    NSInteger bytesPerPixel = rowBytes / MAX(size.width, 1);
    NSMutableData *visible = [NSMutableData data];
    for (NSInteger y = screen.origin.y; y < screen.origin.y + screen.size.height; y++) {
        const uint8_t *row = (const uint8_t *)buffer + y * rowBytes + screen.origin.x * bytesPerPixel;
        [visible appendBytes:row length:screen.size.width * bytesPerPixel];
    }
    return HashOfBytes(visible.bytes, visible.length);
}

// Drains whatever audio the core produced this frame into a running digest. Nobody else reads the ring
// buffers here, so without this they fill up and the core starts dropping samples.
static void DrainAudio(OEGameCore *core, CC_SHA256_CTX *digest, NSUInteger *totalBytes)
{
    for (NSUInteger i = 0; i < core.audioBufferCount; i++) {
        OERingBuffer *ring = (OERingBuffer *)[core audioBufferAtIndex:i];
        ring.anticipatesUnderflow = NO;  // otherwise a read of everything we have is refused
        NSUInteger capacity = ring.availableBytes;
        if (capacity == 0) continue;
        NSMutableData *chunk = [NSMutableData dataWithLength:capacity];
        NSUInteger got = [ring read:chunk.mutableBytes maxLength:capacity];
        CC_SHA256_Update(digest, chunk.bytes, (CC_LONG)got);
        *totalBytes += got;
    }
}

static NSString *DigestString(CC_SHA256_CTX digest, NSUInteger totalBytes)
{
    if (totalBytes == 0) return @"silent";
    unsigned char out[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(out, &digest);
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < 8; i++) [s appendFormat:@"%02x", out[i]];
    return s;
}

static int Fail(NSString *reason)
{
    printf("error: %s\n", reason.UTF8String);
    return 1;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        NSString *corePath = nil, *romPath = nil;
        NSInteger frames = 60;
        BOOL wantAudio = NO;
        NSInteger saveAt = -1, loadAt = -1;
        NSMutableSet<NSNumber *> *hashAt = [NSMutableSet set];
        NSMutableDictionary<NSNumber *, NSNumber *> *searchAt = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSNumber *, NSMutableArray<NSString *> *> *cheatsAt = [NSMutableDictionary dictionary];
        NSMutableSet<NSNumber *> *resetAt = [NSMutableSet set];
        NSMutableDictionary<NSNumber *, NSString *> *saveFileAt = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSNumber *, NSString *> *loadFileAt = [NSMutableDictionary dictionary];
        BOOL bufferOnce = NO;
        NSMutableDictionary<NSNumber *, NSMutableArray<NSArray *> *> *inputs = [NSMutableDictionary dictionary];

        for (int i = 1; i < argc; i++) {
            NSString *arg = @(argv[i]);
            NSString *next = (i + 1 < argc) ? @(argv[i + 1]) : nil;
            if ([arg isEqual:@"--core"] && next) { corePath = next; i++; }
            else if ([arg isEqual:@"--rom"] && next) { romPath = next; i++; }
            else if ([arg isEqual:@"--frames"] && next) { frames = next.integerValue; i++; }
            else if ([arg isEqual:@"--hash-at"] && next) { [hashAt addObject:@(next.integerValue)]; i++; }
            else if ([arg isEqual:@"--save-state-at"] && next) { saveAt = next.integerValue; i++; }
            else if ([arg isEqual:@"--load-state-at"] && next) { loadAt = next.integerValue; i++; }
            else if ([arg isEqual:@"--audio"]) { wantAudio = YES; }
            else if ([arg isEqual:@"--buffer-once"]) { bufferOnce = YES; }
            else if ([arg isEqual:@"--reset-at"] && next) { [resetAt addObject:@(next.integerValue)]; i++; }
            else if (([arg isEqual:@"--save-file-at"] || [arg isEqual:@"--load-file-at"]) && next) {
                NSRange colon = [next rangeOfString:@":"];
                if (colon.location == NSNotFound) return Fail([arg stringByAppendingString:@" wants FRAME:PATH"]);
                NSMutableDictionary *target = [arg isEqual:@"--save-file-at"] ? saveFileAt : loadFileAt;
                target[@([next substringToIndex:colon.location].integerValue)] = [next substringFromIndex:colon.location + 1];
                i++;
            }
            else if ([arg isEqual:@"--cheat-at"] && next) {
                NSRange colon = [next rangeOfString:@":"];
                if (colon.location == NSNotFound) return Fail(@"--cheat-at wants FRAME:CODE");
                NSNumber *frame = @([next substringToIndex:colon.location].integerValue);
                if (!cheatsAt[frame]) cheatsAt[frame] = [NSMutableArray array];
                [cheatsAt[frame] addObject:[next substringFromIndex:colon.location + 1]];
                i++;
            }
            else if ([arg isEqual:@"--search-byte"] && next) {
                NSArray<NSString *> *parts = [next componentsSeparatedByString:@":"];
                if (parts.count != 2) return Fail(@"--search-byte wants FRAME:HEXVALUE");
                unsigned value = 0;
                [[NSScanner scannerWithString:parts[1]] scanHexInt:&value];
                searchAt[@(parts[0].integerValue)] = @(value & 0xFF);
                i++;
            }
            else if ([arg isEqual:@"--input"] && next) {
                NSArray<NSString *> *parts = [next componentsSeparatedByString:@":"];
                if (parts.count < 3) return Fail(@"--input wants FRAME:SELECTOR:INT");
                NSNumber *frame = @(parts.firstObject.integerValue);
                // The selector may itself contain colons, e.g. didPushArcadeButton:forPlayer:
                NSString *selectorName = [[parts subarrayWithRange:NSMakeRange(1, parts.count - 2)] componentsJoinedByString:@":"];
                if (!inputs[frame]) inputs[frame] = [NSMutableArray array];
                [inputs[frame] addObject:@[selectorName, @(parts.lastObject.integerValue)]];
                i++;
            } else {
                return Fail([NSString stringWithFormat:@"unknown or incomplete argument %@", arg]);
            }
        }
        if (!corePath || !romPath) return Fail(@"--core and --rom are required");

        NSBundle *bundle = [NSBundle bundleWithPath:corePath];
        if (!bundle) return Fail(@"core bundle not found");
        NSError *loadError = nil;
        if (![bundle loadAndReturnError:&loadError]) return Fail([NSString stringWithFormat:@"core would not load: %@", loadError]);
        NSString *className = bundle.infoDictionary[@"OEGameCoreClass"];
        HeadlessController *controller = [[HeadlessController alloc] initWithBundle:bundle];
        controller.sandbox = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                                     [NSString stringWithFormat:@"oe-headless-%d", getpid()]]];
        for (NSString *sub in @[@"Support", @"BIOS"]) {
            [[NSFileManager defaultManager] createDirectoryAtURL:[controller.sandbox URLByAppendingPathComponent:sub]
                                     withIntermediateDirectories:YES attributes:nil error:nil];
        }
        OEGameCore *core = [controller newGameCore];
        if (!core) return Fail([NSString stringWithFormat:@"class %@ did not initialise", className]);
        NSString *system = [bundle.infoDictionary[@"OESystemIdentifiers"] firstObject];
        core.owner = controller;
        if (system) core.systemIdentifier = system;
        printf("core-loaded %s\n", className.UTF8String);

        NSError *romError = nil;
        if (![core loadFileAtPath:romPath error:&romError]) return Fail([NSString stringWithFormat:@"ROM would not load: %@", romError]);
        printf("rom-loaded\n");

        dispatch_semaphore_t setupDone = dispatch_semaphore_create(0);
        [core setupEmulationWithCompletionHandler:^{ dispatch_semaphore_signal(setupDone); }];
        // Some cores finish setup on the main queue, so keep it turning while we wait.
        while (dispatch_semaphore_wait(setupDone, DISPATCH_TIME_NOW) != 0) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }

        NSData *savedState = nil;
        CC_SHA256_CTX audioDigest;
        CC_SHA256_Init(&audioDigest);
        NSUInteger audioBytes = 0;
        const void *videoBuffer = NULL;
        NSMutableData *hostVideo = nil;
        for (NSInteger frame = 1; frame <= frames; frame++) {
            for (NSArray *input in inputs[@(frame)]) {
                NSString *name = [input[0] hasSuffix:@":"] ? input[0] : [input[0] stringByAppendingString:@":"];
                SEL selector = NSSelectorFromString(name);
                if (![core respondsToSelector:selector]) return Fail([NSString stringWithFormat:@"core does not respond to %@", input[0]]);
                NSMethodSignature *sig = [core methodSignatureForSelector:selector];
                NSInvocation *call = [NSInvocation invocationWithMethodSignature:sig];
                call.target = core;
                call.selector = selector;
                // Argument 2 is the button. A second argument (player) is filled with 1 when present.
                NSInteger button = [input[1] integerValue];
                [call setArgument:&button atIndex:2];
                if (sig.numberOfArguments > 3) { NSUInteger player = 1; [call setArgument:&player atIndex:3]; }
                [call invoke];
            }
            if (frame == saveAt) {
                NSError *e = nil;
                savedState = [core serializeStateWithError:&e];
                if (!savedState) return Fail([NSString stringWithFormat:@"save state failed: %@", e]);
                printf("state-saved %lu\n", (unsigned long)savedState.length);
            }
            if (frame == loadAt) {
                NSError *e = nil;
                if (!savedState || ![core deserializeState:savedState withError:&e]) return Fail([NSString stringWithFormat:@"load state failed: %@", e]);
                printf("state-loaded\n");
            }
            for (NSString *code in cheatsAt[@(frame)]) {
                [core setCheat:code setType:@"Unknown" setEnabled:YES];
                printf("cheat-set %s\n", code.UTF8String);
            }
            if ([resetAt containsObject:@(frame)]) {
                [core resetEmulation];
                printf("reset\n");
            }
            if (saveFileAt[@(frame)] || loadFileAt[@(frame)]) {
                BOOL saving = saveFileAt[@(frame)] != nil;
                NSString *path = saving ? saveFileAt[@(frame)] : loadFileAt[@(frame)];
                __block BOOL ok = NO;
                __block NSError *fileError = nil;
                dispatch_semaphore_t done = dispatch_semaphore_create(0);
                void (^handler)(BOOL, NSError *) = ^(BOOL success, NSError *e) {
                    ok = success; fileError = e; dispatch_semaphore_signal(done);
                };
                if (saving) [core saveStateToFileAtPath:path completionHandler:handler];
                else [core loadStateFromFileAtPath:path completionHandler:handler];
                while (dispatch_semaphore_wait(done, DISPATCH_TIME_NOW) != 0) {
                    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
                }
                NSString *detail = fileError ? [NSString stringWithFormat:@" %@ %@", fileError.localizedDescription, fileError.localizedRecoverySuggestion ?: @""] : @"";
                if (saving) {
                    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
                    printf("file-saved %s exists=%s%s\n", ok ? "ok" : "failed", exists ? "yes" : "no", detail.UTF8String);
                } else {
                    printf("file-loaded %s%s\n", ok ? "ok" : "failed", detail.UTF8String);
                }
            }
            if (!bufferOnce || frame == 1) {
                videoBuffer = [core getVideoBufferWithHint:hostVideo.mutableBytes];
            }
            if (!videoBuffer && !hostVideo) {
                // Some cores (MAME) only draw into a buffer the host provides.
                hostVideo = [NSMutableData dataWithLength:core.bytesPerRow * core.bufferSize.height];
                videoBuffer = [core getVideoBufferWithHint:hostVideo.mutableBytes];
            }
            [core executeFrame];
            DrainAudio(core, &audioDigest, &audioBytes);
            if (searchAt[@(frame)]) {
                uint8_t wanted = searchAt[@(frame)].unsignedCharValue;
                for (OEMemoryRegionDescriptor *region in [core readableMemoryRegions]) {
                    printf("region %s address=%08X bytes=%lu\n", region.name.UTF8String, region.address, (unsigned long)region.data.length);
                    const uint8_t *bytes = region.data.bytes;
                    for (NSUInteger offset = 0; offset < region.data.length; offset++) {
                        if (bytes[offset] == wanted) printf("hit %08X\n", [region addressForOffset:offset]);
                    }
                }
            }
            if ([hashAt containsObject:@(frame)] || frame == frames) {
                printf("frame %ld video=%s audio=%s\n", (long)frame, VideoHash(core, videoBuffer).UTF8String,
                       wantAudio ? DigestString(audioDigest, audioBytes).UTF8String : "-");
            }
        }
        [core stopEmulationWithCompletionHandler:^{}];
        [[NSFileManager defaultManager] removeItemAtURL:controller.sandbox error:nil];
        printf("done frames=%ld\n", (long)frames);
    }
    return 0;
}
