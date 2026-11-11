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

/// A ScreenScraper media address carries logins. The library must keep it without them and sign it again for use.
final class ScreenScraperAddressTests: XCTestCase {

    private let leaky = URL(string: "https://neoclone.screenscraper.fr/api2/mediaJeu.php?devid=DEV&devpassword=DEVSECRET&softname=OpenEmu-Silicon&ssid=nick&sspassword=USERSECRET&systemeid=14&jeuid=123&media=box-2D(us)")!

    func testRedactingRemovesEveryLoginAndKeepsTheRest() throws {
        let clean = ScreenScraperClient.redacted(leaky).absoluteString
        for secret in ["DEVSECRET", "USERSECRET", "devid", "ssid", "sspassword", "devpassword", "nick"] { XCTAssertFalse(clean.contains(secret), secret) }
        for kept in ["systemeid=14", "jeuid=123", "media=box-2D", "softname=OpenEmu-Silicon", "mediaJeu.php"] { XCTAssertTrue(clean.contains(kept), kept) }
    }

    func testOtherAddressesAreNeverChanged() {
        let other = URL(string: "https://example.com/box.png?ssid=keep&sspassword=keep")!
        XCTAssertEqual(ScreenScraperClient.redacted(other), other)
        XCTAssertEqual(ScreenScraperClient.signed(other), other)
        let plain = URL(string: "https://neoclone.screenscraper.fr/api2/mediaJeu.php?jeuid=1")!
        XCTAssertEqual(ScreenScraperClient.redacted(plain), plain)
    }

    func testOnlyScreenScraperOverHttpsIsTrusted() {
        let trusted = ["https://screenscraper.fr/a?x=1", "https://neoclone.screenscraper.fr/a?x=1", "https://NEOCLONE.ScreenScraper.FR/a"]
        let notTrusted = ["https://evilscreenscraper.fr/a", "https://notscreenscraper.fr/a", "https://screenscraper.fr.evil.com/a",
                          "http://neoclone.screenscraper.fr/a", "https://example.com/screenscraper.fr", "ftp://screenscraper.fr/a"]
        for text in trusted { XCTAssertTrue(ScreenScraperClient.isScreenScraperAddress(URL(string: text)!), text) }
        for text in notTrusted {
            let url = URL(string: text)!
            XCTAssertFalse(ScreenScraperClient.isScreenScraperAddress(url), text)
            XCTAssertEqual(ScreenScraperClient.signed(url, username: "nick", password: "pw"), url, "no login added to \(text)")
        }
    }

    func testALoginIsRemovedFromAnyScreenScraperAddressEvenOverHttp() {
        let old = URL(string: "http://neoclone.screenscraper.fr/api2/mediaJeu.php?ssid=nick&sspassword=pw&jeuid=1")!
        XCTAssertFalse(ScreenScraperClient.redacted(old).absoluteString.contains("pw"))
        let other = URL(string: "https://evilscreenscraper.fr/a?sspassword=pw")!
        XCTAssertEqual(ScreenScraperClient.redacted(other), other, "another site's address is not ours to change")
    }

    func testSigningAddsTheLoginBackAndOnlyOnce() throws {
        let clean = ScreenScraperClient.redacted(leaky)
        let signed = ScreenScraperClient.signed(clean, username: "nick", password: "pw")
        let names = URLComponents(url: signed, resolvingAgainstBaseURL: false)?.queryItems?.map { $0.name } ?? []
        XCTAssertTrue(names.contains("ssid")); XCTAssertTrue(names.contains("sspassword"))
        XCTAssertEqual(names.filter { $0 == "ssid" }.count, 1)
        // An address that already has its login is left alone.
        XCTAssertEqual(ScreenScraperClient.signed(leaky, username: "x", password: "y"), leaky)
        // Signing then redacting gets the clean address back.
        XCTAssertEqual(ScreenScraperClient.redacted(signed), clean)
    }

    func testTheStoredSourceNeverHoldsALoginAndOlderOnesAreScrubbed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenScraperAddressTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let savedPath = UserDefaults.standard.object(forKey: OELibraryDatabase.databasePathKey)
        defer { UserDefaults.standard.set(savedPath, forKey: OELibraryDatabase.databasePathKey) }
        try OELibraryDatabase.load(from: folder)
        let context = try XCTUnwrap(OELibraryDatabase.default).mainThreadContext

        // New covers: the setter removes the login.
        let fresh = OEDBImage.createObject(in: context)
        fresh.sourceURL = leaky
        XCTAssertFalse(try XCTUnwrap(fresh.source).contains("SECRET"))

        // Older covers: written straight into the stored text, as an old library has them.
        let old = OEDBImage.createObject(in: context)
        old.source = leaky.absoluteString
        let untouched = OEDBImage.createObject(in: context)
        untouched.source = "https://example.com/box.png"
        try context.save()

        XCTAssertEqual(OEDBImage.scrubStoredCredentials(in: context), 1)
        XCTAssertFalse(try XCTUnwrap(old.source).contains("SECRET"))
        XCTAssertTrue(try XCTUnwrap(old.source).contains("jeuid=123"))
        XCTAssertEqual(untouched.source, "https://example.com/box.png")
        XCTAssertEqual(OEDBImage.scrubStoredCredentials(in: context), 0, "a second pass has nothing to do")
    }
}
