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
            // Play tests (Scripts/playtest.sh --game ...) use the real library, so no library arguments.
            app.launchArguments = []
        } else {
            // Both keys must match, otherwise the app refuses to create a library at a non-default path.
            app.launchArguments = ["-databasePath", libraryPath, "-defaultDatabasePath", libraryPath]
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

    /// Plays the ROM named by OE_TEST_ROM for OE_PLAYTEST_SECONDS (default 20), typing each key in OE_PLAYTEST_KEYS
    /// (comma separated: return, space, escape, up, down, left, right, or a single character) about every two seconds
    /// and taking a screenshot after each. It asserts almost nothing: its job is to produce screenshots, logs and
    /// frame stats for `Scripts/playtest.sh` to report on. Skipped unless OE_PLAYTEST_SECONDS is set.
    func testPlaytest() throws {
        guard let secondsText = ProcessInfo.processInfo.environment["OE_PLAYTEST_SECONDS"], let seconds = Double(secondsText) else {
            throw XCTSkip("Run through Scripts/playtest.sh")
        }
        let keys = (ProcessInfo.processInfo.environment["OE_PLAYTEST_KEYS"] ?? "")
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let gameWindow = try openGameWindow()
        let start = Date()
        attach(gameWindow, named: "playtest-000s-start")
        var step = 0
        var shots = 0, blank = 0, changes = 0
        var previous = Self.fingerprint(gameWindow.screenshot().image)
        while Date().timeIntervalSince(start) < seconds {
            sleep(2)
            var label = "idle"
            if step < keys.count {
                label = keys[step]
                typeKeyByName(label)
                step += 1
            }
            attach(gameWindow, named: String(format: "playtest-%03ds-%@", Int(Date().timeIntervalSince(start)), label))
            let now = Self.fingerprint(gameWindow.screenshot().image)
            shots += 1
            if Self.isBlank(now) { blank += 1 }
            if Self.differs(previous, now) { changes += 1 }
            previous = now
        }
        // The game's own "Take Screenshot" reads the picture the core rendered, so it works even for cores whose
        // output a window capture cannot see. It adds one screenshot to the library, hence opt-in.
        if ProcessInfo.processInfo.environment["OE_PLAYTEST_GAME_SHOT"] == "1" {
            chooseMenu("Controls", "Take Screenshot")
            sleep(2)
        }
        // Read by Scripts/playtest.sh. "blank" means the picture was one flat colour (black), "changes" how many
        // times the picture differed from the one before it.
        print("PLAYTEST-PICTURE screenshots=\(shots) blank=\(blank) changes=\(changes)")
        // Quick Save writes into the player's save slot, so a play test on the real library skips it unless asked.
        if !Self.usesRealLibrary || ProcessInfo.processInfo.environment["OE_PLAYTEST_SAVE"] == "1" {
            chooseMenu("Controls", "Quick Save")
            sleep(2)
        }
        chooseMenu("Controls", "Quit Game")
        confirmQuitIfAsked()
        XCTAssertTrue(gameWindow.waitForNonExistence(timeout: 15), "Game window did not close after Quit Game")
    }

    private func typeKeyByName(_ name: String) {
        switch name.lowercased() {
        case "return", "enter": app.typeKey(.return, modifierFlags: [])
        case "escape", "esc": app.typeKey(.escape, modifierFlags: [])
        case "space": app.typeKey(" ", modifierFlags: [])
        case "up": app.typeKey(.upArrow, modifierFlags: [])
        case "down": app.typeKey(.downArrow, modifierFlags: [])
        case "left": app.typeKey(.leftArrow, modifierFlags: [])
        case "right": app.typeKey(.rightArrow, modifierFlags: [])
        default: app.typeKey(name, modifierFlags: [])
        }
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
            // The game is already in the library, so there may be no import prompt: press Play if it shows up.
            if play.waitForExistence(timeout: 20) { play.click() }
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

    /// "Are you sure you want to quit the game?" is a dialog inside the game window with a "Quit" button.
    private func confirmQuitIfAsked() {
        let quit = app.buttons.matching(NSPredicate(format: "title IN {'Quit','Quit Game','Stop','OK'}")).firstMatch
        if quit.waitForExistence(timeout: 3) { quit.click() }
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
