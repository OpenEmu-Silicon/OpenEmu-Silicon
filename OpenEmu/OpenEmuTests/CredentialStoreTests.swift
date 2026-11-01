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

/// Every store here lives in a temporary directory; the real `.oe_credentials` files
/// and the keychain are never touched.
final class CredentialStoreTests: XCTestCase {

    private var tempDir: URL!
    private let uuid = "00000000-1111-2222-3333-444444444444"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("CredentialStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore(bundleID: String = "org.openemu.OpenEmu.test", in dir: URL? = nil) -> OECredentialStore {
        OECredentialStore(directory: dir ?? tempDir, bundleID: bundleID, hardwareUUID: uuid, migratesFromKeychain: false)
    }

    private func backups(of store: OECredentialStore) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(store.storeURL.lastPathComponent + ".unreadable-") }
    }

    func testValidStoreRoundTrips() throws {
        let store = makeStore()
        store.set("hunter2", forKey: .screenScraperPassword)
        store.set("token", forKey: .retroAchievementsToken)
        store.remove(.retroAchievementsToken)

        let reopened = makeStore()
        XCTAssertEqual(reopened.get(.screenScraperPassword), "hunter2")
        XCTAssertNil(reopened.get(.retroAchievementsToken))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.legacyStoreURL.path),
                       "the shared legacy file must never be written")
    }

    func testUndecryptableStoreIsBackedUpNotOverwritten() throws {
        // A store written under another key (a different build) reads as garbage here.
        let other = makeStore(bundleID: "org.openemu.OpenEmu.test", in: tempDir)
        other.set("saved-by-other-build", forKey: .screenScraperPassword)
        let original = try Data(contentsOf: other.storeURL)

        let store = OECredentialStore(directory: tempDir, bundleID: "org.openemu.OpenEmu.test",
                                      hardwareUUID: "some-other-machine", migratesFromKeychain: false)
        XCTAssertNil(store.get(.screenScraperPassword))
        XCTAssertEqual(try Data(contentsOf: store.storeURL), original, "reading must not change the file")

        store.set("new", forKey: .retroAchievementsToken)

        let saved = try backups(of: store)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(try Data(contentsOf: saved[0]), original, "the unreadable store must survive byte for byte")
        XCTAssertEqual(OECredentialStore(directory: tempDir, bundleID: "org.openemu.OpenEmu.test",
                                         hardwareUUID: "some-other-machine", migratesFromKeychain: false)
                        .get(.retroAchievementsToken), "new")
    }

    func testCorruptStoreIsBackedUpNotOverwritten() throws {
        let store = makeStore()
        let junk = Data("not a sealed box".utf8)
        try junk.write(to: store.storeURL)

        store.set("new", forKey: .screenScraperPassword)

        let saved = try backups(of: store)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(try Data(contentsOf: saved[0]), junk)
        XCTAssertEqual(makeStore().get(.screenScraperPassword), "new")
    }

    func testReadableLegacyStoreIsMigratedAndLeftInPlace() throws {
        // Build a legacy file: the same key, under the old shared name.
        let source = tempDir.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        makeStore(in: source).set("hunter2", forKey: .screenScraperPassword)
        let store = makeStore()
        try FileManager.default.copyItem(at: makeStore(in: source).storeURL, to: store.legacyStoreURL)
        let legacy = try Data(contentsOf: store.legacyStoreURL)

        XCTAssertEqual(store.get(.screenScraperPassword), "hunter2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.storeURL.path))
        XCTAssertEqual(try Data(contentsOf: store.legacyStoreURL), legacy)
    }

    func testUnreadableLegacyStoreIsNeverWritten() throws {
        let store = makeStore(bundleID: "org.openemu.OpenEmu.debug")
        // Sealed under the release bundle ID, so the debug key cannot open it.
        let release = makeStore(bundleID: "org.openemu.OpenEmu")
        release.set("release-password", forKey: .screenScraperPassword)
        try FileManager.default.moveItem(at: release.storeURL, to: store.legacyStoreURL)
        let legacy = try Data(contentsOf: store.legacyStoreURL)

        XCTAssertNil(store.get(.screenScraperPassword))
        store.set("debug-password", forKey: .screenScraperPassword)

        XCTAssertEqual(try Data(contentsOf: store.legacyStoreURL), legacy)
        XCTAssertEqual(makeStore(bundleID: "org.openemu.OpenEmu.debug").get(.screenScraperPassword), "debug-password")
        XCTAssertEqual(makeStore(bundleID: "org.openemu.OpenEmu").get(.screenScraperPassword), "release-password",
                       "the release build migrates the legacy file it can read")
    }

    func testBundleIDsKeepSeparateStores() {
        makeStore(bundleID: "org.openemu.OpenEmu").set("release", forKey: .screenScraperPassword)
        makeStore(bundleID: "org.openemu.OpenEmu.debug").set("debug", forKey: .screenScraperPassword)

        XCTAssertEqual(makeStore(bundleID: "org.openemu.OpenEmu").get(.screenScraperPassword), "release")
        XCTAssertEqual(makeStore(bundleID: "org.openemu.OpenEmu.debug").get(.screenScraperPassword), "debug")
    }
}
