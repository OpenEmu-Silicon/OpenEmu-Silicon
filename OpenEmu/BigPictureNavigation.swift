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
import OpenEmuSystem

/// One vocabulary for moving around the big-picture UI. Controller, keyboard
/// and mouse are all translated into these, so the views never need to know
/// which device sent an input.
enum BigPictureAction: String {
    case up, down, left, right
    case select, back, menu
    case tabPrevious, tabNext
    /// The Guide / Home button, or Start + Select held together. Opens the pause menu over a running game.
    case home

    var isDirection: Bool {
        switch self {
        case .up, .down, .left, .right: return true
        default: return false
        }
    }
}

/// Turns `OEDeviceManager` controller events into `BigPictureAction`s.
///
/// Controllers are identified through the controller database, so a button is
/// recognised by its printed label ("A", "✕", "D-Pad Up"). A controller the
/// database doesn't know falls back to generic rules (hat switch, left stick,
/// button 1 = select, button 2 = back).
@MainActor
final class BigPictureInput {

    /// Called for every recognised action, including repeats of a held direction.
    var onAction: ((BigPictureAction, String) -> Void)?

    /// Asked before each controller event is handled. Return false and the event
    /// is left alone for the rest of the app (for example, a running game).
    var isActive: () -> Bool = { false }

    /// Called whenever the set of connected controllers may have changed.
    var onControllersChanged: (() -> Void)?

    // Pause chord: Start and Select held together for a moment, or Start held on its own a little longer, in case a
    // controller names its Select button something this does not recognise. Either one acts like the Home button.
    private var startDown = false
    private var selectDown = false
    private var chordTimer: Timer?
    private let chordHold: TimeInterval = 1.0
    private let startOnlyHold: TimeInterval = 2.0

    private var monitor: Any?
    private var deviceObservers = [NSObjectProtocol]()

    // Hold-to-repeat state. Several inputs can hold a direction at once (d-pad
    // and stick), so each input source has its own slot.
    private var held = [String: BigPictureAction]()
    private var repeating: BigPictureAction?
    private var repeatSource = ""
    private var repeatTimer: Timer?
    private let repeatDelay: TimeInterval = 0.40
    private let repeatInterval: TimeInterval = 0.09
    private let stickThreshold: CGFloat = 0.55

    func start() {
        guard monitor == nil else { return }

        monitor = OEDeviceManager.shared.addGlobalEventMonitorHandler { [weak self] handler, event in
            // Keyboards arrive here too; the window handles keyboard input itself.
            guard event.type != .keyboard, let self = self else { return true }

            // IOHIDManager is scheduled on the main run loop, so this is the main thread.
            return MainActor.assumeIsolated { self.handle(handler: handler, event: event) }
        }

        let center = NotificationCenter.default
        for name in [Notification.Name.OEDeviceManagerDidAddDeviceHandler, .OEDeviceManagerDidRemoveDeviceHandler] {
            deviceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onControllersChanged?() }
            })
        }
    }

    func stop() {
        chordTimer?.invalidate()
        chordTimer = nil
        startDown = false
        selectDown = false
        if let monitor = monitor {
            OEDeviceManager.shared.removeMonitor(monitor)
            self.monitor = nil
        }
        deviceObservers.forEach(NotificationCenter.default.removeObserver)
        deviceObservers.removeAll()
        releaseAll()
    }

    /// Stops any held direction, e.g. when the window loses focus.
    func releaseAll() {
        held.removeAll()
        stopRepeating()
    }

    var connectedControllerNames: [String] {
        OEDeviceManager.shared.controllerDeviceHandlers.map { $0.controllerDescription?.name ?? "Unknown controller" }
    }

    // MARK: - Event translation

    /// Returns true when the event should keep flowing to the rest of the app.
    private func handle(handler: OEDeviceHandler, event: OEHIDEvent) -> Bool {
        let controller = handler.controllerDescription?.name ?? "Controller"
        trackPauseChord(handler: handler, event: event, controller: controller)

        // The Guide button must work while a game has focus; everything else
        // only counts while the menu is the active window.
        let action = classify(handler: handler, event: event)

        if case .home? = action.press {
            onAction?(.home, controller)
            return false
        }

        guard isActive() else {
            releaseAll()
            return true
        }

        switch action {
        case .none:
            return true
        case .hold(let key, let direction):
            setHeld(key: key, direction: direction, source: controller)
            return false
        case .press(let pressed):
            onAction?(pressed, controller)
            return false
        }
    }

    private enum Classified {
        case none
        /// A direction that is held (d-pad, hat switch or stick). `nil` direction means released.
        case hold(key: String, direction: BigPictureAction?)
        /// A one-shot button press.
        case press(BigPictureAction)

        var press: BigPictureAction? {
            if case .press(let a) = self { return a }
            return nil
        }
    }

    /// Watches Start and Select (whatever the game is doing with them) and fires `.home` when they are held long enough.
    private func trackPauseChord(handler: OEDeviceHandler, event: OEHIDEvent, controller: String) {
        guard event.type == .button else { return }
        let name = controlName(handler: handler, event: event) ?? ""
        let isStart = ["Start", "Menu", "+", "Options"].contains(name)
        let isSelect = ["Select", "Back", "View", "Share", "Create", "-", "Minus"].contains(name)
        guard isStart || isSelect else { return }

        let down = event.state == .on
        if isStart { startDown = down } else { selectDown = down }

        chordTimer?.invalidate()
        chordTimer = nil
        guard startDown else { return }
        let delay = selectDown ? chordHold : startOnlyHold
        chordTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.startDown = false
                self.selectDown = false
                self.onAction?(.home, controller)
            }
        }
    }

    private func classify(handler: OEDeviceHandler, event: OEHIDEvent) -> Classified {
        switch event.type {
        case .hatSwitch:
            let d = event.hatDirection
            if d.contains(.north) { return .hold(key: "hat", direction: .up) }
            if d.contains(.south) { return .hold(key: "hat", direction: .down) }
            if d.contains(.west)  { return .hold(key: "hat", direction: .left) }
            if d.contains(.east)  { return .hold(key: "hat", direction: .right) }
            return .hold(key: "hat", direction: nil)

        case .axis:
            let name = controlName(handler: handler, event: event)?.lowercased() ?? ""
            // Only the left stick (or a lone d-pad axis) navigates.
            if name.contains("right") { return .none }

            let vertical: Bool
            switch event.axis {
            case .X: vertical = false
            case .Y: vertical = true
            default: return .none
            }

            let key = vertical ? "axisY" : "axisX"
            guard abs(event.value) >= stickThreshold, event.direction != .null else {
                return .hold(key: key, direction: nil)
            }
            if vertical {
                // Stick Y is negative when pushed up on most controllers.
                return .hold(key: key, direction: event.value < 0 ? .up : .down)
            }
            return .hold(key: key, direction: event.value < 0 ? .left : .right)

        case .button, .trigger:
            let name = controlName(handler: handler, event: event) ?? ""
            let isDown = event.type == .trigger ? event.value > 0.5 : event.state == .on

            if let direction = directionForButton(named: name) {
                return .hold(key: "btn-\(name)", direction: isDown ? direction : nil)
            }
            guard isDown else { return .none }

            if let action = actionForButton(named: name) { return .press(action) }

            // Controller not in the database: assume the first two face buttons.
            if handler.controllerDescription?.isGeneric ?? true {
                switch event.buttonNumber {
                case 1: return .press(.select)
                case 2: return .press(.back)
                default: break
                }
            }
            return .none

        default:
            return .none
        }
    }

    private func controlName(handler: OEDeviceHandler, event: OEHIDEvent) -> String? {
        handler.controllerDescription?.controlValueDescription(for: event).controlDescription?.name
    }

    private func directionForButton(named name: String) -> BigPictureAction? {
        switch name {
        case "D-Pad Up Button", "D-Pad Up": return .up
        case "D-Pad Down Button", "D-Pad Down": return .down
        case "D-Pad Left Button", "D-Pad Left": return .left
        case "D-Pad Right Button", "D-Pad Right": return .right
        default: return nil
        }
    }

    private func actionForButton(named name: String) -> BigPictureAction? {
        switch name {
        case "A", "✕", "1": return .select
        case "B", "◯", "2": return .back
        case "Start", "Menu", "+", "Options": return .menu
        case "L", "L1", "Left Shoulder", "ZL", "L2": return .tabPrevious
        case "R", "R1", "Right Shoulder", "ZR", "R2": return .tabNext
        case "Home", "Xbox", "Guide", "PS": return .home
        default:
            if name.hasPrefix("Home") || name.hasPrefix("Xbox") { return .home }
            return nil
        }
    }

    // MARK: - Hold to repeat

    private func setHeld(key: String, direction: BigPictureAction?, source: String) {
        let previous = held[key]
        if let direction = direction {
            guard previous != direction else { return }
            held[key] = direction
            fire(direction, source: source)
        } else {
            held[key] = nil
            // Keep repeating if something else is still holding the same direction.
            if let repeating = repeating, !held.values.contains(repeating) {
                stopRepeating()
            }
        }
    }

    private func fire(_ direction: BigPictureAction, source: String) {
        onAction?(direction, source)
        repeating = direction
        repeatSource = source
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: repeatDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginRepeating() }
        }
    }

    private func beginRepeating() {
        guard repeating != nil else { return }
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: repeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, let direction = self.repeating else { return }
                self.onAction?(direction, self.repeatSource)
            }
        }
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeating = nil
    }
}
