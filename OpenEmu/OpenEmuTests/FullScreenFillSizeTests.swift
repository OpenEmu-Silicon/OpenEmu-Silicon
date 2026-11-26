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

/// Issue 762: on a MacBook with a camera notch, a DS game in full screen was sized to the whole screen,
/// but the full screen window is shorter than the screen by the notch area, so the picture was clipped.
final class FullScreenFillSizeTests: XCTestCase {
    
    private let notch = NSEdgeInsets(top: 32, left: 0, bottom: 0, right: 0)
    private let dsGameSize = CGSize(width: 256, height: 384)
    
    func testDSFillStaysInsideTheRoomThatIsReallyThere() {
        // The three display settings from the report, all notched MacBook screens.
        for screen in [CGSize(width: 1728, height: 1117), CGSize(width: 1920, height: 1200), CGSize(width: 2056, height: 1285)] {
            let room = GameWindowController.fullScreenContentSize(screenSize: screen, safeAreaInsets: notch)
            let fill = GameWindowController.fullScreenFillSize(available: room, gameSize: dsGameSize, fillsAllRoom: true)
            XCTAssertLessThanOrEqual(fill.width, room.width, "\(screen)")
            XCTAssertLessThanOrEqual(fill.height, room.height, "\(screen)")
        }
    }
    
    func testNotchRoomAt1728x1117IsTheWindowsRealHeight() {
        let room = GameWindowController.fullScreenContentSize(screenSize: CGSize(width: 1728, height: 1117), safeAreaInsets: notch)
        XCTAssertEqual(room, CGSize(width: 1728, height: 1080))
    }
    
    func testScreenWithoutNotchIsUnchanged() {
        let screen = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(GameWindowController.fullScreenContentSize(screenSize: screen, safeAreaInsets: NSEdgeInsets()), screen)
    }
    
    func testOtherSystemsStillKeepTheirShape() {
        let fill = GameWindowController.fullScreenFillSize(available: CGSize(width: 1728, height: 1080),
                                                           gameSize: CGSize(width: 256, height: 224), fillsAllRoom: false)
        XCTAssertEqual(fill, CGSize(width: 1234, height: 1080))
    }
    
    func testNotchedWindowSitsBelowTheNotchNotAboveTheScreenBottom() {
        let screen = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let frame = GameWindowController.fullScreenWindowFrame(screenFrame: screen, safeAreaInsets: notch)
        XCTAssertEqual(frame.minY, 0, "the window keeps the screen's bottom edge")
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY - notch.top, "the window stays out of the notch area")
        XCTAssertEqual(frame.size, CGSize(width: 1728, height: 1080))
    }
    
    func testNotchedWindowOnASecondDisplayKeepsItsOrigin() {
        let screen = NSRect(x: 1728, y: 100, width: 1728, height: 1117)
        let frame = GameWindowController.fullScreenWindowFrame(screenFrame: screen, safeAreaInsets: notch)
        XCTAssertEqual(frame.origin, CGPoint(x: 1728, y: 100))
    }
    
    func testScreenWithoutNotchFrameIsUnchanged() {
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(GameWindowController.fullScreenWindowFrame(screenFrame: screen, safeAreaInsets: NSEdgeInsets()), screen)
    }
}
