// Copyright (c) 2026, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import CryptoKit
import Foundation
import OpenEmuBase
internal import os.log

/// The user default that lets Archipelago clients connect to a running game. Off unless the user turns it on.
/// The helper reads it when a game starts.
public let ArchipelagoConnectionsEnabledKey = "archipelagoConnectionsEnabled"

/// The running core, seen as `LiveMemory`. Use only inside `performLiveMemoryTransaction`.
final class GameCoreLiveMemory: LiveMemory {
    private let core: OEGameCore

    init(core: OEGameCore) {
        self.core = core
    }

    var platform: String? { core.liveMemoryPlatform() }

    var areaNames: [String] { core.liveMemoryAreaNames() }

    func size(of area: String) -> Int? {
        let size = core.size(ofLiveMemoryArea: area)
        if size > 0 { return Int(size) }
        return areaNames.contains(area) ? 0 : nil
    }

    func read(_ area: String, at address: UInt64, count: Int) -> [UInt8]? {
        guard count > 0 else { return areaNames.contains(area) ? [] : nil }
        var bytes = [UInt8](repeating: 0, count: count)
        let known = bytes.withUnsafeMutableBufferPointer { buffer in
            core.readLiveMemoryArea(area, offset: address, length: UInt(count), into: buffer.baseAddress!)
        }
        return known ? bytes : nil
    }

    func write(_ area: String, at address: UInt64, bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return areaNames.contains(area) }
        return bytes.withUnsafeBufferPointer { buffer in
            core.writeLiveMemoryArea(area, offset: address, bytes: buffer.baseAddress!, length: UInt(buffer.count))
        }
    }
}

/// Lets Archipelago clients read and write the running game's memory. There is one per running game.
///
/// This is the part every client protocol shares: it runs lists of memory steps between two frames,
/// pauses the game for LOCK, and refuses clients while RetroAchievements hardcore is enforced.
/// Each protocol's own listener (`BizHawkClientListener`, later PolyEmu) sits on top.
final class ArchipelagoConnections: @unchecked Sendable {

    static var isEnabled: Bool {
        UserDefaults.oe_application.bool(forKey: ArchipelagoConnectionsEnabledKey)
    }

    /// How long a LOCK may stop the game before it starts again on its own, as in BizHawk's connector.
    private static let lockTimeout: TimeInterval = 2

    private let queue = DispatchQueue(label: "org.openemu.archipelago")
    private let core: OEGameCore
    private let memory: GameCoreLiveMemory
    private let romURL: URL
    private let romMD5: String?

    // Owned by `queue`.
    private var hardcoreEnabled: Bool
    private var bizHawkListener: BizHawkClientListener?
    private var lockGeneration = 0
    private var stopped = false

    // Owned by the emulation thread: only touched inside performLiveMemoryTransaction.
    private var pausedByLock = false

    init(core: OEGameCore, romURL: URL, hardcoreEnabled: Bool) {
        self.core = core
        self.memory = GameCoreLiveMemory(core: core)
        self.romURL = romURL
        self.romMD5 = core.romMD5
        self.hardcoreEnabled = hardcoreEnabled
    }

    /// Starts listening if the core supports live memory. Safe to call from any thread.
    func start() {
        core.performLiveMemoryTransaction { [self] in
            let platform = memory.platform
            let supported = platform != nil && !memory.areaNames.isEmpty
            queue.async { [self] in
                guard supported, !stopped else {
                    os_log(.info, log: .archipelago, "This core does not support Archipelago connections")
                    return
                }
                let codec = BizHawkClientCodec(romHash: romHash())
                let listener = BizHawkClientListener(queue: queue, codec: codec, connections: self)
                bizHawkListener = listener
                listener.start()
                os_log(.info, log: .archipelago, "Archipelago connections on for platform %{public}@", platform ?? "?")
            }
        }
    }

    /// Call before the core stops. Synchronous, so no list of steps can be queued on the core after this returns.
    func stop() {
        queue.sync { [self] in
            stopped = true
            bizHawkListener?.stop()
            bizHawkListener = nil
        }
        releaseLock()
    }

    func setHardcoreEnabled(_ enabled: Bool) {
        queue.async { [self] in
            hardcoreEnabled = enabled
            if !acceptsClients {
                os_log(.info, log: .archipelago, "Hardcore mode is on: dropping Archipelago clients")
                bizHawkListener?.dropClient()
            }
        }
    }

    // MARK: - Used by listeners, on `queue`

    /// Whether a client may connect or keep its connection right now.
    var acceptsClients: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return !stopped && HardcoreModePolicy.allows(.liveMemoryAccess, hardcoreEnabled: hardcoreEnabled)
    }

    /// Runs the steps between two frames, then calls back on `queue` with one result per step.
    func run(_ operations: [LiveMemoryOperation], completion: @escaping ([LiveMemoryResult]) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { return }

        core.performLiveMemoryTransaction { [self] in
            let outcome = LiveMemoryChain.run(operations, on: memory)
            applyLockRequest(outcome.lockRequest)
            queue.async { [self] in
                for message in outcome.messages {
                    os_log(.info, log: .archipelago, "Message: %{public}@", message)
                }
                if outcome.lockRequest == true {
                    scheduleLockTimeout()
                }
                completion(outcome.results)
            }
        }
    }

    /// A client went away: never leave the game stopped behind it.
    func clientDisconnected() {
        releaseLock()
    }

    // MARK: - Lock

    /// The player paused or unpaused the game. Runs on the emulation thread.
    /// The pause is theirs from now on: a later UNLOCK leaves it alone, and a later LOCK can pause again.
    func playerChangedPause() {
        pausedByLock = false
    }

    /// Runs on the emulation thread.
    private func applyLockRequest(_ request: Bool?) {
        switch request {
        case true?:
            if !pausedByLock && !core.isEmulationPaused {
                core.setPauseEmulation(true)
                pausedByLock = true
            }
        case false?:
            if pausedByLock {
                core.setPauseEmulation(false)
                pausedByLock = false
            }
        case nil:
            break
        }
    }

    private func scheduleLockTimeout() {
        lockGeneration += 1
        let generation = lockGeneration
        queue.asyncAfter(deadline: .now() + Self.lockTimeout) { [self] in
            guard generation == lockGeneration, !stopped else { return }
            releaseLock()
        }
    }

    private func releaseLock() {
        core.performLiveMemoryTransaction { [self] in
            applyLockRequest(false)
        }
    }

    // MARK: - ROM identity

    /// Uppercase SHA-1 of the ROM file, which is what BizHawk reports for most systems.
    /// Archipelago only checks that it stays the same, so fall back to the MD5 OpenEmu already has.
    private func romHash() -> String {
        if let data = try? Data(contentsOf: romURL, options: .mappedIfSafe) {
            return Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
        }
        return (romMD5 ?? "").uppercased()
    }
}
