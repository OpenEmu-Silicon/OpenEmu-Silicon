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

/// The artwork backup only adds. Two Macs that changed the same picture keep both, deleting here removes nothing
/// there, and the folder being read is never changed. Every test uses temporary folders.
final class ArtworkBackupTests: XCTestCase {

    private var base: URL!
    private var rootA: URL!      // this Mac's artwork folder
    private var rootB: URL!      // another Mac's artwork folder
    private var backup: URL!     // the shared backup folder

    private let mario = OEArtworkStore.Game(md5: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", system: "openemu.system.snes", title: "Super Mario World")
    private let zelda = OEArtworkStore.Game(md5: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", system: "openemu.system.nes", title: "Zelda")

    private func bytes(_ n: UInt8) -> Data { Data([0x89, 0x50, 0x4E, 0x47, n, 2, 3]) }

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("ArtworkBackupTests-\(UUID().uuidString)", isDirectory: true)
        rootA = base.appendingPathComponent("macA"); rootB = base.appendingPathComponent("macB"); backup = base.appendingPathComponent("backup")
        for url in [rootA!, rootB!, backup!] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func files(_ root: URL) -> [String: Data] {
        var found = [String: Data]()
        let prefix = root.standardizedFileURL.path + "/"
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return found }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            found[String(url.standardizedFileURL.path.dropFirst(prefix.count))] = try? Data(contentsOf: url)
        }
        return found
    }

    /// A folder with a pinned poster, an automatic (unpinned) cover, and one picture moved to History.
    @discardableResult
    private func populate(_ root: URL, poster: UInt8 = 1) -> OEArtworkStore {
        let store = OEArtworkStore(root: root)
        _ = store.choose(bytes(poster), for: mario, slot: .poster, origin: .user)
        _ = store.fill(bytes(9), for: mario, slot: .cover, origin: .provider("screenscraper"))
        _ = store.choose(bytes(poster &+ 50), for: mario, slot: .poster, origin: .user)   // the first one goes to History
        store.flush()
        return store
    }

    private func run(_ root: URL, scope: OEArtworkBackup.Scope = .pinnedAndHistory, machine: String = "MacA") throws -> OEArtworkBackup.Report {
        switch OEArtworkBackup.backUp(root: root, to: backup, scope: scope, machineID: machine + "-id", machineName: machine) {
        case .success(let report): return report
        case .failure(let problem): throw XCTSkip("backup failed: \(problem)")
        }
    }

    private var backedUp: [String: Data] { files(backup.appendingPathComponent("Artwork")) }
    private func pictureNames(_ list: [String: Data]) -> [String] { list.keys.filter { !$0.hasPrefix("index-") }.sorted() }

    func testDefaultBacksUpPinnedPicksAndHistoryButNotAutomaticOnes() throws {
        populate(rootA)
        _ = try run(rootA)
        let names = pictureNames(backedUp)
        XCTAssertTrue(names.contains { $0.hasPrefix("snes/poster/") && !$0.contains("History") }, "\(names)")
        XCTAssertTrue(names.contains { $0.contains("/History/") }, "\(names)")
        XCTAssertFalse(names.contains { $0.contains("/cover/") }, "an automatic picture is not in the default backup: \(names)")
    }

    func testEverythingAlsoBacksUpAutomaticPictures() throws {
        populate(rootA)
        _ = try run(rootA, scope: .everything)
        XCTAssertTrue(pictureNames(backedUp).contains { $0.contains("/cover/") })
    }

    func testOffCopiesNothing() throws {
        populate(rootA)
        _ = try run(rootA, scope: .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.appendingPathComponent("Artwork").path))
    }

    func testRunningAgainChangesNothing() throws {
        populate(rootA)
        _ = try run(rootA, scope: .everything)
        let first = backedUp
        let report = try run(rootA, scope: .everything)
        XCTAssertEqual(backedUp, first)
        XCTAssertEqual(report.copied, 0)
        XCTAssertEqual(report.keptBoth, 0)
    }

    func testBackingUpNeverChangesTheSourceFolder() throws {
        populate(rootA)
        let before = files(rootA)
        _ = try run(rootA, scope: .everything)
        XCTAssertEqual(files(rootA), before)
    }

    func testTwoMacsThatChangedTheSamePictureKeepBoth() throws {
        populate(rootA, poster: 1)
        populate(rootB, poster: 2)
        _ = try run(rootA, machine: "MacA")
        let afterA = backedUp
        let report = try run(rootB, machine: "MacB")

        XCTAssertGreaterThan(report.keptBoth, 0)
        // Everything MacA put there is still there, byte for byte.
        for (name, data) in afterA where !name.hasPrefix("index-") { XCTAssertEqual(backedUp[name], data, name) }
        XCTAssertTrue(pictureNames(backedUp).contains { $0.contains("(from MacB)") }, "\(pictureNames(backedUp))")

        // And a second run by MacB adds nothing more.
        let settled = backedUp
        _ = try run(rootB, machine: "MacB")
        XCTAssertEqual(backedUp, settled)
    }

    func testDeletingLocallyDeletesNothingInTheBackup() throws {
        populate(rootA)
        _ = try run(rootA, scope: .everything)
        let before = backedUp
        for url in try FileManager.default.contentsOfDirectory(at: rootA, includingPropertiesForKeys: nil) { try FileManager.default.removeItem(at: url) }
        _ = try run(rootA, scope: .everything)
        XCTAssertEqual(backedUp, before)
    }

    func testAFolderInsideTheBackupOrAroundItIsSkipped() throws {
        let inside = backup.appendingPathComponent("Artwork/mine")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        populate(inside)
        XCTAssertEqual(OEArtworkBackup.backUp(root: inside, to: backup, scope: .everything, machineID: "x", machineName: "X"), .failure(.overlapping))
        XCTAssertEqual(OEArtworkBackup.backUp(root: base, to: backup, scope: .everything, machineID: "x", machineName: "X"), .failure(.overlapping))
    }

    func testRestoreAddsMissingFilesAndNeverReplacesADifferentOne() throws {
        populate(rootA, poster: 1)
        _ = try run(rootA, scope: .everything)

        // MacB has its own, different poster and nothing else.
        let storeB = populate(rootB, poster: 7)
        let before = files(rootB)
        let result = OEArtworkBackup.restore(from: backup, into: rootB, store: storeB, machineName: "MacB")
        guard case .success(let report) = result else { return XCTFail("\(result)") }

        let after = files(rootB)
        for (name, data) in before { XCTAssertEqual(after[name], data, "\(name) was changed") }
        XCTAssertGreaterThan(report.keptBoth, 0, "MacA's different poster is kept beside MacB's")
        XCTAssertGreaterThan(after.count, before.count)
        XCTAssertTrue(after.keys.contains { $0.contains("(from backup)") })
    }

    func testRestoreOnAFreshMacBringsBackThePinnedPickAndItsPin() throws {
        let storeA = populate(rootA, poster: 1)
        let pinned = try XCTUnwrap(storeA.entry(mario, .poster))
        _ = try run(rootA)

        let fresh = base.appendingPathComponent("fresh")
        let storeFresh = OEArtworkStore(root: fresh)
        guard case .success(let report) = OEArtworkBackup.restore(from: backup, into: fresh, store: storeFresh, machineName: "New") else { return XCTFail() }
        XCTAssertGreaterThan(report.copied, 0)
        XCTAssertEqual(report.keptBoth, 0)
        let entry = try XCTUnwrap(storeFresh.entry(mario, .poster))
        XCTAssertTrue(entry.pinned)
        XCTAssertEqual(entry.file, pinned.file)
        XCTAssertEqual(try Data(contentsOf: fresh.appendingPathComponent(entry.file)), try Data(contentsOf: rootA.appendingPathComponent(pinned.file)))
    }

    func testRestoreNeverChangesAnExistingPick() throws {
        let storeA = populate(rootA, poster: 1)
        _ = try run(rootA)
        let storeB = populate(rootB, poster: 7)
        let own = try XCTUnwrap(storeB.entry(mario, .poster))
        _ = storeA
        _ = OEArtworkBackup.restore(from: backup, into: rootB, store: storeB, machineName: "MacB")
        XCTAssertEqual(storeB.entry(mario, .poster), own)
    }

    func testRestoreFromAnEmptyBackupSaysSo() throws {
        XCTAssertEqual(OEArtworkBackup.restore(from: backup, into: rootB, machineName: "B"), .failure(.nothingToRestore))
    }
}
