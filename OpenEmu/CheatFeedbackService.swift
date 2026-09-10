// Copyright (c) 2026, OpenEmu Team
// Author: Leonardo Kasperavičius
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
import os.log

// private let log = Logger(subsystem: "org.openemu.OpenEmu", category: "CheatFeedbackService")

/// Whether a cheat code worked for the user on a specific core build.
///
/// `unknown` is an explicit user signal ("I don't know" / retracting a report),
/// distinct from a `nil` status on the entry, which means no report was ever made
/// (e.g. a note-only entry). Keeping them separate matters for the "did this cheat
/// work?" prompt and the ranking service this feeds later.
enum CheatFeedbackStatus: String, Codable, Sendable {
    case works
    case doesNotWork
    case unknown
}

/// One entry, scoped to the core build it was made against. Carries a report
/// (`status`), a note, or both — a note alone leaves `status` nil so it isn't
/// mistaken for a report.
struct CheatFeedbackEntry: Codable, Sendable {
    /// Whitespace-stripped, lowercased — matches how `CheatDatabaseService` deduplicates.
    let code: String
    let coreIdentifier: String
    let coreVersion: String
    /// `nil` when the user has only left a note and never reported efficacy.
    let status: CheatFeedbackStatus?
    /// User-authored, freeform. `nil`/absent for existing files predating this field.
    var notes: String?
    /// Unmodified text as published by the provider, before normalization. Not shown to the
    /// user; kept so a future central feedback service can key on the upstream cheat rather
    /// than on OpenEmu's own normalized encoding, which can change between versions.
    var rawCode: String?
    /// The `CheatDatabaseProvider.name` this code came from (e.g. "Libretro"). `nil` for
    /// manual/Cheat Search entries, which have no upstream provider.
    var provider: String?
    let updatedAt: Date
}

private struct CheatFeedbackFile: Codable {
    var schemaVersion: Int
    var md5: String
    /// Kept alongside the folder structure so a file is self-describing if ever handled
    /// independently of its `CheatFeedback/<systemIdentifier>/` location. Optional only so
    /// files predating this field still decode; every write path fills it in from context.
    var systemIdentifier: String?
    /// Best-effort, for identifying the game if its MD5 no longer resolves (e.g. re-dumped ROM).
    var gameName: String?
    /// Cartridge/disc serial, a second fallback identifier alongside MD5 \u2014 same role it already
    /// plays as a DAT lookup fallback in `LibretroCheatProvider`. Backfillable during migration
    /// since it's already stored on the ROM in the library, independent of any game/core running.
    var serial: String?
    /// RetroAchievements' own per-console game hash. Unlike `serial`, this is computed inside the
    /// core at runtime from the loaded ROM, so it can only ever be captured at write time \u2014 never
    /// backfilled during migration, which runs before any game or core exists.
    var raHash: String?
    var entries: [CheatFeedbackEntry]
}

/// Tracks whether the one-time file migration (see `CheatFeedbackService.migrateIfNeeded()`)
/// has already run, so app startup doesn't re-walk every feedback file on every launch.
private struct CheatFeedbackMigrationConfig: Codable {
    var schemaVersion: Int
}

/// Stores the user's "does this cheat work" reports, separate from their cheat
/// inventory so deleting a cheat never discards the report.
///
/// Reports are scoped to a core build: a different core, or a new version of the
/// same core, starts with a clean slate. Superseded entries are deliberately kept
/// — they are the history a future central ranking service would be built from.
final class CheatFeedbackService {

    static let shared = CheatFeedbackService()

    /// v2 added `rawCode`/`provider` per entry and `gameName`/`systemIdentifier` per file.
    /// See `migrateIfNeeded()` for the one-time reconciliation of files predating this.
    private static let schemaVersion = 2

    private let fileManager = FileManager.default

    /// Normalizes a raw cheat code into the key used for lookups.
    static func key(for code: String) -> String {
        code.replacingOccurrences(of: " ", with: "").lowercased()
    }

    // MARK: - Reading

    /// Reports for the given core build only, keyed by normalized code.
    func statuses(forMD5 md5: String,
                  systemIdentifier: String,
                  coreIdentifier: String,
                  coreVersion: String) -> [String: CheatFeedbackStatus] {
        let entries = load(md5: md5, systemIdentifier: systemIdentifier)?.entries ?? []

        var result: [String: CheatFeedbackStatus] = [:]
        for entry in entries where entry.coreIdentifier == coreIdentifier && entry.coreVersion == coreVersion {
            // Skip note-only entries (nil status) so they don't read as a report.
            if let status = entry.status { result[entry.code] = status }
        }
        return result
    }

    /// Every report ever made for a code, newest first. Intended for showing the
    /// user what they reported on earlier core versions.
    func history(forMD5 md5: String, systemIdentifier: String, code: String) -> [CheatFeedbackEntry] {
        let key = Self.key(for: code)
        let entries = load(md5: md5, systemIdentifier: systemIdentifier)?.entries ?? []
        return entries
            .filter { $0.code == key }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Notes for the given core build only, keyed by normalized code. Empty notes are never stored.
    func notes(forMD5 md5: String,
               systemIdentifier: String,
               coreIdentifier: String,
               coreVersion: String) -> [String: String] {
        let entries = load(md5: md5, systemIdentifier: systemIdentifier)?.entries ?? []

        var result: [String: String] = [:]
        for entry in entries where entry.coreIdentifier == coreIdentifier && entry.coreVersion == coreVersion {
            if let notes = entry.notes, !notes.isEmpty {
                result[entry.code] = notes
            }
        }
        return result
    }

    // MARK: - Writing

    /// Records a report, replacing any previous one for the same code and core build.
    /// Existing notes for that code/build are carried over untouched.
    func setStatus(_ status: CheatFeedbackStatus,
                   forCode code: String,
                   md5: String,
                   systemIdentifier: String,
                   coreIdentifier: String,
                   coreVersion: String,
                   rawCode: String? = nil,
                   provider: String? = nil,
                   gameName: String? = nil,
                   serial: String? = nil,
                   raHash: String? = nil) {
        let key = Self.key(for: code)
        var file = load(md5: md5, systemIdentifier: systemIdentifier)
            ?? CheatFeedbackFile(schemaVersion: Self.schemaVersion, md5: md5, systemIdentifier: systemIdentifier, gameName: gameName, serial: serial, raHash: raHash, entries: [])
        file.systemIdentifier = systemIdentifier
        file.gameName = gameName ?? file.gameName
        file.serial = serial ?? file.serial
        file.raHash = raHash ?? file.raHash

        let existing = file.entries.first {
            $0.code == key && $0.coreIdentifier == coreIdentifier && $0.coreVersion == coreVersion
        }

        file.entries.removeAll {
            $0.code == key && $0.coreIdentifier == coreIdentifier && $0.coreVersion == coreVersion
        }

        file.entries.append(CheatFeedbackEntry(code: key,
                                               coreIdentifier: coreIdentifier,
                                               coreVersion: coreVersion,
                                               status: status,
                                               notes: existing?.notes,
                                               rawCode: rawCode ?? existing?.rawCode,
                                               provider: provider ?? existing?.provider,
                                               updatedAt: Date()))

        save(file, md5: md5, systemIdentifier: systemIdentifier)
    }

    /// Records a personal note, replacing any previous one for the same code and core build.
    /// A note never creates a report: an existing status is carried over, otherwise status stays nil.
    /// `nil`/empty removes the note (and the whole entry if it had no status).
    func setNotes(_ notes: String?,
                  forCode code: String,
                  md5: String,
                  systemIdentifier: String,
                  coreIdentifier: String,
                  coreVersion: String,
                  rawCode: String? = nil,
                  provider: String? = nil,
                  gameName: String? = nil,
                  serial: String? = nil,
                  raHash: String? = nil) {
        let key = Self.key(for: code)
        var file = load(md5: md5, systemIdentifier: systemIdentifier)
            ?? CheatFeedbackFile(schemaVersion: Self.schemaVersion, md5: md5, systemIdentifier: systemIdentifier, gameName: gameName, serial: serial, raHash: raHash, entries: [])
        file.systemIdentifier = systemIdentifier
        file.gameName = gameName ?? file.gameName
        file.serial = serial ?? file.serial
        file.raHash = raHash ?? file.raHash

        let existing = file.entries.first {
            $0.code == key && $0.coreIdentifier == coreIdentifier && $0.coreVersion == coreVersion
        }

        file.entries.removeAll {
            $0.code == key && $0.coreIdentifier == coreIdentifier && $0.coreVersion == coreVersion
        }

        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newNotes = (trimmed?.isEmpty ?? true) ? nil : trimmed

        // Don't persist an empty shell that has neither a status nor a note.
        if existing?.status != nil || newNotes != nil {
            file.entries.append(CheatFeedbackEntry(code: key,
                                                   coreIdentifier: coreIdentifier,
                                                   coreVersion: coreVersion,
                                                   status: existing?.status,
                                                   notes: newNotes,
                                                   rawCode: rawCode ?? existing?.rawCode,
                                                   provider: provider ?? existing?.provider,
                                                   updatedAt: Date()))
        }

        save(file, md5: md5, systemIdentifier: systemIdentifier)
    }

    // MARK: - Storage

    /// Mirrors the `CheatDatabase/` layout so feedback sits beside the cached
    /// provider data, one folder per system.
    private func fileURL(md5: String, systemIdentifier: String) -> URL? {
        guard let base = OELibraryDatabase.default?.databaseFolderURL else { return nil }
        return base
            .appendingPathComponent("CheatFeedback", isDirectory: true)
            .appendingPathComponent(systemIdentifier, isDirectory: true)
            .appendingPathComponent("\(md5.uppercased()).json")
    }

    private func feedbackRootURL() -> URL? {
        OELibraryDatabase.default?.databaseFolderURL.appendingPathComponent("CheatFeedback", isDirectory: true)
    }

    private func load(md5: String, systemIdentifier: String) -> CheatFeedbackFile? {
        guard let url = fileURL(md5: md5, systemIdentifier: systemIdentifier),
              let data = try? Data(contentsOf: url)
        else { return nil }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(CheatFeedbackFile.self, from: data)
        } catch {
            // log.error("Failed to read cheat feedback for \(md5): \(error.localizedDescription)")
            return nil
        }
    }

    private func save(_ file: CheatFeedbackFile, md5: String, systemIdentifier: String) {
        guard let url = fileURL(md5: md5, systemIdentifier: systemIdentifier) else { return }

        do {
            // Created here rather than when resolving the URL, so reads leave no folders behind.
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: url, options: .atomic)
        } catch {
            // log.error("Failed to write cheat feedback for \(md5): \(error.localizedDescription)")
        }
    }

    // MARK: - Migration

    /// One-time reconciliation for files written before `rawCode`/`provider`/`gameName`/
    /// `systemIdentifier` existed. Must be called before any game can load, so the still-cached
    /// provider databases on disk reflect whatever normalization produced the original entries,
    /// before this session gets a chance to refresh them (e.g. via an ETag-driven re-download).
    ///
    /// Synchronous by design: negligible cost at current scale (few users, few systems, few
    /// feedback files), and it avoids any race with game loading altogether.
    func migrateIfNeeded() {
        guard let root = feedbackRootURL() else { return }
        let configURL = root.appendingPathComponent("config.json")

        var config = loadMigrationConfig(at: configURL) ?? CheatFeedbackMigrationConfig(schemaVersion: 1)
        guard config.schemaVersion < Self.schemaVersion else { return }

        if let systemDirs = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            let libretro = LibretroCheatProvider()
            let openEmu = OpenEmuCheatProvider()

            for systemDir in systemDirs {
                guard (try? systemDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let systemIdentifier = systemDir.lastPathComponent
                guard let files = try? fileManager.contentsOfDirectory(at: systemDir, includingPropertiesForKeys: nil) else { continue }
                for fileURL in files where fileURL.pathExtension == "json" {
                    migrateFile(at: fileURL, systemIdentifier: systemIdentifier, libretro: libretro, openEmu: openEmu)
                }
            }
        }

        config.schemaVersion = Self.schemaVersion
        saveMigrationConfig(config, at: configURL)
    }

    /// Backfills `rawCode`/`provider` from the still-cached provider databases (matched by
    /// normalized code), `gameName`/`systemIdentifier`, and `serial` from the ROM library (a second
    /// fallback identifier alongside MD5, already stored there independent of any game/core running —
    /// unlike the RetroAchievements hash, which only exists once a core has actually loaded the ROM
    /// and so can never be recovered during this startup-only migration).
    /// Entries with no match in either cache (already cleared, or never cached) are left as-is —
    /// this is best-effort, not a guaranteed reconciliation.
    private func migrateFile(at fileURL: URL, systemIdentifier: String, libretro: LibretroCheatProvider, openEmu: OpenEmuCheatProvider) {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var file = try? decoder.decode(CheatFeedbackFile.self, from: data), file.schemaVersion < Self.schemaVersion
        else { return }

        let openEmuLookup = openEmu.migrationLookup(forMD5: file.md5, systemIdentifier: systemIdentifier)
        let libretroLookup = libretro.migrationLookup(forMD5: file.md5, systemIdentifier: systemIdentifier)

        var openEmuByCode: [String: String] = [:]
        for cheat in openEmuLookup?.cheats ?? [] {
            openEmuByCode[Self.key(for: cheat.code)] = cheat.rawCode
        }
        var libretroByCode: [String: String] = [:]
        for cheat in libretroLookup?.cheats ?? [] {
            libretroByCode[Self.key(for: cheat.code)] = cheat.rawCode
        }

        file.systemIdentifier = systemIdentifier
        // OpenEmu is tried first everywhere else (CheatDatabaseService's provider precedence,
        // first-match-wins on a duplicate code), so mirror that order here too.
        file.gameName = file.gameName ?? openEmuLookup?.gameName ?? libretroLookup?.gameName
        if file.serial == nil, let context = OELibraryDatabase.default?.mainThreadContext {
            file.serial = (try? OEDBRom.rom(withMD5HashString: file.md5, in: context))?.serial
        }

        for index in file.entries.indices {
            let code = file.entries[index].code
            guard file.entries[index].rawCode == nil || file.entries[index].provider == nil else { continue }
            if let rawCode = openEmuByCode[code] {
                file.entries[index].rawCode = file.entries[index].rawCode ?? rawCode
                file.entries[index].provider = file.entries[index].provider ?? openEmu.name
            } else if let rawCode = libretroByCode[code] {
                file.entries[index].rawCode = file.entries[index].rawCode ?? rawCode
                file.entries[index].provider = file.entries[index].provider ?? libretro.name
            }
        }

        file.schemaVersion = Self.schemaVersion

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: fileURL, options: .atomic)
        } catch {
            // log.error("Failed to write migrated cheat feedback for \(file.md5): \(error.localizedDescription)")
        }
    }

    private func loadMigrationConfig(at url: URL) -> CheatFeedbackMigrationConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CheatFeedbackMigrationConfig.self, from: data)
    }

    private func saveMigrationConfig(_ config: CheatFeedbackMigrationConfig, at url: URL) {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(config).write(to: url, options: .atomic)
        } catch {
            // log.error("Failed to write cheat feedback migration config: \(error.localizedDescription)")
        }
    }
}
