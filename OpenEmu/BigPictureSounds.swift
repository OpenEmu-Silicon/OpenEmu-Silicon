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

import Cocoa

/// The short sound effects big picture plays as you move around it (see `BigPictureSounds/CREDITS.txt`).
///
/// Each cue is one WAV file in the app's `BigPictureSounds` folder. To change a sound, replace its file; to turn them
/// all off, run `defaults write org.openemu.OpenEmu OEBigPictureSoundsOff -bool YES`.
@MainActor
enum BigPictureSounds {

    enum Cue: String, CaseIterable {
        /// The highlight moved one step. Very short, because holding a direction repeats it about ten times a second.
        case move
        /// A button, card or menu entry was chosen.
        case select
        /// Went back a screen, or closed a menu.
        case back
        /// Switched tab with the shoulder buttons or by clicking a tab.
        case tab
        /// A game is starting.
        case launch
        /// The pause menu or the "Exit Big Picture?" dialog opened.
        case pause
        /// Resume Game, or staying in big picture, closed the dialog.
        case resume
        /// Quit Game, or leaving big picture.
        case quit
    }

    private static var sounds = [Cue: NSSound]()

    static var isEnabled: Bool { !UserDefaults.standard.bool(forKey: "OEBigPictureSoundsOff") }

    static func play(_ cue: Cue) {
        guard isEnabled else { return }
        guard let sound = sound(for: cue) else { return }
        // A sound that is still playing ignores play(), so a fast run of moves would go quiet without this.
        sound.stop()
        sound.play()
    }

    private static func sound(for cue: Cue) -> NSSound? {
        if let sound = sounds[cue] { return sound }
        guard let url = Bundle.main.url(forResource: cue.rawValue, withExtension: "wav", subdirectory: "BigPictureSounds"),
              let sound = NSSound(contentsOf: url, byReference: false) else {
            return nil
        }
        sounds[cue] = sound
        return sound
    }
}
