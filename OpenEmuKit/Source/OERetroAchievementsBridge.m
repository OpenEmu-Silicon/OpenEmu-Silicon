// Copyright (c) 2026, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the names of its contributors
//       may be used to endorse or promote products derived from this software
//       without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY EXPRESS OR
// IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
// OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.

#import "OERetroAchievementsBridge.h"
#import "OERetroAchievementsTransport.h"
#import <OpenEmuBase/OpenEmuBase.h> // full OEGameCore + OEGameCoreController interfaces (core.pluginName/owner.bundle)
#import <os/log.h>
#include <rc_hash.h>

// Bridge owns its own copy of the OERetroAchievements* notification names
// so per-core code doesn't have to import the transport header alongside the
// bridge header.

@interface OERetroAchievementsBridge ()
@property (atomic, readwrite) BOOL romReady;
@property (atomic, readwrite) BOOL shuttingDown;
@end

// Per-instance queue identity key. We set the bridge pointer as the specific
// value on _serialQueue at init time. `dispatch_get_specific` returns it iff
// the current dispatch context is *this bridge's* serial queue. Used to make
// `shutdown` re-entrant from queued blocks (avoids dispatch_sync deadlock).
static const void *const kOERABridgeQueueKey = &kOERABridgeQueueKey;

@implementation OERetroAchievementsBridge
{
    rc_client_t                                *_rcClient;
    OERetroAchievementsMemoryReader             _memoryReader;
    uint32_t                                    _consoleID;
    NSString                                   *_romPath;
    NSString                                   *_coreUserAgentClause;

    dispatch_queue_t                            _serialQueue;
    dispatch_queue_t                            _snapshotQueue;
    NSURLSession                               *_urlSession;
    NSMutableSet<NSURLSessionTask *>           *_inflightTasks;
    NSLock                                     *_tasksLock;

    id                                          _tokenObserver;
    id                                          _hardcoreObserver;

    BOOL                                        _started;
    BOOL                                        _snapshotDirty;
}

#pragma mark - Lifecycle

- (instancetype)initWithGameCore:(OEGameCore *)core
                    memoryReader:(OERetroAchievementsMemoryReader)reader
                       consoleID:(uint32_t)consoleID
{
    if ((self = [super init])) {
        _core            = core;
        _memoryReader    = reader;
        _consoleID       = consoleID;

        // Capture the core's name + version now, while `core` is guaranteed
        // alive. The network path runs later off a weak ref that can have
        // niled out by request time. RetroAchievements wants the emulator core
        // identified in the User-Agent, matching RetroArch's
        // "<frontend>/<ver> (<os>) <core_name>/<core_version>" form — spaces in
        // the core name become underscores so the clause stays a single token.
        // Several cores (e.g. Gambatte, Nestopia) ship only CFBundleVersion,
        // not CFBundleShortVersionString, so fall back to it — otherwise the
        // version silently drops for those cores.
        NSString *coreName    = core.pluginName;
        NSBundle *coreBundle  = core.owner.bundle;
        NSString *coreVersion = [coreBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]
                             ?: [coreBundle objectForInfoDictionaryKey:@"CFBundleVersion"];
        if (coreName.length) {
            NSString *safeName = [coreName stringByReplacingOccurrencesOfString:@" " withString:@"_"];
            _coreUserAgentClause = coreVersion.length
                ? [NSString stringWithFormat:@"%@/%@ ", safeName, coreVersion]
                : [NSString stringWithFormat:@"%@ ", safeName];
        } else {
            _coreUserAgentClause = @"";
        }

        _serialQueue     = dispatch_queue_create("com.openemu.ra-bridge.serial", DISPATCH_QUEUE_SERIAL);
        _snapshotQueue   = dispatch_queue_create("com.openemu.ra-bridge.snapshot", DISPATCH_QUEUE_SERIAL);
        // Tag _serialQueue so we can detect "already running on this bridge's
        // serial queue" from inside `shutdown` and skip the otherwise-fatal
        // `dispatch_sync(_serialQueue, ...)` self-call (would deadlock).
        dispatch_queue_set_specific(_serialQueue, kOERABridgeQueueKey, (__bridge void *)self, NULL);
        _inflightTasks   = [NSMutableSet set];
        _tasksLock       = [[NSLock alloc] init];
        _hardcoreEnabled = YES;

        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 30.0;
        _urlSession = [NSURLSession sessionWithConfiguration:cfg
                                                    delegate:nil
                                               delegateQueue:nil];
    }
    return self;
}

- (void)dealloc
{
    // Safety net for paths that release the core without calling stopEmulation.
    // shutdown is idempotent.
    [self shutdown];
}

#pragma mark - Memory reader / server-call trampolines

static uint32_t oe_ra_bridge_read_memory(uint32_t address, uint8_t *buffer,
                                          uint32_t num_bytes, rc_client_t *client)
{
    OERetroAchievementsBridge *bridge = (__bridge OERetroAchievementsBridge *)rc_client_get_userdata(client);
    if (!bridge || !bridge.romReady || bridge.shuttingDown) { return 0; }
    OERetroAchievementsMemoryReader reader = bridge->_memoryReader;
    if (!reader) { return 0; }
    return reader(address, buffer, num_bytes, client);
}

static void oe_ra_bridge_log(const char *message, const rc_client_t *client)
{
    (void)client;
    os_log(OS_LOG_DEFAULT, "[rcheevos] %{public}s", message);
}

// rcheevos reserves achievement IDs >= 101000001 as "warning achievements"
// attached to sessions running on emulator clients that aren't on RA's
// recognized/hardcore-compliant list. They flow through the normal
// ACHIEVEMENT_TRIGGERED path but should be surfaced as a one-time notice, not
// as a fake unlock. Mirrors `RC_CLIENT_ACHIEVEMENT_WARNING_ID` in rcheevos.
#ifndef OE_RA_WARNING_ACHIEVEMENT_MIN_ID
#define OE_RA_WARNING_ACHIEVEMENT_MIN_ID 101000001u
#endif

static void oe_ra_bridge_event_handler(const rc_client_event_t *event, rc_client_t *client)
{
    // Always post the generic event notification — host UI consumes this for
    // banners, leaderboard trackers, etc.
    oeRetroAchievementsPostEventNotification(event, client);

    OERetroAchievementsBridge *bridge = (__bridge OERetroAchievementsBridge *)rc_client_get_userdata(client);
    if (!bridge) { return; }

    if (event->type == RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED) {
        const rc_client_achievement_t *ach = event->achievement;
        if (ach) {
            if (ach->id >= OE_RA_WARNING_ACHIEVEMENT_MIN_ID) {
                // Unknown-emulator warning. Suppress the unlock banner and
                // fire a one-time notice so the host can show a placard
                // explaining hardcore unlocks will save as Softcore until
                // OpenEmu-Silicon is approved by RA. See PR refs #579.
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:OERAEmulatorUnrecognizedNotification
                                  object:nil
                                userInfo:nil];
            } else {
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
            }
        }
        // Snapshot will be rebuilt off the frame thread.
        bridge->_snapshotDirty = YES;
    }
}

#pragma mark - URL session bridge transport

// callback_data carries the rcheevos-owned per-call pointer. The bridge's
// transport task tracks its NSURLSessionTask so shutdown can cancel it.
typedef struct {
    rc_client_server_callback_t  callback;
    void                        *callback_data;
    __unsafe_unretained OERetroAchievementsBridge *bridge;  // not retained: bridge outlives task; if not, completion bails
} oe_ra_transport_ctx_t;

static void oe_ra_bridge_server_call(const rc_api_request_t *request,
                                      rc_client_server_callback_t callback,
                                      void *callback_data,
                                      rc_client_t *client)
{
    OERetroAchievementsBridge *bridge = (__bridge OERetroAchievementsBridge *)rc_client_get_userdata(client);
    [bridge _performServerCallURL:[NSString stringWithUTF8String:request->url ?: ""]
                          postBody:request->post_data ? [NSString stringWithUTF8String:request->post_data] : nil
                       contentType:request->content_type ? [NSString stringWithUTF8String:request->content_type] : nil
                          callback:callback
                      callbackData:callback_data];
}

- (void)_performServerCallURL:(NSString *)urlString
                     postBody:(nullable NSString *)postBody
                  contentType:(nullable NSString *)contentType
                     callback:(rc_client_server_callback_t)callback
                 callbackData:(void *)callbackData
{
    if (self.shuttingDown) {
        // Best effort: report a client error synchronously so rcheevos releases
        // callback_data. Safe — caller is on the rcheevos thread, not our queue.
        rc_api_server_response_t err = { .body = "", .body_length = 0,
                                          .http_status_code = RC_API_SERVER_RESPONSE_CLIENT_ERROR };
        callback(&err, callbackData);
        return;
    }

    // URLWithString: throws NSInvalidArgumentException on nil. stringWithUTF8String
    // can return nil if rcheevos ever hands us a non-UTF-8 byte sequence — paranoid
    // guard since rcheevos URLs are ASCII in practice.
    if (!urlString) {
        rc_api_server_response_t err = { .body = "", .body_length = 0,
                                          .http_status_code = RC_API_SERVER_RESPONSE_CLIENT_ERROR };
        callback(&err, callbackData);
        return;
    }
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        rc_api_server_response_t err = { .body = "", .body_length = 0,
                                          .http_status_code = RC_API_SERVER_RESPONSE_CLIENT_ERROR };
        callback(&err, callbackData);
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];

    char rcClause[64] = {0};
    rc_client_get_user_agent_clause(_rcClient, rcClause, sizeof(rcClause));
    NSString *hostVersion = OEHostAppVersion();
    NSOperatingSystemVersion osv = [[NSProcessInfo processInfo] operatingSystemVersion];
    NSString *userAgent = [NSString stringWithFormat:@"OpenEmu-Silicon/%@ (macOS %ld.%ld.%ld) %@%s",
                            hostVersion, (long)osv.majorVersion, (long)osv.minorVersion,
                            (long)osv.patchVersion, _coreUserAgentClause ?: @"", rcClause];
    [req setValue:userAgent forHTTPHeaderField:@"User-Agent"];

    if (postBody) {
        req.HTTPMethod = @"POST";
        req.HTTPBody   = [postBody dataUsingEncoding:NSUTF8StringEncoding];
        [req setValue:(contentType ?: @"application/x-www-form-urlencoded")
            forHTTPHeaderField:@"Content-Type"];
    } else {
        req.HTTPMethod = @"GET";
    }

    __weak __typeof(self) weakSelf = self;
    __block NSURLSessionDataTask *task = nil;
    task = [_urlSession dataTaskWithRequest:req
                          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __typeof(self) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf _untrackTask:task];
        }

        // Capture only block-safe values. The serial-queue block builds its
        // own stack error buffer so we don't have to worry about array lifetime.
        NSString *errMsg = error ? (error.localizedDescription ?: @"") : nil;
        NSData *bodyCopy = (data && data.length > 0) ? data : nil;
        long statusCode = 0;
        BOOL isHTTP = [response isKindOfClass:NSHTTPURLResponse.class];
        if (isHTTP) { statusCode = ((NSHTTPURLResponse *)response).statusCode; }
        BOOL hadError = (error != nil);

        if (!strongSelf) { return; }  // bridge gone; rcheevos already destroyed

        // Strong-capture into the serial-queue block so the bridge is
        // guaranteed alive when we run, regardless of whether the URL
        // completion's outer scope was the last strong holder. Without this,
        // weakSelf could nil out between dispatch_async enqueue and execution
        // and we'd silently skip the callback() invocation, leaking
        // callback_data on the shutdown path. Bridge itself does its own
        // shuttingDown / _rcClient guards before touching rc_client state.
        OERetroAchievementsBridge *captured = strongSelf;
        dispatch_async(captured->_serialQueue, ^{
            OERetroAchievementsBridge *s = captured;

            // Shutdown path: rc_client may already be destroyed (or about to
            // be on this same queue). Only invoke the rcheevos callback if
            // rc_client is still alive — it's required to be invoked exactly
            // once per request so rcheevos can free its callback_data.
            // Serial-queue FIFO ordering means if we reach this block before
            // shutdown's destroy block, _rcClient is still set; if we reach
            // it after, _rcClient is NULL and a callback() into rcheevos
            // would touch freed state, so we accept the (bounded) per-session
            // callback_data leak in that case.
            if (s.shuttingDown) {
                if (s->_rcClient) {
                    const char *m = "Request cancelled (shutting down)";
                    rc_api_server_response_t err = {
                        .body             = m,
                        .body_length      = strlen(m),
                        .http_status_code = RC_API_SERVER_RESPONSE_CLIENT_ERROR,
                    };
                    callback(&err, callbackData);
                }
                return;
            }

            if (hadError || !bodyCopy) {
                char errBuf[256] = {0};
                if (errMsg) {
                    const char *u = errMsg.UTF8String;
                    if (u) { strncpy(errBuf, u, sizeof(errBuf) - 1); }
                }
                rc_api_server_response_t err = {
                    .body             = errBuf,
                    .body_length      = strlen(errBuf),
                    .http_status_code = RC_API_SERVER_RESPONSE_RETRYABLE_CLIENT_ERROR,
                };
                callback(&err, callbackData);
                return;
            }
            if (!isHTTP) {
                const char *m = "Invalid HTTP response";
                rc_api_server_response_t err = {
                    .body             = m,
                    .body_length      = strlen(m),
                    .http_status_code = RC_API_SERVER_RESPONSE_RETRYABLE_CLIENT_ERROR,
                };
                callback(&err, callbackData);
                return;
            }
            rc_api_server_response_t resp = {
                .body             = (const char *)bodyCopy.bytes,
                .body_length      = bodyCopy.length,
                .http_status_code = (int)statusCode,
            };
            callback(&resp, callbackData);
        });
    }];

    [self _trackTask:task];
    [task resume];
}

- (void)_trackTask:(NSURLSessionTask *)task
{
    if (!task) { return; }
    [_tasksLock lock];
    [_inflightTasks addObject:task];
    [_tasksLock unlock];
}

- (void)_untrackTask:(NSURLSessionTask *)task
{
    if (!task) { return; }
    [_tasksLock lock];
    [_inflightTasks removeObject:task];
    [_tasksLock unlock];
}

#pragma mark - Start / shutdown

- (void)startWithROMPath:(NSString *)romPath
{
    if (_started) { return; }
    _started = YES;
    _romPath = [romPath copy];

    dispatch_sync(_serialQueue, ^{
        if (self->_rcClient) { return; }
        self->_rcClient = rc_client_create(oe_ra_bridge_read_memory, oe_ra_bridge_server_call);
        if (!self->_rcClient) { return; }

        rc_client_set_userdata(self->_rcClient, (__bridge void *)self);
        rc_client_set_event_handler(self->_rcClient, oe_ra_bridge_event_handler);
        rc_client_set_hardcore_enabled(self->_rcClient, self.hardcoreEnabled ? 1 : 0);
        rc_client_set_allow_background_memory_reads(self->_rcClient, 0);
        rc_client_enable_logging(self->_rcClient, RC_CLIENT_LOG_LEVEL_INFO, oe_ra_bridge_log);
    });

    __weak __typeof(self) weakSelf = self;

    _tokenObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:OERetroAchievementsTokenDidChangeNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        // Hop onto the serial queue — observers fire on the XPC notification
        // thread, which must never touch rc_client directly.
        __typeof(self) outer = weakSelf;
        if (!outer) { return; }
        NSString *token    = note.userInfo[OERetroAchievementsTokenKey];
        NSString *username = note.userInfo[OERetroAchievementsUsernameKey];
        dispatch_async(outer->_serialQueue, ^{
            __typeof(self) s = weakSelf;
            if (!s || s.shuttingDown || !s->_rcClient) { return; }
            if (token && username) {
                rc_client_begin_login_with_token(s->_rcClient,
                                                 username.UTF8String,
                                                 token.UTF8String,
                                                 oe_ra_bridge_login_cb,
                                                 (__bridge void *)s);
            } else {
                rc_client_logout(s->_rcClient);
            }
        });
    }];

    _hardcoreObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:OEHardcoreModeDidChangeNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        __typeof(self) outer = weakSelf;
        if (!outer) { return; }
        NSNumber *enabled = note.userInfo[OEHardcoreEnabledKey];
        if (!enabled) { return; }
        BOOL hc = enabled.boolValue;
        dispatch_async(outer->_serialQueue, ^{
            __typeof(self) s = weakSelf;
            if (!s || s.shuttingDown || !s->_rcClient) { return; }
            s.hardcoreEnabled = hc;
            rc_client_set_hardcore_enabled(s->_rcClient, hc ? 1 : 0);
        });
    }];
}

- (void)markROMReady
{
    self.romReady = YES;
}

- (void)setHashFileReader:(const struct rc_hash_filereader *)reader
{
    if (!reader) { return; }
    rc_hash_filereader_t copy = *reader;
    dispatch_sync(_serialQueue, ^{
        if (!self->_rcClient || self.shuttingDown) { return; }
        rc_hash_callbacks_t callbacks;
        memset(&callbacks, 0, sizeof(callbacks));
        callbacks.filereader = copy;
        rc_client_set_hash_callbacks(self->_rcClient, &callbacks);
    });
}

- (void)shutdown
{
    if (self.shuttingDown) { return; }
    self.shuttingDown = YES;

    // 1. Remove observers first so no new XPC notification slips through.
    if (_tokenObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_tokenObserver];
        _tokenObserver = nil;
    }
    if (_hardcoreObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_hardcoreObserver];
        _hardcoreObserver = nil;
    }

    // 2. Cancel in-flight URL tasks. Their completions will dispatch_async
    //    onto _serialQueue and check shuttingDown — they'll early-exit.
    NSSet *tasks;
    [_tasksLock lock];
    tasks = [_inflightTasks copy];
    [_inflightTasks removeAllObjects];
    [_tasksLock unlock];
    for (NSURLSessionTask *t in tasks) { [t cancel]; }
    [_urlSession invalidateAndCancel];

    // 3. Drain pending serial-queue work. After this returns, no further
    //    rc_client_* calls are in flight.
    //
    //    Re-entrance: if dealloc fires while we are already executing on
    //    _serialQueue (e.g. the last strong ref was held by a queued URL
    //    completion that finished and dropped its `s = weakSelf` strong),
    //    dispatch_sync to the queue we're already on would deadlock. The
    //    queue-specific tag lets us detect that and just run the destroy
    //    block inline. Idempotent shutdown protects against double-destroy.
    void (^destroyBlock)(void) = ^{
        if (self->_rcClient) {
            rc_client_unload_game(self->_rcClient);
            rc_client_destroy(self->_rcClient);
            self->_rcClient = NULL;
        }
    };
    if (dispatch_get_specific(kOERABridgeQueueKey) == (__bridge void *)self) {
        destroyBlock();
    } else {
        dispatch_sync(_serialQueue, destroyBlock);
    }
}

#pragma mark - Login + game-load callbacks

static void oe_ra_bridge_login_cb(int result, const char *error_message,
                                   rc_client_t *client, void *userdata)
{
    OERetroAchievementsBridge *bridge = (__bridge OERetroAchievementsBridge *)userdata;
    if (!bridge) { return; }
    if (result != RC_OK) {
        oeRetroAchievementsPostLoginFailure(result, error_message);
        os_log(OS_LOG_DEFAULT, "[RA-bridge] login failed — result=%d error=%{public}s",
               result, error_message ?: "(none)");
        return;
    }
    // Already on the serial queue (server call completion dispatched here).
    [bridge _beginLoadGame];
}

static void oe_ra_bridge_load_game_cb(int result, const char *error_message,
                                       rc_client_t *client, void *userdata)
{
    OERetroAchievementsBridge *bridge = (__bridge OERetroAchievementsBridge *)userdata;
    if (!bridge) { return; }
    if (result != RC_OK) {
        os_log(OS_LOG_DEFAULT, "[RA-bridge] game load failed — result=%d error=%{public}s",
               result, error_message ?: "(none)");
        oeRetroAchievementsPostSessionLoadFailure(result, error_message);
        return;
    }
    [bridge postSessionSnapshot];
}

- (void)_beginLoadGame
{
    if (!_rcClient || !_romPath || self.shuttingDown) { return; }
    rc_client_begin_identify_and_load_game(_rcClient,
                                           _consoleID,
                                           _romPath.fileSystemRepresentation,
                                           NULL, 0,
                                           oe_ra_bridge_load_game_cb,
                                           (__bridge void *)self);
}

#pragma mark - Frame loop hooks

- (void)doFrame
{
    if (self.shuttingDown) { return; }
    dispatch_sync(_serialQueue, ^{
        if (self->_rcClient && !self.shuttingDown) {
            rc_client_do_frame(self->_rcClient);
        }
    });
    // If an achievement triggered during this frame, rebuild the snapshot off
    // the game thread so we don't stall the next frame.
    if (_snapshotDirty) {
        _snapshotDirty = NO;
        [self postSessionSnapshot];
    }
}

- (void)idle
{
    if (self.shuttingDown) { return; }
    dispatch_sync(_serialQueue, ^{
        if (self->_rcClient && !self.shuttingDown) {
            rc_client_idle(self->_rcClient);
        }
    });
}

- (BOOL)canPauseWithFramesRemaining:(uint32_t *)framesRemaining
{
    if (self.shuttingDown) { return YES; }
    __block BOOL canPause = YES;
    __block uint32_t frames = 0;
    dispatch_sync(_serialQueue, ^{
        if (!self->_rcClient) { canPause = YES; return; }
        canPause = rc_client_can_pause(self->_rcClient, &frames) != 0;
    });
    if (framesRemaining) { *framesRemaining = frames; }
    return canPause;
}

- (void)reset
{
    if (self.shuttingDown) { return; }
    dispatch_sync(_serialQueue, ^{
        if (self->_rcClient && !self.shuttingDown) {
            rc_client_reset(self->_rcClient);
        }
    });
}

#pragma mark - Hardcore property

- (void)setHardcoreEnabled:(BOOL)hardcoreEnabled
{
    _hardcoreEnabled = hardcoreEnabled;
    if (self.shuttingDown) { return; }
    dispatch_async(_serialQueue, ^{
        if (self->_rcClient && !self.shuttingDown) {
            rc_client_set_hardcore_enabled(self->_rcClient, hardcoreEnabled ? 1 : 0);
        }
    });
}

#pragma mark - Save-state progress

- (NSData *)serializeProgress
{
    __block NSData *out = nil;
    if (self.shuttingDown) { return nil; }
    dispatch_sync(_serialQueue, ^{
        if (!self->_rcClient || self.shuttingDown) { return; }
        size_t size = rc_client_progress_size(self->_rcClient);
        if (size == 0) { return; }
        NSMutableData *data = [NSMutableData dataWithLength:size];
        if (rc_client_serialize_progress_sized(self->_rcClient, data.mutableBytes, size) != RC_OK) { return; }
        out = data;
    });
    return out;
}

- (void)deserializeProgress:(NSData *)data
{
    if (self.shuttingDown) { return; }
    if (!data) {
        os_log(OS_LOG_DEFAULT, "[RA-bridge] deserializeProgress: nil sidecar — rcheevos progress will reset for this load.");
    }
    NSData *snapshot = [data copy];
    dispatch_sync(_serialQueue, ^{
        if (!self->_rcClient || self.shuttingDown) { return; }
        if (snapshot) {
            rc_client_deserialize_progress_sized(self->_rcClient,
                                                 (const uint8_t *)snapshot.bytes,
                                                 snapshot.length);
        } else {
            rc_client_deserialize_progress_sized(self->_rcClient, NULL, 0);
        }
    });
}

#pragma mark - Snapshot publication

- (void)postSessionSnapshot
{
    if (self.shuttingDown) { return; }
    dispatch_async(_snapshotQueue, ^{
        [self _buildAndPostSnapshot];
    });
}

- (void)_buildAndPostSnapshot
{
    // Snapshot building reads rc_client extensively; it must run on the
    // serial queue to be safe vs. concurrent frame/observer mutations.
    __block NSDictionary *payload = nil;
    dispatch_sync(_serialQueue, ^{
        if (!self->_rcClient || self.shuttingDown) { return; }
        if (!rc_client_is_game_loaded(self->_rcClient)) { return; }
        payload = [self _snapshotPayloadLocked];
    });
    if (payload) {
        [[NSNotificationCenter defaultCenter] postNotificationName:OERASessionUpdatedNotification
                                                            object:nil
                                                          userInfo:payload];
    }
}

// Caller must hold the serial queue.
- (NSDictionary *)_snapshotPayloadLocked
{
    const rc_client_game_t *game = rc_client_get_game_info(_rcClient);
    if (!game || game->id == 0) { return nil; }

    rc_client_user_game_summary_t summary;
    memset(&summary, 0, sizeof(summary));
    rc_client_get_user_game_summary(_rcClient, &summary);

    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[OERAGameIDKey] = @(game->id);
    payload[OERAGameTitleKey] = @(game->title ?: "");
    payload[OERAGameHashKey] = @(game->hash ?: "");
    payload[OERAUnlockedCountKey] = @(summary.num_unlocked_achievements);
    payload[OERAAchievementCountKey] = @(summary.num_core_achievements);
    payload[OERAUnlockedPointsKey] = @(summary.points_unlocked);
    payload[OERATotalPointsKey] = @(summary.points_core);

    char gameImageURL[512] = {0};
    if (rc_client_game_get_image_url(game, gameImageURL, sizeof(gameImageURL)) == RC_OK) {
        payload[OERAGameBadgeURLKey] = @(gameImageURL);
    }

    NSMutableArray *sets = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, NSString *> *setTitlesByID = [NSMutableDictionary dictionary];
    rc_client_subset_list_t *subsetList = rc_client_create_subset_list(_rcClient);
    if (subsetList) {
        for (uint32_t i = 0; i < subsetList->num_subsets; i++) {
            const rc_client_subset_t *subset = subsetList->subsets[i];
            if (!subset) { continue; }
            NSString *subsetTitle = @(subset->title ?: "Achievement Set");
            NSNumber *subsetID = @(subset->id);
            setTitlesByID[subsetID] = subsetTitle;
            NSMutableDictionary *setInfo = [NSMutableDictionary dictionary];
            setInfo[OERASetIDKey] = subsetID;
            setInfo[OERASetTitleKey] = subsetTitle;
            setInfo[OERASetAchievementCountKey] = @(subset->num_achievements);
            setInfo[OERASetLeaderboardCountKey] = @(subset->num_leaderboards);
            if (subset->badge_url) { setInfo[OERASetBadgeURLKey] = @(subset->badge_url); }
            [sets addObject:setInfo];
        }
        rc_client_destroy_subset_list(subsetList);
    }
    if (sets.count == 0) {
        NSNumber *gameID = @(game->id);
        NSString *gameTitle = @(game->title ?: "Achievement Set");
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
            NSString *bucketTitle = @(bucket.label ?: "Achievements");
            for (uint32_t a = 0; a < bucket.num_achievements; a++) {
                const rc_client_achievement_t *ach = bucket.achievements[a];
                if (!ach) { continue; }
                NSNumber *subsetID = @(bucket.subset_id);
                NSMutableDictionary *entry = [NSMutableDictionary dictionary];
                entry[OERASetIDKey] = subsetID;
                entry[OERASetTitleKey] = setTitlesByID[subsetID] ?: @(game->title ?: "Achievement Set");
                entry[OERABucketTitleKey] = bucketTitle;
                entry[OERABucketTypeKey] = @(bucket.bucket_type);
                entry[OEAchievementIDKey] = @(ach->id);
                entry[OEAchievementTitleKey] = @(ach->title ?: "");
                entry[OEAchievementDescriptionKey] = @(ach->description ?: "");
                entry[OEAchievementPointsKey] = @(ach->points);
                entry[OERAStateKey] = @(ach->state);
                entry[OERATypeKey] = @(ach->type);
                entry[OERAUnlockedKey] = @(ach->unlocked);
                entry[OERARarityKey] = @(ach->rarity);
                entry[OERAHardcoreRarityKey] = @(ach->rarity_hardcore);
                entry[OERAMeasuredPercentKey] = @(ach->measured_percent);
                entry[OERAMeasuredProgressKey] = @(ach->measured_progress ?: "");
                if (ach->badge_url)         { entry[OEAchievementBadgeURLKey] = @(ach->badge_url); }
                if (ach->badge_locked_url)  { entry[OERABadgeLockedURLKey]    = @(ach->badge_locked_url); }
                [achievements addObject:entry];
            }
        }
        rc_client_destroy_achievement_list(list);
    }
    payload[OERAAchievementsKey] = achievements;
    return payload;
}

@end
