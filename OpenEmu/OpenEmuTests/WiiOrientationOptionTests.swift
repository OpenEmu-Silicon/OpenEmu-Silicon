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
import OpenEmuSystem
@testable import OpenEmu

/// The Wii plugin's "Orientation" row in the Controls pane and the Dolphin core must agree on where the choice is
/// saved and what the values are. The core's side is the constants at the top of Dolphin/DolphinGameCore.mm
/// (kDolphinOrientationPrefKey and the Upright/Sideways names), and the saved-dictionary key is
/// "displayMode.<core bundle id>" (OEGameCoreDisplayModeKeyFormat). If you change one, change the other.
final class WiiOrientationOptionTests: XCTestCase {

    /// Reads the plist from the source tree (this file is OpenEmu/OpenEmuTests/..., the plist is next door in
    /// OpenEmu/SystemPlugins/Wii), because the Wii plugin is a separate bundle the app tests do not load.
    private func wiiPlist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SystemPlugins/Wii/Wii-Info.plist")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any], "cannot read \(url.path)")
    }

    private func orientationRows() throws -> [ControlOption] {
        let groups = try XCTUnwrap(try wiiPlist()[OEControlListKey] as? [[Any]])
        return groups.flatMap { $0 }.compactMap { ($0 as? [AnyHashable: Any]).flatMap(ControlOption.init(plistRow:)) }
    }

    func testWiiPluginDeclaresExactlyOneOrientationChoice() throws {
        XCTAssertEqual(try orientationRows().count, 1)
    }

    func testChoiceMatchesWhatTheDolphinCoreReads() throws {
        let option = try XCTUnwrap(try orientationRows().first)
        XCTAssertEqual(option.defaultsKey, "dolphin.orientation")
        XCTAssertEqual(option.containerKey, String(format: OEGameCoreDisplayModeKeyFormat, "org.openemu.Dolphin"))
        XCTAssertEqual(option.choices.map(\.value), ["Upright", "Sideways"], "first is the default: upright")
    }

    func testOldHotkeyRowsAreNotShownAnyMore() throws {
        let groups = try XCTUnwrap(try wiiPlist()[OEControlListKey] as? [[Any]])
        let names = groups.flatMap { $0 }.compactMap { ($0 as? [String: String])?[OEControlListKeyNameKey] }
        XCTAssertFalse(names.contains("OEWiimoteSideways"))
        XCTAssertFalse(names.contains("OEWiimoteUpright"))
    }
}
