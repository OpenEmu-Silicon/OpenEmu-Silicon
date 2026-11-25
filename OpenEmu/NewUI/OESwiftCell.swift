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

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if let image = model.image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: BP.posterRadius, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                        .overlay(overlay)
                } else {
                    RoundedRectangle(cornerRadius: BP.posterRadius, style: .continuous)
                        .fill(LinearGradient(colors: BP.systemColors(model.systemIdentifier), startPoint: .top, endPoint: .bottom))
                }
            }
            .padding(model.isSelected ? 0 : 3)
            .overlay(RoundedRectangle(cornerRadius: BP.posterRadius + 2, style: .continuous)
                .stroke(BP.focusRing, lineWidth: model.isSelected ? BP.focusLine : 0))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(model.title).font(BP.captionBold).foregroundColor(BP.primary).lineLimit(2)
            if model.rating > 0 {
                HStack(spacing: 1) { ForEach(0..<model.rating, id: \.self) { _ in Image(systemName: "star.fill").font(.system(size: 8)) } }
                    .foregroundColor(BP.secondary)
            }
        }
        .padding(6)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var overlay: some View {
        switch model.indication {
        case .none: EmptyView()
        case .fileMissing: Color.red.opacity(0.4)
        case .processing: ZStack { Color.black.opacity(0.7); ProgressView() }
        }
    }
}
