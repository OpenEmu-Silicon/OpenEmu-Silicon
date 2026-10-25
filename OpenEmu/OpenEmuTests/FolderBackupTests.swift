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

final class FolderBackupTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("FolderBackupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Versions

    func testArchiveKeepsOldSave() throws {
        let save = tempDir.appendingPathComponent("Game.sav")
        try Data("old".utf8).write(to: save)
        let copy = try XCTUnwrap(OESaveVersions.archive(save))
        try Data("new".utf8).write(to: save)
        XCTAssertEqual(try String(contentsOf: copy), "old")
        XCTAssertEqual(copy.deletingLastPathComponent().lastPathComponent, ".versions")
    }

    func testArchiveKeepsOnlyLastFive() throws {
        let save = tempDir.appendingPathComponent("Game.sav")
        for i in 0..<8 {
            try Data("v\(i)".utf8).write(to: save)
            try OESaveVersions.archive(save, now: Date(timeIntervalSince1970: 1_000_000 + Double(i)))
        }
        let kept = OESaveVersions.versions(of: save)
        XCTAssertEqual(kept.count, 5)
        XCTAssertEqual(try String(contentsOf: kept.first!), "v7")
        XCTAssertEqual(try String(contentsOf: kept.last!), "v3")
    }

    func testArchiveSameInstantDoesNotOverwrite() throws {
        let save = tempDir.appendingPathComponent("Game.sav")
        let now = Date(timeIntervalSince1970: 2_000_000)
        try Data("a".utf8).write(to: save)
        try OESaveVersions.archive(save, now: now)
        try Data("b".utf8).write(to: save)
        try OESaveVersions.archive(save, now: now)
        XCTAssertEqual(OESaveVersions.versions(of: save).count, 2)
    }

    func testArchiveKeepsSaveStateBundle() throws {
        let bundle = tempDir.appendingPathComponent("Slot 1.oesavestate", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("state".utf8).write(to: bundle.appendingPathComponent("State"))
        let copy = try XCTUnwrap(OESaveVersions.archive(bundle))
        XCTAssertEqual(try String(contentsOf: copy.appendingPathComponent("State")), "state")
    }

    func testArchiveOfMissingFileDoesNothing() throws {
        XCTAssertNil(try OESaveVersions.archive(tempDir.appendingPathComponent("Nope.sav")))
    }

    // MARK: - Bundle dates

    func testDeepDateSeesEditInsideBundle() throws {
        let bundle = tempDir.appendingPathComponent("Slot 1.oesavestate", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let inner = bundle.appendingPathComponent("State")
        try Data("one".utf8).write(to: inner)
        let old = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: inner.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: bundle.path)

        let before = try XCTUnwrap(OEFolderBackupManager.deepModificationDate(of: bundle))
        XCTAssertEqual(before.timeIntervalSince1970, old.timeIntervalSince1970, accuracy: 1)

        let newer = Date()
        try FileManager.default.setAttributes([.modificationDate: newer], ofItemAtPath: inner.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: bundle.path)
        let after = try XCTUnwrap(OEFolderBackupManager.deepModificationDate(of: bundle))
        XCTAssertEqual(after.timeIntervalSince1970, newer.timeIntervalSince1970, accuracy: 1)
    }

    func testCopyKeepsBundleDates() throws {
        let bundle = tempDir.appendingPathComponent("Slot 1.oesavestate", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: bundle.appendingPathComponent("State"))
        let old = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: bundle.appendingPathComponent("State").path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: bundle.path)

        let copy = tempDir.appendingPathComponent("Copy.oesavestate")
        try FileManager.default.copyItem(at: bundle, to: copy)
        let a = try XCTUnwrap(OEFolderBackupManager.deepModificationDate(of: bundle))
        let b = try XCTUnwrap(OEFolderBackupManager.deepModificationDate(of: copy))
        XCTAssertEqual(a.timeIntervalSince1970, b.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: - Decision

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func testNoBackupIsUpToDate() {
        XCTAssertEqual(OEBackupPolicy.decide(backupDate: nil, localDate: at(5), backupWrittenByThisMac: false, record: nil), .upToDate)
    }

    func testNoHistoryNewerBackupWins() {
        XCTAssertEqual(OEBackupPolicy.decide(backupDate: at(100), localDate: at(5), backupWrittenByThisMac: false, record: nil), .newerBackup)
        XCTAssertEqual(OEBackupPolicy.decide(backupDate: at(100), localDate: nil, backupWrittenByThisMac: false, record: nil), .newerBackup)
        XCTAssertEqual(OEBackupPolicy.decide(backupDate: at(5), localDate: at(100), backupWrittenByThisMac: false, record: nil), .upToDate)
    }

    func testOtherMacChangedOnlyOffersRestore() {
        let record = OEBackupSyncRecord(backupDate: at(10), localDate: at(10))
        XCTAssertEqual(OEBackupPolicy.decide(backupDate: at(50), localDate: at(10), backupWrittenByThisMac: false, record: record), .newerBackup)
    }

    func testBothMacsChangedIsConflict() {
        let record = OEBackupSyncRecord(backupDate: at(10), localDate: at(10))
        XCTAssertEqual(OEBackupPolicy.decide(backupDate: at(50), localDate: at(60), backupWrittenByThisMac: false, record: record), .conflict)
        // The other Mac's clock being behind must not hide the conflict.
        XCTAssertEqual(OEBackupPolicy.decide(backupDate: at(50), localDate: at(500), backupWrittenByThisMac: false, record: record), .conflict)
    }

    func testOnlyThisMacChangedIsUpToDate() {
        let record = OEBackupSyncRecord(backupDate: at(10), localDate: at(10))
        XCTAssertEqual(OEBackupPolicy.decide(backupDate: at(10), localDate: at(60), backupWrittenByThisMac: false, record: record), .upToDate)
    }

    func testOwnBackupWriteIsNotAChange() {
        let record = OEBackupSyncRecord(backupDate: at(10), localDate: at(10))
        XCTAssertEqual(OEBackupPolicy.decide(backupDate: at(60), localDate: at(60), backupWrittenByThisMac: true, record: record), .upToDate)
    }

    func testDatesWithinToleranceAreEqual() {
        let record = OEBackupSyncRecord(backupDate: at(10), localDate: at(10))
        XCTAssertEqual(OEBackupPolicy.decide(backupDate: at(10.5), localDate: at(10.5), backupWrittenByThisMac: false, record: record), .upToDate)
    }

    func testOlderChangedBackupNeverRollsBackLocal() {
        let record = OEBackupSyncRecord(backupDate: at(10), localDate: at(100))
        XCTAssertEqual(OEBackupPolicy.decide(backupDate: at(50), localDate: at(100), backupWrittenByThisMac: false, record: record), .upToDate)
    }

    func testSyncIsRecordedOnlyWhenBothSidesMatch() {
        XCTAssertTrue(OEBackupPolicy.isInSync(backupDate: at(10), localDate: at(10.4)))
        // Local is newer: the upload failed or was skipped because of a conflict.
        XCTAssertFalse(OEBackupPolicy.isInSync(backupDate: at(10), localDate: at(60)))
        // Backup is newer: another Mac's save has not been pulled in.
        XCTAssertFalse(OEBackupPolicy.isInSync(backupDate: at(60), localDate: at(10)))
        XCTAssertFalse(OEBackupPolicy.isInSync(backupDate: nil, localDate: at(10)))
        XCTAssertFalse(OEBackupPolicy.isInSync(backupDate: at(10), localDate: nil))
    }

    // MARK: - Battery save names

    func testBatteryNamesMatchTitleRomNameAndDiscID() {
        let names: Set<String> = ["Super Mario 64 (USA)", "Super Mario 64 (U) [!]", "MK-51035"]
        XCTAssertTrue(OEBatterySaveMatcher.matches(fileName: "Super Mario 64 (USA).srm", names: names))
        XCTAssertTrue(OEBatterySaveMatcher.matches(fileName: "Super Mario 64 (U) [!].eep", names: names))
        XCTAssertFalse(OEBatterySaveMatcher.matches(fileName: "Super Mario 64 Land.sav", names: names))
        XCTAssertFalse(OEBatterySaveMatcher.matches(fileName: "Super Mario 64 (USA).2.sav", names: names))
    }

    func testMednafenHashedMemoryCardsMatch() {
        let hash = "0123456789abcdef0123456789abcdef"
        XCTAssertTrue(OEBatterySaveMatcher.matches(fileName: "Crash Bandicoot (USA).\(hash).0.mcr", names: ["Crash Bandicoot (USA)"]))
        XCTAssertTrue(OEBatterySaveMatcher.matches(fileName: "Crash Bandicoot (USA).\(hash).sav", names: ["Crash Bandicoot (USA)"]))
        XCTAssertFalse(OEBatterySaveMatcher.matches(fileName: "Crash Bandicoot (USA).nothash.0.mcr", names: ["Crash Bandicoot (USA)"]))
        XCTAssertFalse(OEBatterySaveMatcher.matches(fileName: "Crash Bandicoot 2.\(hash).0.mcr", names: ["Crash Bandicoot"]))
    }

    func testFlycastVMUMatchesOnlyItsOwnDiscID() {
        XCTAssertTrue(OEBatterySaveMatcher.matches(fileName: "MK-51035_vmu_save_A1.bin", names: ["MK-51035"]))
        XCTAssertFalse(OEBatterySaveMatcher.matches(fileName: "MK-51036_vmu_save_A1.bin", names: ["MK-51035"]))
        XCTAssertFalse(OEBatterySaveMatcher.matches(fileName: "vmu_save_A1.bin", names: ["MK-51035"]))
    }

    func testSharedSaveFilesNeverMatchAGame() {
        let names: Set<String> = ["Sonic CD (USA)", "Sonic CD"]
        for file in ["cart.brm", "scd_U.brm", "scd_E.brm", "dc_nvmem.bin", "blkmap.lst", "MemoryCardA.USA.raw"] {
            XCTAssertFalse(OEBatterySaveMatcher.matches(fileName: file, names: names), file)
        }
    }

    // MARK: - PSP, Wii and GameCube locations

    func testPSPSaveFolderBelongsToItsDiscID() {
        let parts = ["PPSSPP", "PSP", "SAVEDATA", "ULUS10297DATA00", "DATA.BIN"]
        XCTAssertEqual(OEExtraSaveLocations.unitComponents(for: parts), ["PPSSPP", "PSP", "SAVEDATA", "ULUS10297DATA00"])
        XCTAssertEqual(OEExtraSaveLocations.gameKey(for: parts), "ULUS10297")
        XCTAssertTrue(OEExtraSaveLocations.isPSPDiscID("ULUS10297"))
        XCTAssertFalse(OEExtraSaveLocations.isPSPDiscID("Zelda"))
    }

    func testWiiSaveFolderMapsToGameID() {
        let hex = try! XCTUnwrap(OEExtraSaveLocations.wiiTitleFolder(forGameID: "RSPE01"))
        XCTAssertEqual(hex, "52535045")
        let parts = ["Dolphin", "Wii", "title", "00010000", hex, "data", "banner.bin"]
        XCTAssertEqual(OEExtraSaveLocations.unitComponents(for: parts), Array(parts[0...5]))
        XCTAssertEqual(OEExtraSaveLocations.gameKey(for: parts), "RSPE")
        XCTAssertNil(OEExtraSaveLocations.wiiTitleFolder(forGameID: "rspe"))
    }

    func testGameCubeCardsAreBackedUpButBelongToNoGame() {
        let parts = ["Dolphin", "GC", "MemoryCardA.USA.raw"]
        XCTAssertEqual(OEExtraSaveLocations.unitComponents(for: parts), parts)
        XCTAssertNil(OEExtraSaveLocations.gameKey(for: parts))
        XCTAssertNil(OEExtraSaveLocations.unitComponents(for: ["Dolphin", "GC", "USA", "Card A", "x.gci"]))
    }

    func testPSPSavesKeepOldCopiesOutsideSavedata() {
        let save = URL(fileURLWithPath: "/x/PPSSPP/PSP/SAVEDATA/ULUS10297DATA00")
        XCTAssertEqual(OEFolderBackupManager.versionsFolder(for: save)?.path, "/x/PPSSPP/PSP/.versions")
        XCTAssertNil(OEFolderBackupManager.versionsFolder(for: URL(fileURLWithPath: "/x/mGBA/Battery Saves/Game.sav")))
    }
}
