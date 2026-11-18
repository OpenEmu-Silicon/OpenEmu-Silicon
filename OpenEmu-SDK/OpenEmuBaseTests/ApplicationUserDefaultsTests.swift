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

// Which settings the helper reads. It has its own bundle identifier (org.openemu.OpenEmuHelperApp),
// so it must follow the app it lives in: a debug build's helper reads the debug app's settings.

import XCTest
@testable import OpenEmuBase

final class ApplicationUserDefaultsTests: XCTestCase {

    private func identifier(main: String?, enclosing: String?) -> String {
        UserDefaults.oe_applicationIdentifier(forMainIdentifier: main, enclosingAppIdentifier: enclosing)
    }

    func testTheAppUsesItsOwnSettings() {
        XCTAssertEqual(identifier(main: "org.openemu.OpenEmu", enclosing: nil), "org.openemu.OpenEmu")
        XCTAssertEqual(identifier(main: "org.openemu.OpenEmu.debug", enclosing: nil), "org.openemu.OpenEmu.debug")
    }

    func testTheHelperFollowsTheAppAroundIt() {
        XCTAssertEqual(identifier(main: "org.openemu.OpenEmuHelperApp", enclosing: "org.openemu.OpenEmu"), "org.openemu.OpenEmu")
        XCTAssertEqual(identifier(main: "org.openemu.OpenEmuHelperApp", enclosing: "org.openemu.OpenEmu.debug"), "org.openemu.OpenEmu.debug",
                       "A debug build's helper must read the debug app's settings, where the Preferences window writes them.")
    }

    func testAnythingElseFallsBackToTheReleaseApp() {
        XCTAssertEqual(identifier(main: "com.apple.dt.xctest.tool", enclosing: nil), "org.openemu.OpenEmu")
        XCTAssertEqual(identifier(main: nil, enclosing: "com.example.Other"), "org.openemu.OpenEmu")
    }
}
