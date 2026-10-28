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

import GameController

/// Asks macOS to leave the controller's Home / Guide button to big picture while the mode is open.
///
/// By default a press of that button opens the system Games overlay, which switches Spaces and takes focus away from
/// a running game. Setting `preferredSystemGestureState` to disabled is the request Apple documents for apps that
/// want the button themselves. It is a request, not a guarantee, so the Start + Select hold stays as another way to
/// reach the pause menu.
@MainActor
final class BigPictureSystemGestures {

    private var observer: NSObjectProtocol?

    /// Takes the Home button from the system for every controller now connected and any that connect later.
    func claim() {
        GCController.controllers().forEach { Self.setHome($0, claimed: true) }
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
            guard let controller = note.object as? GCController else { return }
            MainActor.assumeIsolated { Self.setHome(controller, claimed: true) }
        }
    }

    /// Gives the button back to the system.
    func release() {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        GCController.controllers().forEach { Self.setHome($0, claimed: false) }
    }

    private static func setHome(_ controller: GCController, claimed: Bool) {
        controller.extendedGamepad?.buttonHome?.preferredSystemGestureState = claimed ? .disabled : .enabled
    }
}
