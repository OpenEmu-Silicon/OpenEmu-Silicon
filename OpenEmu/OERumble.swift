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


import Cocoa
import CoreHaptics
import GameController

/// The Preferences switch for controller rumble. On by default; controllers that cannot rumble ignore it either way.
enum OERumbleSettings {
    static let enabledKey = "OERumbleEnabled"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
    }
}

/// The plain rules for turning a core's rumble request into motor strengths, and for choosing which connected
/// controller a player's request goes to. No hardware is touched here, so it can be tested.
enum OERumbleMapping {

    /// A strength from a core, kept to 0 through 1. Not-a-number and infinity become 0 so a bad value never
    /// leaves a motor running.
    static func clamped(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    /// The two motor strengths to apply. Both are 0 when rumble is switched off.
    static func strengths(strong: Float, weak: Float, enabled: Bool) -> (strong: Float, weak: Float) {
        guard enabled else { return (0, 0) }
        return (clamped(strong), clamped(weak))
    }

    /// Picks which controller in `controllerNames` should rumble for a player (counting from 1).
    ///
    /// A controller whose name matches the player's input device wins. Otherwise, with only one controller
    /// connected it is used, and with several the one in the player's position is used. Returns nil when
    /// nothing fits, so a request never lands on the wrong pad by guessing past the end of the list.
    static func controllerIndex(forPlayer player: Int, deviceName: String?, controllerNames: [String?]) -> Int? {
        guard player >= 1, !controllerNames.isEmpty else { return nil }

        if let wanted = deviceName?.trimmingCharacters(in: .whitespaces).lowercased(), !wanted.isEmpty {
            let matches = controllerNames.indices.filter {
                controllerNames[$0]?.trimmingCharacters(in: .whitespaces).lowercased() == wanted
            }
            if matches.count == 1 { return matches[0] }
        }

        if controllerNames.count == 1 { return 0 }
        let position = player - 1
        return position < controllerNames.count ? position : nil
    }
}

/// Runs the left and right motors of controllers that the system's GameController framework can vibrate
/// (Xbox, DualShock 4, DualSense, Switch Pro on current macOS). Controllers without haptics are ignored.
@MainActor
final class OEControllerHaptics {

    static let shared = OEControllerHaptics()

    private final class Motor {
        let engine: CHHapticEngine
        var player: CHHapticAdvancedPatternPlayer?
        init(engine: CHHapticEngine) { self.engine = engine }
    }

    private struct Motors {
        var strong: Motor?
        var weak: Motor?
    }

    private var motors: [ObjectIdentifier: Motors] = [:]

    /// Sets both motors of the controller that belongs to a player. Zero strengths stop them.
    func rumble(player: Int, deviceName: String?, strong: Float, weak: Float) {
        let controllers = GCController.controllers().filter { $0.haptics != nil }
        let names = controllers.map { $0.vendorName }
        guard let index = OERumbleMapping.controllerIndex(forPlayer: player, deviceName: deviceName, controllerNames: names),
              let haptics = controllers[index].haptics
        else { return }

        let key = ObjectIdentifier(controllers[index])
        var entry = motors[key] ?? Motors()
        entry.strong = update(entry.strong, haptics: haptics, locality: .leftHandle, strength: strong)
        entry.weak = update(entry.weak, haptics: haptics, locality: .rightHandle, strength: weak)
        motors[key] = entry
    }

    /// Stops every motor this class started.
    func stopAll() {
        for entry in motors.values {
            for motor in [entry.strong, entry.weak] {
                try? motor?.player?.stop(atTime: CHHapticTimeImmediate)
                motor?.player = nil
            }
        }
    }

    private func update(_ existing: Motor?, haptics: GCDeviceHaptics, locality: GCHapticsLocality, strength: Float) -> Motor? {
        if strength <= 0 {
            try? existing?.player?.stop(atTime: CHHapticTimeImmediate)
            existing?.player = nil
            return existing
        }

        let motor: Motor
        if let existing {
            motor = existing
        } else {
            guard let engine = haptics.createEngine(withLocality: locality) else { return nil }
            let created = Motor(engine: engine)
            engine.resetHandler = { [weak created] in created?.player = nil }
            engine.stoppedHandler = { [weak created] _ in created?.player = nil }
            do { try engine.start() } catch { return nil }
            motor = created
        }

        do {
            if let player = motor.player {
                try player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: strength, relativeTime: 0)],
                                          atTime: CHHapticTimeImmediate)
            } else {
                // One long steady event; its strength is changed in place afterwards. The system caps it at 30
                // seconds, after which the next request starts a new one.
                let event = CHHapticEvent(eventType: .hapticContinuous,
                                          parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: strength),
                                                       CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)],
                                          relativeTime: 0, duration: 30)
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                let player = try motor.engine.makeAdvancedPlayer(with: pattern)
                player.completionHandler = { [weak motor] _ in
                    DispatchQueue.main.async { motor?.player = nil }
                }
                try player.start(atTime: CHHapticTimeImmediate)
                motor.player = player
            }
        } catch {
            motor.player = nil
        }
        return motor
    }
}
