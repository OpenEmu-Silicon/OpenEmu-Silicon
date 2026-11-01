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
}
