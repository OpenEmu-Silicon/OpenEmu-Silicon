// Copyright (c) 2021, OpenEmu Team
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

/// Smoke tests that drive the real app window.
/// Each test launches the Debug build against a throwaway, empty library, so nothing in the user's library changes.
/// Controls are found by their on-screen titles and labels.
final class OpenEmuSmokeUITests: XCTestCase {

    private var app: XCUIApplication!
    private var libraryPath: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        libraryPath = NSTemporaryDirectory() + "openemu-ui-\(UUID().uuidString)"
        app = XCUIApplication(bundleIdentifier: "org.openemu.OpenEmu.debug")
        // Both keys must match, otherwise the app refuses to create a library at a non-default path.
        app.launchArguments = ["-databasePath", libraryPath, "-defaultDatabasePath", libraryPath]
        app.launch()
        XCTAssertTrue(libraryWindow.waitForExistence(timeout: 45), "Library window did not appear")
        dismissFirstRunAlert()
    }

    override func tearDownWithError() throws {
        app.terminate()
        try? FileManager.default.removeItem(atPath: libraryPath)
    }

    private var libraryWindow: XCUIElement { app.windows["LibraryWindow"] }

    func testLaunchShowsEmptyLibrary() throws {
        XCTAssertTrue(libraryWindow.outlines.staticTexts["All Games"].waitForExistence(timeout: 10))
        XCTAssertTrue(libraryWindow.staticTexts["Game Scanner"].exists)
        attachScreenshot(named: "empty-library")
    }

    func testLibraryCategoryTabsSwitch() throws {
        let category = libraryWindow.toolbars.radioGroups["Category"]
        for name in ["Save States", "Screenshots", "Homebrew", "Library"] {
            let tab = category.radioButtons[name]
            XCTAssertTrue(tab.waitForExistence(timeout: 5), "Missing tab: \(name)")
            tab.click()
            XCTAssertEqual(tab.value as? Int, 1, "\(name) tab did not become selected")
        }
        attachScreenshot(named: "category-tabs")
    }

    func testPreferencesPanesAllOpen() throws {
        app.typeKey(",", modifierFlags: .command)
        let panes = ["Library", "Gameplay", "Controls", "Cores", "System Files",
                     "Cloud Sync", "Cover Art", "Achievements", "Secrets"]
        for name in panes {
            let button = app.buttons[name].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10), "Missing pane button: \(name)")
            button.click()
            XCTAssertTrue(app.windows[name].waitForExistence(timeout: 5), "\(name) pane did not open")
            attachScreenshot(named: "prefs-\(name)")
        }
    }

    func testCoresPaneListsInstalledCores() throws {
        app.typeKey(",", modifierFlags: .command)
        let button = app.buttons["Cores"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.click()
        XCTAssertTrue(app.windows["Cores"].waitForExistence(timeout: 5))
        // One row per system. A normal build lists dozens; an empty table means the core plugins failed to load.
        let rows = app.windows["Cores"].tables.firstMatch.tableRows
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "No systems listed in the Cores pane")
        XCTAssertGreaterThan(rows.count, 10, "Cores pane lists too few systems")
        attachScreenshot(named: "cores-pane")
    }

    /// Loads the ROM named by OE_TEST_ROM (set with `check.sh --rom <path>`), then checks that the game
    /// draws, keeps changing, can quick save, can take a screenshot, and quits cleanly.
    func testGameLoadsAndRuns() throws {
        guard let rom = ProcessInfo.processInfo.environment["OE_TEST_ROM"], !rom.isEmpty else {
            throw XCTSkip("Set OE_TEST_ROM to a ROM path (check.sh --rom <path>) to run this test")
        }
        // Reopen the app with the ROM so the file-open path is exercised.
        app.terminate()
        app.launchArguments += [rom]
        app.launch()
        dismissFirstRunAlert()
        let play = app.sheets.buttons["Play Game"]
        XCTAssertTrue(play.waitForExistence(timeout: 60), "Import-finished prompt did not appear")
        play.click()

        let gameWindow = app.windows.matching(NSPredicate(
            format: "identifier != 'LibraryWindow' AND title != '' AND title != 'OpenEmu'")).firstMatch
        XCTAssertTrue(gameWindow.waitForExistence(timeout: 30), "Game window did not open")

        // Give the core time to boot, then sample three frames a few seconds apart.
        sleep(5)
        var frames: [[UInt8]] = []
        for i in 0..<3 {
            let shot = gameWindow.screenshot()
            frames.append(Self.fingerprint(shot.image))
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = "game-frame-\(i)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if i < 2 { sleep(3) }
        }
        XCTAssertFalse(frames.contains { Self.isBlank($0) }, "Game window is blank (black or one flat colour)")
        XCTAssertTrue(Self.differs(frames[0], frames[1]) || Self.differs(frames[1], frames[2]),
                      "Game picture did not change across 6 seconds (frozen, or a static screen: try another ROM)")

        // Quick save should enable Quick Load.
        chooseMenu("Controls", "Quick Save")
        app.menuBars.menuBarItems["Controls"].click()
        XCTAssertTrue(app.menuBars.menuItems["Quick Load"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuBars.menuItems["Quick Load"].isEnabled, "Quick Load stayed disabled after Quick Save")
        app.typeKey(.escape, modifierFlags: [])

        chooseMenu("Controls", "Take Screenshot")
        sleep(2)
        XCTAssertFalse(Self.isBlank(Self.fingerprint(gameWindow.screenshot().image)), "Game went blank after screenshot")

        chooseMenu("Controls", "Quit Game")
        let quitSheet = app.sheets.buttons.matching(NSPredicate(format: "title IN {'Quit Game','Stop','OK'}")).firstMatch
        if quitSheet.waitForExistence(timeout: 3) { quitSheet.click() }
        XCTAssertTrue(gameWindow.waitForNonExistence(timeout: 15), "Game window did not close after Quit Game")
    }

    private func chooseMenu(_ menu: String, _ item: String) {
        app.menuBars.menuBarItems[menu].click()
        let menuItem = app.menuBars.menuItems[item]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "Missing menu item: \(menu) > \(item)")
        menuItem.click()
    }

    /// 32x32 grayscale thumbnail, used to compare frames without caring about exact pixels.
    private static func fingerprint(_ image: NSImage) -> [UInt8] {
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return pixels }
        context.interpolationQuality = .low
        // Skip the title bar (top 7%) so a black game still counts as blank.
        let content = cg.cropping(to: CGRect(x: 0, y: Int(Double(cg.height) * 0.07),
                                             width: cg.width, height: Int(Double(cg.height) * 0.93))) ?? cg
        context.draw(content, in: CGRect(x: 0, y: 0, width: size, height: size))
        return pixels
    }

    private static func isBlank(_ pixels: [UInt8]) -> Bool {
        guard let lo = pixels.min(), let hi = pixels.max() else { return true }
        return hi - lo < 12
    }

    private static func differs(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        let total = zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return total > 200
    }

    /// A fresh library shows a one-time "Have you read the guide?" alert. Dismiss it so it cannot block the test.
    private func dismissFirstRunAlert() {
        let dismiss = app.sheets.buttons["Dismiss"]
        if dismiss.waitForExistence(timeout: 5) {
            dismiss.click()
        }
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
