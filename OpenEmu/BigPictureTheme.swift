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

/// Values for the big-picture screens.
///
/// The design is the OpenEmu alternative UI at the size it was drawn: a 1280 × 720 canvas with its type, pills, cards
/// and gaps. `BigPictureCanvas` scales that canvas to the screen, so a laptop, a monitor and a 4K TV all get the same
/// layout, only larger. Change `canvas` to make everything bigger or smaller relative to the screen; nothing else moves.
enum BP {

    // MARK: Canvas

    static let canvas = CGSize(width: 1280, height: 720)
    /// Side margin. Keeps content inside the area a TV may crop.
    static let margin: CGFloat = 56
    /// Space between neighbouring cards in a shelf.
    static let gutter: CGFloat = 22

    // MARK: Color

    static let background = Color(hex: 0x0A0A0C)
    static let primary = Color(hex: 0xF5F5F7)
    static let secondary = Color(hex: 0xF5F5F7).opacity(0.6)
    static let tertiary = Color(hex: 0xF5F5F7).opacity(0.4)
    static let accent = Color(hex: 0x3B82F6)
    static let success = Color(hex: 0x22C55E)
    /// Soft surface and its hairline border, for pills, cards and groups.
    static let surface = Color.white.opacity(0.07)
    static let surfaceStrong = Color.white.opacity(0.14)
    static let border = Color.white.opacity(0.08)
    /// Panels that sit over the page (sidebar, save-state cards).
    static let material = Color(hex: 0x131318)
    /// Focus is the accent: a ring on art and buttons, a fill on small rows.
    static let focusRing = Color(hex: 0x3B82F6)
    static let focusFill = Color(hex: 0x3B82F6)
    static let focusText = Color.white

    // MARK: Type (AltUI sizes)

    static let display = Font.system(size: 44, weight: .heavy)
    static let title = Font.system(size: 32, weight: .bold)
    static let headline = Font.system(size: 20, weight: .bold)
    static let callout = Font.system(size: 14, weight: .regular)
    static let calloutBold = Font.system(size: 14, weight: .semibold)
    static let caption = Font.system(size: 12, weight: .regular)
    static let captionBold = Font.system(size: 12, weight: .semibold)

    // MARK: Spacing scale (use these, not loose numbers, so the rhythm stays consistent)

    static let space4: CGFloat = 4
    static let space8: CGFloat = 8
    static let space12: CGFloat = 12
    static let space16: CGFloat = 16
    static let space28: CGFloat = 28
    /// Between one shelf and the next.
    static let sectionGap: CGFloat = 40

    // MARK: Size

    static let tabBarHeight: CGFloat = 40
    static let buttonSize = CGSize(width: 150, height: 36)
    static let posterSize = CGSize(width: 140, height: 194)
    static let posterRadius: CGFloat = 5
    static let cardRadius: CGFloat = 8
    static let wideCard = CGSize(width: 260, height: 146)
    static let sidebarWidth: CGFloat = 260
    static let focusLine: CGFloat = 3

    /// Colors for a system's badge, taken from the home-screen designs.
    static func systemColors(_ identifier: String?) -> [Color] {
        func pair(_ a: UInt32, _ b: UInt32) -> [Color] { [Color(hex: a), Color(hex: b)] }
        switch identifier {
        case "openemu.system.nes", "openemu.system.fds": return pair(0xA01818, 0x7A1010)
        case "openemu.system.snes": return pair(0x5B3A99, 0x43297A)
        case "openemu.system.n64": return pair(0x1F6F3A, 0x155228)
        case "openemu.system.gba", "openemu.system.gb", "openemu.system.nds": return pair(0x3B2A8A, 0x2A1E6A)
        case "openemu.system.scd", "openemu.system.32x", "openemu.system.saturn", "openemu.system.dc":
            return pair(0x242426, 0x181818)
        case "openemu.system.psx", "openemu.system.ps2", "openemu.system.psp": return pair(0x151720, 0x0E1018)
        case "openemu.system.arcade": return pair(0x111111, 0x0A0A0A)
        default: return pair(0x2A2A30, 0x1A1A1F)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Lays the design canvas (BP.canvas) out at whatever size the screen is.
struct BigPictureCanvas<Content: View>: View {

    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        GeometryReader { geometry in
            // The window starts at zero size; a zero scale makes AppKit's scroll views assert.
            let scale = min(geometry.size.width / BP.canvas.width, geometry.size.height / BP.canvas.height)
            if scale > 0.05 {
                content
                    .frame(width: BP.canvas.width, height: BP.canvas.height)
                    .clipped()
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: BP.canvas.width * scale, height: BP.canvas.height * scale, alignment: .topLeading)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        .background(BP.background)
        .ignoresSafeArea()
    }
}
