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

/// SPIKE (middle route). With `-OESwiftUICells YES`, each cell of the AppKit games grid draws its picture, title, rating
/// and overlays in SwiftUI. The grid itself stays an NSCollectionView, so selection, drag and drop, menus, Quick Look and
/// type-to-select are the ones the app already has.
enum OESwiftCell {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "OESwiftUICells") }
}

final class OESwiftCellModel: ObservableObject {
    @Published var image: NSImage?
    @Published var title = ""
    @Published var rating = 0
    @Published var indication: GameIndication = .none
    @Published var isSelected = false
    @Published var systemIdentifier: String?
}

struct OESwiftCellContent: View {
    @ObservedObject var model: OESwiftCellModel

    private var artShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: OEDesign.artworkRadius, style: .continuous)
    }

    var body: some View {
        VStack(spacing: OEDesign.titleSpacing) {
            artwork
                // The inset is the same selected or not, so the art never changes size when it is selected.
                .padding(OEDesign.selectionLine + 1)
                .overlay(
                    RoundedRectangle(cornerRadius: OEDesign.artworkRadius + OEDesign.selectionLine, style: .continuous)
                        .strokeBorder(OEDesign.accent, lineWidth: OEDesign.selectionLine)
                        .opacity(model.isSelected ? 1 : 0))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            caption
        }
        .padding(OEDesign.cellPadding)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.title)
        .accessibilityValue(model.rating > 0 ? "\(model.rating) stars" : "")
    }

    @ViewBuilder private var artwork: some View {
        if let image = model.image {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                .clipShape(artShape)
                .shadow(color: OEDesign.artworkShadow.color, radius: OEDesign.artworkShadow.radius, y: OEDesign.artworkShadow.y)
                .overlay(indicationOverlay.clipShape(artShape))
        } else {
            artShape.fill(LinearGradient(colors: BP.systemColors(model.systemIdentifier), startPoint: .top, endPoint: .bottom))
        }
    }

    /// Like Finder's icon view: the name sits on an accent capsule while the item is selected.
    private var caption: some View {
        VStack(spacing: 2) {
            Text(model.title)
                .font(OEDesign.title)
                .foregroundColor(model.isSelected ? OEDesign.onAccent : OEDesign.primaryText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(OEDesign.accent).opacity(model.isSelected ? 1 : 0))
            if model.rating > 0 {
                HStack(spacing: 1) {
                    ForEach(0..<model.rating, id: \.self) { _ in Image(systemName: "star.fill").font(.system(size: 8)) }
                }
                .foregroundColor(OEDesign.secondaryText)
            }
        }
    }

    @ViewBuilder private var indicationOverlay: some View {
        switch model.indication {
        case .none: EmptyView()
        case .fileMissing: Color.red.opacity(0.4)
        case .processing: ZStack { Color.black.opacity(0.7); ProgressView() }
        }
    }
}
