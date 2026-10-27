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
        // Not NSTemporaryDirectory(): the UI test runner is sandboxed, so that folder lives inside the runner's
        // container, which macOS does not let the app under test write to. The app then cannot create the
        // library and shows "library not found". /private/tmp is writable by both.
        libraryPath = "/private/tmp/openemu-ui-\(UUID().uuidString)"
        app = XCUIApplication(bundleIdentifier: "org.openemu.OpenEmu.debug")
        if Self.usesRealLibrary {
            // Real-library runs (Scripts/playtest.sh --game ..., Scripts/check.sh --game ...) use the player's library,
            // so no library arguments. Closing a game must not replace the player's auto save (debug builds only).
            app.launchArguments = ["-OESkipAutosaveOnStop", "1"]
        } else {
            // Both keys must match, otherwise the app refuses to create a library at a non-default path.
            // The empty backup folder keeps the tests away from any Cloud Sync folder set in the debug app.
            app.launchArguments = baseArguments + ["-OEBackupFolderPath", ""]
        }
        app.launch()
        XCTAssertTrue(libraryWindow.waitForExistence(timeout: 45), "Library window did not appear")
        dismissFirstRunAlert()
    }

    override func tearDownWithError() throws {
        app.terminate()
        if !Self.usesRealLibrary { try? FileManager.default.removeItem(atPath: libraryPath) }
    }

    /// True when OE_USE_REAL_LIBRARY=1: the test opens games from the user's own library instead of a throwaway one.
    private static var usesRealLibrary: Bool { ProcessInfo.processInfo.environment["OE_USE_REAL_LIBRARY"] == "1" }

    private var baseArguments: [String] { ["-databasePath", libraryPath, "-defaultDatabasePath", libraryPath] }

    private var libraryWindow: XCUIElement { app.windows["LibraryWindow"] }

    func testLaunchShowsEmptyLibrary() throws {
        try XCTSkipIf(Self.usesRealLibrary, "Needs the throwaway empty library (check.sh --throwaway-library)")
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
                     "Cloud Sync", "Cover Art", "Achievements"]
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
        // Reopens the app with the ROM so the file-open path is exercised.
        let gameWindow = try openGameWindow()

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

        // Quick save should enable Quick Load. Skipped on a real library: it would write a save state into it.
        if !Self.usesRealLibrary {
            chooseMenu("Controls", "Quick Save")
            app.menuBars.menuBarItems["Controls"].click()
            XCTAssertTrue(app.menuBars.menuItems["Quick Load"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.menuBars.menuItems["Quick Load"].isEnabled, "Quick Load stayed disabled after Quick Save")
            app.typeKey(.escape, modifierFlags: [])
        }

        chooseMenu("Controls", "Take Screenshot")
        sleep(2)
        XCTAssertFalse(Self.isBlank(Self.fingerprint(gameWindow.screenshot().image)), "Game went blank after screenshot")

        chooseMenu("Controls", "Quit Game")
        confirmQuitIfAsked()
        XCTAssertTrue(gameWindow.waitForNonExistence(timeout: 15), "Game window did not close after Quit Game")
    }

    /// Pausing must freeze the picture and resuming must start it moving again.
    /// Needs OE_TEST_ROM to name a ROM whose picture always changes (check.sh supplies a built-in test ROM).
    func testPauseFreezesPictureAndResumeContinues() throws {
        let gameWindow = try openGameWindow()
        sleep(5)

        chooseMenu("Controls", "Pause Game")
        sleep(1)
        attach(gameWindow, named: "paused-A")
        let frozenA = Self.fingerprint(gameWindow.screenshot().image)
        sleep(2)
        attach(gameWindow, named: "paused-B")
        let frozenB = Self.fingerprint(gameWindow.screenshot().image)
        XCTAssertFalse(Self.differs(frozenA, frozenB), "Picture kept changing while the game was paused")

        chooseMenu("Controls", "Resume Game")
        sleep(1)
        let movingA = Self.fingerprint(gameWindow.screenshot().image)
        sleep(2)
        let movingB = Self.fingerprint(gameWindow.screenshot().image)
        XCTAssertTrue(Self.differs(movingA, movingB), "Picture stayed frozen after Resume Game")

        chooseMenu("Controls", "Quit Game")
        confirmQuitIfAsked()
        XCTAssertTrue(gameWindow.waitForNonExistence(timeout: 15), "Game window did not close after Quit Game")
    }

    /// A key typed into the game window must reach the game as a button press.
    /// The built-in test ROM latches Start (default key: Return) by changing its shades for good.
    /// Brightness, not the exact picture, is compared because the picture also scrolls.
    func testKeyboardPressReachesGame() throws {
        let gameWindow = try openGameWindow()
        sleep(5)
        attach(gameWindow, named: "before-key")
        let before = Self.meanBrightness(Self.fingerprint(gameWindow.screenshot().image))

        app.typeKey(.return, modifierFlags: [])
        sleep(2)
        attach(gameWindow, named: "after-key")
        let after = Self.meanBrightness(Self.fingerprint(gameWindow.screenshot().image))
        XCTAssertGreaterThan(abs(after - before), 8, "Pressing Return did not reach the game (brightness \(before) -> \(after))")

        chooseMenu("Controls", "Quit Game")
        confirmQuitIfAsked()
        XCTAssertTrue(gameWindow.waitForNonExistence(timeout: 15), "Game window did not close after Quit Game")
    }

    private static func meanBrightness(_ pixels: [UInt8]) -> Double {
        pixels.isEmpty ? 0 : Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count)
    }

    /// Opens the ROM named by OE_TEST_ROM in a game window and returns that window.
    private func openGameWindow() throws -> XCUIElement {
        guard let rom = ProcessInfo.processInfo.environment["OE_TEST_ROM"], !rom.isEmpty else {
            throw XCTSkip("Set OE_TEST_ROM to a ROM path (check.sh --rom <path>) to run this test")
        }
        app.terminate()
        app.launchArguments += [rom]
        app.launch()
        dismissFirstRunAlert()
        let play = app.sheets.buttons["Play Game"]
        if Self.usesRealLibrary {
            // The game is usually already in the library, so there may be no import prompt. A game that was just
            // imported (the built-in test ROM) can take a while to finish, so wait up to 60 seconds for the prompt,
            // but stop waiting as soon as the game window or the resume question is up.
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                if play.exists { play.click(); break }
                if app.windows.matching(NSPredicate(format: "identifier != 'LibraryWindow' AND title != '' AND title != 'OpenEmu'")).firstMatch.exists
                    || app.buttons["Resume"].firstMatch.exists { break }
                usleep(500_000)
            }
        } else {
            XCTAssertTrue(play.waitForExistence(timeout: 60), "Import-finished prompt did not appear")
            play.click()
        }
        if Self.usesRealLibrary {
            // A game that was closed before offers "Would you like to continue your last game?". Answer it the way a
            // player would: Resume (or Restart when OE_PLAYTEST_RESTART=1).
            let answer = ProcessInfo.processInfo.environment["OE_PLAYTEST_RESTART"] == "1" ? "Restart" : "Resume"
            let button = app.buttons[answer].firstMatch
            if button.waitForExistence(timeout: 15) { button.click() }
        }
        let gameWindow = app.windows.matching(NSPredicate(
            format: "identifier != 'LibraryWindow' AND title != '' AND title != 'OpenEmu'")).firstMatch
        XCTAssertTrue(gameWindow.waitForExistence(timeout: 60), "Game window did not open")
        return gameWindow
    }

    private func attach(_ element: XCUIElement, named name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }


    /// Big-picture spike (#789): opens the mode, visits each screen with the keyboard, launches a game from it,
    /// and checks the menu comes back when the game quits. Controller input can't be sent from a test.
    func testBigPictureKeyboardNavigationLaunchAndReturn() throws {
        let gameWindow = try openGameWindow()
        sleep(3)
        chooseMenu("Controls", "Quit Game")
        confirmQuitIfAsked()
        XCTAssertTrue(gameWindow.waitForNonExistence(timeout: 15), "Game window did not close after Quit Game")

        let bigPicture = app.windows["BigPictureWindow"]
        app.typeKey("b", modifierFlags: [.control, .command])
        XCTAssertTrue(bigPicture.waitForExistence(timeout: 10), "Big-picture window did not open")
        XCTAssertTrue(bigPicture.staticTexts["Resume"].waitForExistence(timeout: 10), "Hero Resume button missing")
        sleep(2)
        attachScreenshot(named: "bigpicture-home")

        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        sleep(1)
        attachScreenshot(named: "bigpicture-shelf")
        app.typeKey("m", modifierFlags: [])
        XCTAssertTrue(bigPicture.staticTexts["SYSTEMS"].waitForExistence(timeout: 5), "Sidebar did not open")
        sleep(1)
        attachScreenshot(named: "bigpicture-sidebar")
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey(.return, modifierFlags: [])
        sleep(1)
        attachScreenshot(named: "bigpicture-detail")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("m", modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        sleep(1)
        attachScreenshot(named: "bigpicture-settings")
        app.typeKey(.escape, modifierFlags: [])
        sleep(1)

        // Leaving Settings puts the highlight on the hero's Resume button, so Return launches the game.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(gameWindow.waitForExistence(timeout: 30), "Game did not launch from big picture")
        XCTAssertTrue(bigPicture.waitForNonExistence(timeout: 10), "Big-picture window stayed up over the game")
        sleep(4)

        // The game is fullscreen and hides the menu bar, so use the Close Window shortcut.
        app.typeKey("w", modifierFlags: .command)
        // The "Are you sure?" dialog can take a few seconds to show over a fullscreen game.
        let quit = app.dialogs.buttons["Quit"]
        if quit.waitForExistence(timeout: 10) { quit.click() }
        XCTAssertTrue(bigPicture.waitForExistence(timeout: 20), "Big picture did not return after the game quit")
        attachScreenshot(named: "bigpicture-returned")

        // The first Escape moves the highlight up to the tab bar; the second leaves the mode.
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(bigPicture.waitForNonExistence(timeout: 10), "Escape did not close big picture")
    }

    /// Plays the ROM named by OE_TEST_ROM with a backup folder set, then checks that a quick save is
    /// copied into the folder with a "which Mac saved this" file, and that saving again keeps the
    /// replaced copy in a .versions folder.
    func testQuickSaveIsBackedUpWithVersions() throws {
        try XCTSkipIf(Self.usesRealLibrary, "Writes save states, so it only runs against the throwaway library")
        guard let rom = ProcessInfo.processInfo.environment["OE_TEST_ROM"], !rom.isEmpty else {
            throw XCTSkip("Set OE_TEST_ROM to a ROM path (check.sh --rom <path>) to run this test")
        }
        let backupFolder = NSTemporaryDirectory() + "openemu-ui-backup-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: backupFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: backupFolder) }

        app.terminate()
        app.launchArguments = baseArguments + ["-OEBackupFolderPath", backupFolder, rom]
        app.launch()
        dismissFirstRunAlert()
        let play = app.sheets.buttons["Play Game"]
        XCTAssertTrue(play.waitForExistence(timeout: 60), "Import-finished prompt did not appear")
        play.click()

        let gameWindow = app.windows.matching(NSPredicate(
            format: "identifier != 'LibraryWindow' AND title != '' AND title != 'OpenEmu'")).firstMatch
        XCTAssertTrue(gameWindow.waitForExistence(timeout: 30), "Game window did not open")
        sleep(8)

        chooseMenu("Controls", "Quick Save")
        let saveState = try waitForFile(in: backupFolder, timeout: 30) { $0.pathExtension == "oesavestate" }
        XCTAssertNotNil(saveState, "Quick save was not copied into the backup folder")
        let info = try waitForFile(in: backupFolder + "/Sync Info", timeout: 15) { $0.pathExtension == "json" }
        XCTAssertNotNil(info, "No sync info file was written next to the backup")
        if let info {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: info)) as? [String: Any]
            XCTAssertFalse((json?["machineName"] as? String ?? "").isEmpty, "Sync info does not name the Mac")
            XCTAssertFalse((json?["machineID"] as? String ?? "").isEmpty, "Sync info has no Mac id")
        }

        sleep(3)
        chooseMenu("Controls", "Quick Save")
        let kept = try waitForFile(in: backupFolder, timeout: 30) { $0.deletingLastPathComponent().lastPathComponent == ".versions" }
        XCTAssertNotNil(kept, "Saving again did not keep the replaced copy in a .versions folder")

        chooseMenu("Controls", "Quit Game")
        confirmQuitIfAsked()
        XCTAssertTrue(gameWindow.waitForNonExistence(timeout: 15), "Game window did not close after Quit Game")
    }

    /// Polls until a file under `root` (hidden folders included) matches, or the timeout passes.
    private func waitForFile(in root: String, timeout: TimeInterval, matching: (URL) -> Bool) throws -> URL? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil, options: []) {
                for case let url as URL in enumerator where matching(url) { return url }
            }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
        return nil
    }

    /// Quitting a game asks "Are you sure?" unless the user ticked "Do not ask me again". It appears as a
    /// sheet, a separate dialog, or a dialog inside the game window, depending on the window state.
    private func confirmQuitIfAsked() {
        let names = "{'Quit Game','Quit','Stop','OK'}"
        let sheetButton = app.sheets.buttons.matching(NSPredicate(format: "title IN \(names)")).firstMatch
        let dialogButton = app.dialogs.buttons.matching(NSPredicate(format: "title IN \(names)")).firstMatch
        let inWindowButton = app.buttons.matching(NSPredicate(format: "title IN \(names)")).firstMatch
        if sheetButton.waitForExistence(timeout: 3) {
            sheetButton.click()
        } else if dialogButton.waitForExistence(timeout: 1) {
            dialogButton.click()
        } else if inWindowButton.waitForExistence(timeout: 1) {
            inWindowButton.click()
        }
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
        // Skip the title bar (top 7%) so a black game still counts as blank, and the bottom 20% where the
        // on-screen control bar fades in and out, which would otherwise look like the picture changing.
        let content = cg.cropping(to: CGRect(x: 0, y: Int(Double(cg.height) * 0.07),
                                             width: cg.width, height: Int(Double(cg.height) * 0.73))) ?? cg
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
