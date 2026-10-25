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
        var blank: Bool
        var changedFromPrevious: Bool
    }

    private struct Result: Encodable {
        var status: String
        var message: String
        var game: String
        var secondsPlayed: Double
        var keysSent: [String]
        var shots: [Shot]
    }

    private var plan: Plan?
    private var started = false
    private var shots: [Shot] = []
    private var keysSent: [String] = []
    private var lastKey = "none"
    private var previousPrint: [UInt8]?
    private var gameName = ""
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
        openGame()
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
            (NSApp.delegate as! AppDelegate).mainWindowController.startGame(game)
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
                OEDeviceManager.shared.sendKeyboardKey(withUsage: usage, pressed: true)
                // Hold long enough for several frames; a tap shorter than a frame can be missed by the game.
                DispatchQueue.main.asyncAfter(deadline: .now() + (step.hold ?? 0.15)) {
                    OEDeviceManager.shared.sendKeyboardKey(withUsage: usage, pressed: false)
                }
            }
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

    private func takeShot(_ document: OEGameDocument) {
        guard let plan else { return }
        guard let image = document.screenshot() else { return }
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
        shots.append(Shot(file: name, secondsIn: seconds, lastKey: lastKey, blank: blank, changedFromPrevious: changed))
    }

    private func closeGame(_ document: OEGameDocument) {
        // The "continue your last game" and "are you sure you want to quit" alerts are suppressed by launch arguments
        // (see Scripts/playtest.sh), so this closes the game the way a player would, including the auto save state.
        document.stopEmulation(nil)
        waitForGameToClose(deadline: Date().addingTimeInterval(30))
    }

    private func waitForGameToClose(deadline: Date) {
        if currentDocument() == nil {
            finish(status: "ok", message: "Played and closed the game")
            return
        }
        if Date() > deadline {
            finish(status: "error", message: "The game did not close within 30 seconds")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.waitForGameToClose(deadline: deadline) }
    }

    private func finish(status: String, message: String) {
        let result = Result(status: status, message: message, game: gameName,
                            secondsPlayed: Date().timeIntervalSince(runStart),
                            keysSent: keysSent, shots: shots)
        if let directory = plan?.outputDirectory ?? UserDefaults.standard.string(forKey: "OEPlaytestOutput") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(result) {
                try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("result.json"))
            }
        }
        os_log(.info, log: log, "Play test finished: %{public}@ (%{public}@)", status, message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { NSApp.terminate(nil) }
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
