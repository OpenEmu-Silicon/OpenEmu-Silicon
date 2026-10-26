// Copyright (c) 2026, OpenEmu Team
// Author: Leonardo Kasperavičius
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

import CoreData
import XCTest
@testable import OpenEmu

@MainActor
final class GameLaunchTests: XCTestCase {

    private func autosave(coreIdentifier: String) throws -> OEDBSaveState {
        let modelURL = try XCTUnwrap(Bundle.main.url(forResource: "OEDatabase", withExtension: "momd"))
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL))
        let entity = try XCTUnwrap(model.entitiesByName["SaveState"])
        let state = OEDBSaveState(entity: entity, insertInto: nil)
        state.coreIdentifier = coreIdentifier
        return state
    }

    func testPlayWithSkipsAnotherCoresAutosave() throws {
        for (savedCore, selectedCore) in [
            ("org.openemu.MAME", "org.openemu.FBNeo"),
            ("org.openemu.FBNeo", "org.openemu.MAME"),
            ("org.openemu.Nestopia", "org.openemu.FCEU"),
            ("org.openemu.SNES9x", "org.openemu.BSNES"),
        ] {
            let state = try autosave(coreIdentifier: savedCore)
            XCTAssertNil(MainWindowController.autosaveForLaunch(state, coreIdentifier: selectedCore))
            XCTAssertEqual(state.coreIdentifier, savedCore)
        }
    }

    func testPlayWithOffersMatchingAutosave() throws {
        let state = try autosave(coreIdentifier: "org.openemu.FBNeo")
        XCTAssertTrue(MainWindowController.autosaveForLaunch(state, coreIdentifier: state.coreIdentifier) === state)
    }

    func testNormalLaunchOffersLastPlayedAutosave() throws {
        let state = try autosave(coreIdentifier: "org.openemu.MAME")
        XCTAssertTrue(MainWindowController.autosaveForLaunch(state, coreIdentifier: nil) === state)
    }

    func testLaunchWithoutAutosave() {
        XCTAssertNil(MainWindowController.autosaveForLaunch(nil, coreIdentifier: "org.openemu.FBNeo"))
        XCTAssertNil(MainWindowController.autosaveForLaunch(nil, coreIdentifier: nil))
    }
}
