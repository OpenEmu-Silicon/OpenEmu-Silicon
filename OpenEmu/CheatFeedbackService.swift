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
    let updatedAt: Date
}

private struct CheatFeedbackFile: Codable {
    var schemaVersion: Int
    var md5: String
    var entries: [CheatFeedbackEntry]
}

/// Stores the user's "does this cheat work" reports, separate from their cheat
/// inventory so deleting a cheat never discards the report.
///
/// Reports are scoped to a core build: a different core, or a new version of the
/// same core, starts with a clean slate. Superseded entries are deliberately kept
/// — they are the history a future central ranking service would be built from.
final class CheatFeedbackService {

    static let shared = CheatFeedbackService()

    private static let schemaVersion = 1

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
                   rawCode: String? = nil) {
        let key = Self.key(for: code)
        var file = load(md5: md5, systemIdentifier: systemIdentifier)
            ?? CheatFeedbackFile(schemaVersion: Self.schemaVersion, md5: md5, entries: [])

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
                  rawCode: String? = nil) {
        let key = Self.key(for: code)
        var file = load(md5: md5, systemIdentifier: systemIdentifier)
            ?? CheatFeedbackFile(schemaVersion: Self.schemaVersion, md5: md5, entries: [])

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
}
