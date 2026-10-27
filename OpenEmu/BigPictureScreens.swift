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

// MARK: - Root

struct BigPictureView: View {

    @ObservedObject var model: BigPictureModel
    @ObservedObject private var art = OEBigPictureArt.shared

    var body: some View {
        BigPictureCanvas {
            ZStack(alignment: .topLeading) {
                BP.background

                switch model.screen {
                case .settings:
                    BPSettingsPage(model: model)
                default:
                    BPPage(model: model, art: art)
                }

                BPTabBar(model: model)

                if model.sidebarOpen {
                    BPSidebar(model: model)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: model.sidebarOpen)
        }
        .edgesIgnoringSafeArea(.all)
    }
}

// MARK: - Helpers

private extension OEDBGame {

    var systemName: String { system?.name ?? "" }

    var playedSummary: String {
        var parts = [String]()
        let hours = playTime / 3600
        if hours >= 1 { parts.append(String(format: "%.0f hrs", hours)) }
        else if playTime >= 60 { parts.append(String(format: "%.0f min", playTime / 60)) }
        if let lastPlayed = lastPlayed {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            parts.append(formatter.localizedString(for: lastPlayed, relativeTo: Date()))
        }
        return parts.joined(separator: "  ·  ")
    }
}

/// Library cover art first, then SteamGridDB, on a blurred copy of itself so a cover is never cropped.
private struct BPPoster: View {

    let game: OEDBGame
    let size: CGSize
    let coverTick: Int
    @ObservedObject var art: OEBigPictureArt

    var body: some View {
        let key = OEBigPictureArt.GameKey(game)
        let image = art.grid(for: key) ?? game.boxImage?.image
        ZStack {
            if let image = image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).blur(radius: 24).opacity(0.7)
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                LinearGradient(colors: BP.systemColors(game.system?.systemIdentifier), startPoint: .top, endPoint: .bottom)
                Text(game.cleanDisplayName)
                    .font(BP.calloutBold)
                    .foregroundColor(BP.primary)
                    .multilineTextAlignment(.center)
                    .padding(10)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: BP.posterRadius, style: .continuous))
        .onAppear { art.load(key) }
        .id("\(game.objectID)-\(coverTick)")
    }
}

/// A small outlined tag, like the rating and format chips on Apple TV.
private struct BPChip: View {

    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold)).tracking(0.5)
            .foregroundColor(BP.secondary)
            .padding(.horizontal, 6).frame(height: 18)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(BP.secondary, lineWidth: 1))
    }
}

private struct BPButton: View {

    let title: String
    let symbol: String
    let isPrimary: Bool
    let focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
            Text(title).font(BP.calloutBold)
        }
        .foregroundColor(isPrimary ? Color.black.opacity(0.9) : BP.primary)
        .frame(width: BP.buttonSize.width, height: BP.buttonSize.height)
        .background(Capsule().fill(isPrimary ? Color.white : BP.surfaceStrong))
        .overlay(Capsule().strokeBorder(BP.focusRing, lineWidth: focused ? BP.focusLine : 0).padding(-4))
        .scaleEffect(focused ? 1.05 : 1)
        .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 12, y: 6)
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

// MARK: - Tab bar

private struct BPTabBar: View {

    @ObservedObject var model: BigPictureModel

    var body: some View {
        HStack(spacing: 10) {
            let sidebarFocused = model.isTabBarFocused && model.tabBarIndex == 0
            Image(systemName: "sidebar.left")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(sidebarFocused ? BP.focusText : BP.primary)
                .frame(width: BP.tabBarHeight, height: BP.tabBarHeight)
                .background(Circle().fill(sidebarFocused ? BP.focusFill : BP.surface))
                .overlay(Circle().strokeBorder(BP.border, lineWidth: sidebarFocused ? 0 : 1))
                .onTapGesture { model.clickTab(0) }

            HStack(spacing: 0) {
                ForEach(BigPictureTab.allCases, id: \.rawValue) { tab in
                    let focused = model.isTabBarFocused && model.tabBarIndex == tab.rawValue + 1
                    let current = model.screen == .browse && model.tab == tab
                    Text(tab.title)
                        .font(BP.calloutBold)
                        .foregroundColor(focused ? BP.focusText : BP.primary)
                        .padding(.horizontal, 16)
                        .frame(height: BP.tabBarHeight - 6)
                        .background(Capsule().fill(focused ? BP.focusFill : (current ? BP.surfaceStrong : Color.clear)))
                        .onTapGesture { model.clickTab(tab.rawValue + 1) }
                }
            }
            .padding(3)
            .background(Capsule().fill(BP.surface))
            .overlay(Capsule().strokeBorder(BP.border, lineWidth: 1))
        }
        .frame(width: BP.canvas.width)
        .offset(y: 28)
        .animation(.easeOut(duration: 0.12), value: model.tabBarIndex)
    }
}

// MARK: - Page (hero + shelves)

/// Heights are fixed so the page can be positioned from the highlight alone. SwiftUI's scroll views are avoided on
/// purpose: inside the scaled design canvas they mis-position their content.
private enum BPMetrics {
    /// Top of the page content, just under the tab bar.
    static let top: CGFloat = 92
    /// The hero block: art, cover, title, buttons, plus the air below it before the first shelf.
    static let heroHeight: CGFloat = 508
    static let headerHeight: CGFloat = 56
    static let posterBody: CGFloat = 262
    static let stateBody: CGFloat = 228
    static let iconBody: CGFloat = 176
    static let featuredBody: CGFloat = 372
    static let laneGap: CGFloat = BP.sectionGap
    /// Where a shelf's top sits on screen when it has the highlight.
    static let focusTarget: CGFloat = 84

    static func height(of lane: BigPictureLane) -> CGFloat {
        let header = lane.title == nil ? 0 : headerHeight
        switch lane.kind {
        case .heroActions: return 0
        case .games:
            switch lane.style {
            case .icons: return header + iconBody + laneGap
            case .featured: return header + featuredBody + laneGap
            default: return header + posterBody + laneGap
            }
        case .saveStates, .screenshots: return header + stateBody + laneGap
        }
    }
}

private struct BPPage: View {

    @ObservedObject var model: BigPictureModel
    @ObservedObject var art: OEBigPictureArt

    private var showsHero: Bool {
        if case .detail = model.screen { return true }
        return model.tab == .home && model.heroGame != nil
    }

    private var laneTops: [CGFloat] {
        var y = BPMetrics.top + (showsHero ? BPMetrics.heroHeight : 0)
        return model.lanes.map { lane in
            defer { y += BPMetrics.height(of: lane) }
            return y
        }
    }

    private var pageOffset: CGFloat {
        if model.detailScrolled, let lastTop = laneTops.last, let last = model.lanes.last {
            return -max(0, lastTop + BPMetrics.height(of: last) - BPMetrics.focusTarget)
        }
        guard model.lane >= 0, model.lanes.indices.contains(model.lane) else { return 0 }
        if case .heroActions = model.lanes[model.lane].kind { return 0 }
        return -max(0, laneTops[model.lane] - BPMetrics.focusTarget)
    }

    var body: some View {
        let tops = laneTops
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                if showsHero, let game = model.heroGame {
                    BPBackdrop(game: game, art: art)
                }

                if showsHero, let game = model.heroGame {
                    BPHero(model: model, game: game, art: art)
                        .frame(width: BP.canvas.width, height: BPMetrics.heroHeight, alignment: .topLeading)
                        .offset(y: BPMetrics.top)
                }

                ForEach(Array(model.lanes.enumerated()), id: \.element.id) { index, lane in
                    if case .heroActions = lane.kind {
                        EmptyView()
                    } else {
                        BPLane(model: model, art: art, lane: lane, index: index)
                            .frame(width: BP.canvas.width, height: BPMetrics.height(of: lane), alignment: .topLeading)
                            .offset(y: tops[index])
                    }
                }

                if case .detail(let game) = model.screen, let last = model.lanes.last, let lastTop = tops.last {
                    BPDetailSections(game: game, art: art)
                        .offset(y: lastTop + BPMetrics.height(of: last))
                }

                if model.lanes.isEmpty || model.tab == .saveStates || model.tab == .search {
                    BPEmpty(model: model).offset(y: BPMetrics.top)
                }
            }
            .frame(width: BP.canvas.width, height: BP.canvas.height, alignment: .topLeading)
            .offset(y: pageOffset)
            .animation(.easeOut(duration: 0.22), value: pageOffset)
            .bpFadeUnderTabBar()
        }
        .frame(width: BP.canvas.width, height: BP.canvas.height, alignment: .topLeading)
        .clipped()
    }
}

/// Content fades out under the tab bar instead of running through it.
private extension View {
    func bpFadeUnderTabBar() -> some View {
        mask(LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .clear, location: 64 / BP.canvas.height),
            .init(color: .black, location: 100 / BP.canvas.height),
            .init(color: .black, location: 1),
        ], startPoint: .top, endPoint: .bottom))
    }
}

private struct BPEmpty: View {

    @ObservedObject var model: BigPictureModel

    var body: some View {
        let message: String
        switch model.tab {
        case .saveStates: message = "No save states yet."
        case .search: message = "Search is not available yet."
        case .favorites: message = "Rate a game 4 stars or more to see it here."
        default: message = "No games in the library yet."
        }
        return Text(message)
            .font(BP.callout)
            .foregroundColor(BP.secondary)
            .padding(.horizontal, BP.margin)
            .padding(.top, 24)
    }
}

/// The hero's art. It belongs to the page, so it scrolls away with the hero like the AltUI home does.
private struct BPBackdrop: View {

    let game: OEDBGame
    @ObservedObject var art: OEBigPictureArt

    private var height: CGFloat { BPMetrics.top + BPMetrics.heroHeight }

    var body: some View {
        ZStack {
            let key = OEBigPictureArt.GameKey(game)
            if let hero = art.hero(for: key) {
                Image(nsImage: hero).resizable().aspectRatio(contentMode: .fill).opacity(0.6)
            } else if let cover = game.boxImage?.image {
                Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill).blur(radius: 40).opacity(0.35)
            } else {
                LinearGradient(colors: BP.systemColors(game.system?.systemIdentifier), startPoint: .topTrailing, endPoint: .bottomLeading).opacity(0.45)
            }
            // Dim under the tab bar, a soft pool behind the text, and a fade into the page below.
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 90).frame(maxHeight: .infinity, alignment: .top)
            LinearGradient(colors: [BP.background.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, BP.background], startPoint: .top, endPoint: .bottom)
                .frame(height: 170).frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(width: BP.canvas.width, height: height)
        .clipped()
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.3), value: art.tick)
    }
}

// MARK: - Hero

private struct BPHero: View {

    @ObservedObject var model: BigPictureModel
    let game: OEDBGame
    @ObservedObject var art: OEBigPictureArt

    var body: some View {
        let key = OEBigPictureArt.GameKey(game)
        let details = art.details(for: key)
        let actionsFocused = model.lane == 0 && !model.sidebarOpen && model.lanes.first.map { if case .heroActions = $0.kind { return true } else { return false } } == true

        ZStack(alignment: .topLeading) {
            heroCover
                .offset(x: BP.margin, y: 98)

            Text(eyebrow)
                .font(.system(size: 10.5, weight: .bold)).tracking(1.2).foregroundColor(BP.primary)
                .padding(.horizontal, 12).frame(height: 24)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.55), lineWidth: 1))
                .offset(x: heroTextX, y: 100)

            Text(game.cleanDisplayName)
                .font(BP.display).tracking(-0.5).foregroundColor(BP.primary)
                .lineLimit(1).minimumScaleFactor(0.65).frame(width: 800, alignment: .leading)
                .offset(x: heroTextX, y: 132)

            metaRow(details: details).offset(x: heroTextX, y: 200)

            Text(details?.summary ?? game.gameDescription ?? "")
                .font(BP.callout).foregroundColor(BP.secondary)
                .lineLimit(2).frame(width: 640, alignment: .topLeading)
                .offset(x: heroTextX, y: 230)

            HStack(spacing: 10) {
                BPButton(title: "Resume", symbol: "play.fill", isPrimary: true, focused: actionsFocused && model.column == 0)
                    .onTapGesture { model.click(lane: 0, column: 0) }
                BPButton(title: "Save States", symbol: "square.and.arrow.down", isPrimary: false, focused: actionsFocused && model.column == 1)
                    .onTapGesture { model.click(lane: 0, column: 1) }
            }
            .offset(x: heroTextX, y: 282)
        }
        .onAppear { art.load(key) }
    }

    /// Text starts after the cover and its gap.
    private var heroTextX: CGFloat { BP.margin + coverWidth + 28 }

    private var eyebrow: String {
        let place: String
        if case .detail = model.screen { place = game.systemName } else { place = "Recently played" }
        return place.uppercased()
    }

    /// Box art at its own shape (a SNES box is wide, a poster tall), like the AltUI hero; the shelf poster if there is none.
    private var coverImage: NSImage? { game.boxImage?.image }

    private var coverWidth: CGFloat {
        guard let image = coverImage, image.size.height > 0 else { return 150 }
        return min(max(220 * image.size.width / image.size.height, 130), 320)
    }

    @ViewBuilder private var heroCover: some View {
        if let image = coverImage {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                .frame(width: coverWidth, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: BP.posterRadius, style: .continuous))
                .shadow(color: .black.opacity(0.65), radius: 16, y: 8)
        } else {
            BPPoster(game: game, size: CGSize(width: 150, height: 220), coverTick: model.coverTick, art: art)
                .shadow(color: .black.opacity(0.55), radius: 16, y: 8)
        }
    }

    /// Platform and genres, a year chip, rating, time played, and a saves chip: the Apple TV metadata line.
    private func metaRow(details: OEBigPictureArt.Details?) -> some View {
        HStack(spacing: 10) {
            let facts = ([game.systemName] + (details?.genres.prefix(2).map { $0 } ?? [])).filter { !$0.isEmpty }
            Text(facts.joined(separator: " · ")).font(BP.calloutBold).foregroundColor(BP.primary)
            if let year = details?.releaseDate.map({ String($0.suffix(4)) }), !year.isEmpty { BPChip(text: year) }
            if let stars = game.rating?.intValue, stars > 0 {
                Text(String(repeating: "★", count: min(stars, 5)) + String(repeating: "☆", count: max(5 - stars, 0)))
                    .font(BP.callout).foregroundColor(Color(hex: 0xF5A524))
            }
            let played = game.playedSummary
            if !played.isEmpty { Text(played).font(BP.callout).foregroundColor(BP.secondary) }
            let saves = game.defaultROM?.normalSaveStates.count ?? 0
            if saves > 0 { BPChip(text: saves == 1 ? "1 SAVE" : "\(saves) SAVES") }
        }
        .lineLimit(1)
    }
}

// MARK: - Shelves

private extension BigPictureLane {
    enum Style { case icons, poster, featured, wide }

    /// How a shelf draws its items: icon tiles for what you just played, large cards for favorites, else posters.
    var style: Style {
        switch kind {
        case .saveStates, .screenshots: return .wide
        default: return id == "recent" ? .icons : (id == "most-played" ? .featured : .poster)
        }
    }

    var itemWidth: CGFloat {
        switch style {
        case .icons: return BP.iconSize
        case .poster: return BP.posterSize.width
        case .featured: return BP.featuredSize.width
        case .wide: return BP.wideCard.width
        }
    }

    var itemGap: CGFloat { style == .icons ? 18 : (style == .featured ? 14 : BP.gutter) }

    /// Columns that fit on screen before the shelf starts to slide.
    var visibleColumns: Int {
        switch style {
        case .icons: return 8
        case .poster: return 6
        case .featured: return 5
        case .wide: return 4
        }
    }

    var isWide: Bool {
        switch kind {
        case .saveStates, .screenshots: return true
        default: return false
        }
    }
}

private struct BPLane: View {

    @ObservedObject var model: BigPictureModel
    @ObservedObject var art: OEBigPictureArt
    let lane: BigPictureLane
    let index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = lane.title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(BP.headline).foregroundColor(BP.primary)
                    if let subtitle = lane.subtitle {
                        Text(subtitle).font(BP.callout).foregroundColor(BP.secondary)
                    }
                }
                .padding(.horizontal, BP.margin)
                .frame(height: BPMetrics.headerHeight, alignment: .bottomLeading)
            }

            let step = lane.itemWidth + lane.itemGap
            let shift = model.lane == index ? -CGFloat(max(0, model.column - (lane.visibleColumns - 1))) * step : 0
            HStack(alignment: .top, spacing: lane.itemGap) {
                switch lane.kind {
                case .games(let games):
                    ForEach(Array(games.enumerated()), id: \.offset) { column, game in
                        switch lane.style {
                        case .icons: iconTile(game, column: column)
                        case .featured: featuredCard(game, column: column)
                        default: poster(game, column: column)
                        }
                    }
                case .saveStates(let states):
                    ForEach(Array(states.enumerated()), id: \.offset) { column, state in
                        stateCard(state, column: column)
                    }
                case .screenshots(let shots):
                    ForEach(Array(shots.enumerated()), id: \.offset) { column, shot in
                        screenshotCard(shot, column: column)
                    }
                case .heroActions:
                    EmptyView()
                }
            }
            .padding(.leading, BP.margin)
            .padding(.top, BP.space12)
            .offset(x: shift)
            .animation(.easeOut(duration: 0.2), value: shift)
        }
    }

    private func isNew(_ game: OEDBGame) -> Bool {
        guard let date = game.importDate else { return false }
        return date > Date().addingTimeInterval(-14 * 24 * 3600)
    }

    /// The small line under a poster's title: when it was played, how long, or its system, depending on the shelf.
    private func secondaryLine(for game: OEDBGame) -> String? {
        switch lane.id {
        case "recent":
            return game.lastPlayed.map { Self.ago.localizedString(for: $0, relativeTo: Date()) }
        case "most-played":
            let hours = Int(game.playTime / 3600), minutes = Int(game.playTime.truncatingRemainder(dividingBy: 3600) / 60)
            let played = hours > 0 ? "\(hours) hrs played" : (minutes > 0 ? "\(minutes)m played" : nil)
            return [game.system?.name, played].compactMap { $0 }.joined(separator: " · ")
        case "added":
            return game.system?.name
        default:
            return nil
        }
    }

    private static let ago: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private func screenshotCard(_ shot: OEDBScreenshot, column: Int) -> some View {
        let focused = isFocused(column)
        let image = NSImage(contentsOf: shot.url)
        return ZStack {
            Color.white.opacity(0.06)
            if let image = image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
        }
        .frame(width: BP.wideCard.width, height: BP.wideCard.height).clipped()
        .clipShape(RoundedRectangle(cornerRadius: BP.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BP.cardRadius, style: .continuous).strokeBorder(focused ? BP.focusRing : BP.border, lineWidth: focused ? BP.focusLine : 1))
        .scaleEffect(focused ? 1.04 : 1, anchor: .top)
        .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 14, y: 8)
        .animation(.easeOut(duration: 0.12), value: focused)
        .onHover { inside in if inside { model.hover(lane: index, column: column) } }
        .onTapGesture { model.click(lane: index, column: column) }
    }

    private func isFocused(_ column: Int) -> Bool {
        !model.sidebarOpen && model.lane == index && model.column == column
    }

    /// A rounded game icon with its name and when it was played: quick access to what you just played.
    private func iconTile(_ game: OEDBGame, column: Int) -> some View {
        let focused = isFocused(column)
        let key = OEBigPictureArt.GameKey(game)
        let image = art.icon(for: key) ?? art.grid(for: key) ?? game.boxImage?.image
        return VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let image = image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: BP.systemColors(game.system?.systemIdentifier), startPoint: .top, endPoint: .bottom)
                }
            }
            .frame(width: BP.iconSize, height: BP.iconSize).clipped()
            .clipShape(RoundedRectangle(cornerRadius: BP.iconRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BP.iconRadius, style: .continuous)
                .strokeBorder(BP.focusRing, lineWidth: focused ? BP.focusLine : 0).padding(-3))
            .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
            Text(game.cleanDisplayName).font(BP.captionBold).foregroundColor(BP.primary)
                .lineLimit(2).frame(width: BP.iconSize, alignment: .leading)
            if let played = game.lastPlayed {
                Text(Self.ago.localizedString(for: played, relativeTo: Date()))
                    .font(.system(size: 11)).foregroundColor(BP.tertiary).lineLimit(1)
            }
        }
        .scaleEffect(focused ? 1.06 : 1, anchor: .top)
        .animation(.easeOut(duration: 0.12), value: focused)
        .onAppear { art.load(key) }
        .onHover { inside in if inside { model.hover(lane: index, column: column) } }
        .onTapGesture { model.click(lane: index, column: column) }
    }

    /// A large poster with an info bar under it, like the AltUI Most Played cards.
    private func featuredCard(_ game: OEDBGame, column: Int) -> some View {
        let focused = isFocused(column)
        return VStack(spacing: 0) {
            BPPoster(game: game, size: BP.featuredSize, coverTick: model.coverTick, art: art)
                .clipShape(Rectangle())
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.cleanDisplayName).font(BP.calloutBold).foregroundColor(BP.primary).lineLimit(1)
                    Text(secondaryLine(for: game) ?? "").font(.system(size: 11)).foregroundColor(BP.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("Play").font(.system(size: 11, weight: .semibold)).foregroundColor(BP.primary)
                    .padding(.horizontal, 10).frame(height: 22)
                    .background(Capsule().fill(BP.surfaceStrong))
            }
            .padding(.horizontal, 10)
            .frame(width: BP.featuredSize.width, height: BP.featuredInfoHeight)
            .background(BP.material)
        }
        .clipShape(RoundedRectangle(cornerRadius: BP.cardRadius + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BP.cardRadius + 2, style: .continuous)
            .strokeBorder(focused ? BP.focusRing : BP.border, lineWidth: focused ? BP.focusLine : 1))
        .scaleEffect(focused ? 1.04 : 1, anchor: .top)
        .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 14, y: 8)
        .animation(.easeOut(duration: 0.12), value: focused)
        .onHover { inside in if inside { model.hover(lane: index, column: column) } }
        .onTapGesture { model.click(lane: index, column: column) }
    }

    private func poster(_ game: OEDBGame, column: Int) -> some View {
        let focused = isFocused(column)
        return VStack(alignment: .leading, spacing: BP.space8) {
            BPPoster(game: game, size: BP.posterSize, coverTick: model.coverTick, art: art)
                .overlay(alignment: .topLeading) {
                    if lane.id == "added", isNew(game) {
                        Text("NEW").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Capsule().fill(BP.accent)).padding(6)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(game.cleanDisplayName)
                    .font(BP.captionBold).foregroundColor(BP.primary)
                    .lineLimit(1)
                if let line = secondaryLine(for: game) {
                    Text(line).font(BP.caption).foregroundColor(BP.tertiary).lineLimit(1)
                }
            }
            .frame(width: BP.posterSize.width, alignment: .leading)
            .opacity(focused ? 1 : 0.8)
        }
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: BP.posterRadius + 3, style: .continuous)
                .strokeBorder(BP.focusRing, lineWidth: focused ? BP.focusLine : 0)
                .frame(width: BP.posterSize.width + 8, height: BP.posterSize.height + 8)
                .offset(y: -4)
        }
        .scaleEffect(focused ? 1.06 : 1, anchor: .top)
        .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 14, y: 8)
        .animation(.easeOut(duration: 0.12), value: focused)
        .onHover { inside in if inside { model.hover(lane: index, column: column) } }
        .onTapGesture { model.click(lane: index, column: column) }
    }

    private func stateCard(_ state: OEDBSaveState, column: Int) -> some View {
        let focused = isFocused(column)
        let image = NSImage(contentsOf: state.screenshotURL)
        let title = lane.showsGame ? (state.rom?.game?.cleanDisplayName ?? state.displayName) : state.displayName
        let detail = [lane.showsGame ? state.displayName : nil, state.timestamp.map { $0.formatted(.dateTime.month().day().hour().minute()) }]
            .compactMap { $0 }.joined(separator: "  ·  ")
        return VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.white.opacity(0.06)
                if let image = image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            }
            .frame(width: BP.wideCard.width, height: BP.wideCard.height).clipped()
            HStack(spacing: 10) {
                if let cover = state.rom?.game?.boxImage?.image {
                    Image(nsImage: cover).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 30, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(BP.calloutBold).foregroundColor(BP.primary).lineLimit(1)
                    Text(detail).font(BP.caption).foregroundColor(BP.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(width: BP.wideCard.width, height: 62, alignment: .leading)
        }
        .background(BP.material)
        .clipShape(RoundedRectangle(cornerRadius: BP.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BP.cardRadius, style: .continuous).strokeBorder(focused ? BP.focusRing : BP.border, lineWidth: focused ? BP.focusLine : 1))
        .frame(width: BP.wideCard.width, alignment: .leading)
        .scaleEffect(focused ? 1.04 : 1, anchor: .top)
        .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 14, y: 8)
        .animation(.easeOut(duration: 0.12), value: focused)
        .onHover { inside in if inside { model.hover(lane: index, column: column) } }
        .onTapGesture { model.click(lane: index, column: column) }
    }
}

// MARK: - Detail sections

private struct BPDetailSections: View {

    let game: OEDBGame
    @ObservedObject var art: OEBigPictureArt

    private var ago: RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }

    var body: some View {
        let details = art.details(for: OEBigPictureArt.GameKey(game))
        let saves = game.defaultROM?.normalSaveStates.count ?? 0
        VStack(alignment: .leading, spacing: BP.space16) {
            Text("About").font(BP.headline).foregroundColor(BP.primary)

            HStack(alignment: .top, spacing: BP.space16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.cleanDisplayName).font(.system(size: 18, weight: .bold)).foregroundColor(BP.primary)
                    Text(([game.systemName] + (details?.genres ?? [])).filter { !$0.isEmpty }.joined(separator: ", ").uppercased())
                        .font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundColor(BP.secondary)
                    Text(details?.summary ?? game.gameDescription ?? "No description yet.")
                        .font(BP.callout).foregroundColor(BP.secondary).lineSpacing(3).lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                }
                .padding(BP.space16)
                .frame(width: 600, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(BP.material))

                VStack(alignment: .leading, spacing: 4) {
                    Text(game.playTime >= 3600 ? String(format: "%.0f hrs", game.playTime / 3600) : String(format: "%.0f min", game.playTime / 60))
                        .font(.system(size: 18, weight: .bold)).foregroundColor(BP.primary)
                    Text("TIME PLAYED").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundColor(BP.secondary)
                    Text(game.lastPlayed.map { "Last played " + ago.localizedString(for: $0, relativeTo: Date()) } ?? "Not played yet")
                        .font(BP.callout).foregroundColor(BP.secondary).padding(.top, 6)
                    if saves > 0 { Text(saves == 1 ? "1 save state" : "\(saves) save states").font(BP.callout).foregroundColor(BP.secondary) }
                }
                .padding(BP.space16)
                .frame(width: 260, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(BP.material))
            }

            HStack(alignment: .top, spacing: 60) {
                column("Information", [
                    ("Released", details?.releaseDate),
                    ("Developer", details?.developer),
                    ("Publisher", details?.publisher),
                    ("Genre", details.map { $0.genres.joined(separator: ", ") }),
                ])
                column("Library", [
                    ("Platform", game.systemName),
                    ("Added", game.importDate?.formatted(date: .long, time: .omitted)),
                    ("Rating", game.rating.flatMap { $0.intValue > 0 ? "\($0.intValue) of 5" : nil }),
                    ("File", game.defaultROM?.fileName),
                ])
            }
            .padding(.top, BP.space16)
        }
        .padding(.horizontal, BP.margin)
        .padding(.top, BP.space8)
    }

    private func column(_ title: String, _ rows: [(String, String?)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 16, weight: .bold)).foregroundColor(BP.primary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if let value = row.1, !value.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0).font(BP.captionBold).foregroundColor(BP.primary)
                        Text(value).font(BP.caption).foregroundColor(BP.secondary).lineLimit(2)
                    }
                }
            }
        }
        .frame(width: 280, alignment: .topLeading)
    }
}

// MARK: - Sidebar

private struct BPSidebar: View {

    @ObservedObject var model: BigPictureModel

    private func symbol(_ entry: BigPictureModel.SidebarEntry) -> String {
        switch entry {
        case .tab(.home): return "house"
        case .tab(.recent): return "clock"
        case .tab(.favorites): return "heart"
        case .settings: return "slider.horizontal.3"
        default: return "circle"
        }
    }

    private func title(_ entry: BigPictureModel.SidebarEntry) -> String {
        switch entry {
        case .tab(let tab): return tab.title
        case .settings: return "Settings"
        case .system(let id): return model.systems.first { $0.id == id }?.name ?? id
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.35).onTapGesture { model.perform(.back, source: "mouse") }

            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenEmu").font(BP.headline).foregroundColor(BP.primary)
                    Text(model.librarySummary).font(BP.caption).foregroundColor(BP.secondary)
                }
                .frame(height: 56, alignment: .leading).padding(.leading, 12)

                ForEach(Array(model.sidebarEntries.enumerated()), id: \.offset) { index, entry in
                    if index == 4 {
                        Text("SYSTEMS").font(BP.captionBold).tracking(1.2).foregroundColor(BP.tertiary)
                            .padding(.leading, 12).padding(.top, 14).padding(.bottom, 4)
                    }
                    row(index: index, entry: entry)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 16)
            .offset(y: -CGFloat(max(0, model.sidebarIndex - 9)) * 44)
            .animation(.easeOut(duration: 0.15), value: model.sidebarIndex)
            .frame(width: BP.sidebarWidth, height: BP.canvas.height - 16, alignment: .topLeading)
            .clipped()
            .background(BP.material)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(BP.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 48, y: 12)
            .offset(x: 12, y: 8)
        }
        .frame(width: BP.canvas.width, height: BP.canvas.height)
    }

    private func row(index: Int, entry: BigPictureModel.SidebarEntry) -> some View {
        let focused = model.sidebarIndex == index
        return HStack(spacing: 12) {
            if case .system(let id) = entry {
                ZStack {
                    Circle().fill(LinearGradient(colors: BP.systemColors(id), startPoint: .top, endPoint: .bottom))
                    if let icon = model.systems.first(where: { $0.id == id })?.icon {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).padding(5)
                    }
                }
                .frame(width: 26, height: 26)
            } else {
                Image(systemName: symbol(entry)).font(.system(size: 15)).frame(width: 26)
            }
            Text(title(entry)).font(BP.callout).lineLimit(1)
            Spacer(minLength: 0)
            if case .system(let id) = entry, let count = model.systems.first(where: { $0.id == id })?.count {
                Text("\(count)").font(BP.caption).foregroundColor(focused ? BP.focusText.opacity(0.8) : BP.tertiary)
            }
        }
        .foregroundColor(focused ? BP.focusText : BP.primary)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(focused ? BP.focusFill : Color.clear))
        .onTapGesture { model.clickSidebar(index) }
    }
}

// MARK: - Settings

private struct BPSettingsPage: View {

    @ObservedObject var model: BigPictureModel

    private func status(_ on: Bool, detail: String) -> String { on ? "Connected" : detail }

    var body: some View {
        let screenScraper = !(UserDefaults.standard.string(forKey: "ScreenScraperUsername") ?? "").isEmpty && OECredentialStore.shared.has(.screenScraperPassword)
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings").font(BP.headline).foregroundColor(BP.primary).padding(.top, 110)

            group("ARTWORK AND GAME INFO", rows: [
                ("Library cover art", "Always on", "Used when SteamGridDB has nothing"),
                ("SteamGridDB", status(SteamGridDBClient.isConfigured, detail: "Not set up"), "Posters and backdrops"),
                ("OpenVGDB", OpenVGDB.shared.isAvailable ? "Connected" : "Downloading", "Descriptions, genres, developers"),
                ("ScreenScraper", status(screenScraper, detail: "Not signed in"), "Cover art lookup"),
            ])

            group("INPUT", rows: [
                ("Controllers", model.controllers.isEmpty ? "None found" : model.controllers.joined(separator: ", "), "Keyboard also works"),
            ])

            Text("Enter provider keys in OpenEmu → Settings → Artwork.")
                .font(BP.caption).foregroundColor(BP.tertiary)
        }
        .padding(.horizontal, 320)
        .frame(width: BP.canvas.width, height: BP.canvas.height, alignment: .topLeading)
    }

    private func group(_ title: String, rows: [(String, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(BP.captionBold).tracking(1.2).foregroundColor(BP.tertiary).padding(.leading, 8)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.horizontal, 18) }
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.0).font(BP.calloutBold).foregroundColor(BP.primary)
                            Text(row.2).font(BP.caption).foregroundColor(BP.secondary)
                        }
                        Spacer()
                        Text(row.1).font(BP.callout).foregroundColor(row.1 == "Connected" || row.1 == "Always on" ? BP.success : BP.secondary)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                }
            }
            .background(RoundedRectangle(cornerRadius: BP.cardRadius, style: .continuous).fill(BP.material))
            .overlay(RoundedRectangle(cornerRadius: BP.cardRadius, style: .continuous).strokeBorder(BP.border, lineWidth: 1))
        }
    }
}
