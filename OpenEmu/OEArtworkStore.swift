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

/// The artwork folder: every game's pictures, kept exactly as they arrived, where the person can see them.
///
/// ```
/// <root>/<System>/<slot>/<Title>.<ext>            the active picture
/// <root>/<System>/<slot>/History/<Title> <time>.<ext>   anything that was replaced
/// <root>/index.json                               where each picture came from, and whether it is pinned
/// ```
///
/// The rules that make it safe (see docs/artwork-providers-and-storage.md):
/// - Nothing here deletes a file. The only things this type does to existing files are to leave them alone, or to move a
///   replaced picture into `History`.
/// - A picture a person chose (pinned) is never replaced by a provider, a refetch or a change of provider.
/// - Fetching only fills an empty slot. Replacing is a separate, deliberate call.
/// - Bytes are stored as they arrived. Nothing is decoded and saved again.
/// - The index is a convenience. If it is lost, pictures are found again by their path, and any picture the index does
///   not know is treated as pinned.
final class OEArtworkStore: @unchecked Sendable {

    enum Slot: String, CaseIterable, Codable {
        /// The library's own box art.
        case cover
        /// A 2:3 portrait.
        case poster
        /// A wide backdrop.
        case hero
        case icon
        case logo
    }

    /// Where a picture came from.
    enum Origin: Equatable {
        case provider(String)
        case user
        case library
        /// Found on disk with no record of where it came from.
        case unknown

        var raw: String {
            switch self {
            case .provider(let id): return "provider:\(id)"
            case .user: return "user"
            case .library: return "library"
            case .unknown: return "unknown"
            }
        }

        init(raw: String) {
            if raw.hasPrefix("provider:") { self = .provider(String(raw.dropFirst("provider:".count))) }
            else if raw == "user" { self = .user }
            else if raw == "library" { self = .library }
            else { self = .unknown }
        }
    }

    /// Which game a picture belongs to. The hash is the identity; the system and title only decide the file's name.
    struct Game: Equatable {
        let md5: String
        let system: String
        let title: String
    }

    enum Outcome: Equatable {
        /// Written, and now the active picture.
        case stored(URL)
        /// The slot already has a picture and fetching never replaces one. Nothing changed.
        case keptExisting(URL)
        /// The active picture is pinned and this was not a deliberate choice. Nothing changed.
        case keptPinned(URL)
        /// The same bytes are already the active picture.
        case alreadyActive(URL)
        case failed
    }

    struct Entry: Codable, Equatable {
        var file: String
        var origin: String
        var pinned: Bool
        var added: Date
    }

    static let folderName = "Artwork"
    static let historyName = "History"
    static let indexName = "index.json"

    /// `~/Library/Application Support/OpenEmu/Artwork`. Preferences will let a person move it.
    static let defaultRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OpenEmu", isDirectory: true)
        .appendingPathComponent(folderName, isDirectory: true)

    static let shared = OEArtworkStore(root: defaultRoot)

    let root: URL
    private let lock = NSLock()
    private var index: [String: [String: Entry]]?   // md5 -> slot -> entry
    private var saveScheduled = false

    init(root: URL) {
        self.root = root
    }

    // MARK: - Reading

    /// The active picture for a game and slot, or nil. Safe to call from any thread.
    func active(_ game: Game, _ slot: Slot) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return locatedActive(game, slot)?.url
    }

    /// Everything that was replaced for a game and slot, oldest first.
    func history(_ game: Game, _ slot: Slot) -> [URL] {
        let folder = slotFolder(game, slot).appendingPathComponent(Self.historyName, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let base = Self.fileStem(game.title)
        return names.filter { $0.hasPrefix(base) }.sorted().map { folder.appendingPathComponent($0) }
    }

    func entry(_ game: Game, _ slot: Slot) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return locatedActive(game, slot)?.entry
    }

    // MARK: - Writing

    /// Puts a picture in an empty slot. A slot that already has one is left exactly as it is.
    @discardableResult
    func fill(_ data: Data, for game: Game, slot: Slot, origin: Origin) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        if let found = locatedActive(game, slot) { return .keptExisting(found.url) }
        guard let url = write(data, game, slot) else { return .failed }
        record(game, slot, Entry(file: relativePath(url), origin: origin.raw, pinned: false, added: Date()))
        scheduleSave()
        return .stored(url)
    }

    /// Replaces the active picture because a person chose this one. The old one moves to `History`. The new one is
    /// pinned, so nothing automatic replaces it later.
    @discardableResult
    func choose(_ data: Data, for game: Game, slot: Slot, origin: Origin = .user) -> Outcome {
        replace(data, game, slot, origin: origin, pinned: true, onlyIfUnpinned: false)
    }

    /// Replaces the active picture with a provider's, for a change of provider. A pinned picture is never replaced.
    @discardableResult
    func replaceAutomatic(_ data: Data, for game: Game, slot: Slot, origin: Origin) -> Outcome {
        replace(data, game, slot, origin: origin, pinned: false, onlyIfUnpinned: true)
    }

    /// Keeps a picture that is about to be lost somewhere else (a library cover about to be replaced or deleted).
    /// An empty slot is filled with it. A slot that holds different bytes gets it in `History`. The active picture is
    /// never changed and nothing is overwritten.
    @discardableResult
    func archive(_ data: Data, for game: Game, slot: Slot, origin: Origin) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        guard let current = locatedActive(game, slot) else {
            guard let url = write(data, game, slot) else { return .failed }
            record(game, slot, Entry(file: relativePath(url), origin: origin.raw, pinned: false, added: Date()))
            scheduleSave()
            return .stored(url)
        }
        if let existing = try? Data(contentsOf: current.url), existing == data { return .alreadyActive(current.url) }
        for kept in history(game, slot) where (try? Data(contentsOf: kept)) == data { return .alreadyActive(kept) }

        let folder = current.url.deletingLastPathComponent().appendingPathComponent(Self.historyName, isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return .failed }
        let url = uniqueURL(in: folder, stem: "\(Self.fileStem(game.title)) \(Self.stamp.string(from: Date()))",
                            ext: OEArtworkOriginals.fileExtension(for: data))
        do { try data.write(to: url, options: .withoutOverwriting) } catch { return .failed }
        return .stored(url)
    }

    /// Lets automatic fetching replace this slot again. The picture stays where it is.
    func unpin(_ game: Game, _ slot: Slot) {
        lock.lock(); defer { lock.unlock() }
        guard var found = locatedActive(game, slot) else { return }
        found.entry.pinned = false
        record(game, slot, found.entry)
        saveNow()
    }

    /// Writes the index to disk now. Called after a deliberate choice and when the app quits.
    func flush() {
        lock.lock(); defer { lock.unlock() }
        saveNow()
    }

    // MARK: - Replacing

    private func replace(_ data: Data, _ game: Game, _ slot: Slot, origin: Origin, pinned: Bool, onlyIfUnpinned: Bool) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default

        guard let current = locatedActive(game, slot) else {
            guard let url = write(data, game, slot) else { return .failed }
            record(game, slot, Entry(file: relativePath(url), origin: origin.raw, pinned: pinned, added: Date()))
            saveNow()
            return .stored(url)
        }
        if onlyIfUnpinned, current.entry.pinned { return .keptPinned(current.url) }
        if let existing = try? Data(contentsOf: current.url), existing == data {
            if pinned, !current.entry.pinned {
                var same = current.entry; same.pinned = true
                record(game, slot, same); saveNow()
            }
            return .alreadyActive(current.url)
        }

        // Write the new picture beside the old one first, so a failure leaves the old one in place.
        let folder = slotFolder(game, slot)
        let staged = folder.appendingPathComponent(".incoming-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: staged, options: .withoutOverwriting)
        } catch { return .failed }

        guard moveToHistory(current.url, game, slot) != nil else {
            try? fm.removeItem(at: staged)   // our own staging file, never the person's
            return .failed
        }

        let final = uniqueURL(in: folder, stem: Self.fileStem(game.title), ext: OEArtworkOriginals.fileExtension(for: data))
        do { try fm.moveItem(at: staged, to: final) } catch { return .failed }
        record(game, slot, Entry(file: relativePath(final), origin: origin.raw, pinned: pinned, added: Date()))
        saveNow()
        return .stored(final)
    }

    private func moveToHistory(_ url: URL, _ game: Game, _ slot: Slot) -> URL? {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent().appendingPathComponent(Self.historyName, isDirectory: true)
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return nil }
        let stamp = Self.stamp.string(from: Date())
        let target = uniqueURL(in: folder, stem: "\(url.deletingPathExtension().lastPathComponent) \(stamp)", ext: url.pathExtension)
        do { try fm.moveItem(at: url, to: target) } catch { return nil }
        return target
    }

    // MARK: - Files

    private func slotFolder(_ game: Game, _ slot: Slot) -> URL {
        root.appendingPathComponent(Self.folderName(game.system), isDirectory: true)
            .appendingPathComponent(slot.rawValue, isDirectory: true)
    }

    /// The first free name for a picture. Never an existing file.
    private func uniqueURL(in folder: URL, stem: String, ext: String) -> URL {
        let fm = FileManager.default
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var candidate = folder.appendingPathComponent(stem + suffix)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) \(n)\(suffix)")
            n += 1
        }
        return candidate
    }

    /// Writes a new active picture named after the game. A different game with the same title gets its hash in the name.
    private func write(_ data: Data, _ game: Game, _ slot: Slot) -> URL? {
        guard !data.isEmpty else { return nil }
        let fm = FileManager.default
        let folder = slotFolder(game, slot)
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return nil }

        let ext = OEArtworkOriginals.fileExtension(for: data)
        var stem = Self.fileStem(game.title)
        if Self.activeFile(in: folder, stem: stem) != nil { stem += " [\(game.md5.prefix(8))]" }
        let url = uniqueURL(in: folder, stem: stem, ext: ext)
        do { try data.write(to: url, options: .withoutOverwriting) } catch { return nil }
        return url
    }

    /// Extensions a picture can have. Looking for these by name keeps a lookup the same cost however many pictures
    /// share the folder, where listing the folder would grow with the library.
    private static let knownExtensions = ["png", "jpg", "jpeg", "webp", "gif", "ico", "img", "bmp", "tif", "tiff", "heic"]

    /// An active file in a slot folder named exactly `stem` plus a picture extension (History and hidden files do not count).
    private static func activeFile(in folder: URL, stem: String) -> URL? {
        let fm = FileManager.default
        for ext in knownExtensions {
            let url = folder.appendingPathComponent("\(stem).\(ext)")
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// The game's active picture: the one the index says, otherwise one found by its name (a lost index, or a file a
    /// person placed there). Such a file is adopted as pinned.
    private func locatedActive(_ game: Game, _ slot: Slot) -> (url: URL, entry: Entry)? {
        loadIndexIfNeeded()
        if let entry = index?[game.md5]?[slot.rawValue] {
            let url = root.appendingPathComponent(entry.file)
            if FileManager.default.fileExists(atPath: url.path) { return (url, entry) }
        }
        let folder = slotFolder(game, slot)
        let stem = Self.fileStem(game.title)
        for candidate in [stem + " [\(game.md5.prefix(8))]", stem] {
            if let url = Self.activeFile(in: folder, stem: candidate) {
                if candidate == stem, claimedByOtherGame(url, game) { continue }
                let entry = Entry(file: relativePath(url), origin: Origin.unknown.raw, pinned: true, added: Date())
                record(game, slot, entry)
                scheduleSave()
                return (url, entry)
            }
        }
        return nil
    }

    private func claimedByOtherGame(_ url: URL, _ game: Game) -> Bool {
        let path = relativePath(url)
        for (md5, slots) in index ?? [:] where md5 != game.md5 {
            if slots.values.contains(where: { $0.file == path }) { return true }
        }
        return false
    }

    private func relativePath(_ url: URL) -> String {
        let base = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    static func fileStem(_ title: String) -> String {
        var text = title.map { "/\\:*?\"<>|\0".contains($0) ? "-" : $0 }.reduce(into: "") { $0.append($1) }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        if text.count > 120 { text = String(text.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return text.isEmpty ? "Untitled" : text
    }

    /// `openemu.system.n64` -> `n64`.
    static func folderName(_ system: String) -> String {
        let last = system.split(separator: ".").last.map(String.init) ?? system
        let clean = fileStem(last)
        return clean.hasPrefix(".") ? "System" : clean
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    // MARK: - Index

    private var indexURL: URL { root.appendingPathComponent(Self.indexName) }

    private func record(_ game: Game, _ slot: Slot, _ entry: Entry) {
        loadIndexIfNeeded()
        index?[game.md5, default: [:]][slot.rawValue] = entry
    }

    private func loadIndexIfNeeded() {
        guard index == nil else { return }
        if let data = try? Data(contentsOf: indexURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let loaded = try? decoder.decode([String: [String: Entry]].self, from: data) { index = loaded; return }
            // An index that cannot be read is kept, not replaced, and pictures are found again by path.
            let aside = indexURL.deletingLastPathComponent().appendingPathComponent("index.unreadable-\(Self.stamp.string(from: Date())).json")
            try? FileManager.default.moveItem(at: indexURL, to: aside)
        }
        index = [:]
    }

    /// Index writes are batched: a bulk fetch would otherwise rewrite the whole file for every picture.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.lock.lock()
            self?.saveNow()
            self?.lock.unlock()
        }
    }

    private func saveNow() {
        saveScheduled = false
        guard let index = index else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(index) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: .atomic)
    }
}

// MARK: - Library covers

extension OEArtworkStore.Game {

    /// The game as the artwork folder names it. Call on the game's own context.
    init(_ game: OEDBGame) {
        let md5 = game.defaultROM?.md5Hash ?? ""
        self.init(md5: md5.isEmpty ? "unhashed-\(game.cleanDisplayName)" : md5,
                  system: game.system?.systemIdentifier ?? "unknown",
                  title: game.cleanDisplayName)
    }
}

extension OEArtworkStore {

    /// Copies a library cover into the artwork folder before the library lets go of it. The library's own file is only
    /// read. Call before a cover is replaced or deleted.
    static func keepCover(_ image: OEDBImage) {
        guard let game = image.Box, let url = image.imageURL, let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        shared.archive(data, for: Game(game), slot: .cover, origin: .library)
    }

    /// Records a cover the library just took on. The previous one stays in `History`. `source` is the file it came from
    /// when there is one, so the bytes kept are the ones that arrived rather than the library's re-saved copy.
    static func recordNewCover(of game: OEDBGame, source: URL? = nil) {
        guard let image = game.boxImage,
              let url = source ?? image.imageURL,
              let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        shared.replaceAutomatic(data, for: Game(game), slot: .cover, origin: .library)
    }
}

extension OEArtworkStore {

    private static let importedKey = "OEArtworkStoreCoversImported"

    /// Copies every cover already in the library into the artwork folder, once. The library's own files are only
    /// read. Safe to run again: a game that already has a cover in the folder is left alone.
    static func importLibraryCovers(from database: OELibraryDatabase) {
        guard !UserDefaults.standard.bool(forKey: importedKey) else { return }
        let context = database.makeChildContext()
        context.perform {
            let request = OEDBGame.fetchRequest()
            request.predicate = NSPredicate(format: "boxImage != nil")
            request.fetchBatchSize = 200
            let fetched = try? context.fetch(request)
            guard let games = fetched as? [OEDBGame] else {
                NSLog("Artwork folder: could not list library covers (\(String(describing: fetched?.count)))")
                return
            }

            var copied = 0
            for game in games {
                autoreleasepool {
                    guard let url = game.boxImage?.imageURL, let data = try? Data(contentsOf: url), !data.isEmpty else { return }
                    if case .stored = shared.fill(data, for: Game(game), slot: .cover, origin: .library) { copied += 1 }
                }
            }
            shared.flush()
            if !games.isEmpty { UserDefaults.standard.set(true, forKey: importedKey) }   // an empty list may only mean the library is still loading
            NSLog("Artwork folder: copied \(copied) of \(games.count) library covers")
        }
    }
}
