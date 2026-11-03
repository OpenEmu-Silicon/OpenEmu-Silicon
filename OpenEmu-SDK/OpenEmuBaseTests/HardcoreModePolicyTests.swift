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

// Regression tests for HardcoreModePolicy — the single source of truth for what
// is allowed during a RetroAchievements hardcore session. The actual gates
// (in OEGameCore, OpenEmuHelperApp, OEGameDocument) consult this type, so any
// silent loosening of the rules surfaces here rather than as a flagged player
// account in the wild.
//
// Spec under test:
// https://docs.retroachievements.org/general/hardcore-compliance-requirements.html

import XCTest
@testable import OpenEmuBase


final class HardcoreModePolicyTests: XCTestCase {

    // MARK: - Hardcore OFF — everything permitted

    func testHardcoreDisabledAllowsEverything() {
        let actions: [HardcoreModeAction] = [.loadState, .rewind, .fastForward, .frameStep, .cheats, .saveState]
        for action in actions {
            XCTAssertTrue(HardcoreModePolicy.allows(action, hardcoreEnabled: false),
                          "Softcore must allow \(action) — restrictions only apply in hardcore mode.")
        }
    }

    // MARK: - Hardcore ON — RA-forbidden actions blocked

    func testHardcoreBlocksLoadState() {
        XCTAssertFalse(HardcoreModePolicy.allows(.loadState, hardcoreEnabled: true),
                       "RA spec: save state loading must be blocked in hardcore.")
    }

    func testHardcoreBlocksRewind() {
        XCTAssertFalse(HardcoreModePolicy.allows(.rewind, hardcoreEnabled: true),
                       "RA spec: rewind must be blocked in hardcore.")
    }

    func testHardcoreAllowsFastForward() {
        XCTAssertTrue(HardcoreModePolicy.allows(.fastForward, hardcoreEnabled: true),
                      "RA spec: fast-forward is allowed in hardcore — only slowdown and frame advance are restricted.")
    }

    func testHardcoreBlocksFrameStep() {
        XCTAssertFalse(HardcoreModePolicy.allows(.frameStep, hardcoreEnabled: true),
                       "RA spec: frame step must be blocked in hardcore.")
    }

    func testHardcoreBlocksCheats() {
        XCTAssertFalse(HardcoreModePolicy.allows(.cheats, hardcoreEnabled: true),
                       "RA spec: cheats must be blocked in hardcore.")
    }

    func testHardcoreBlocksLiveMemoryAccess() {
        XCTAssertFalse(HardcoreModePolicy.allows(.liveMemoryAccess, hardcoreEnabled: true),
                       "An outside tool writing game memory is a cheat, so Archipelago connections must be refused in hardcore.")
        XCTAssertTrue(HardcoreModePolicy.allows(.liveMemoryAccess, hardcoreEnabled: false))
    }

    // MARK: - Hardcore ON — explicitly permitted actions

    func testHardcoreAllowsSaveState() {
        // RA only restricts restoring prior state, not capturing it. Save IS
        // allowed; load is not.
        XCTAssertTrue(HardcoreModePolicy.allows(.saveState, hardcoreEnabled: true),
                      "Saving (not loading) state remains permitted in hardcore.")
    }

    // MARK: - Mid-session toggle behavior

    func testEnablingHardcoreRequiresReset() {
        XCTAssertTrue(HardcoreModePolicy.requiresResetWhenEnabling,
                      "RA spec: switching softcore→hardcore mid-game must restart the run so prior advantages don't carry over.")
    }

    func testDisablingHardcoreDoesNotRequireReset() {
        XCTAssertFalse(HardcoreModePolicy.requiresResetWhenDisabling,
                       "Hardcore→softcore is a relaxation; no reset required.")
    }
}
