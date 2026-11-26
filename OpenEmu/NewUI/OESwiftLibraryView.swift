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
import OpenEmuKit

/// SPIKE. The library window in SwiftUI: a sidebar of systems, a search and sort bar, and a lazy grid or list of games.
/// Colors, sizes and artwork come from Big Picture (`BP`, `OEBigPictureArt`) so the two SwiftUI screens match.
struct OESwiftLibraryView: View {

    @ObservedObject var store: OESwiftLibraryStore
    @State private var selection: NSManagedObjectID?
    @State private var showsList = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(BP.border).frame(width: 0.5)
            VStack(spacing: 0) {
                header
                Rectangle().fill(BP.border).frame(height: 0.5)
                if showsList { list } else { grid }
            }
        }
        .background(BP.background)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Color.clear.frame(height: 44) // under the traffic lights
                row("All Games", count: store.totalCount, selected: store.scope == nil) { store.scope = nil }
                Text("CONSOLES").font(BP.captionBold).foregroundColor(BP.tertiary).padding(.top, 14).padding(.leading, 10).padding(.bottom, 4)
                ForEach(store.systems) { system in
                    row(system.name, count: system.count, selected: store.scope == system.id) { store.scope = system.id }
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(width: 220)
        .background(BP.material)
    }

    private func row(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(BP.callout).lineLimit(1)
                Spacer()
                Text("\(count)").font(BP.caption).foregroundColor(BP.tertiary)
            }
            .foregroundColor(selected ? BP.focusText : BP.primary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? BP.focusFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Text(store.scope.flatMap { id in store.systems.first { $0.id == id }?.name } ?? "All Games").font(BP.headline).foregroundColor(BP.primary)
            Text("\(store.games.count) games").font(BP.caption).foregroundColor(BP.secondary)
            Spacer()
            TextField("Search", text: $store.search)
                .textFieldStyle(.roundedBorder).frame(width: 200)
            Picker("", selection: $store.sort) {
                ForEach(OESwiftLibraryStore.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().frame(width: 150)
            Picker("", selection: $showsList) {
                Image(systemName: "square.grid.2x2").tag(false)
                Image(systemName: "list.bullet").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 80)
        }
        .padding(.horizontal, 20).padding(.top, 8).frame(height: 56)
    }

    // MARK: Grid and list

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 18)], spacing: 22) {
                ForEach(store.games, id: \.objectID) { game in
                    OESwiftGameCell(game: game, selected: selection == game.objectID)
                        .onTapGesture(count: 2) { store.onPlay?(game) }
                        .onTapGesture { selection = game.objectID }
                }
            }
            .padding(20)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.games, id: \.objectID) { game in
                    OESwiftGameRow(game: game, selected: selection == game.objectID)
                        .onTapGesture(count: 2) { store.onPlay?(game) }
                        .onTapGesture { selection = game.objectID }
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

/// One grid cell. The picture is Big Picture's rule: the provider poster if there is one, the library cover if not. A
/// cover that is still decoding shows the placeholder, and this cell (only this cell) redraws when its cover arrives.
struct OESwiftGameCell: View {
    let game: OEDBGame
    let selected: Bool
    @ObservedObject private var art = OEBigPictureArt.shared
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    OESwiftPlaceholder(game: game)
                }
            }
            .frame(maxWidth: .infinity).aspectRatio(0.72, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: BP.posterRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BP.posterRadius, style: .continuous).stroke(BP.focusRing, lineWidth: selected ? BP.focusLine : 0))
            Text(game.displayName).font(BP.captionBold).foregroundColor(BP.primary).lineLimit(2)
        }
        .onAppear { image = art.poster(for: game); if !OELibraryBench.isOn { art.load(OEBigPictureArt.GameKey(game)) } }
        .onReceive(NotificationCenter.default.publisher(for: .oeDBImageDidBecomeAvailable)) { note in
            guard image == nil, let id = note.userInfo?[OEDBImageObjectIDKey] as? NSManagedObjectID, id == game.boxImage?.objectID else { return }
            image = art.poster(for: game)
        }
        .onChange(of: art.tick) { _ in if image == nil || !art.hasStandardPoster(for: OEBigPictureArt.GameKey(game)) { image = art.poster(for: game) ?? image } }
    }
}

struct OESwiftPlaceholder: View {
    let game: OEDBGame
    var body: some View {
        ZStack {
            LinearGradient(colors: BP.systemColors(game.system?.systemIdentifier), startPoint: .top, endPoint: .bottom)
            Text(String(game.displayName.prefix(2)).uppercased()).font(.system(size: 34, weight: .heavy)).foregroundColor(BP.primary.opacity(0.85))
        }
    }
}

struct OESwiftGameRow: View {
    let game: OEDBGame
    let selected: Bool
    var body: some View {
        HStack {
            Text(game.displayName).font(BP.callout).foregroundColor(BP.primary).lineLimit(1)
            Spacer()
            Text(game.system?.name ?? "").font(BP.caption).foregroundColor(BP.secondary)
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? BP.focusFill : .clear))
        .contentShape(Rectangle())
    }
}
