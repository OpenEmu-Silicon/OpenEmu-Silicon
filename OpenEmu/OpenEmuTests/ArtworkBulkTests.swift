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


import XCTest
@testable import OpenEmu

/// Bulk fetching and cleanup: a bounded pool, pause and resume, a clean stop on quota, and a cleanup that only ever
/// moves unused automatic pictures. Fetching is faked; cleanup uses a temporary folder.
final class ArtworkBulkTests: XCTestCase {

    private func keys(_ count: Int) -> [OEBigPictureArt.GameKey] {
        (0..<count).map { OEBigPictureArt.GameKey(md5: "md5-\($0)", name: "Game \($0)", systemIdentifier: "openemu.system.nes") }
    }

    /// Counts calls and how many ran at once.
    private final class Tracker: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var started = [String]()
        private(set) var running = 0
        private(set) var peak = 0
        func begin(_ key: OEBigPictureArt.GameKey) { lock.lock(); started.append(key.md5); running += 1; peak = max(peak, running); lock.unlock() }
        func end() { lock.lock(); running -= 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return started.count }
    }

    func testNeverRunsMoreThanTheWorkerCountAtOnce() async {
        let tracker = Tracker()
        let run = OEArtworkBulkFetch(keys: keys(20), workers: 3) { key in
            tracker.begin(key); try? await Task.sleep(nanoseconds: 5_000_000); tracker.end(); return .filled
        }
        let finish = await run.run()
        XCTAssertEqual(finish, .finished)
        XCTAssertEqual(tracker.count, 20)
        XCTAssertLessThanOrEqual(tracker.peak, 3)
        XCTAssertGreaterThan(tracker.peak, 1, "it does use the pool")
        XCTAssertEqual(run.current.filled, 20)
        XCTAssertEqual(run.current.processed, 20)
    }

    func testPauseStartsNothingNewAndResumeCarriesOn() async throws {
        let tracker = Tracker()
        let run = OEArtworkBulkFetch(keys: keys(30), workers: 2) { key in
            tracker.begin(key); try? await Task.sleep(nanoseconds: 10_000_000); tracker.end(); return .filled
        }
        let task = Task { await run.run() }
        try await Task.sleep(nanoseconds: 60_000_000)
        run.pause()
        try await Task.sleep(nanoseconds: 100_000_000)   // let the games already running finish
        let atPause = tracker.count
        XCTAssertLessThan(atPause, 30)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(tracker.count, atPause, "nothing new starts while paused")
        run.resume()
        let finish = await task.value
        XCTAssertEqual(finish, .finished)
        XCTAssertEqual(tracker.count, 30)
        XCTAssertEqual(Set(tracker.started).count, 30, "no game was fetched twice")
    }

    func testStopLetsRunningGamesFinishAndStartsNoMore() async throws {
        let tracker = Tracker()
        let run = OEArtworkBulkFetch(keys: keys(50), workers: 2) { key in
            tracker.begin(key); try? await Task.sleep(nanoseconds: 10_000_000); tracker.end(); return .filled
        }
        let task = Task { await run.run() }
        try await Task.sleep(nanoseconds: 50_000_000)
        run.stop()
        let finish = await task.value
        XCTAssertEqual(finish, .stopped)
        XCTAssertLessThan(tracker.count, 50)
        XCTAssertEqual(run.current.processed, tracker.count, "every game that started was finished and counted")
    }

    func testAQuotaErrorStopsTheRunCleanlyAndTheGameIsNotCounted() async {
        let tracker = Tracker()
        let run = OEArtworkBulkFetch(keys: keys(40), workers: 1) { key in
            tracker.begin(key); tracker.end()
            return key.md5 == "md5-5" ? .outOfQuota : .filled
        }
        let finish = await run.run()
        XCTAssertEqual(finish, .outOfQuota)
        XCTAssertEqual(tracker.count, 6, "games 0 to 5, and nothing after the quota answer")
        XCTAssertEqual(run.current.processed, 5, "the game that hit the quota will be done by the next run")
    }

    func testSeveralGamesInARowWithNoAnswerStopsTheRun() async {
        let run = OEArtworkBulkFetch(keys: keys(40), workers: 1, patience: 4) { _ in .notAnswered }
        let finish = await run.run()
        XCTAssertEqual(finish, .unreachable)
        XCTAssertEqual(run.current.notAnswered, 4)
    }

    func testAnAnswerResetsThePatience() async {
        let run = OEArtworkBulkFetch(keys: keys(12), workers: 1, patience: 3) { key in
            Int(key.md5.dropFirst(4))! % 3 == 2 ? .filled : .notAnswered   // two misses, then a hit, over and over
        }
        let finish = await run.run()
        XCTAssertEqual(finish, .finished)
    }

    func testTheLibraryFetchSkipsGamesTheFolderAlreadyCovers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArtworkBulkTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = OEArtworkStore.shared
        OEArtworkStore.useRoot(root)
        defer { OEArtworkStore.install(previous) }

        let key = OEBigPictureArt.GameKey(md5: "cc", name: "Metroid", systemIdentifier: "openemu.system.nes")
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        for slot in [OEArtworkStore.Slot.poster, .hero, .icon, .logo] {
            _ = OEArtworkStore.shared.fill(bytes, for: key.artworkGame, slot: slot, origin: .provider("steamgriddb"))
        }

        final class Asked: @unchecked Sendable { var count = 0 }
        let asked = Asked()
        struct Provider: OEBigPictureArtProvider {
            let asked: Asked
            var id: String { "steamgriddb" }
            var title: String { id }
            var isThrottled: Bool { false }
            var providesStandardPosters: Bool { true }
            func art(for key: OEBigPictureArt.GameKey) async -> OEBigPictureArtSet { asked.count += 1; return OEBigPictureArtSet(isDefinitive: true) }
        }
        let signature = "bulk-test-\(UUID().uuidString)"
        let answers = OEBigPictureArtStore(signature: signature)
        defer { try? FileManager.default.removeItem(at: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenEmu/BigPictureArt/v3/\(signature)")) }
        let fetch = OEArtworkBulkFetch.libraryFetch(providers: [Provider(asked: asked)], preferred: "steamgriddb", answers: answers)
        let skipped = await fetch(key)
        XCTAssertEqual(skipped, .alreadyHad)
        XCTAssertEqual(asked.count, 0, "no provider was asked")

        let other = OEBigPictureArt.GameKey(md5: "dd", name: "Kid Icarus", systemIdentifier: "openemu.system.nes")
        let none = await fetch(other)
        XCTAssertEqual(none, .noArt)
        XCTAssertEqual(asked.count, 1)
        // A second run does not ask a provider that already said it has nothing.
        let again = await fetch(other)
        XCTAssertEqual(again, .noArt)
        XCTAssertEqual(asked.count, 1, "the provider is not asked twice")
    }

    // MARK: Cleanup

    private var root: URL!
    private var store: OEArtworkStore!
    private func game(_ md5: String, _ title: String = "Title") -> OEArtworkStore.Game { .init(md5: md5, system: "openemu.system.snes", title: title + md5) }
    private func bytes(_ n: UInt8) -> Data { Data([0x89, 0x50, 0x4E, 0x47, n, 2, 3]) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ArtworkCleanupTests-\(UUID().uuidString)", isDirectory: true)
        store = OEArtworkStore(root: root)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func files() -> [String: Data] {
        var found = [String: Data]()
        let prefix = root.standardizedFileURL.path + "/"
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return found }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            if url.lastPathComponent == OEArtworkStore.indexName { continue }
            found[String(url.standardizedFileURL.path.dropFirst(prefix.count))] = try? Data(contentsOf: url)
        }
        return found
    }

    func testCleanupMovesOnlyUnusedAutomaticPicturesAndDeletesNothing() throws {
        _ = store.fill(bytes(1), for: game("gone"), slot: .poster, origin: .provider("steamgriddb"))           // unused, automatic: moves
        _ = store.fill(bytes(2), for: game("gone"), slot: .hero, origin: .provider("libretro"))               // moves
        _ = store.choose(bytes(3), for: game("pin"), slot: .poster, origin: .user)                // pinned: stays
        _ = store.fill(bytes(4), for: game("kept"), slot: .poster, origin: .provider("steamgriddb"))          // game still here: stays
        _ = store.fill(bytes(5), for: game("gone2"), slot: .cover, origin: .library)                           // library cover: stays
        _ = store.choose(bytes(6), for: game("gone3"), slot: .logo, origin: .provider("steamgriddb"))
        store.unpin(game("gone3"), .logo)
        _ = store.choose(bytes(7), for: game("gone3"), slot: .logo, origin: .provider("steamgriddb"))          // replaced one is in History: stays
        store.flush()
        let before = files()

        let plan = OEArtworkCleanup.plan(store: store, inLibrary: ["kept"])
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(Set(plan.map { $0.slot }), [.poster, .hero])
        XCTAssertGreaterThan(plan.reduce(0) { $0 + $1.bytes }, 0)
        XCTAssertEqual(files(), before, "planning moves nothing")

        let outcome = OEArtworkCleanup.perform(plan, store: store, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(outcome.moved, 2)
        XCTAssertEqual(outcome.failed, 0)
        let after = files()
        // Every byte that existed still exists exactly once, somewhere in the folder.
        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(Set(after.values), Set(before.values))
        XCTAssertEqual(after.keys.filter { $0.hasPrefix("Cleaned ") }.count, 2)
        XCTAssertNil(store.entry(game("gone"), .poster))
        XCTAssertNotNil(store.entry(game("kept"), .poster))
        XCTAssertEqual(store.entry(game("pin"), .poster)?.pinned, true)
        XCTAssertEqual(OEArtworkCleanup.plan(store: store, inLibrary: ["kept"]).count, 0, "a second pass has nothing left")
    }

    func testCleanupWithEveryGameInTheLibraryMovesNothing() throws {
        _ = store.fill(bytes(1), for: game("a"), slot: .poster, origin: .provider("steamgriddb"))
        XCTAssertTrue(OEArtworkCleanup.plan(store: store, inLibrary: ["a"]).isEmpty)
    }
}
