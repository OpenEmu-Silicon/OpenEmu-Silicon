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

/// Values read from the big-picture designs (Sketch, built on the Apple tvOS UI kit).
///
/// Everything is expressed on the kit's 1920 × 1080 canvas. `BigPictureCanvas` scales that canvas to the screen,
/// so these numbers can be used exactly as the design gives them.
enum BP {

    // MARK: Canvas

    static let canvas = CGSize(width: 1920, height: 1080)
    /// Left and right margin of the tvOS safe area.
    static let margin: CGFloat = 80
    static let gutter: CGFloat = 40

    // MARK: Color

    static let background = Color(red: 0.039, green: 0.039, blue: 0.047)
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.6)
    static let tertiary = Color.white.opacity(0.4)
    /// tvOS focus: a light fill with dark text.
    static let focusFill = Color(white: 0.9)
    static let focusText = Color.black.opacity(0.85)
    static let idleFill = Color.white.opacity(0.1)
    static let material = Color(red: 0.11, green: 0.11, blue: 0.118)

    // MARK: Type (tvOS text styles at 1× on a 1080p canvas)

    static let title = Font.system(size: 62, weight: .bold)
    static let headline = Font.system(size: 38, weight: .semibold)
    static let callout = Font.system(size: 31, weight: .regular)
    static let calloutBold = Font.system(size: 31, weight: .semibold)
    static let caption = Font.system(size: 25, weight: .regular)
    static let captionBold = Font.system(size: 25, weight: .semibold)

    // MARK: Size

    static let tabBarHeight: CGFloat = 68
    static let buttonSize = CGSize(width: 384, height: 84)
    static let posterSize = CGSize(width: 260, height: 361)
    static let posterRadius: CGFloat = 12
    static let sidebarWidth: CGFloat = 420
    static let sidebarRowPitch: CGFloat = 78

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

/// Lays the 1920 × 1080 design canvas out at whatever size the screen is.
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
