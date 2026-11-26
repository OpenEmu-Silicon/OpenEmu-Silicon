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

/// The rules that turn a core's rumble request into motor strengths and pick the controller. The motors themselves
/// need a real controller, so they are not covered here.
final class OERumbleMappingTests: XCTestCase {

    func testStrengthsAreKeptInRange() {
        let s = OERumbleMapping.strengths(strong: 1.7, weak: -0.4, enabled: true)
        XCTAssertEqual(s.strong, 1)
        XCTAssertEqual(s.weak, 0)
        let mid = OERumbleMapping.strengths(strong: 0.25, weak: 0.5, enabled: true)
        XCTAssertEqual(mid.strong, 0.25)
        XCTAssertEqual(mid.weak, 0.5)
    }

    func testBadNumbersBecomeZero() {
        let s = OERumbleMapping.strengths(strong: .nan, weak: .infinity, enabled: true)
        XCTAssertEqual(s.strong, 0)
        XCTAssertEqual(s.weak, 0)
    }

    func testSwitchedOffMeansBothMotorsStop() {
        let s = OERumbleMapping.strengths(strong: 1, weak: 1, enabled: false)
        XCTAssertEqual(s.strong, 0)
        XCTAssertEqual(s.weak, 0)
    }

    func testRumbleIsOnByDefaultAndCanBeSwitchedOff() {
        let suite = "OERumbleMappingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(OERumbleSettings.isEnabled(defaults))
        OERumbleSettings.setEnabled(false, defaults: defaults)
        XCTAssertFalse(OERumbleSettings.isEnabled(defaults))
        OERumbleSettings.setEnabled(true, defaults: defaults)
        XCTAssertTrue(OERumbleSettings.isEnabled(defaults))
    }

    func testNoControllersMeansNoTarget() {
        XCTAssertNil(OERumbleMapping.controllerIndex(forPlayer: 1, deviceName: "Pad", controllerNames: []))
    }

    func testNameMatchWinsOverPosition() {
        let names: [String?] = ["Xbox Wireless Controller", "DualSense Wireless Controller"]
        XCTAssertEqual(OERumbleMapping.controllerIndex(forPlayer: 1, deviceName: "dualsense wireless controller", controllerNames: names), 1)
    }

    func testTwoControllersWithTheSameNameFallBackToPlayerPosition() {
        let names: [String?] = ["Pad", "Pad"]
        XCTAssertEqual(OERumbleMapping.controllerIndex(forPlayer: 1, deviceName: "Pad", controllerNames: names), 0)
        XCTAssertEqual(OERumbleMapping.controllerIndex(forPlayer: 2, deviceName: "Pad", controllerNames: names), 1)
    }

    func testOnlyControllerBelongsToPlayerOne() {
        XCTAssertEqual(OERumbleMapping.controllerIndex(forPlayer: 1, deviceName: "Something else", controllerNames: ["Pad"]), 0)
        XCTAssertNil(OERumbleMapping.controllerIndex(forPlayer: 2, deviceName: "Something else", controllerNames: ["Pad"]))
    }

    func testPlayerPastTheListGetsNothing() {
        XCTAssertNil(OERumbleMapping.controllerIndex(forPlayer: 3, deviceName: nil, controllerNames: ["A", "B"]))
        XCTAssertNil(OERumbleMapping.controllerIndex(forPlayer: 0, deviceName: nil, controllerNames: ["A", "B"]))
    }
}
