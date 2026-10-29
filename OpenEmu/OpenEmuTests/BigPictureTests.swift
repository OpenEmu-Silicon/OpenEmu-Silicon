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

    func testCanvasHeightFollowsTheScreenShape() {
        XCTAssertEqual(BP.canvasHeight(for: CGSize(width: 1920, height: 1080)), 720, accuracy: 0.01)   // 16:9, TVs and most monitors
        XCTAssertEqual(BP.canvasHeight(for: CGSize(width: 1728, height: 1080)), 800, accuracy: 0.01)   // 16:10, MacBooks
        XCTAssertEqual(BP.canvasHeight(for: CGSize(width: 1280, height: 1024)), 960, accuracy: 0.01)   // 5:4 is clamped to 960
        XCTAssertEqual(BP.canvasHeight(for: CGSize(width: 3440, height: 1440)), 600, accuracy: 0.01)   // ultrawide is clamped to 600
    }

    func testCanvasHeightIsSafeBeforeTheWindowHasASize() {
        XCTAssertEqual(BP.canvasHeight(for: .zero), 720)
    }

    func testControllerActionsKnowTheirDirections() {
        XCTAssertTrue(BigPictureAction.up.isDirection)
        XCTAssertTrue(BigPictureAction.right.isDirection)
        XCTAssertFalse(BigPictureAction.select.isDirection)
        XCTAssertFalse(BigPictureAction.home.isDirection)
    }

    /// A game with no art is drawn on its system's colors. Near-black ones read as an empty box.
    func testNoArtPlaceholdersAreNeverNearBlack() {
        let systems = ["openemu.system.nes", "openemu.system.snes", "openemu.system.n64", "openemu.system.gba",
                       "openemu.system.psx", "openemu.system.ps2", "openemu.system.psp", "openemu.system.arcade",
                       "openemu.system.saturn", "openemu.system.dc", "openemu.system.genesis", "openemu.system.unknown", nil]
        for system in systems {
            for color in BP.systemColors(system) {
                let c = NSColor(color).usingColorSpace(.sRGB)!
                let brightest = max(c.redComponent, c.greenComponent, c.blueComponent)
                XCTAssertGreaterThan(brightest, 0.25, "\(system ?? "nil") placeholder is nearly black")
            }
        }
    }

    /// Hover only highlights; the page stays put. Wheel and keys hand the view back and forth.
    @MainActor func testPointerScrollingLeavesTheHighlightAlone() {
        let model = BigPictureModel()
        // With no library there are no shelves, so scrolling is refused and nothing moves.
        model.scrollPage(by: 100)
        XCTAssertEqual(model.pageNudge, 0)
        XCTAssertFalse(model.pointerDriven)
        model.perform(.down, source: "keyboard")
        XCTAssertFalse(model.pointerDriven)
    }

    private func media(_ type: String, _ name: String, region: String = "wor") -> [String: Any] {
        ["type": type, "region": region, "url": "https://example.test/\(name).png"]
    }

    func testScreenScraperGivesPosterBackdropAndLogoFromOneLookup() {
        let jeu: [String: Any] = ["medias": [
            media("box-2D", "box"), media("ss", "shot"), media("fanart", "fan"), media("wheel", "wheel"), media("wheel-hd", "wheelhd"), media("mixrbv1", "mix1"), media("mixrbv2", "mix2"), media("support-2D", "cart"),
        ]]
        let result = ScreenScraperClient.shared.parseGameInfo(jeu: jeu)
        XCTAssertEqual(result?.boxImageURL?.lastPathComponent, "box.png")
        XCTAssertEqual(result?.heroImageURL?.lastPathComponent, "fan.png")      // fan art beats a screenshot
        XCTAssertEqual(result?.logoImageURL?.lastPathComponent, "wheelhd.png")  // the HD logo beats the plain one
        XCTAssertEqual(result?.iconImageURL?.lastPathComponent, "cart.png")     // the cartridge or disc, for tiles
        XCTAssertEqual(result?.iconImageURLs.map { $0.lastPathComponent }, ["cart.png", "mix2.png", "mix1.png"])
    }

    func testFanArtBeatsAScreenshotEvenWhenOnlyTheScreenshotHasTheRightRegion() {
        // Fan art carries no region tag; the screenshot is tagged for the player's region.
        let fan: [String: Any] = ["type": "fanart", "url": "https://example.test/fan.png"]
        let jeu: [String: Any] = ["medias": [media("box-2D", "box"), media("ss", "shot", region: "us"), fan]]
        XCTAssertEqual(ScreenScraperClient.shared.parseGameInfo(jeu: jeu)?.heroImageURL?.lastPathComponent, "fan.png")
    }

    func testScreenScraperBackdropFallsBackToAScreenshot() {
        let result = ScreenScraperClient.shared.parseGameInfo(jeu: ["medias": [media("box-2D", "box"), media("ss", "shot")]])
        XCTAssertEqual(result?.heroImageURL?.lastPathComponent, "shot.png")
        XCTAssertNil(result?.logoImageURL)
    }

    func testScreenScraperTileTriesTheCutoutsBeforeTheSquareMix() {
        let jeu: [String: Any] = ["medias": [media("box-2D", "box"), media("mixrbv2", "mix2"), media("box-3D", "box3d")]]
        let result = ScreenScraperClient.shared.parseGameInfo(jeu: jeu)
        XCTAssertEqual(result?.iconImageURLs.map { $0.lastPathComponent }, ["box3d.png", "mix2.png"])  // no support-2D: the 3D box
    }

    func testCutoutsAreToldApartFromPicturesWithABackground() {
        func image(opaque: Bool) -> NSImage {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(using: .copy)
            if opaque { NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill() }
            NSColor.blue.setFill(); NSRect(x: 2, y: 2, width: 4, height: 4).fill()
            NSGraphicsContext.restoreGraphicsState()
            let result = NSImage(size: NSSize(width: 8, height: 8)); result.addRepresentation(rep); return result
        }
        XCTAssertTrue(image(opaque: false).hasTransparentCorners)
        XCTAssertFalse(image(opaque: true).hasTransparentCorners)
        XCTAssertTrue(image(opaque: true).isNearlySquare)
    }

    func testALogoInThePlayersRegionBeatsAnHDLogoInAnother() {
        // Super Mario Bros.: the plain logo has US and EU versions; the only HD logo is the Japanese one.
        let jeu: [String: Any] = ["medias": [
            media("box-2D", "box"), media("wheel", "wheel-eu", region: "eu"), media("wheel", "wheel-us", region: "us"),
            media("wheel-hd", "hd-jp", region: "jp"),
        ]]
        let result = ScreenScraperClient.shared.parseGameInfo(jeu: jeu)
        XCTAssertTrue(["wheel-us.png", "wheel-eu.png"].contains(result?.logoImageURL?.lastPathComponent ?? ""))
    }

    func testAJapaneseLogoIsTheLastResort() {
        let jeu: [String: Any] = ["medias": [media("box-2D", "box"), media("wheel-hd", "hd-jp", region: "jp"), media("wheel", "wheel-fr", region: "fr")]]
        XCTAssertEqual(ScreenScraperClient.shared.parseGameInfo(jeu: jeu)?.logoImageURL?.lastPathComponent, "wheel-fr.png")
        let only: [String: Any] = ["medias": [media("box-2D", "box"), media("wheel-hd", "hd-jp", region: "jp")]]
        XCTAssertEqual(ScreenScraperClient.shared.parseGameInfo(jeu: only)?.logoImageURL?.lastPathComponent, "hd-jp.png")
    }

    func testLibraryOnlyUsesNoProvider() {
        let defaults = UserDefaults.standard
        let before = defaults.object(forKey: OEBigPictureArtSource.defaultsKey)
        defer { defaults.set(before, forKey: OEBigPictureArtSource.defaultsKey) }
        defaults.set("libraryOnly", forKey: OEBigPictureArtSource.defaultsKey)
        XCTAssertTrue(OEBigPictureArtSource.providers().isEmpty)
        XCTAssertEqual(OEBigPictureArtSource.inUseTitle, "Library covers only")
    }

    func testAutomaticAlwaysEndsWithTheKeylessProvider() {
        let defaults = UserDefaults.standard
        let before = defaults.object(forKey: OEBigPictureArtSource.defaultsKey)
        defer { defaults.set(before, forKey: OEBigPictureArtSource.defaultsKey) }
        defaults.set("automatic", forKey: OEBigPictureArtSource.defaultsKey)
        XCTAssertEqual(OEBigPictureArtSource.providers().last?.id, "libretro")
    }

    func testAGameTakesEachPictureFromTheFirstProviderThatHasIt() {
        let first = NSImage(size: NSSize(width: 1, height: 1)), second = NSImage(size: NSSize(width: 2, height: 2))
        var art = OEBigPictureArtSet(hero: first)
        XCTAssertFalse(art.isComplete)
        art.fillGaps(from: OEBigPictureArtSet(hero: second, grid: second, icon: second, logo: second))
        XCTAssertTrue(art.hero === first)   // kept
        XCTAssertTrue(art.grid === second)  // filled
        XCTAssertTrue(art.isComplete)
    }

    func testEverySourceCanBeSavedAndRead() {
        for source in OEBigPictureArtSource.allCases {
            XCTAssertEqual(OEBigPictureArtSource(rawValue: source.rawValue), source)
            XCTAssertFalse(source.title.isEmpty)
        }
    }

    private func solid(_ width: Int, _ height: Int, cutout: Bool) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill(using: .copy)
        NSColor.red.setFill()
        (cutout ? NSRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2) : NSRect(x: 0, y: 0, width: width, height: height)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: height)); image.addRepresentation(rep); return image
    }

    func testSavedCopiesKeepFullResolutionAndComeBackTheSame() throws {
        let store = OEBigPictureArtStore(signature: "test-\(UUID().uuidString)")
        let md5 = UUID().uuidString
        let backdrop = solid(1920, 1080, cutout: false), cartridge = solid(600, 386, cutout: true)
        store.write(OEBigPictureArtSet(hero: backdrop, grid: solid(498, 680, cutout: false), icon: cartridge, logo: cartridge), md5: md5, standardPoster: false)
        let read = store.read(md5: md5, providerIDs: []).stored
        XCTAssertEqual(try XCTUnwrap(read.backdrop).size.width, 1920)                      // nothing is scaled down
        XCTAssertEqual(try XCTUnwrap(read.backdrop).size.width / read.backdrop!.size.height, 1920.0 / 1080.0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(read.icon).size.width / read.icon!.size.height, 600.0 / 386.0, accuracy: 0.02)
        XCTAssertTrue(OEBigPictureArtStore.hasTransparentCorners(try XCTUnwrap(read.icon)))   // a cutout stays a cutout
        XCTAssertNotNil(store.readHero(md5: md5))
        XCTAssertFalse(read.standardPoster)
    }

    func testAProviderIsAskedAgainOnlyIfItFoundNothingLongAgo() {
        let store = OEBigPictureArtStore(signature: "test-\(UUID().uuidString)")
        let md5 = UUID().uuidString
        XCTAssertTrue(store.read(md5: md5, providerIDs: ["libretro"]).answered.isEmpty)
        store.recordAnswer(md5: md5, providerID: "libretro", found: false)
        store.recordAnswer(md5: md5, providerID: "screenscraper", found: true)
        XCTAssertEqual(store.read(md5: md5, providerIDs: ["libretro", "screenscraper"]).answered, ["libretro", "screenscraper"])
        XCTAssertTrue(store.read(md5: md5, providerIDs: ["steamgriddb"]).answered.isEmpty)   // a different provider has not answered
    }

    func testSourcesDoNotShareSavedCopies() throws {
        let one = OEBigPictureArtStore(signature: "test-a-\(UUID().uuidString)"), two = OEBigPictureArtStore(signature: "test-b-\(UUID().uuidString)")
        let md5 = UUID().uuidString
        one.write(OEBigPictureArtSet(grid: solid(100, 140, cutout: false)), md5: md5, standardPoster: true)
        XCTAssertNotNil(one.read(md5: md5, providerIDs: []).stored.poster)
        XCTAssertTrue(one.read(md5: md5, providerIDs: []).stored.standardPoster)
        XCTAssertNil(two.read(md5: md5, providerIDs: []).stored.poster)
    }
}
