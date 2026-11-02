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
import os.log

private let log = OSLog(subsystem: "org.openemu.OpenEmu", category: "ArtworkBackup")

/// Copies the artwork folder to `{backup folder}/Artwork/` and back. It only ever adds files:
/// - A file already in the destination with the same bytes is left alone.
/// - A file there with different bytes is never replaced. The incoming file is kept beside it as
///   `Name (from <Mac>).png`, so two Macs that changed the same picture keep both.
/// - Nothing is deleted, in either direction. Deleting a picture here removes nothing from the backup.
///
/// The source folder is only read. Each Mac also writes its own `index-<id>.json` (its pins and where each picture
/// came from), which a restore reads but never merges over a pick the other Mac already has.
enum OEArtworkBackup {

    enum Scope: Int {
        case off = 0
        /// Pinned picks and everything in `History`. The default: what a person chose, and what it replaced.
        case pinnedAndHistory = 1
        /// Every picture, including ones fetched automatically.
        case everything = 2
    }

    struct Report: Equatable {
        var copied = 0
        var unchanged = 0
        /// Files that differed from one already there and were kept beside it.
        var keptBoth = 0
        var indexEntriesAdopted = 0
    }

    enum Problem: Error, Equatable {
        /// The artwork folder and the backup folder are the same place, or one is inside the other. Copying would loop.
        case overlapping
        case notWritable
        case copyFailed(String)
        case nothingToRestore
    }

    static let folderName = "Artwork"
    static let defaultsKey = "OEArtworkBackupScope"

    /// What the preference says. Pinned and history by default.
    static var configuredScope: Scope {
        get {
            guard UserDefaults.standard.object(forKey: defaultsKey) != nil else { return .pinnedAndHistory }
            return Scope(rawValue: UserDefaults.standard.integer(forKey: defaultsKey)) ?? .pinnedAndHistory
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    static func isIndexSnapshot(_ name: String) -> Bool { name.hasPrefix("index-") && name.hasSuffix(".json") }

    // MARK: Back up

    @discardableResult
    static func backUp(root: URL, to backupFolder: URL, scope: Scope, machineID: String, machineName: String) -> Result<Report, Problem> {
        guard scope != .off else { return .success(Report()) }
        let fm = FileManager.default
        let destination = backupFolder.appendingPathComponent(folderName, isDirectory: true)
        guard !overlapping(root, destination) else { return .failure(.overlapping) }
        guard fm.fileExists(atPath: root.path) else { return .success(Report()) }
        do { try fm.createDirectory(at: destination, withIntermediateDirectories: true) } catch { return .failure(.notWritable) }

        let index = readIndex(root.appendingPathComponent(OEArtworkStore.indexName))
        let pinned = Set(index.values.flatMap { $0.values }.filter { $0.pinned }.map { $0.file })

        var report = Report()
        for (rel, real) in OEArtworkLocation.listFiles(in: root).files {
            let name = (rel as NSString).lastPathComponent
            if rel == OEArtworkStore.indexName || name.hasPrefix(".") || name.hasPrefix("index.") { continue }
            // History sits inside each slot folder: `snes/poster/History/…`.
            let inHistory = rel.split(separator: "/").dropLast().contains { $0 == OEArtworkStore.historyName }
            if scope == .pinnedAndHistory, !inHistory, !pinned.contains(rel) { continue }
            switch add(real, as: rel, in: destination, machineName: machineName) {
            case .success(let outcome): outcome.add(to: &report)
            case .failure(let problem): return .failure(problem)
            }
        }

        // This Mac's own record of its picks. Replaced only when it changed, and only ever this Mac's file.
        if !index.isEmpty {
            let snapshot = destination.appendingPathComponent("index-\(machineID.prefix(8)).json")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            if let data = try? encoder.encode(index), (try? Data(contentsOf: snapshot)) != data { try? data.write(to: snapshot, options: .atomic) }
        }
        os_log(.info, log: log, "Artwork backup: %d copied, %d unchanged, %d kept both", report.copied, report.unchanged, report.keptBoth)
        return .success(report)
    }

    // MARK: Restore

    /// Brings backed-up pictures into `root`. A picture this Mac already has is never replaced. Entries from the
    /// backup's index snapshots are adopted for pictures this Mac has no entry for.
    @discardableResult
    static func restore(from backupFolder: URL, into root: URL, store: OEArtworkStore? = nil, machineName: String) -> Result<Report, Problem> {
        let fm = FileManager.default
        let source = backupFolder.appendingPathComponent(folderName, isDirectory: true)
        guard fm.fileExists(atPath: source.path) else { return .failure(.nothingToRestore) }
        guard !overlapping(root, source) else { return .failure(.overlapping) }
        do { try fm.createDirectory(at: root, withIntermediateDirectories: true) } catch { return .failure(.notWritable) }

        var report = Report()
        for (rel, real) in OEArtworkLocation.listFiles(in: source).files {
            let name = (rel as NSString).lastPathComponent
            if isIndexSnapshot(rel) || name.hasPrefix(".") { continue }
            switch add(real, as: rel, in: root, machineName: machineName, label: "from backup") {
            case .success(let outcome): outcome.add(to: &report)
            case .failure(let problem): return .failure(problem)
            }
        }

        if let store = store {
            var incoming = [String: [String: OEArtworkStore.Entry]]()
            for name in ((try? fm.contentsOfDirectory(atPath: source.path)) ?? []).sorted() where isIndexSnapshot(name) {
                for (md5, slots) in readIndex(source.appendingPathComponent(name)) {
                    for (slot, entry) in slots where incoming[md5]?[slot] == nil { incoming[md5, default: [:]][slot] = entry }
                }
            }
            report.indexEntriesAdopted = store.adoptMissing(incoming)
        }
        return .success(report)
    }

    // MARK: Adding one file

    private enum Outcome {
        case copied, unchanged, keptBoth
        func add(to report: inout Report) {
            switch self {
            case .copied: report.copied += 1
            case .unchanged: report.unchanged += 1
            case .keptBoth: report.keptBoth += 1
            }
        }
    }

    /// Puts `real` at `rel` under `folder` if nothing is there; otherwise leaves what is there and, if it differs,
    /// keeps `real` beside it under a name that says where it came from.
    private static func add(_ real: URL, as rel: String, in folder: URL, machineName: String, label: String? = nil) -> Result<Outcome, Problem> {
        let fm = FileManager.default
        let target = folder.appendingPathComponent(rel)
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: target.path) {
                try fm.copyItem(at: real, to: target)
                return fm.contentsEqual(atPath: real.path, andPath: target.path) ? .success(.copied) : .failure(.copyFailed(rel))
            }
            if fm.contentsEqual(atPath: real.path, andPath: target.path) { return .success(.unchanged) }

            // Different bytes. An earlier run may already have kept this very file beside it.
            let ns = rel as NSString
            let stem = (ns.lastPathComponent as NSString).deletingPathExtension, ext = ns.pathExtension
            let dir = target.deletingLastPathComponent()
            let tag = " (" + (label ?? "from \(machineName)")
            for sibling in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where sibling.hasPrefix(stem + tag) && sibling.hasSuffix(ext.isEmpty ? "" : "." + ext) {
                if fm.contentsEqual(atPath: real.path, andPath: dir.appendingPathComponent(sibling).path) { return .success(.unchanged) }
            }
            var n = 1
            while true {
                let suffix = n == 1 ? ")" : " \(n))"
                let candidate = dir.appendingPathComponent(stem + tag + suffix + (ext.isEmpty ? "" : "." + ext))
                if !fm.fileExists(atPath: candidate.path) {
                    try fm.copyItem(at: real, to: candidate)
                    return fm.contentsEqual(atPath: real.path, andPath: candidate.path) ? .success(.keptBoth) : .failure(.copyFailed(rel))
                }
                n += 1
            }
        } catch {
            return .failure(.copyFailed(rel))
        }
    }

    private static func overlapping(_ a: URL, _ b: URL) -> Bool {
        let x = OEArtworkLocation.canonicalPath(a), y = OEArtworkLocation.canonicalPath(b)
        return x == y || x.hasPrefix(y + "/") || y.hasPrefix(x + "/")
    }

    private static func readIndex(_ url: URL) -> [String: [String: OEArtworkStore.Entry]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: [String: OEArtworkStore.Entry]].self, from: data)) ?? [:]
    }
}
