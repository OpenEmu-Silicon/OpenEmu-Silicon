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


import SwiftUI

/// The design tokens for the main app's SwiftUI views. System first: colors and type are the macOS semantic ones, so the
/// app follows the user's accent color, appearance and Dynamic Type-style sizing without extra code. Anything with
/// character (a retro frame, a CRT look, a console tint) is added on top of these and named separately, so the plain
/// version always still works. Big Picture keeps its own TV theme in `BP`.
///
/// See `docs/design-system.md`.
enum OEDesign {
    // MARK: Shape and space
    /// Corner radius of cover art in the grid. Fixed, so it does not change when the user zooms.
    static let artworkRadius: CGFloat = 6
    /// Width of the selection ring around art.
    static let selectionLine: CGFloat = 3
    static let cellPadding: CGFloat = 6
    static let titleSpacing: CGFloat = 6

    // MARK: Color (system semantic)
    /// The user's chosen accent color from System Settings.
    static var accent: Color { .accentColor }
    static var primaryText: Color { .primary }
    static var secondaryText: Color { .secondary }
    /// Text drawn on top of the accent color.
    static let onAccent = Color.white

    // MARK: Type (system)
    static let title = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 10)

    // MARK: Depth
    static let artworkShadow = (color: Color.black.opacity(0.3), radius: CGFloat(4), y: CGFloat(2))
}
