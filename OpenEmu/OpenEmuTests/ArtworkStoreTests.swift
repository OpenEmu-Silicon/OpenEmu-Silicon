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

import AppKit
import XCTest
@testable import OpenEmu

/// The rules that keep a person's artwork safe: nothing is lost when the provider changes, a chosen picture is never
/// replaced by fetching, and a lost index or a missing folder changes no file. Every test uses a temporary folder.
final class ArtworkStoreTests: XCTestCase {

    private var root: URL!
    private var store: OEArtworkStore!

    private let game = OEArtworkStore.Game(md5: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", system: "openemu.system.snes", title: "Super Mario World")
    private func data(_ byte: UInt8, ext: String = "png") -> Data {
        ext == "png" ? Data([0x89, 0x50, 0x4E, 0x47, byte, 2, 3]) : Data([0xFF, 0xD8, 0xFF, byte, 2, 3])
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ArtworkStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = OEArtworkStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Every file under the root with its bytes, to prove nothing changed.
    private func snapshot() -> [String: Data] {
        var found = [String: Data]()
        let base = root.standardizedFileURL.path + "/"
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return found }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            if url.lastPathComponent == OEArtworkStore.indexName { continue }
            found[String(url.standardizedFileURL.path.dropFirst(base.count))] = try? Data(contentsOf: url)
        }
        return found
    }

    func testFillsAnEmptySlotWithTheExactBytes() throws {
        let bytes = data(1)
        guard case .stored(let url) = store.fill(bytes, for: game, slot: .poster, origin: .provider("steamgriddb")) else { return XCTFail() }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(url.lastPathComponent, "Super Mario World.png")
        XCTAssertEqual(url.deletingLastPathComponent().path, root.appendingPathComponent("snes/poster").path)
        XCTAssertEqual(store.active(game, .poster), url)
    }

    func testFetchingNeverReplacesAPictureThatIsThere() throws {
        store.fill(data(1), for: game, slot: .poster, origin: .provider("steamgriddb"))
        let before = snapshot()
        let outcome = store.fill(data(2), for: game, slot: .poster, origin: .provider("screenscraper"))
        guard case .keptExisting = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(snapshot(), before)
    }

    func testChoosingMovesTheOldPictureToHistoryAndPinsTheNewOne() throws {
        store.fill(data(1), for: game, slot: .hero, origin: .provider("steamgriddb"))
        guard case .stored(let url) = store.choose(data(2), for: game, slot: .hero) else { return XCTFail() }

        XCTAssertEqual(try Data(contentsOf: url), data(2))
        let kept = store.history(game, .hero)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(try Data(contentsOf: kept[0]), data(1), "the replaced picture is kept, byte for byte")
        XCTAssertTrue(store.entry(game, .hero)?.pinned == true)
    }

    func testSwitchingProviderBackAndForthLosesNothing() throws {
        store.fill(data(1), for: game, slot: .hero, origin: .provider("steamgriddb"))
        store.replaceAutomatic(data(2), for: game, slot: .hero, origin: .provider("screenscraper"))
        store.replaceAutomatic(data(1), for: game, slot: .hero, origin: .provider("steamgriddb"))

        XCTAssertEqual(try Data(contentsOf: store.active(game, .hero)!), data(1))
        let contents = snapshot().values
        XCTAssertTrue(contents.contains(data(2)), "the second provider's picture is still on disk")
        XCTAssertEqual(store.history(game, .hero).count, 2)
    }

    func testAProviderChangeNeverReplacesAChosenPicture() throws {
        store.choose(data(9), for: game, slot: .poster)
        let before = snapshot()
        let outcome = store.replaceAutomatic(data(3), for: game, slot: .poster, origin: .provider("steamgriddb"))
        guard case .keptPinned = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(snapshot(), before)
        XCTAssertEqual(try Data(contentsOf: store.active(game, .poster)!), data(9))
    }

    func testUnpinningKeepsThePictureAndLetsAProviderReplaceItLater() throws {
        store.choose(data(9), for: game, slot: .poster)
        store.unpin(game, .poster)
        XCTAssertEqual(try Data(contentsOf: store.active(game, .poster)!), data(9))
        guard case .stored = store.replaceAutomatic(data(3), for: game, slot: .poster, origin: .provider("steamgriddb")) else { return XCTFail() }
        XCTAssertTrue(snapshot().values.contains(data(9)), "the unpinned picture moved to History, it was not deleted")
    }

    func testChoosingTheSamePictureTwiceChangesNothing() throws {
        store.choose(data(4), for: game, slot: .logo)
        let before = snapshot()
        guard case .alreadyActive = store.choose(data(4), for: game, slot: .logo) else { return XCTFail() }
        XCTAssertEqual(snapshot(), before)
    }

    func testALostIndexChangesNoFileAndPicturesAreStillFound() throws {
        store.fill(data(1), for: game, slot: .poster, origin: .provider("steamgriddb"))
        store.flush()
        let before = snapshot()
        try FileManager.default.removeItem(at: root.appendingPathComponent(OEArtworkStore.indexName))

        let reopened = OEArtworkStore(root: root)
        XCTAssertNotNil(reopened.active(game, .poster))
        XCTAssertEqual(snapshot(), before)
        XCTAssertTrue(reopened.entry(game, .poster)?.pinned == true, "a picture the index does not know is treated as chosen")
        guard case .keptPinned = reopened.replaceAutomatic(data(2), for: game, slot: .poster, origin: .provider("x")) else { return XCTFail() }
    }

    func testAnUnreadableIndexIsKeptNotReplaced() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = root.appendingPathComponent(OEArtworkStore.indexName)
        try Data("not json".utf8).write(to: index)

        let reopened = OEArtworkStore(root: root)
        reopened.fill(data(1), for: game, slot: .poster, origin: .user)
        reopened.flush()

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("index.unreadable-") }, "the bad file was moved aside")
    }

    func testAPictureAPersonPlacedInTheFolderIsRespected() throws {
        let folder = root.appendingPathComponent("snes/poster", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data(7, ext: "jpg").write(to: folder.appendingPathComponent("Super Mario World.jpg"))
        let before = snapshot()

        guard case .keptExisting = store.fill(data(1), for: game, slot: .poster, origin: .provider("steamgriddb")) else { return XCTFail() }
        guard case .keptPinned = store.replaceAutomatic(data(1), for: game, slot: .poster, origin: .provider("steamgriddb")) else { return XCTFail() }
        XCTAssertEqual(snapshot(), before)
    }

    func testTwoGamesWithTheSameTitleKeepSeparateFiles() throws {
        let other = OEArtworkStore.Game(md5: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", system: game.system, title: game.title)
        store.fill(data(1), for: game, slot: .poster, origin: .user)
        store.fill(data(2), for: other, slot: .poster, origin: .user)
        XCTAssertNotEqual(store.active(game, .poster), store.active(other, .poster))
        XCTAssertEqual(try Data(contentsOf: store.active(game, .poster)!), data(1))
        XCTAssertEqual(try Data(contentsOf: store.active(other, .poster)!), data(2))
    }

    func testTitlesCannotEscapeTheFolder() throws {
        let sneaky = OEArtworkStore.Game(md5: "cccc", system: "../../etc", title: "../../x/..:y")
        guard case .stored(let url) = store.fill(data(1), for: sneaky, slot: .icon, origin: .user) else { return XCTFail() }
        XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
    }

    func testAMissingFolderIsRecreatedAndNothingElseMoves() throws {
        store.fill(data(1), for: game, slot: .poster, origin: .user)
        let before = snapshot()
        let other = OEArtworkStore.Game(md5: "dddd", system: "openemu.system.n64", title: "Mario Kart 64")
        store.fill(data(2), for: other, slot: .hero, origin: .user)
        for (path, bytes) in before { XCTAssertEqual(snapshot()[path], bytes) }
    }

    func testArchivingALibraryCoverKeepsItWithoutChangingTheActiveOne() throws {
        store.fill(data(1), for: game, slot: .cover, origin: .library)
        let active = store.active(game, .cover)

        guard case .stored = store.archive(data(2), for: game, slot: .cover, origin: .library) else { return XCTFail() }
        XCTAssertEqual(store.active(game, .cover), active)
        XCTAssertEqual(try Data(contentsOf: active!), data(1))
        XCTAssertEqual(store.history(game, .cover).count, 1)

        guard case .alreadyActive = store.archive(data(2), for: game, slot: .cover, origin: .library) else { return XCTFail() }
        guard case .alreadyActive = store.archive(data(1), for: game, slot: .cover, origin: .library) else { return XCTFail() }
        XCTAssertEqual(store.history(game, .cover).count, 1, "the same picture is not kept twice")
    }

    func testArchivingIntoAnEmptySlotFillsIt() throws {
        guard case .stored(let url) = store.archive(data(5), for: game, slot: .cover, origin: .library) else { return XCTFail() }
        XCTAssertEqual(store.active(game, .cover), url)
    }

    func testTheIndexSurvivesARestartWithOriginsAndPins() throws {
        store.fill(data(1), for: game, slot: .poster, origin: .provider("steamgriddb"))
        store.choose(data(2), for: game, slot: .hero)
        store.flush()

        let reopened = OEArtworkStore(root: root)
        XCTAssertEqual(reopened.entry(game, .poster)?.origin, "provider:steamgriddb")
        XCTAssertEqual(reopened.entry(game, .poster)?.pinned, false)
        XCTAssertEqual(reopened.entry(game, .hero)?.pinned, true)
    }

    // MARK: Icons

    /// A Windows icon holding PNG pictures at the given sizes, in the given order.
    private func icoData(sizes: [Int]) throws -> Data {
        let pngs: [Data] = try sizes.map { size in
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        }
        func le(_ value: Int, _ bytes: Int) -> [UInt8] { (0..<bytes).map { UInt8((value >> (8 * $0)) & 0xFF) } }
        var out = Data(le(0, 2) + le(1, 2) + le(sizes.count, 2))
        var offset = 6 + 16 * sizes.count
        for (size, png) in zip(sizes, pngs) {
            out.append(contentsOf: [UInt8(size % 256), UInt8(size % 256), 0, 0] + le(1, 2) + le(32, 2) + le(png.count, 4) + le(offset, 4))
            offset += png.count
        }
        pngs.forEach { out.append($0) }
        return out
    }

    func testAnIconFileIsReadAtItsLargestSizeWhateverTheOrder() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for sizes in [[16, 32, 64], [64, 32, 16], [32, 64, 16]] {
            let file = root.appendingPathComponent("icon-\(sizes.map(String.init).joined(separator: "-")).ico")
            try icoData(sizes: sizes).write(to: file)
            let image = try XCTUnwrap(OEArtworkStore.largestImage(at: file), "\(sizes)")
            XCTAssertEqual(image.width, 64, "\(sizes)")
        }
    }

    func testAnUnreadableFileGivesNoPictureInsteadOfCrashing() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("junk.ico")
        try Data([1, 2, 3, 4]).write(to: file)
        XCTAssertNil(OEArtworkStore.largestImage(at: file))
        XCTAssertNil(OEArtworkStore.largestImage(at: root.appendingPathComponent("missing.ico")))
    }

    // MARK: Hard cases

    func testManyThreadsFillingAtOnceLoseNothing() throws {
        let games = (0..<60).map { OEArtworkStore.Game(md5: String(format: "%032x", $0), system: "openemu.system.nes", title: "Game \($0 % 20)") }
        DispatchQueue.concurrentPerform(iterations: games.count * 3) { n in
            let g = games[n % games.count]
            store.fill(data(UInt8(n % 200)), for: g, slot: .cover, origin: .provider("p"))
            if n % 7 == 0 { store.choose(data(UInt8(n % 200 + 1)), for: g, slot: .poster) }
        }
        store.flush()
        for g in games {
            let url = try XCTUnwrap(store.active(g, .cover), g.title)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        let reopened = OEArtworkStore(root: root)
        for g in games { XCTAssertNotNil(reopened.active(g, .cover)) }
        let leftovers = snapshot().keys.filter { $0.contains(".incoming-") }
        XCTAssertEqual(leftovers, [], "no staged file is left behind")
    }

    func testStrangeTitlesStayInsideTheFolderAndKeepTheirPicture() throws {
        let titles = ["", ".", "..", "...", " ", "a/b", "../../etc/passwd", "CON", "aux.png", String(repeating: "x", count: 600),
                      String(repeating: "é", count: 300), "title\u{0}with null", "emoji 🎮", "trailing dot.", "  spaced  "]
        for (n, title) in titles.enumerated() {
            let g = OEArtworkStore.Game(md5: String(format: "%032x", n), system: "openemu.system.snes", title: title)
            guard case .stored(let url) = store.fill(data(UInt8(n)), for: g, slot: .cover, origin: .library) else { return XCTFail("title \(title.debugDescription) was not stored") }
            XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"), title)
            XCTAssertEqual(try Data(contentsOf: url), data(UInt8(n)), title)
            XCTAssertEqual(store.active(g, .cover), url, title)
        }
    }

    func testTitlesThatDifferOnlyInCaseOrAccentsDoNotShareAFile() throws {
        let a = OEArtworkStore.Game(md5: String(format: "%032x", 1), system: "openemu.system.snes", title: "Zelda")
        let b = OEArtworkStore.Game(md5: String(format: "%032x", 2), system: "openemu.system.snes", title: "ZELDA")
        let c = OEArtworkStore.Game(md5: String(format: "%032x", 3), system: "openemu.system.snes", title: "Caf\u{E9}")
        let d = OEArtworkStore.Game(md5: String(format: "%032x", 4), system: "openemu.system.snes", title: "Cafe\u{301}")
        for (n, g) in [a, b, c, d].enumerated() { store.fill(data(UInt8(n)), for: g, slot: .cover, origin: .library) }
        for (n, g) in [a, b, c, d].enumerated() {
            let url = try XCTUnwrap(store.active(g, .cover), g.title)
            XCTAssertEqual(try Data(contentsOf: url), data(UInt8(n)), "\(g.title) must still have its own picture")
        }
    }

    func testLongTitlesInAnyScriptAreStillKept() throws {
        let titles = [String(repeating: "日", count: 200), String(repeating: "🎮", count: 200), String(repeating: "é", count: 400)]
        for (n, title) in titles.enumerated() {
            let g = OEArtworkStore.Game(md5: String(format: "%032x", n + 100), system: "openemu.system.snes", title: title)
            XCTAssertLessThanOrEqual(OEArtworkStore.fileStem(title).utf8.count, 160)
            guard case .stored = store.fill(data(1), for: g, slot: .cover, origin: .library) else { return XCTFail("not kept: \(title.prefix(3))") }
            guard case .stored = store.choose(data(2), for: g, slot: .cover) else { return XCTFail("replace failed: \(title.prefix(3))") }
            XCTAssertEqual(store.history(g, .cover).count, 1)
        }
    }

    func testHistoryListsOnlyTheGamesOwnPictures() throws {
        let mario = OEArtworkStore.Game(md5: String(format: "%032x", 1), system: "openemu.system.snes", title: "Mario")
        let kart = OEArtworkStore.Game(md5: String(format: "%032x", 2), system: "openemu.system.snes", title: "Mario Kart")
        for g in [mario, kart] {
            store.fill(data(1), for: g, slot: .cover, origin: .library)
            store.choose(data(2), for: g, slot: .cover)
        }
        XCTAssertEqual(store.history(mario, .cover).count, 1)
        XCTAssertEqual(store.history(kart, .cover).count, 1)
        XCTAssertTrue(store.history(mario, .cover)[0].lastPathComponent.hasPrefix("Mario 2"))
    }

    func testAnIndexThatCannotBeReadIsNeverWrittenOver() throws {
        store.fill(data(1), for: game, slot: .cover, origin: .provider("p"))
        store.flush()
        let index = root.appendingPathComponent(OEArtworkStore.indexName)
        let before = try Data(contentsOf: index)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: index.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: index.path) }

        let reopened = OEArtworkStore(root: root)
        XCTAssertNotNil(reopened.active(game, .cover), "the picture is still found by its name")
        reopened.fill(data(9), for: OEArtworkStore.Game(md5: String(format: "%032x", 7), system: "openemu.system.snes", title: "Other"), slot: .cover, origin: .library)
        reopened.flush()

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: index.path)
        XCTAssertEqual(try Data(contentsOf: index), before, "the unreadable index was left alone")
    }

    func testAPickIsPinnedAndAutomaticFetchingNeverReplacesIt() throws {
        store.fill(data(1), for: game, slot: .poster, origin: .provider("libretro"))
        OEArtworkChoice.choose(data(2), for: game, slot: .poster, provider: "steamgriddb", store: store)

        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.active(game, .poster))), data(2))
        XCTAssertEqual(store.entry(game, .poster)?.pinned, true)
        XCTAssertEqual(store.entry(game, .poster)?.origin, "provider:steamgriddb")
        XCTAssertEqual(store.history(game, .poster).count, 1, "the picture it replaced is kept")

        // Switching provider and coming back leaves the pick where it is.
        if case .keptPinned = store.replaceAutomatic(data(3), for: game, slot: .poster, origin: .provider("screenscraper")) {} else { XCTFail("a pinned pick was replaced") }
        if case .keptPinned = store.replaceAutomatic(data(4), for: game, slot: .poster, origin: .provider("steamgriddb")) {} else { XCTFail("a pinned pick was replaced") }
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.active(game, .poster))), data(2))
    }

    func testResetToAutomaticKeepsThePictureAndLetsProvidersReplaceIt() throws {
        OEArtworkChoice.choose(data(2), for: game, slot: .hero, provider: nil, store: store)
        XCTAssertEqual(store.entry(game, .hero)?.origin, "user")
        OEArtworkChoice.resetToAutomatic(game, slot: .hero, store: store)

        XCTAssertEqual(store.entry(game, .hero)?.pinned, false)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.active(game, .hero))), data(2), "resetting deletes nothing")
        store.replaceAutomatic(data(5), for: game, slot: .hero, origin: .provider("steamgriddb"))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.active(game, .hero))), data(5))
        XCTAssertEqual(store.history(game, .hero).count, 1, "the earlier pick moved to History, not away")
    }

    func testAPickSurvivesReopeningTheStore() throws {
        OEArtworkChoice.choose(data(2), for: game, slot: .logo, provider: "steamgriddb", store: store)
        let reopened = OEArtworkStore(root: root)
        XCTAssertEqual(reopened.entry(game, .logo)?.pinned, true)
    }

    private func png(width: Int, height: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testAPinnedPickReachesTheBigPictureCopiesAndChangesWithTheNextPick() throws {
        let previous = OEArtworkStore.shared
        OEArtworkStore.useRoot(root)
        defer { OEArtworkStore.install(previous) }
        let signature = "test-\(UUID().uuidString)"
        let display = OEBigPictureArtStore(signature: signature)
        defer {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(at: caches.appendingPathComponent("OpenEmu/BigPictureArt/v3/\(signature)"))
        }

        display.syncPinned(game, md5: game.md5)
        XCTAssertNil(display.read(md5: game.md5, providerIDs: []).stored.poster, "nothing pinned, nothing copied")

        OEArtworkStore.shared.fill(try png(width: 10, height: 15), for: game, slot: .poster, origin: .provider("libretro"))
        display.syncPinned(game, md5: game.md5)
        XCTAssertNil(display.read(md5: game.md5, providerIDs: []).stored.poster, "an automatic picture is not forced on the display copies")

        OEArtworkChoice.choose(try png(width: 20, height: 30), for: game, slot: .poster, provider: nil, store: OEArtworkStore.shared)
        display.syncPinned(game, md5: game.md5)
        let first = try XCTUnwrap(display.read(md5: game.md5, providerIDs: []).stored)
        XCTAssertEqual(first.poster.map { Int($0.size.width) }, 20)
        XCTAssertTrue(first.standardPoster)

        OEArtworkChoice.choose(try png(width: 40, height: 60), for: game, slot: .poster, provider: nil, store: OEArtworkStore.shared)
        display.syncPinned(game, md5: game.md5)
        XCTAssertEqual(display.read(md5: game.md5, providerIDs: []).stored.poster.map { Int($0.size.width) }, 40, "the newer pick wins")
    }

    // MARK: Changing provider

    func testAPreferredProviderReplacesAnotherProvidersAutomaticPictureAndKeepsTheOldOne() throws {
        _ = store.fill(data(1), for: game, slot: .poster, origin: .provider("libretro"))
        guard case .stored(let url) = store.supply(data(2), for: game, slot: .poster, origin: .provider("steamgriddb"), preferred: true) else { return XCTFail() }
        XCTAssertEqual(try Data(contentsOf: url), data(2))
        XCTAssertEqual(store.entry(game, .poster)?.origin, "provider:steamgriddb")
        XCTAssertEqual(try store.history(game, .poster).map { try Data(contentsOf: $0) }, [data(1)], "the old picture is kept")
    }

    func testWithoutAPreferredProviderTheFirstPictureStays() throws {
        _ = store.fill(data(1), for: game, slot: .poster, origin: .provider("libretro"))
        guard case .keptExisting = store.supply(data(2), for: game, slot: .poster, origin: .provider("steamgriddb"), preferred: false) else { return XCTFail() }
        XCTAssertEqual(store.entry(game, .poster)?.origin, "provider:libretro")
        XCTAssertTrue(store.history(game, .poster).isEmpty)
    }

    func testAPreferredProviderNeverReplacesAPinnedOrOwnPicture() throws {
        _ = store.choose(data(1), for: game, slot: .poster, origin: .user)
        guard case .keptExisting = store.supply(data(2), for: game, slot: .poster, origin: .provider("steamgriddb"), preferred: true) else { return XCTFail() }
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.active(game, .poster))), data(1))
        store.unpin(game, .poster)
        // Unpinned but the person's own file: only a provider's automatic picture is replaced.
        guard case .keptExisting = store.supply(data(2), for: game, slot: .poster, origin: .provider("steamgriddb"), preferred: true) else { return XCTFail() }
    }

    func testSwitchingProvidersBackAndForthLosesNothing() throws {
        _ = store.fill(data(1), for: game, slot: .hero, origin: .provider("libretro"))
        _ = store.supply(data(2), for: game, slot: .hero, origin: .provider("steamgriddb"), preferred: true)
        _ = store.supply(data(3), for: game, slot: .hero, origin: .provider("libretro"), preferred: true)
        let everything = Set(snapshot().values)
        XCTAssertTrue(everything.isSuperset(of: [data(1), data(2), data(3)]), "every picture ever stored is still a file")
    }

    func testReusableOnlyCountsPicturesThatAlreadyDoTheJob() throws {
        _ = store.fill(data(1), for: game, slot: .poster, origin: .provider("libretro"))
        // Nothing chosen on its own: any provider in use counts.
        XCTAssertNotNil(store.reusable(game, .poster, providers: ["steamgriddb", "libretro"], preferred: nil))
        XCTAssertNil(store.reusable(game, .poster, providers: ["steamgriddb"], preferred: nil))
        // A source chosen on its own: only its own pictures count, so a change of provider fetches.
        XCTAssertNil(store.reusable(game, .poster, providers: ["steamgriddb"], preferred: "steamgriddb"))
        XCTAssertNotNil(store.reusable(game, .poster, providers: ["libretro"], preferred: "libretro"))
        // A pick always counts, and a library cover never does.
        _ = store.choose(data(5), for: game, slot: .hero, origin: .user)
        XCTAssertNotNil(store.reusable(game, .hero, providers: [], preferred: "steamgriddb"))
        _ = store.fill(data(6), for: game, slot: .cover, origin: .library)
        XCTAssertNil(store.reusable(game, .cover, providers: ["steamgriddb"], preferred: nil))
    }

    func testAFailedReplaceLeavesThePictureAndTheIndexAsTheyWere() throws {
        _ = store.fill(data(1), for: game, slot: .poster, origin: .provider("libretro"))
        let before = try XCTUnwrap(store.entry(game, .poster))
        let beforeFiles = snapshot()
        // A plain file where History must go makes the replace fail after it has started.
        let folder = try XCTUnwrap(store.active(game, .poster)).deletingLastPathComponent()
        try Data("in the way".utf8).write(to: folder.appendingPathComponent(OEArtworkStore.historyName))

        XCTAssertEqual(store.supply(data(2), for: game, slot: .poster, origin: .provider("steamgriddb"), preferred: true), .failed)
        XCTAssertEqual(store.entry(game, .poster), before)
        var after = snapshot()
        after.removeValue(forKey: "snes/poster/" + OEArtworkStore.historyName)
        XCTAssertEqual(after, beforeFiles, "no picture lost and no staging file left behind")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.active(game, .poster))), data(1))
    }

    // MARK: Library covers from the chosen source

    private struct FakeProvider: OEBigPictureArtProvider {
        let id: String
        let picture: NSImage?
        var title: String { id }
        var isThrottled: Bool { false }
        var providesStandardPosters: Bool { true }
        func art(for key: OEBigPictureArt.GameKey) async -> OEBigPictureArtSet { OEBigPictureArtSet(grid: picture, isDefinitive: true) }
    }

    func testACoverComesFromTheFirstProviderThatHasOne() async throws {
        let first = NSImage(size: NSSize(width: 10, height: 20)), second = NSImage(size: NSSize(width: 30, height: 40))
        let key = OEBigPictureArt.GameKey(md5: "aa", name: "Zelda", systemIdentifier: "openemu.system.nes")
        let found = await OEArtworkCoverSource.cover(for: key, providers: [FakeProvider(id: "a", picture: nil), FakeProvider(id: "b", picture: first), FakeProvider(id: "c", picture: second)])
        XCTAssertTrue(found === first)
        let none = await OEArtworkCoverSource.cover(for: key, providers: [FakeProvider(id: "a", picture: nil)])
        XCTAssertNil(none)
    }

    func testAutomaticAndLibraryOnlyLeaveCoversToTheLibrary() throws {
        let key = OEBigPictureArtSource.defaultsKey, saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        for source in [OEBigPictureArtSource.automatic, .libraryOnly] {
            UserDefaults.standard.set(source.rawValue, forKey: key)
            XCTAssertNil(OEArtworkCoverSource.providersForCovers(), source.rawValue)
        }
        UserDefaults.standard.set(OEBigPictureArtSource.libretro.rawValue, forKey: key)
        XCTAssertEqual(OEArtworkCoverSource.providersForCovers()?.first?.id, "libretro")
    }

    // MARK: Picker filters and other providers

    func testTheSteamGridDBFilterBuildsTheQueryAndNeverAllowsAdultContent() {
        func query(_ filter: SteamGridDBFilter, _ type: SteamGridDBItemType) -> [String: String] {
            Dictionary(uniqueKeysWithValues: filter.queryItems(for: type).map { ($0.name, $0.value ?? "") })
        }
        let none = query(SteamGridDBFilter(), .grid)
        XCTAssertEqual(none["nsfw"], "false")
        XCTAssertEqual(none["types"], "static")
        XCTAssertNil(none["styles"]); XCTAssertNil(none["dimensions"])
        XCTAssertEqual(none["mimes"], "image/png,image/jpeg,image/webp")

        let all = query(SteamGridDBFilter(style: "blurred", dimensions: "600x900", mime: "image/png"), .grid)
        XCTAssertEqual(all["styles"], "blurred")
        XCTAssertEqual(all["dimensions"], "600x900")
        XCTAssertEqual(all["mimes"], "image/png")
        XCTAssertEqual(all["nsfw"], "false")

        // Logos have no size filter, so one that was set is not sent.
        XCTAssertNil(query(SteamGridDBFilter(dimensions: "600x900"), .logo)["dimensions"])
    }

    func testEverySlotOffersItsOwnStylesAndSizes() {
        for slot in OEArtworkStore.Slot.allCases { XCTAssertFalse(SteamGridDBFilter.styles(for: slot).isEmpty, slot.rawValue) }
        XCTAssertTrue(SteamGridDBFilter.dimensions(for: .logo).isEmpty)
        XCTAssertTrue(SteamGridDBFilter.dimensions(for: .hero).allSatisfy { $0.hasPrefix("1920") || $0.hasPrefix("3840") || $0.hasPrefix("1600") })
        XCTAssertTrue(SteamGridDBFilter.dimensions(for: .poster).contains("600x900"))
    }

    func testAProviderThatOffersNoPicturesReturnsNone() async {
        struct Quiet: OEBigPictureArtProvider {
            var id: String { "quiet" }; var title: String { id }; var isThrottled: Bool { false }; var providesStandardPosters: Bool { false }
            func art(for key: OEBigPictureArt.GameKey) async -> OEBigPictureArtSet { OEBigPictureArtSet() }
        }
        let key = OEBigPictureArt.GameKey(md5: "aa", name: "Zelda", systemIdentifier: "openemu.system.nes")
        let none = await Quiet().pictures(for: key, slot: .poster)
        XCTAssertTrue(none.isEmpty)
    }

    func testAPickedProviderPictureIsStoredAsReceivedAndPinnedWithItsProvider() throws {
        let picture = OEProviderPicture(provider: "libretro", providerTitle: "libretro-thumbnails", data: data(8))
        guard case .stored(let url) = OEArtworkChoice.choose(picture.data, for: game, slot: .poster, provider: picture.provider, store: store) else { return XCTFail() }
        XCTAssertEqual(try Data(contentsOf: url), data(8), "the bytes the provider sent")
        XCTAssertEqual(store.entry(game, .poster)?.origin, "provider:libretro")
        XCTAssertEqual(store.entry(game, .poster)?.pinned, true)
    }

    // MARK: Review follow-ups

    func testAFinishedCoverDownloadIsAppliedOnlyWhileTheGameIsStillWaiting() {
        XCTAssertTrue(OEArtworkCoverSource.shouldApply(.processing))
        for status in [OEDBGame.Status.ok, .alert, .downloading] { XCTAssertFalse(OEArtworkCoverSource.shouldApply(status), "\(status)") }
    }

    func testBigPictureReadsThePicturesTheFolderAlreadyHasAndOnlyForMissingSlots() throws {
        let png = try png(width: 600, height: 900)
        _ = store.fill(png, for: game, slot: .poster, origin: .provider("steamgriddb"))
        _ = store.fill(png, for: game, slot: .hero, origin: .provider("libretro"))
        _ = store.fill(png, for: game, slot: .icon, origin: .provider("steamgriddb"))

        // Automatic: any provider in use counts. The SteamGridDB poster and icon are the shape the screens want.
        let all = (hero: true, poster: true, icon: true, logo: true)
        let automatic = OEArtworkFolderReuse.pictures(for: game, providers: ["steamgriddb", "libretro"], preferred: nil, store: store, missing: all)
        XCTAssertNotNil(automatic.set.grid); XCTAssertNotNil(automatic.set.hero); XCTAssertNotNil(automatic.set.icon)
        XCTAssertNil(automatic.set.logo, "nothing stored for the logo")
        XCTAssertTrue(automatic.standard); XCTAssertTrue(automatic.square)

        // A slot already supplied is not read again.
        let onlyHero = OEArtworkFolderReuse.pictures(for: game, providers: ["steamgriddb", "libretro"], preferred: nil, store: store,
                                                     missing: (hero: true, poster: false, icon: false, logo: false))
        XCTAssertNotNil(onlyHero.set.hero); XCTAssertNil(onlyHero.set.grid); XCTAssertNil(onlyHero.set.icon)

        // A source chosen on its own: only its pictures count, so the others are fetched again.
        let libretro = OEArtworkFolderReuse.pictures(for: game, providers: ["libretro"], preferred: "libretro", store: store, missing: all)
        XCTAssertNotNil(libretro.set.hero); XCTAssertNil(libretro.set.grid); XCTAssertNil(libretro.set.icon)
        XCTAssertFalse(libretro.standard)

        // Nothing is read from a folder with nothing in it.
        let empty = OEArtworkFolderReuse.pictures(for: .init(md5: "zz", system: "openemu.system.nes", title: "None"), providers: ["steamgriddb"], preferred: nil, store: store, missing: all)
        XCTAssertFalse(empty.set.hasAny)
    }
}
