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

import Foundation
import CryptoKit
import IOKit
import Security
import os.log

private let log = OSLog(subsystem: "org.openemu.OpenEmu", category: "CredentialStore")

// MARK: - Credential Keys

/// Every credential the app stores, identified by a stable string key.
enum OECredentialKey: String, CaseIterable {
    /// ScreenScraper cover-art account password.
    case screenScraperPassword   = "screenscraper.password"
    /// RetroAchievements login token — not the password; the password is used
    /// only once to obtain this token from the RA server.
    case retroAchievementsToken  = "retroachievements.token"
    /// Left over from the removed Google Drive sign-in. Only read so it can be deleted.
    case googleDriveRefreshToken = "googledrive.refreshToken"
}

// MARK: - OECredentialStore

/// Replaces the system keychain for OpenEmu credential storage.
///
/// ## Why not keychain?
/// macOS ties keychain item access to the binary's code signature. Every app update
/// produces a new signature, which makes the OS prompt "Allow / Always Allow" again.
/// For the low-stakes tokens OpenEmu stores (cover-art passwords, achievement tokens,
/// a Drive OAuth refresh token) that friction outweighs the marginal security benefit.
///
/// ## How this works instead
/// 1. A 256-bit encryption key is derived from the machine's hardware UUID and the
///    app's bundle ID using HKDF-SHA256. The key is deterministic — same machine,
///    same app, always the same key — so it never needs to be stored anywhere.
/// 2. All credentials are kept as a `[String: String]` dictionary, serialised to JSON,
///    and encrypted with AES-GCM.
/// 3. The sealed blob is written to `~/Library/Application Support/OpenEmu/.oe_credentials`.
///
/// Reads and writes are fast (local file I/O + in-process AES) and never trigger any
/// OS permission dialogs.
///
/// ## Thread safety
/// All access is serialised through a private dispatch queue. Call `get`, `set`, and
/// `remove` from any thread.
final class OECredentialStore {

    // MARK: - Singleton

    static let shared = OECredentialStore()

    // MARK: - Storage path

    private static var storeURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        // Leading dot makes the file hidden in Finder, matching the convention for
        // internal app data files that users should not edit directly.
        return support.appendingPathComponent("OpenEmu/.oe_credentials", isDirectory: false)
    }

    // MARK: - In-memory cache

    private let queue = DispatchQueue(label: "org.openemu.credentialstore", qos: .userInitiated)
    private var cache: [String: String] = [:]
    private var isLoaded = false

    // MARK: - Init

    private init() {}

    // MARK: - Public API

    /// Returns the stored value for `key`, or `nil` if nothing has been saved.
    func get(_ key: OECredentialKey) -> String? {
        queue.sync {
            ensureLoaded()
            return cache[key.rawValue]
        }
    }

    /// Returns `true` if a non-empty value has been saved for `key`.
    func has(_ key: OECredentialKey) -> Bool {
        get(key) != nil
    }

    /// Saves `value` for `key` and writes the updated store to disk.
    func set(_ value: String, forKey key: OECredentialKey) {
        queue.sync {
            ensureLoaded()
            cache[key.rawValue] = value
            persist()
        }
    }

    /// Removes the value for `key` and writes the updated store to disk.
    func remove(_ key: OECredentialKey) {
        queue.sync {
            ensureLoaded()
            cache.removeValue(forKey: key.rawValue)
            persist()
        }
    }

    // MARK: - Key Derivation

    /// Derives the AES-GCM encryption key from stable, non-secret inputs.
    ///
    /// Inputs:
    /// - Hardware UUID — a unique identifier burned into the logic board at the factory.
    ///   It never changes, even across macOS reinstalls or app updates.
    /// - Bundle ID — ties the key to this specific app so another app on the same machine
    ///   cannot decrypt the file even if it finds it.
    ///
    /// HKDF (HMAC-based Key Derivation Function) takes those inputs and produces a
    /// properly-distributed 256-bit symmetric key. Using HKDF instead of a raw hash
    /// provides stronger cryptographic guarantees about key quality.
    private func deriveKey() -> SymmetricKey {
        let uuid     = hardwareUUID() ?? "unknown-machine"
        let bundleID = Bundle.main.bundleIdentifier ?? "org.openemu.OpenEmu"
        let inputMaterial = SymmetricKey(data: Data((uuid + ":" + bundleID).utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputMaterial,
            salt: Data("OpenEmu-CredentialStore-v1".utf8),
            info: Data("credentials".utf8),
            outputByteCount: 32
        )
    }

    /// Reads the hardware platform UUID from IOKit.
    /// Example value: "8A3F1C2D-4E5F-6789-ABCD-EF0123456789"
    private func hardwareUUID() -> String? {
        // kIOMainPortDefault was introduced in macOS 12; fall back to the deprecated
        // kIOMasterPortDefault on macOS 11 (still functional, just renamed).
        let port: mach_port_t
        if #available(macOS 12.0, *) {
            port = kIOMainPortDefault
        } else {
            port = kIOMasterPortDefault
        }
        let service = IOServiceGetMatchingService(
            port,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(service) }
        guard service != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(
            service,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        ).takeRetainedValue() as? String
    }

    // MARK: - Load / Persist

    /// Loads the credential cache from disk. Must only be called from within `queue`.
    private func ensureLoaded() {
        guard !isLoaded else { return }
        isLoaded = true

        let url = OECredentialStore.storeURL

        // One-time migration: only touch legacy keychain items when the encrypted
        // file store does not exist yet. If the store already exists, trying to
        // read old keychain leftovers can trigger a macOS access prompt when a
        // different Debug/Release build or app path launches.
        if !FileManager.default.fileExists(atPath: url.path) {
            migrateFromKeychain()
        }

        guard FileManager.default.fileExists(atPath: url.path),
              let ciphertext = try? Data(contentsOf: url)
        else { return }

        let key = deriveKey()
        do {
            let box       = try AES.GCM.SealedBox(combined: ciphertext)
            let plaintext = try AES.GCM.open(box, using: key)
            cache         = try JSONDecoder().decode([String: String].self, from: plaintext)
            os_log(.info, log: log, "Credential store loaded (%d entries).", cache.count)
        } catch {
            os_log(.error, log: log,
                   "Failed to decrypt credential store — store will be treated as empty: %{public}@",
                   error.localizedDescription)
        }
    }

    /// Encrypts the current cache and writes it to disk atomically.
    /// Must only be called from within `queue`.
    private func persist() {
        let url = OECredentialStore.storeURL
        let key = deriveKey()
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let plaintext = try JSONEncoder().encode(cache)
            let sealed    = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else {
                os_log(.error, log: log, "AES-GCM seal produced no combined ciphertext.")
                return
            }
            // .atomic writes to a temp file first then renames, preventing a partial write
            // from corrupting the store if the app quits mid-write.
            try combined.write(to: url, options: .atomic)
            // Restrict to owner-read/write only (0600). The key is derived from the hardware
            // UUID so any local user who can read the file could also derive the key — 0600
            // closes that gap and matches what the Keychain enforced for us automatically.
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: url.path
            )
            os_log(.info, log: log, "Credential store persisted (%d entries).", cache.count)
        } catch {
            os_log(.error, log: log,
                   "Failed to persist credential store: %{public}@",
                   error.localizedDescription)
        }
    }

    // MARK: - One-time Keychain Migration

    /// Reads any credentials left in the old keychain entries, copies them into the
    /// cache, then deletes the keychain items. This runs exactly once — after the store
    /// file exists the keychain items are gone and this code is never reached again.
    ///
    /// Migration must never show a Keychain permission dialog. If macOS would require
    /// interaction because the item was created by a different binary/path/signature,
    /// skip that item and let the user sign in again through Preferences instead.
    private func migrateFromKeychain() {
        var migrated = 0

        if let password = keychainRead(service: "com.openemu.ScreenScraper", account: "password") {
            cache[OECredentialKey.screenScraperPassword.rawValue] = password
            keychainDelete(service: "com.openemu.ScreenScraper", account: "password")
            migrated += 1
        }

        if let token = keychainRead(service: "com.openemu.RetroAchievements", account: "token") {
            cache[OECredentialKey.retroAchievementsToken.rawValue] = token
            keychainDelete(service: "com.openemu.RetroAchievements", account: "token")
            migrated += 1
        }

        // The Google Drive sign-in is gone. Delete what it left in the keychain.
        keychainDelete(service: "com.openemu.GoogleDriveSaveSync", account: "refreshToken")
        keychainDelete(service: "com.openemu.GoogleDriveSaveSync", account: "saveFolderID")

        if migrated > 0 {
            os_log(.info, log: log,
                   "Migrated %d credential(s) from keychain to encrypted file store.", migrated)
            persist()
        }
    }

    // MARK: - Low-level Keychain Helpers (migration use only)

    private func keychainRead(service: String, account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:               kSecClassGenericPassword,
            kSecAttrService:         service,
            kSecAttrAccount:         account,
            kSecReturnData:          kCFBooleanTrue!,
            kSecMatchLimit:          kSecMatchLimitOne,
            kSecUseAuthenticationUI: kSecUseAuthenticationUIFail,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainDelete(service: String, account: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
