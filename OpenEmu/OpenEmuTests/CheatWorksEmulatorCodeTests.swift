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

class CheatWorksEmulatorCodeTests: XCTestCase {

    /// `CheatWorksConfig.emulatorCode(for:)` derives the backend emulator code from a core's
    /// bundle-id last component (e.g. `org.openemu.Dolphin` → `dolphin`). That convention is
    /// implicit: a new core whose name has no matching `CheatWorksEmulatorCode` case resolves to
    /// `nil`, and its cheat feedback is silently dropped with no build-time signal.
    ///
    /// This guards against that by walking the authoritative shipped-core list in `oecores.xml`
    /// and asserting every core id maps to a code. Adding a core to `oecores.xml` without a
    /// matching enum case fails CI here.
    func testEveryShippedCoreResolvesToEmulatorCode() throws {
        let coreIDs = try shippedCoreBundleIDs()
        XCTAssertFalse(coreIDs.isEmpty, "Parsed no core ids from oecores.xml — the test's locator or parser is broken.")

        for id in coreIDs {
            XCTAssertNotNil(
                CheatWorksConfig.emulatorCode(for: id),
                """
                Core '\(id)' does not resolve to a CheatWorksEmulatorCode, so its cheat feedback \
                would be silently dropped. Add a case to CheatWorksEmulatorCode whose raw value is \
                the lowercased last component of the bundle id, or switch emulatorCode(for:) to an \
                explicit map.
                """)
        }
    }

    /// Core ids declared in `oecores.xml`, the repo's source of truth for shipped cores. Core ids
    /// use the `org.openemu.` prefix; system ids use `openemu.system.`, so matching the former
    /// cleanly separates the two.
    private func shippedCoreBundleIDs() throws -> [String] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OpenEmuTests
            .deletingLastPathComponent()   // OpenEmu
            .deletingLastPathComponent()   // repo root
        let coresURL = repoRoot.appendingPathComponent("oecores.xml")
        let xml = try String(contentsOf: coresURL, encoding: .utf8)

        let regex = try NSRegularExpression(pattern: #"id="(org\.openemu\.[^"]+)""#)
        let range = NSRange(xml.startIndex..., in: xml)
        return regex.matches(in: xml, range: range).compactMap { match in
            Range(match.range(at: 1), in: xml).map { String(xml[$0]) }
        }
    }
}
