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


import Cocoa

// MARK: - Bulk fetch

/// Fetches artwork for many games with a few workers at a time. It can be paused and resumed, stopped, and it stops by
/// itself, cleanly, when a provider says its quota is used up or cannot be reached. Pictures are saved as each game
/// finishes, so a stopped run loses nothing, and running it again skips every game that already has its art.
final class OEArtworkBulkFetch: @unchecked Sendable {

    enum Answer: Equatable {
        /// A picture was saved.
        case filled
        /// Every slot was already covered, so no provider was asked.
        case alreadyHad
        /// The providers answered and have nothing for this game.
        case noArt
        /// No answer (offline, a bad login).
        case notAnswered
        /// A provider's quota is used up. Asking more only wastes the wait.
        case outOfQuota
    }

    enum Finish: Equatable {
        case finished
        case stopped
        case outOfQuota
        /// Several games in a row got no answer from any provider.
        case unreachable
    }

    struct Progress: Equatable {
        var total = 0
        var processed = 0
        var filled = 0
        var alreadyHad = 0
        var noArt = 0
        var notAnswered = 0
    }

    private let keys: [OEBigPictureArt.GameKey]
    private let workers: Int
    private let fetch: @Sendable (OEBigPictureArt.GameKey) async -> Answer
    private let lock = NSLock()
    private var next = 0
    private var paused = false
    private var stopRequested = false
    private var quotaHit = false
    private var unansweredInARow = 0
    private var progress: Progress
    /// How many games in a row may go unanswered before the run gives up.
    private let patience: Int
    var onProgress: (@Sendable (Progress) -> Void)?

    init(keys: [OEBigPictureArt.GameKey], workers: Int = 3, patience: Int = 6, fetch: @escaping @Sendable (OEBigPictureArt.GameKey) async -> Answer) {
        self.keys = keys
        self.workers = max(1, workers)
        self.patience = max(1, patience)
        self.fetch = fetch
        self.progress = Progress(total: keys.count)
    }

    func pause() { lock.lock(); paused = true; lock.unlock() }
    func resume() { lock.lock(); paused = false; lock.unlock() }
    func stop() { lock.lock(); stopRequested = true; lock.unlock() }
    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }
    var current: Progress { lock.lock(); defer { lock.unlock() }; return progress }

    /// Runs until every game is done or the run stops. Games being fetched when it stops are allowed to finish.
    func run() async -> Finish {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workers { group.addTask { [self] in await work() } }
        }
        lock.lock(); defer { lock.unlock() }
        if quotaHit { return .outOfQuota }
        if unansweredInARow >= patience { return .unreachable }
        return stopRequested || progress.processed < progress.total ? .stopped : .finished
    }

    private func work() async {
        while let key = await take() {
            let answer = await fetch(key)
            record(answer)
        }
    }

    /// The next game, waiting while paused. nil when the run is over.
    private func take() async -> OEBigPictureArt.GameKey? {
        while true {
            lock.lock()
            let over = stopRequested || quotaHit || unansweredInARow >= patience || next >= keys.count
            let wait = paused
            var key: OEBigPictureArt.GameKey?
            if !over, !wait { key = keys[next]; next += 1 }
            lock.unlock()
            if over { return nil }
            if let key = key { return key }
            if Task.isCancelled { return nil }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func record(_ answer: Answer) {
        lock.lock()
        switch answer {
        case .filled: progress.filled += 1; unansweredInARow = 0
        case .alreadyHad: progress.alreadyHad += 1
        case .noArt: progress.noArt += 1; unansweredInARow = 0
        case .notAnswered: progress.notAnswered += 1; unansweredInARow += 1
        case .outOfQuota: quotaHit = true
        }
        // A game stopped by the quota was not finished, so it is not counted and a later run does it again.
        if answer != .outOfQuota { progress.processed += 1 }
        let snapshot = progress
        lock.unlock()
        onProgress?(snapshot)
    }

    /// What one game needs: skip it when the artwork folder already covers every slot, otherwise ask the providers in
    /// order and stop at the first that has anything.
    static func libraryFetch(providers: [OEBigPictureArtProvider], preferred: String?,
                             answers: OEBigPictureArtStore? = nil) -> @Sendable (OEBigPictureArt.GameKey) async -> Answer {
        let ids = providers.map { $0.id }
        let answers = answers ?? OEBigPictureArtStore(signature: ids.joined(separator: "+"))
        return { key in
            let game = key.artworkGame
            let slots: [OEArtworkStore.Slot] = [.poster, .hero, .icon, .logo]
            func have(_ slot: OEArtworkStore.Slot) -> Bool { OEArtworkStore.shared.reusable(game, slot, providers: ids, preferred: preferred) != nil }
            if slots.allSatisfy(have) { return .alreadyHad }

            // A provider that already answered for this game (and has not been out of date for a week, if it had
            // nothing) is not asked again, so a second run costs almost nothing.
            let answered = answers.answered(md5: key.md5, providerIDs: ids)
            var unanswered = false
            for provider in providers where !answered.contains(provider.id) {
                let found = await provider.art(for: key)
                if found.isDefinitive { answers.recordAnswer(md5: key.md5, providerID: provider.id, found: found.hasAny) }
                if found.hasAny { return .filled }
                if !found.isDefinitive {
                    if await provider.isOutOfQuota() { return .outOfQuota }
                    unanswered = true
                }
            }
            if unanswered { return .notAnswered }
            return slots.contains(where: have) ? .alreadyHad : .noArt
        }
    }
}

// MARK: - Cleanup

/// Moves pictures nobody can see any more out of the artwork folder, into `Cleaned <time>/` inside it. Only automatic
/// pictures from a provider, for games no longer in the library. Pinned and own pictures, anything in `History`, and
/// every picture of a game still in the library stay where they are. Nothing is deleted.
enum OEArtworkCleanup {

    struct Item: Equatable {
        let md5: String
        let slot: OEArtworkStore.Slot
        let file: String
        let bytes: Int
    }

    struct Outcome: Equatable {
        var moved = 0
        var failed = 0
        var folder: URL?
    }

    /// What a cleanup would move. `inLibrary` holds the md5 of every game still in the library.
    static func plan(store: OEArtworkStore = .shared, inLibrary: Set<String>) -> [Item] {
        var items = [Item]()
        for (md5, slots) in store.allEntries() where !inLibrary.contains(md5) {
            for (name, entry) in slots {
                guard let slot = OEArtworkStore.Slot(rawValue: name), !entry.pinned,
                      case .provider = OEArtworkStore.Origin(raw: entry.origin) else { continue }
                let url = store.root.appendingPathComponent(entry.file)
                guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { continue }
                items.append(Item(md5: md5, slot: slot, file: entry.file, bytes: size))
            }
        }
        return items.sorted { $0.file < $1.file }
    }

    @discardableResult
    static func perform(_ items: [Item], store: OEArtworkStore = .shared, now: Date = Date()) -> Outcome {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = store.root.appendingPathComponent("Cleaned \(formatter.string(from: now))", isDirectory: true)
        let fm = FileManager.default
        var outcome = Outcome()
        for item in items {
            let source = store.root.appendingPathComponent(item.file)
            let target = folder.appendingPathComponent(item.file)
            guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path) else { outcome.failed += 1; continue }
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: source, to: target)
            } catch { outcome.failed += 1; continue }
            // The entry goes only after the file has moved, so a failure never leaves a picture without a record.
            store.release(md5: item.md5, slot: item.slot)
            outcome.moved += 1
        }
        if outcome.moved > 0 { outcome.folder = folder; store.flush() }
        return outcome
    }
}
