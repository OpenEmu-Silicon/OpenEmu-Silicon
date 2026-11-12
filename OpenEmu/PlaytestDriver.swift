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

#if DEBUG
import Cocoa
import CryptoKit
import OpenEmuSystem
import os.log

/// Plays a game from inside the debug app so `Scripts/playtest.sh` needs no UI-test runner (and none of the macOS
/// permission prompts that come with one).
///
/// Started by the launch argument `-OEPlaytestPlan <plan.json>`. It opens the game in the library, waits until it
/// is running, sends keys at the times in the plan through the same path a real keyboard uses, saves screenshots
/// of what the core rendered (not a capture of the window, and nothing is added to the library), then closes the
/// game the normal way and quits the app. It writes `result.json` into the plan's output folder.
///
/// Plan format (all times in seconds after the game starts running):
/// ```
/// { "romPath": "/path/in/library.z64", "seconds": 20, "screenshotEvery": 2, "outputDirectory": "/tmp/out",
///   "steps": [ {"at": 2, "key": "return"}, {"at": 4, "key": "k", "hold": 0.2} ] }
/// ```
/// Keys: a letter or digit, return, escape, space, up, down, left, right, lshift, rshift.
final class PlaytestDriver {

    static let shared = PlaytestDriver()
    static let planKey = "OEPlaytestPlan"

    private struct Plan: Decodable {
        var romPath: String
        var seconds: Double
        var screenshotEvery: Double?
        var outputDirectory: String
        var steps: [Step]
        /// Also restore from the backup and compare. This rewrites the local saves, so it is off unless asked for.
        var auditRestore: Bool?
        /// Look at big picture instead of playing a game: actions ("up", "select", "back") and "shot:<name>" /
        /// "wait:<seconds>" steps. Nothing is launched and nothing is saved.
        var bigPicture: [String]?
    }

    private struct Step: Decodable {
        var at: Double
        var key: String
        var hold: Double?
    }

    private struct Shot: Encodable {
        var file: String
        var secondsIn: Double
        var lastKey: String
        /// The picture after the shader chain (what a player sees, and what the PNG shows).
        var blank: Bool
        /// The core's own picture before the shader chain. nil when it could not be captured.
        var sourceBlank: Bool?
        var changedFromPrevious: Bool
    }

    private struct Result: Encodable {
        var status: String
        var message: String
        var game: String
        var secondsPlayed: Double
        var keysSent: [String]
        var shots: [Shot]
        var backupAudit: [String]
        /// The longest time the main thread went without running the 50 ms stall timer, in milliseconds. A long one is
        /// a window that would show the spinning wheel (for example while waiting on a slow iCloud folder).
        var longestMainThreadStallMs: Int
    }

    private var plan: Plan?
    private var watchdog: Timer?
    private var stallTimer: Timer?
    private var longestStall: TimeInterval = 0
    private var started = false
    private var shots: [Shot] = []
    private var keysSent: [String] = []
    private var lastKey = "none"
    private var previousPrint: [UInt8]?
    private var gameName = ""
    private var systemIdentifier = ""
    private var backupAudit: [String] = []
    private var runStart = Date()
    private var shotCounter = 0

    private let log = OSLog(subsystem: "org.openemu.OpenEmu", category: "playtest")

    func startIfRequested() {
        guard !started, let planPath = UserDefaults.standard.string(forKey: Self.planKey) else { return }
        started = true
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: planPath))
            let plan = try JSONDecoder().decode(Plan.self, from: data)
            self.plan = plan
            try FileManager.default.createDirectory(atPath: plan.outputDirectory, withIntermediateDirectories: true)
        } catch {
            finish(status: "error", message: "Could not read the play test plan: \(error)")
            return
        }
        os_log(.info, log: log, "Play test starting")
        NSApp.activate(ignoringOtherApps: true)
        // An alert can appear inside the very call that opens the game (the save sync "Still Syncing" prompt does) and
        // block it, so the checks below would never run. This timer runs in all run loop modes, including a modal one.
        var ticks = 0
        let watchdog = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            ticks += 1
            if self.failIfAlertIsShowing(during: "the play test") { return }
            // Every 10 seconds, say which windows exist, so a stuck run can be understood from the log.
            if ticks % 20 == 0, self.currentDocument()?.isPlaying != true {
                let list = NSApp.windows.filter { $0.isVisible }.map {
                    "\(type(of: $0)) level=\($0.level.rawValue) title='\($0.title)' modal=\($0 == NSApp.modalWindow) sheet=\($0.attachedSheet != nil)"
                }
                os_log(.info, log: self.log, "Not playing yet. Visible windows: %{public}@", list.joined(separator: "; "))
            }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog
        var lastTick = Date()
        let stall = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            self.longestStall = max(self.longestStall, now.timeIntervalSince(lastTick) - 0.05)
            lastTick = now
        }
        RunLoop.main.add(stall, forMode: .common)
        self.stallTimer = stall
        if let steps = plan?.bigPicture {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.runBigPicture(steps) } }
        } else {
            DispatchQueue.main.async { self.openGame() }
        }
    }

    // MARK: - Big picture

    /// Opens big picture on the real library and walks through `steps`, saving a screenshot at each "shot:<name>".
    @MainActor private func runBigPicture(_ steps: [String]) {
        guard let plan else { return }
        gameName = "big picture"
        runStart = Date()
        BigPictureWindowController.shared.show()
        var index = 0
        func next(after delay: TimeInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in MainActor.assumeIsolated {
                guard let self else { return }
                guard index < steps.count else {
                    BigPictureWindowController.shared.hide()
                    self.finish(status: "ok", message: "big picture walked through \(steps.count) steps")
                    return
                }
                let step = steps[index]
                index += 1
                if step == "reopen" {
                    // Leave big picture and come back, as exiting and pressing Ctrl+Cmd+B does.
                    BigPictureWindowController.shared.hide()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { MainActor.assumeIsolated {
                        BigPictureWindowController.shared.show()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { MainActor.assumeIsolated {
                            self.keysSent.append("reopen: " + BigPictureWindowController.shared.playtestGeometry())
                            next(after: 0.3)
                        } }
                    } }
                    return
                }
                if step.hasPrefix("shot:") {
                    let name = String(step.dropFirst(5))
                    if let image = BigPictureWindowController.shared.playtestSnapshot(),
                       let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        self.shotCounter += 1
                        let file = String(format: "bp-%02d-%@.png", self.shotCounter, name)
                        try? png.write(to: URL(fileURLWithPath: plan.outputDirectory).appendingPathComponent(file))
                        self.keysSent.append(step)
                    }
                    next(after: 0.3)
                } else if step.hasPrefix("wait:") {
                    next(after: Double(step.dropFirst(5)) ?? 1)
                } else if step.hasPrefix("scroll:") || step.hasPrefix("hscroll:") || step.hasPrefix("hover:") {
                    BigPictureWindowController.shared.playtestPointer(step)
                    self.keysSent.append(step)
                    next(after: 0.5)
                } else if step.hasPrefix("play:") {
                    // Choose what is highlighted (Resume on the hero), let the real game run, then close it.
                    self.bigPicturePlay(seconds: Double(step.dropFirst(5)) ?? 8, via: nil) { next(after: 0.5) }
                } else if step.hasPrefix("pauseplay:") {
                    // "pauseplay:<seconds>:quit" or ":resume": run the game, press Home, and leave through the pause menu.
                    let parts = step.dropFirst(10).split(separator: ":").map(String.init)
                    self.bigPicturePlay(seconds: Double(parts.first ?? "") ?? 6, via: parts.count > 1 ? parts[1] : "quit") { next(after: 0.5) }
                } else {
                    // "home" is the Home button as the window controller sees it; the rest are model actions.
                    if step == "home" { BigPictureWindowController.shared.playtestHome() } else { BigPictureWindowController.shared.playtestPerform(step) }
                    self.keysSent.append(step)
                    next(after: 0.9)
                }
            } }
        }
        // The window goes fullscreen first, which takes a moment.
        next(after: 3.5)
    }

    /// Launches the highlighted game from big picture, plays it for `seconds`, saves what the core drew, closes it the
    /// normal way (the auto save is skipped by -OESkipAutosaveOnStop) and checks that big picture comes back.
    @MainActor private func bigPicturePlay(seconds: Double, via: String?, then resume: @escaping () -> Void) {
        BigPictureWindowController.shared.playtestPerform("select")
        func waitForGame(deadline: Date) {
            if failIfAlertIsShowing(during: "waiting for the game to start") { return }
            if let document = currentDocument(), document.isPlaying {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated {
                    self.lastKey = "play"
                    self.takeShot(document)
                    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated {
                        self.takeShot(document)
                        guard let via = via else {
                            document.stopEmulation(nil)
                            waitForReturn(deadline: Date().addingTimeInterval(30))
                            return
                        }
                        // The Home button: the pause menu should open over big picture and the game should be paused.
                        BigPictureWindowController.shared.playtestHome()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated {
                            self.keysSent.append(document.isEmulationPaused ? "home:game-paused" : "home:GAME-NOT-PAUSED")
                            self.keysSent.append(self.spaceReport(document, label: "after-home"))
                            self.saveBigPictureShot("pause-menu")
                            if via == "quit" {
                                // Down to Quit Game, then Select: no "Are you sure?" alert may appear.
                                BigPictureWindowController.shared.playtestPerform("down")
                                BigPictureWindowController.shared.playtestPerform("select")
                                waitForReturn(deadline: Date().addingTimeInterval(30))
                            } else {
                                // Select on Resume Game: the game must run again.
                                BigPictureWindowController.shared.playtestPerform("select")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { MainActor.assumeIsolated {
                                    self.keysSent.append(document.isEmulationPaused ? "resume:STILL-PAUSED" : "resume:game-running")
                                    self.keysSent.append(self.spaceReport(document, label: "after-resume"))
                                    self.takeShot(document)
                                    document.stopEmulation(nil)
                                    waitForReturn(deadline: Date().addingTimeInterval(30))
                                } }
                            }
                        } }
                    } }
                } }
                return
            }
            if Date() > deadline { finish(status: "error", message: "The game did not start from big picture within 120 seconds"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { waitForGame(deadline: deadline) } }
        }
        func waitForReturn(deadline: Date) {
            if failIfAlertIsShowing(during: "closing the game") { return }
            if currentDocument() == nil {
                // Give the fullscreen Space time to close, then big picture should be back in front.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated {
                    let window = BigPictureWindowController.shared.window
                    let back = window?.isVisible == true && window?.isKeyWindow == true
                    self.keysSent.append(back ? "returned-to-big-picture" : "DID-NOT-RETURN")
                    if !back { self.finish(status: "error", message: "Big picture did not come back after the game closed"); return }
                    resume()
                } }
                return
            }
            if Date() > deadline { finish(status: "error", message: "The game did not close within 30 seconds"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { waitForReturn(deadline: deadline) } }
        }
        waitForGame(deadline: Date().addingTimeInterval(120))
    }

    // MARK: - Steps

    private func openGame() {
        guard let plan else { return }
        let url = URL(fileURLWithPath: plan.romPath)
        do {
            guard let game = try OEDBGame.game(withURL: url) else {
                finish(status: "error", message: "No game in the library for \(plan.romPath)")
                return
            }
            gameName = game.displayName ?? url.lastPathComponent
            systemIdentifier = game.system?.systemIdentifier ?? ""
            (NSApp.delegate as! AppDelegate).mainWindowController.startGameAsPlayer(game)
        } catch {
            finish(status: "error", message: "Could not look the game up: \(error)")
            return
        }
        waitForGameToRun(deadline: Date().addingTimeInterval(120))
    }

    private func currentDocument() -> OEGameDocument? {
        NSDocumentController.shared.documents.compactMap { $0 as? OEGameDocument }.first
    }

    private func waitForGameToRun(deadline: Date) {
        if failIfAlertIsShowing(during: "waiting for the game to start") { return }
        if let document = currentDocument(), document.isPlaying {
            // Give the first frames a moment so the first screenshot is not the loading screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.play(document) }
            return
        }
        if Date() > deadline {
            finish(status: "error", message: "The game did not start running within 120 seconds")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.waitForGameToRun(deadline: deadline) }
    }

    private func play(_ document: OEGameDocument) {
        guard let plan else { return }
        runStart = Date()
        NSApp.activate(ignoringOtherApps: true)
        takeShot(document)

        for step in plan.steps {
            guard let usage = Self.hidUsage(forKey: step.key) else {
                os_log(.error, log: log, "Unknown key %{public}@ in the plan, skipped", step.key)
                continue
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + step.at) {
                self.lastKey = step.key
                self.keysSent.append(step.key)
                // Keys go in inside the helper process, where the game reads its input; the app's own device manager
                // is not connected to the game.
                document.gameCoreHelper?.injectKeyboardKey(usage: UInt(usage), pressed: true)
                // Hold long enough for several frames; a tap shorter than a frame can be missed by the game.
                DispatchQueue.main.asyncAfter(deadline: .now() + (step.hold ?? 0.15)) {
                    document.gameCoreHelper?.injectKeyboardKey(usage: UInt(usage), pressed: false)
                }
            }
        }

        var checkAt = 1.0
        while checkAt < plan.seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + checkAt) { _ = self.failIfAlertIsShowing(during: "playing") }
            checkAt += 1.0
        }
        
        let every = plan.screenshotEvery ?? 2
        var t = every
        while t < plan.seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { self.takeShot(document) }
            t += every
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + plan.seconds) {
            self.takeShot(document)
            self.closeGame(document)
        }
    }

    /// Which of the game window and the big-picture window is on the Space the player is looking at, and which is key.
    @MainActor private func spaceReport(_ document: OEGameDocument, label: String) -> String {
        let game = document.windowControllers.first?.window
        let bp = BigPictureWindowController.shared.window
        let overlay = BigPictureWindowController.shared.playtestPauseOverlay
        func flags(_ window: NSWindow?) -> String {
            guard let window = window else { return "none" }
            return "\(window.isOnActiveSpace ? "ON-SCREEN" : "off-screen")/\(window.isKeyWindow ? "key" : "notkey")"
        }
        return "\(label): game=\(flags(game)) pause-menu=\(flags(overlay)) bigpicture=\(flags(bp))"
    }

    /// A picture of the big-picture window, saved next to the other pictures.
    @MainActor private func saveBigPictureShot(_ name: String) {
        guard let plan, let image = BigPictureWindowController.shared.playtestSnapshot(),
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        shotCounter += 1
        try? png.write(to: URL(fileURLWithPath: plan.outputDirectory).appendingPathComponent(String(format: "bp-%02d-%@.png", shotCounter, name)))
    }

    private func takeShot(_ document: OEGameDocument) {
        guard let plan else { return }
        guard let image = document.screenshot() else { return }
        let sourceBlank = document.sourceScreenshot().map { Self.isBlank(Self.fingerprint(of: $0)) }
        shotCounter += 1
        let seconds = Date().timeIntervalSince(runStart)
        let name = String(format: "shot-%02d-%03ds-%@.png", shotCounter, Int(seconds), lastKey)
        let fingerprint = Self.fingerprint(of: image)
        let blank = Self.isBlank(fingerprint)
        let changed = previousPrint.map { Self.differs($0, fingerprint) } ?? false
        previousPrint = fingerprint
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: plan.outputDirectory).appendingPathComponent(name))
        }
        shots.append(Shot(file: name, secondsIn: seconds, lastKey: lastKey, blank: blank, sourceBlank: sourceBlank, changedFromPrevious: changed))
    }

    private func closeGame(_ document: OEGameDocument) {
        // The "continue your last game" and "are you sure you want to quit" alerts are suppressed by launch arguments
        // (see Scripts/playtest.sh), so this closes the game the way a player would, including the auto save state.
        document.stopEmulation(nil)
        waitForGameToClose(deadline: Date().addingTimeInterval(30))
    }

    private func waitForGameToClose(deadline: Date) {
        if failIfAlertIsShowing(during: "closing the game") { return }
        if currentDocument() == nil {
            auditBackup { self.finish(status: "ok", message: "Played and closed the game") }
            return
        }
        if Date() > deadline {
            finish(status: "error", message: "The game did not close within 30 seconds")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.waitForGameToClose(deadline: deadline) }
    }


    // MARK: - Unexpected alerts

    /// Text of any alert or sheet that is blocking the app right now, or nil. Alerts such as the save sync "Still
    /// Syncing" prompt or "Could not load the state" wait for a person, so a play test must stop and say so instead of
    /// waiting out its timeout.
    private func visibleAlertText() -> String? {
        var windows: [NSWindow] = []
        if let modal = NSApp.modalWindow { windows.append(modal) }
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { windows.append(sheet) }
            // Alerts shown with runModal sit at the modal panel level.
            if window.isVisible, window.level == .modalPanel, !windows.contains(window) { windows.append(window) }
        }
        for window in windows {
            let texts = window.contentView.map { Self.texts(in: $0) } ?? []
            if !texts.isEmpty { return texts.joined(separator: " | ") }
        }
        return nil
    }
    
    private static func texts(in view: NSView) -> [String] {
        var found: [String] = []
        if let field = view as? NSTextField, !field.stringValue.isEmpty { found.append(field.stringValue) }
        if let button = view as? NSButton, !button.title.isEmpty { found.append("[\(button.title)]") }
        for sub in view.subviews { found.append(contentsOf: texts(in: sub)) }
        return found
    }
    
    /// Stops the play test with a clear message when an alert is blocking. Returns true when it did.
    private func failIfAlertIsShowing(during step: String) -> Bool {
        guard !finished, let text = visibleAlertText() else { return false }
        finish(status: "error", message: "An alert is blocking the app while \(step): \(text)", exitImmediately: true)
        return true
    }
    
    // MARK: - Save backup audit

    /// After the game has closed: checks that the save backup folder (iCloud, or wherever it points) really holds
    /// this game's saves, byte for byte, and that restoring from it works. Restoring rewrites the local saves with the
    /// backup's bytes, so it only runs on request (--audit-restore), when they are already identical, and a copy of the local saves is kept first.
    private func auditBackup(then done: @escaping () -> Void) {
        let manager = OEFolderBackupManager.shared
        guard let backup = manager.backupFolderURL else {
            backupAudit = ["No save backup folder is set, nothing to check."]
            done()
            return
        }
        // The same sync that runs when OpenEmu quits, so a state saved a moment ago has been copied.
        manager.flush { [self] in
            DispatchQueue.global(qos: .userInitiated).async {
                var lines: [String] = []
                let fm = FileManager.default
                let support = URL.oeApplicationSupportDirectory
                let safeName = gameName.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "__")
                let shortSystem = systemIdentifier.replacingOccurrences(of: "openemu.system.", with: "")
                
                // Where the sync writes: it mirrors the local folder names.
                let localStates = support.appendingPathComponent("Save States")
                var mirroredDir: URL?
                var localDir: URL?
                if let systems = try? fm.contentsOfDirectory(at: localStates, includingPropertiesForKeys: nil) {
                    // Local folders are named after the ROM file (with its region), the game's name may be shorter.
                    for system in systems {
                        let entries = (try? fm.contentsOfDirectory(at: system, includingPropertiesForKeys: nil)) ?? []
                        if let match = entries.first(where: { $0.lastPathComponent == safeName })
                            ?? entries.first(where: { $0.lastPathComponent.hasPrefix(safeName) }) {
                            localDir = match
                        }
                    }
                }
                if let localDir {
                    let relative = localDir.standardized.path.dropFirst(support.standardized.path.count)
                    mirroredDir = URL(fileURLWithPath: backup.standardized.path + relative)
                }
                guard let localDir, let mirroredDir else {
                    lines.append("No local save states found for \(safeName).")
                    DispatchQueue.main.async { self.backupAudit = lines; done() }
                    return
                }
                lines.append("local saves:  \(localDir.path)")
                lines.append("backup copy:  \(mirroredDir.path)")
                
                func states(in dir: URL) -> [URL] {
                    ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                        .filter { $0.pathExtension.lowercased() == "oesavestate" }
                }
                func digest(of bundle: URL) -> String {
                    var parts: [String] = []
                    let files = (fm.enumerator(at: bundle, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
                    for file in files.sorted(by: { $0.path < $1.path }) {
                        var isDir: ObjCBool = false
                        fm.fileExists(atPath: file.path, isDirectory: &isDir)
                        guard !isDir.boolValue, let data = try? Data(contentsOf: file) else { continue }
                        let name = file.path.dropFirst(bundle.path.count)
                        parts.append("\(name):\(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())")
                    }
                    return SHA256.hash(data: Data(parts.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
                }
                
                let local = states(in: localDir)
                var identical = 0, missing: [String] = [], different: [String] = []
                for state in local {
                    let counterpart = mirroredDir.appendingPathComponent(state.lastPathComponent)
                    if !fm.fileExists(atPath: counterpart.path) { missing.append(state.lastPathComponent); continue }
                    if digest(of: state) == digest(of: counterpart) { identical += 1 } else { different.append(state.lastPathComponent) }
                }
                let newest = states(in: mirroredDir).compactMap {
                    (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                }.max()
                lines.append("save states: \(local.count) local, \(identical) identical in the backup, \(missing.count) missing, \(different.count) different")
                if !missing.isEmpty { lines.append("   missing from backup: \(missing.prefix(5).joined(separator: ", "))") }
                if !different.isEmpty { lines.append("   different in backup: \(different.prefix(5).joined(separator: ", "))") }
                let hidden = (try? fm.contentsOfDirectory(at: mirroredDir, includingPropertiesForKeys: nil, options: [])) ?? []
                let placeholders = hidden.filter { $0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent.hasSuffix(".icloud") }
                lines.append("iCloud placeholders in the backup folder (saves not downloaded to this Mac): \(placeholders.count)")
                if !placeholders.isEmpty { lines.append("   e.g. \(placeholders.prefix(3).map { $0.lastPathComponent }.joined(separator: ", "))") }
                if let newest { lines.append("newest backup copy written \(Int(Date().timeIntervalSince(newest))) seconds ago") }
                
                // Restore uses its own lookup folder; report whether that folder exists in the backup.
                let restoreLooksIn = backup.appendingPathComponent("Save States").appendingPathComponent(shortSystem).appendingPathComponent(safeName)
                let restoreFolderExists = fm.fileExists(atPath: restoreLooksIn.path)
                lines.append("restore looks in: Save States/\(shortSystem)/\(safeName) -> \(restoreFolderExists ? "found" : "NOT FOUND in the backup")")
                
                guard missing.isEmpty, different.isEmpty, !local.isEmpty else {
                    lines.append("Restore not run: the backup does not match the local saves.")
                    DispatchQueue.main.async { self.backupAudit = lines; done() }
                    return
                }
                
                // Reading is all a play test does to your saves unless it was asked to restore (--audit-restore).
                if plan?.auditRestore != true {
                    DispatchQueue.main.async {
                        manager.checkForNewerBackup(systemIdentifier: self.systemIdentifier, gameName: self.gameName) { check in
                            lines.append("checkForNewerBackup: \(check)")
                            lines.append("Restore not run: it rewrites local saves (opt in with --audit-restore).")
                            self.backupAudit = lines; done()
                        }
                    }
                    return
                }
                // Keep a copy of the local saves, then restore and compare again.
                let snapshot = URL(fileURLWithPath: "/private/tmp/openemu-playtest-localsaves-\(Int(Date().timeIntervalSince1970))")
                try? fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
                for state in local { try? fm.copyItem(at: state, to: snapshot.appendingPathComponent(state.lastPathComponent)) }
                lines.append("copy of local saves kept at \(snapshot.path)")
                let before = Dictionary(uniqueKeysWithValues: local.map { ($0.lastPathComponent, digest(of: $0)) })
                
                DispatchQueue.main.async {
                    manager.checkForNewerBackup(systemIdentifier: self.systemIdentifier, gameName: self.gameName) { check in
                        lines.append("checkForNewerBackup: \(check)")
                        manager.restoreFromBackup(systemIdentifier: self.systemIdentifier, gameName: self.gameName) { success in
                            DispatchQueue.global(qos: .userInitiated).async {
                                let after = states(in: localDir)
                                let unchanged = after.allSatisfy { before[$0.lastPathComponent] == digest(of: $0) } && after.count == local.count
                                lines.append("restoreFromBackup: reported \(success ? "success" : "failure"); local saves afterwards \(unchanged ? "unchanged and intact" : "CHANGED")")
                                DispatchQueue.main.async { self.backupAudit = lines; done() }
                            }
                        }
                    }
                }
            }
        }
    }

    private var finished = false
    
    private func finish(status: String, message: String, exitImmediately: Bool = false) {
        guard !finished else { return }
        finished = true
        watchdog?.invalidate()
        stallTimer?.invalidate()
        let result = Result(status: status, message: message, game: gameName,
                            secondsPlayed: Date().timeIntervalSince(runStart),
                            keysSent: keysSent, shots: shots, backupAudit: backupAudit,
                            longestMainThreadStallMs: Int(longestStall * 1000))
        if let directory = plan?.outputDirectory ?? UserDefaults.standard.string(forKey: "OEPlaytestOutput") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(result) {
                try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("result.json"))
            }
        }
        os_log(.info, log: log, "Play test finished: %{public}@ (%{public}@)", status, message)
        if exitImmediately {
            // A blocking alert would also block a normal quit, so leave straight away.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { NSApp.terminate(nil) }
        }
    }

    // MARK: - Helpers

    /// HID keyboard usage for a key name, the same numbers the bindings files use.
    private static func hidUsage(forKey key: String) -> UInt? {
        let named: [String: UInt] = ["return": 40, "enter": 40, "escape": 41, "esc": 41, "space": 44,
                                     "right": 79, "left": 80, "down": 81, "up": 82,
                                     "lshift": 225, "rshift": 229]
        if let usage = named[key.lowercased()] { return usage }
        guard key.count == 1, let scalar = key.lowercased().unicodeScalars.first else { return nil }
        switch scalar.value {
        case 97...122: return UInt(scalar.value - 97 + 4)   // a-z
        case 49...57: return UInt(scalar.value - 49 + 30)   // 1-9
        case 48: return 39                                  // 0
        default: return nil
        }
    }

    /// 32x32 grayscale thumbnail, used to tell a blank picture from a real one and to see whether it changed.
    private static func fingerprint(of image: NSImage) -> [UInt8] {
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return pixels }
        context.interpolationQuality = .low
        context.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        return pixels
    }

    private static func isBlank(_ pixels: [UInt8]) -> Bool {
        guard let lo = pixels.min(), let hi = pixels.max() else { return true }
        return hi - lo < 12
    }

    private static func differs(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } > 200
    }
}
#endif
