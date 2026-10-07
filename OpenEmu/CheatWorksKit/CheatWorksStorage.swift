// Copyright (c) 2026, CheatWorks Team
// Author: Leonardo Kasperavičius
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the CheatWorks Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY CheatWorks Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL CheatWorks Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

// Part of the portable CheatWorks Integration SDK core — no host dependencies.

import Foundation
import CryptoKit

/// On-device key-value storage for the SDK's durable state (installation token, revocation flag).
/// Hosts may inject a custom implementation; the SDK ships an encrypted-file default.
public protocol CheatWorksStorage: Sendable {
    func string(forKey key: String) -> String?
    /// Sets a value, or removes it when `value` is `nil`.
    func setString(_ value: String?, forKey key: String)
}

/// Default storage: an AES-GCM-encrypted JSON file under Application Support. The encryption key
/// is derived (HKDF-SHA256) from the Mac's hardware UUID and the app bundle id, so it is stable
/// per machine+app and is never itself stored. This avoids the Keychain's code-signature
/// re-authorization prompts that recur on every app update.
public final class CheatWorksFileStorage: CheatWorksStorage, @unchecked Sendable {

    private let fileURL: URL
    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private var loaded = false

    /// - Parameter fileURL: override the store location; defaults to
    ///   `Application Support/<bundleID>/CheatWorks/.cheatworks_store`.
    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let bundleID = Bundle.main.bundleIdentifier ?? "org.cheatworks.client"
            self.fileURL = support
                .appendingPathComponent(bundleID, isDirectory: true)
                .appendingPathComponent("CheatWorks", isDirectory: true)
                .appendingPathComponent(".cheatworks_store", isDirectory: false)
        }
    }

    public func string(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return cache[key]
    }

    public func setString(_ value: String?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        if let value {
            cache[key] = value
        } else {
            cache.removeValue(forKey: key)
        }
        persist()
    }

    // MARK: - Crypto + IO

    /// Derives the AES-GCM key from stable, non-secret inputs; the raw hardware UUID never leaves
    /// the device and the key is never persisted.
    private func encryptionKey() -> SymmetricKey {
        let uuid = CheatWorksHardware.platformUUID() ?? "unknown-machine"
        let bundleID = Bundle.main.bundleIdentifier ?? "org.cheatworks.client"
        let inputMaterial = SymmetricKey(data: Data("\(uuid):\(bundleID)".utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputMaterial,
            salt: Data("CheatWorks-Storage-v1".utf8),
            info: Data("cheatworks".utf8),
            outputByteCount: 32
        )
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: encryptionKey()),
              let dict = try? JSONDecoder().decode([String: String].self, from: plain)
        else { return }
        cache = dict
    }

    private func persist() {
        guard let plain = try? JSONEncoder().encode(cache),
              let sealed = try? AES.GCM.seal(plain, using: encryptionKey()).combined
        else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? sealed.write(to: fileURL, options: .atomic)
    }
}
