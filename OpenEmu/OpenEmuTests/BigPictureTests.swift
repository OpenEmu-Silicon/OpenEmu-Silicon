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

/// The pure rules behind big-picture mode: how a layered OpenVGDB genre becomes one tile name, and how a title loses
/// its region and revision tags. The screens themselves are checked with `Scripts/bigpicture-look.sh`.
final class BigPictureTests: XCTestCase {

    private func genre(_ layers: [String]) -> String? {
        var details = OEBigPictureArt.Details()
        details.genres = layers
        return details.primaryGenre
    }

    func testBroadGenresUseTheNextLevelDown() {
        XCTAssertEqual(genre(["Action", "Platformer", "2D"]), "Platformer")
        XCTAssertEqual(genre(["Action", "Shooter", "Scrolling"]), "Shooter")
        XCTAssertEqual(genre(["Miscellaneous", "Puzzle", "General"]), "Puzzle")
    }

    func testGeneralIsNotAGenre() {
        XCTAssertEqual(genre(["Action", "General"]), "Action")
    }

    func testSpecificTopLevelGenresAreKept() {
        XCTAssertEqual(genre(["Role-Playing", "Console-style RPG"]), "Role-Playing")
        XCTAssertEqual(genre(["Adventure", "General"]), "Adventure")
    }

    func testNoGenreGivesNoName() {
        XCTAssertNil(genre([]))
    }

    func testTitlesLoseRegionAndRevisionTags() {
        XCTAssertEqual(OEBigPictureArt.GameKey.searchName("Dragon Quest VIII (USA)"), "Dragon Quest VIII")
        XCTAssertEqual(OEBigPictureArt.GameKey.searchName("Contra (US / Asia, set 1)"), "Contra")
        XCTAssertEqual(OEBigPictureArt.GameKey.searchName("Dragon Ball Z (rev B)"), "Dragon Ball Z")
        XCTAssertEqual(OEBigPictureArt.GameKey.searchName("Sonic the Hedgehog [!]"), "Sonic the Hedgehog")
    }

    func testATitleThatIsOnlyATagIsKept() {
        XCTAssertEqual(OEBigPictureArt.GameKey.searchName("(USA)"), "(USA)")
    }

    func testShoulderButtonsCycleTabsAndWrap() {
        XCTAssertEqual(BigPictureTab.cycled(from: .home, by: 1), .recent)
        XCTAssertEqual(BigPictureTab.cycled(from: .recent, by: -1), .home)
        XCTAssertEqual(BigPictureTab.cycled(from: .home, by: -1), .search)
        XCTAssertEqual(BigPictureTab.cycled(from: .search, by: 1), .home)
    }

    func testControllerActionsKnowTheirDirections() {
        XCTAssertTrue(BigPictureAction.up.isDirection)
        XCTAssertTrue(BigPictureAction.right.isDirection)
        XCTAssertFalse(BigPictureAction.select.isDirection)
        XCTAssertFalse(BigPictureAction.home.isDirection)
    }
}
