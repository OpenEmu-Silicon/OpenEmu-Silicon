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
import CryptoKit
import XCTest
@testable import OpenEmu

/// Reading a person's own artwork folder: which pictures it finds, what slot and game each one is for, which shapes
/// get a warning, and that the folder itself is never changed. Every test builds its own sample folder.
final class ArtworkFolderScanTests: XCTestCase {

    private var folder: URL!
    private var storeRoot: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ArtworkFolderScanTests-\(UUID().uuidString)", isDirectory: true)
        folder = base.appendingPathComponent("mine", isDirectory: true)
        storeRoot = base.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }

    private func png(_ width: Int, _ height: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    @discardableResult
    private func write(_ path: String, _ width: Int = 600, _ height: Int = 900) throws -> URL {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png(width, height).write(to: url)
        return url
    }

    private func digests() throws -> [String: String] {
        var result = [String: String]()
        let base = folder.standardizedFileURL.path + "/"
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            result[String(url.standardizedFileURL.path.dropFirst(base.count))] = hash
        }
        return result
    }

    func testFlatNamesAndSlotSuffixes() throws {
        try write("Sonic.png")
        try write("Sonic-poster.png", 600, 900)
        try write("Sonic-hero.png", 1920, 620)
        try write("Sonic_icon.png", 512, 512)
        try write("Sonic-logo.png", 800, 300)
        let found = ArtworkFolderScan.scan(folder)
        let slots = Dictionary(uniqueKeysWithValues: found.map { ($0.url.lastPathComponent, $0.slot) })
        XCTAssertEqual(slots["Sonic.png"], .cover)
        XCTAssertEqual(slots["Sonic-poster.png"], .poster)
        XCTAssertEqual(slots["Sonic-hero.png"], .hero)
        XCTAssertEqual(slots["Sonic_icon.png"], .icon)
        XCTAssertEqual(slots["Sonic-logo.png"], .logo)
        XCTAssertTrue(found.allSatisfy { $0.title == "Sonic" })
        XCTAssertTrue(found.allSatisfy { $0.warning == nil }, "\(found.compactMap { $0.warning })")
    }

    func testEsDeLayoutGivesTheSlotFromTheFolderName() throws {
        try write("snes/covers/Super Mario World.png")
        try write("snes/fanart/Super Mario World.jpg.png", 1920, 1080)
        try write("snes/marquees/Super Mario World.png", 800, 300)
        try write("snes/miximages/Super Mario World.png", 640, 900)
        try write("snes/videos/Super Mario World.png")
        let slots = Dictionary(uniqueKeysWithValues: ArtworkFolderScan.scan(folder).map { ($0.url.pathComponents.suffix(2).joined(separator: "/"), $0.slot) })
        XCTAssertEqual(slots["covers/Super Mario World.png"], .cover)
        XCTAssertEqual(slots["fanart/Super Mario World.jpg.png"], .hero)
        XCTAssertEqual(slots["marquees/Super Mario World.png"], .logo)
        XCTAssertEqual(slots["miximages/Super Mario World.png"], .poster)
        // "videos" is not an artwork folder, so its picture falls back to the default cover slot.
        XCTAssertEqual(slots["videos/Super Mario World.png"], .cover)
    }

    func testWrongShapesGetAWarningButAreStillFound() throws {
        try write("Zelda-icon.png", 1200, 300)
        try write("Zelda-hero.png", 300, 900)
        try write("Zelda-poster.png", 600, 900)
        let found = Dictionary(uniqueKeysWithValues: ArtworkFolderScan.scan(folder).map { ($0.slot, $0) })
        XCTAssertNotNil(found[.icon]?.warning)
        XCTAssertNotNil(found[.hero]?.warning)
        XCTAssertNil(found[.poster]?.warning)
    }

    func testHistoryFoldersLinksAndOtherFilesAreSkipped() throws {
        try write("History/Old.png")
        try write("Real.png")
        try "not a picture".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Linked.png"), withDestinationURL: folder.appendingPathComponent("Real.png"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Loop"), withDestinationURL: folder)
        XCTAssertEqual(ArtworkFolderScan.scan(folder).map { $0.url.lastPathComponent }, ["Real.png"])
    }

    func testDeepFoldersStopAtThreeLevels() throws {
        try write("a/b/c/Near.png")
        try write("a/b/c/d/Far.png")
        XCTAssertEqual(ArtworkFolderScan.scan(folder).map { $0.title }, ["Near"])
    }

    func testMatchingIsByNameAndNeverGuessesBetweenTwoGamesWithTheSameName() throws {
        let found = [
            ArtworkFolderScan.Found(url: URL(fileURLWithPath: "/a/Sonic.png"), title: "Sonic", slot: .cover, warning: nil),
            ArtworkFolderScan.Found(url: URL(fileURLWithPath: "/a/sonic-hero.png"), title: "sonic", slot: .hero, warning: nil),
            ArtworkFolderScan.Found(url: URL(fileURLWithPath: "/b/SONIC.jpg"), title: "SONIC", slot: .cover, warning: nil),
            ArtworkFolderScan.Found(url: URL(fileURLWithPath: "/a/Twin.png"), title: "Twin", slot: .cover, warning: nil),
            ArtworkFolderScan.Found(url: URL(fileURLWithPath: "/a/Nothing.png"), title: "Nothing", slot: .cover, warning: nil),
        ]
        let result = ArtworkFolderMatcher.assign(found, gameNames: ["Sonic", "Twin", "Twin"])
        XCTAssertEqual(result.matched.map { "\($0.found.url.lastPathComponent)>\($0.game)" }, ["Sonic.png>0", "sonic-hero.png>0"])
        XCTAssertEqual(Set(result.unmatched.map { $0.url.lastPathComponent }), ["SONIC.jpg", "Twin.png", "Nothing.png"])
    }

    func testScanningAndStoringLeavesTheFolderByteForByteUnchanged() throws {
        try write("Pong.png")
        try write("Pong-poster.png", 600, 900)
        try write("arcade/marquees/Pong.png", 800, 300)
        let before = try digests()
        let modified = try folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        let store = OEArtworkStore(root: storeRoot)
        let game = OEArtworkStore.Game(md5: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", system: "openemu.system.2600", title: "Pong")
        for file in ArtworkFolderScan.scan(folder) {
            let outcome = OEArtworkChoice.choose(try Data(contentsOf: file.url), for: game, slot: file.slot, provider: nil, store: store)
            guard case .stored = outcome else { return XCTFail("\(file.url.lastPathComponent): \(outcome)") }
        }

        XCTAssertEqual(try digests(), before)
        XCTAssertEqual(try folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
        XCTAssertEqual(store.entry(game, .poster)?.pinned, true)
        XCTAssertEqual(store.entry(game, .logo)?.origin, OEArtworkStore.Origin.user.raw)
        XCTAssertNotNil(store.active(game, .cover))
    }
}
