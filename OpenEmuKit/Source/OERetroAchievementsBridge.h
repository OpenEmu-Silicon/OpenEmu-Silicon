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

#ifndef OERetroAchievementsBridge_h
#define OERetroAchievementsBridge_h

#import <Foundation/Foundation.h>
#ifndef RC_CLIENT_SUPPORTS_HASH
#define RC_CLIENT_SUPPORTS_HASH 1
#endif
#include <rc_client.h>

@class OEGameCore;
struct rc_hash_filereader;

NS_ASSUME_NONNULL_BEGIN

/// Per-core memory reader signature. Same prototype rcheevos uses.
/// Implementations may assume the bridge has already gated for ROM readiness
/// and shutdown, and that the call is serialized on the bridge queue.
typedef uint32_t (*OERetroAchievementsMemoryReader)(uint32_t address,
                                                    uint8_t  *buffer,
                                                    uint32_t  num_bytes,
                                                    rc_client_t *client);

/// Owns an rc_client per game-core instance and serializes every interaction
/// with it. All mutation of rc_client state happens on an internal serial
/// queue; observers and URL-session completions hop onto that queue before
/// touching the client. Replaces the inline RA wiring previously copied across
/// each RA-enabled core.
@interface OERetroAchievementsBridge : NSObject

/// Designated initializer.
/// - core: the owning OEGameCore. Held weakly internally except for the
///         duration of in-flight async login/load callbacks. Each per-core
///         reader can read `bridge.core` if it needs core-specific state.
/// - reader: function pointer to the per-core memory reader. Bridge wraps
///           this with a ROM-ready/shutdown gate before invoking.
/// - consoleID: RC_CONSOLE_* value used by `rc_client_begin_identify_and_load_game`.
- (instancetype)initWithGameCore:(OEGameCore *)core
                    memoryReader:(OERetroAchievementsMemoryReader)reader
                       consoleID:(uint32_t)consoleID NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// The owning game core. Per-core memory readers retrieve this via
/// `(__bridge OERetroAchievementsBridge *)rc_client_get_userdata(client)`
/// and then `bridge.core`. Held weakly.
@property (nonatomic, weak, readonly, nullable) OEGameCore *core;

/// YES once `markROMReady` has been called. The memory reader returns 0
/// until this becomes true. The setter on this is for the bridge itself.
@property (atomic, readonly) BOOL romReady;

/// YES while a shutdown is in progress. Memory reader and server-call
/// trampoline both short-circuit when this is set.
@property (atomic, readonly) BOOL shuttingDown;

/// Mirrors the user's hardcore preference. Setter dispatches
/// `rc_client_set_hardcore_enabled` onto the serial queue.
@property (atomic, assign) BOOL hardcoreEnabled;

/// Start the bridge: create rc_client, install hardcore + background-reads
/// flags, register token/hardcore observers, kick off a login if a token is
/// already cached. Safe to call from any thread. Idempotent — second calls
/// are no-ops.
- (void)startWithROMPath:(NSString *)romPath;

/// Mark ROM data as ready to be read by rcheevos. Cores must call this after
/// their `Memory.LoadROM`/equivalent succeeds — before this, the memory
/// reader returns 0 for everything.
- (void)markROMReady;

/// Install a custom rcheevos hash file reader on the underlying rc_client, so a
/// core can present a compressed image (e.g. PSP CSO) to rcheevos as a plain
/// stream during game identification. Must be called after `startWithROMPath:`
/// and before identification runs; the bridge only keeps rcheevos's default
/// cdreader, which reads through this file reader. No-op if the client is gone.
- (void)setHashFileReader:(const struct rc_hash_filereader *)reader;

/// Cancel in-flight URL tasks, drain pending serial-queue work, remove
/// observers, and destroy rc_client. Safe to call from any thread.
/// Subsequent calls are no-ops.
- (void)shutdown;

/// Wraps `rc_client_do_frame`. Must be called from the game-core thread.
- (void)doFrame;

/// Wraps `rc_client_idle`. Must be called from the game-core thread.
- (void)idle;

/// Wraps `rc_client_can_pause`. Returns YES if no client exists.
- (BOOL)canPauseWithFramesRemaining:(uint32_t *)framesRemaining;

/// Wraps `rc_client_reset`.
- (void)reset;

/// Serializes rcheevos progress for save-state sidecar storage (softcore only).
/// Returns nil if no client / nothing to serialize / rc_client returns an error.
- (nullable NSData *)serializeProgress;

/// Restores rcheevos progress from save-state sidecar (softcore only).
/// `data` may be nil — in that case rcheevos is told to reset progress
/// (matches `_postRetroAchievementsSessionSnapshot` semantics).
- (void)deserializeProgress:(nullable NSData *)data;

/// Publish a session snapshot to the host (achievements list + summary).
/// Cores call this in their `_postRetroAchievementsSessionSnapshot`-equivalent
/// hooks. Free-threaded — internally dispatches to a background queue.
- (void)postSessionSnapshot;

@end

NS_ASSUME_NONNULL_END

#endif /* OERetroAchievementsBridge_h */
