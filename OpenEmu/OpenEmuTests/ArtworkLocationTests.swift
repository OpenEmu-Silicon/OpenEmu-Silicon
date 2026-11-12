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

/// Moving the artwork folder must never lose, change or overwrite a picture, in the old place or the new one.
final class ArtworkLocationTests: XCTestCase {

    private var base: URL!
    private var old: URL { base.appendingPathComponent("old", isDirectory: true) }
    private var new: URL { base.appendingPathComponent("new", isDirectory: true) }

    private let game = OEArtworkStore.Game(md5: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", system: "openemu.system.nes", title: "Metroid")
    private func data(_ byte: UInt8) -> Data { Data([0x89, 0x50, 0x4E, 0x47, byte, 2, 3]) }

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("ArtworkLocationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func snapshot(_ root: URL) -> [String: Data] {
        var found = [String: Data]()
        let prefix = root.standardizedFileURL.path + "/"
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return found }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            found[String(url.standardizedFileURL.path.dropFirst(prefix.count))] = try? Data(contentsOf: url)
        }
        return found
    }

    /// A folder with a picture, a replaced picture in History, and an index.
    private func fillOld() -> OEArtworkStore {
        let store = OEArtworkStore(root: old)
        store.fill(data(1), for: game, slot: .cover, origin: .library)
        store.choose(data(2), for: game, slot: .cover)
        store.fill(data(3), for: game, slot: .hero, origin: .provider("steamgriddb"))
        store.flush()
        return store
    }

    func testCopiesEverythingAndLeavesTheOldFolderUntouched() throws {
        _ = fillOld()
        let before = snapshot(old)
        XCTAssertGreaterThanOrEqual(before.count, 4, "two pictures, one in History, and the index")

        guard case .success(let count) = OEArtworkLocation.copyAndVerify(from: old, to: new) else { return XCTFail() }
        XCTAssertEqual(count, before.count)
        XCTAssertEqual(snapshot(new), before)
        XCTAssertEqual(snapshot(old), before)
    }

    func testTheCopyWorksAsAStore() throws {
        let store = fillOld()
        let active = try Data(contentsOf: try XCTUnwrap(store.active(game, .cover)))
        _ = OEArtworkLocation.copyAndVerify(from: old, to: new)

        let moved = OEArtworkStore(root: new)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(moved.active(game, .cover))), active)
        XCTAssertEqual(moved.entry(game, .cover)?.pinned, true, "a chosen picture is still pinned in the new place")
        XCTAssertEqual(moved.history(game, .cover).count, 1)
    }

    func testRunningItAgainCopiesNothingMore() throws {
        _ = fillOld()
        _ = OEArtworkLocation.copyAndVerify(from: old, to: new)
        let after = snapshot(new)
        guard case .success(let count) = OEArtworkLocation.copyAndVerify(from: old, to: new) else { return XCTFail() }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(snapshot(new), after)
    }

    func testADifferentFileAlreadyThereStopsEverythingBeforeAnyCopy() throws {
        _ = fillOld()
        let theirs = new.appendingPathComponent("nes/cover", isDirectory: true)
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        let clash = theirs.appendingPathComponent("Metroid.png")
        try Data("their own picture".utf8).write(to: clash)
        let before = snapshot(new)
        let oldBefore = snapshot(old)

        guard case .failure(.conflict(let names)) = OEArtworkLocation.copyAndVerify(from: old, to: new) else { return XCTFail() }
        XCTAssertEqual(names, ["nes/cover/Metroid.png"])
        XCTAssertEqual(snapshot(new), before, "nothing was added to the new folder")
        XCTAssertEqual(snapshot(old), oldBefore)
        XCTAssertEqual(try Data(contentsOf: clash), Data("their own picture".utf8))
    }

    func testOtherFilesInTheNewFolderAreLeftAlone() throws {
        _ = fillOld()
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        let mine = new.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: mine)
        guard case .success = OEArtworkLocation.copyAndVerify(from: old, to: new) else { return XCTFail() }
        XCTAssertEqual(try Data(contentsOf: mine), Data("keep".utf8))
    }

    func testTheSameOrNestedFoldersAreRefused() throws {
        _ = fillOld()
        XCTAssertEqual(OEArtworkLocation.copyAndVerify(from: old, to: old).failureValue, .sameFolder)
        XCTAssertEqual(OEArtworkLocation.copyAndVerify(from: old, to: old.appendingPathComponent("inside")).failureValue, .nested)
        XCTAssertEqual(OEArtworkLocation.copyAndVerify(from: old.appendingPathComponent("nes"), to: old).failureValue, .nested)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.appendingPathComponent("inside").path), "nothing was created")
    }

    func testAFolderThatDoesNotExistYetIsAnEmptyLibrary() throws {
        guard case .success(let count) = OEArtworkLocation.copyAndVerify(from: old, to: new) else { return XCTFail() }
        XCTAssertEqual(count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.path))
    }

    func testICloudAndLocalFolders() {
        XCTAssertTrue(OEArtworkLocation.isInCloudFolder("/Users/a/Library/Mobile Documents/com~apple~CloudDocs/Art"))
        XCTAssertTrue(OEArtworkLocation.isInCloudFolder("/Users/a/Library/CloudStorage/Dropbox/Art"))
        XCTAssertFalse(OEArtworkLocation.isInCloudFolder("/Users/a/Documents/Art"))
        XCTAssertEqual(OEArtworkLocation.warnings(for: new), [], "a folder in the temporary directory is local")
    }

    func testMovingSwitchesTheStoreAndKeepsEverything() throws {
        let key = OEArtworkLocation.defaultsKey
        let previousPath = UserDefaults.standard.string(forKey: key)
        let previousStore = OEArtworkStore.shared
        defer {
            if let previousPath { UserDefaults.standard.set(previousPath, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            OEArtworkStore.useRoot(previousStore.root)
        }

        OEArtworkStore.useRoot(old)
        OEArtworkStore.shared.fill(data(1), for: game, slot: .cover, origin: .library)
        OEArtworkStore.shared.choose(data(2), for: game, slot: .cover)
        let oldBefore = snapshot(old)

        guard case .success = OEArtworkLocation.move(to: new) else { return XCTFail() }
        XCTAssertEqual(OEArtworkStore.shared.root.standardizedFileURL, new.standardizedFileURL)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), new.standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(OEArtworkStore.shared.active(game, .cover))), data(2))
        XCTAssertEqual(snapshot(old).filter { $0.key != OEArtworkStore.indexName }, oldBefore.filter { $0.key != OEArtworkStore.indexName },
                       "the old folder keeps every picture")

        // A later pick goes to the new folder only.
        OEArtworkStore.shared.choose(data(9), for: game, slot: .cover)
        XCTAssertEqual(snapshot(old).filter { $0.key != OEArtworkStore.indexName }, oldBefore.filter { $0.key != OEArtworkStore.indexName })
    }

    /// Runs a body with the store pointed at `old`, and puts the app's real settings back afterwards.
    private func withStore(at root: URL, _ body: () throws -> Void) rethrows {
        let key = OEArtworkLocation.defaultsKey
        let previousPath = UserDefaults.standard.string(forKey: key)
        let previousStore = OEArtworkStore.shared
        defer {
            if let previousPath { UserDefaults.standard.set(previousPath, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            OEArtworkStore.useRoot(previousStore.root)
        }
        OEArtworkStore.useRoot(root)
        try body()
    }

    func testAFailedMoveSwitchesNothing() throws {
        try withStore(at: old) {
            OEArtworkStore.shared.fill(data(1), for: game, slot: .cover, origin: .library)
            let before = UserDefaults.standard.string(forKey: OEArtworkLocation.defaultsKey)
            guard case .failure(.nested) = OEArtworkLocation.move(to: old.appendingPathComponent("inside")) else { return XCTFail() }
            XCTAssertEqual(OEArtworkStore.shared.root.standardizedFileURL, old.standardizedFileURL)
            XCTAssertEqual(UserDefaults.standard.string(forKey: OEArtworkLocation.defaultsKey), before)
        }
    }

    func testAMoveKeepsBothWhenTheNewFolderHasADifferentFileOfTheSameName() throws {
        try withStore(at: old) {
            OEArtworkStore.shared.fill(data(1), for: game, slot: .cover, origin: .library)
            OEArtworkStore.shared.choose(data(2), for: game, slot: .cover)
            let theirs = new.appendingPathComponent("nes/cover", isDirectory: true)
            try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
            let clash = theirs.appendingPathComponent("Metroid.png")
            try Data("their own picture".utf8).write(to: clash)

            guard case .success = OEArtworkLocation.move(to: new) else { return XCTFail() }
            XCTAssertEqual(try Data(contentsOf: clash), Data("their own picture".utf8), "their file is untouched")
            let active = try XCTUnwrap(OEArtworkStore.shared.active(game, .cover))
            XCTAssertEqual(try Data(contentsOf: active), data(2), "the chosen picture is still the active one")
            XCTAssertNotEqual(active, clash)
            XCTAssertEqual(OEArtworkStore.shared.entry(game, .cover)?.pinned, true)
            XCTAssertEqual(OEArtworkStore.shared.history(game, .cover).count, 1)
        }
    }

    func testMovingAwayChoosingAndMovingBackLosesNothing() throws {
        try withStore(at: old) {
            OEArtworkStore.shared.fill(data(1), for: game, slot: .cover, origin: .library)
            guard case .success = OEArtworkLocation.move(to: new) else { return XCTFail("out") }
            OEArtworkStore.shared.choose(data(2), for: game, slot: .cover)   // the same name now holds different bytes than in `old`
            OEArtworkStore.shared.fill(data(5), for: game, slot: .hero, origin: .provider("p"))

            guard case .success = OEArtworkLocation.move(to: old) else { return XCTFail("back") }
            XCTAssertEqual(OEArtworkStore.shared.root.standardizedFileURL, old.standardizedFileURL)
            XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(OEArtworkStore.shared.active(game, .cover))), data(2))
            XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(OEArtworkStore.shared.active(game, .hero))), data(5))
            XCTAssertEqual(OEArtworkStore.shared.entry(game, .cover)?.pinned, true)
            let allBytes = Set(snapshot(old).values)
            XCTAssertTrue(allBytes.contains(data(1)) && allBytes.contains(data(2)), "both versions of the cover are still on disk")
        }
    }

    func testAPictureSavedThroughTheOldStoreDuringAMoveEndsUpInTheNewFolder() throws {
        try withStore(at: old) {
            let stale = OEArtworkStore.shared   // a fetch that fetched its reference earlier
            stale.fill(data(1), for: game, slot: .cover, origin: .library)
            let other = OEArtworkStore.Game(md5: String(format: "%032x", 9), system: "openemu.system.nes", title: "Kid Icarus")
            let writer = DispatchQueue(label: "writer")
            let done = expectation(description: "writes")
            writer.async {
                for n in 0..<150 { stale.fill(self.data(UInt8(n % 200)), for: OEArtworkStore.Game(md5: String(format: "%032x", 1000 + n), system: "openemu.system.nes", title: "Game \(n)"), slot: .cover, origin: .provider("p")) }
                done.fulfill()
            }
            guard case .success = OEArtworkLocation.move(to: new) else { return XCTFail() }
            wait(for: [done], timeout: 30)
            stale.choose(data(77), for: other, slot: .cover)   // after the switch, through the old reference

            stale.flush()   // what quitting does
            let fresh = OEArtworkStore(root: new)
            for n in 0..<150 {
                let g = OEArtworkStore.Game(md5: String(format: "%032x", 1000 + n), system: "openemu.system.nes", title: "Game \(n)")
                XCTAssertNotNil(fresh.active(g, .cover), "game \(n) is in the new folder")
            }
            XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(fresh.active(other, .cover))), data(77))
            XCTAssertNil(OEArtworkStore(root: old).active(other, .cover), "nothing new was written to the old folder after the switch")
        }
    }

    func testFoldersThatOverlapThroughCaseOrLinksAreRefused() throws {
        _ = fillOld()
        let before = snapshot(old)
        let upper = base.appendingPathComponent("OLD/inner")
        XCTAssertEqual(OEArtworkLocation.copyAndVerify(from: old, to: upper).failureValue, .nested)
        XCTAssertEqual(OEArtworkLocation.copyAndVerify(from: old, to: base.appendingPathComponent("OLD")).failureValue, .sameFolder)

        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: old.appendingPathComponent("nes"))
        XCTAssertEqual(OEArtworkLocation.copyAndVerify(from: old, to: link.appendingPathComponent("deeper")).failureValue, .nested)
        let toRoot = base.appendingPathComponent("rootlink")
        try FileManager.default.createSymbolicLink(at: toRoot, withDestinationURL: old)
        XCTAssertEqual(OEArtworkLocation.copyAndVerify(from: old, to: toRoot).failureValue, .sameFolder)
        XCTAssertEqual(snapshot(old), before, "the old folder was not touched")
    }

    func testLinkedPicturesAndFoldersAreCopiedAsTheirContents() throws {
        _ = fillOld()
        let elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try data(8).write(to: elsewhere.appendingPathComponent("Linked.png"))
        let folderOnAnotherDisk = base.appendingPathComponent("nes-hero-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folderOnAnotherDisk, withIntermediateDirectories: true)
        try data(9).write(to: folderOnAnotherDisk.appendingPathComponent("Pic.png"))
        try FileManager.default.createSymbolicLink(at: old.appendingPathComponent("nes/cover/Linked.png"), withDestinationURL: elsewhere.appendingPathComponent("Linked.png"))
        try FileManager.default.createSymbolicLink(at: old.appendingPathComponent("nes/extra"), withDestinationURL: folderOnAnotherDisk)
        try FileManager.default.createSymbolicLink(at: old.appendingPathComponent("loop"), withDestinationURL: old)   // a link back to itself

        guard case .success = OEArtworkLocation.copyAndVerify(from: old, to: new) else { return XCTFail() }
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("nes/cover/Linked.png")), data(8))
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("nes/extra/Pic.png")), data(9))
    }

    func testABrokenLinkStopsTheMoveInsteadOfBeingSkipped() throws {
        _ = fillOld()
        try FileManager.default.createSymbolicLink(at: old.appendingPathComponent("nes/cover/Gone.png"), withDestinationURL: base.appendingPathComponent("nowhere.png"))
        XCTAssertEqual(OEArtworkLocation.copyAndVerify(from: old, to: new).failureValue, .copyFailed("nes/cover/Gone.png"))
    }

    func testAnOddPathInTheSettingFallsBackToTheDefault() {
        let key = OEArtworkLocation.defaultsKey
        let previous = UserDefaults.standard.string(forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.set("relative/Art", forKey: key)
        XCTAssertEqual(OEArtworkLocation.chosenRoot, OEArtworkStore.defaultRoot)
        UserDefaults.standard.set("~/Pictures/Art", forKey: key)
        XCTAssertEqual(OEArtworkLocation.chosenRoot.path, NSHomeDirectory() + "/Pictures/Art")
    }
}

private extension Result {
    var failureValue: Failure? { if case .failure(let error) = self { return error } else { return nil } }
}
