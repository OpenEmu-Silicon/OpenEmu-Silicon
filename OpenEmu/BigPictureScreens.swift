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

                // The game's pause menu is drawn over the game itself (see BigPicturePauseRoot); this one is for leaving.
                if case .exit? = model.pauseKind {
                    BPPauseMenu(model: model, kind: .exit, art: art)
                        .transition(.opacity)
                }

                if let menu = model.openMenu {
                    BPFilterMenu(model: model, menu: menu)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: model.sidebarOpen)
        }
        .edgesIgnoringSafeArea(.all)
    }
}

/// "5 min ago", but "just now" for anything within a minute, instead of "in 0s" when the clock puts a time slightly ahead.
final class BPRelativeFormatter: RelativeDateTimeFormatter {
    override func localizedString(for date: Date, relativeTo reference: Date) -> String {
        abs(date.timeIntervalSince(reference)) < 60 ? "just now" : super.localizedString(for: date, relativeTo: reference)
    }
}

// MARK: - Artwork

extension OEBigPictureArt {

    /// The one rule for game art: SteamGridDB's portrait poster first, the library's own cover if it has none.
    /// Every poster, hero cover, banner and save-state fallback goes through this, so a game looks the same everywhere.
    func poster(for game: OEDBGame) -> NSImage? { grid(for: GameKey(game)) ?? game.boxImage?.image }

    /// The small square tile (Continue Playing, genre tiles): SteamGridDB's icon, then the poster.
    func tile(for game: OEDBGame) -> NSImage? { icon(for: GameKey(game)) ?? poster(for: game) }
}

// MARK: - Helpers

private extension OEDBGame {

    var systemName: String { system?.name ?? "" }

    /// The title as shown on screen, without region and revision tags: "Dragon Quest VIII (USA)" is "Dragon Quest VIII".
    var bpTitle: String { OEBigPictureArt.GameKey.searchName(cleanDisplayName) }

    var playedSummary: String {
        var parts = [String]()
        let hours = playTime / 3600
        if hours >= 1 { parts.append(String(format: "%.0f hrs", hours)) }
        else if playTime >= 60 { parts.append(String(format: "%.0f min", playTime / 60)) }
        if let lastPlayed = lastPlayed {
            let formatter = BPRelativeFormatter()
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
        let image = art.poster(for: game)
        ZStack {
            if let image = image {
                if image.size.height >= image.size.width {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).blur(radius: 24).opacity(0.7)
                } else {
                    // Landscape art in a portrait slot: the system's color behind it reads better than a blur.
                    LinearGradient(colors: BP.systemColors(game.system?.systemIdentifier), startPoint: .top, endPoint: .bottom).opacity(0.8)
                }
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                LinearGradient(colors: BP.systemColors(game.system?.systemIdentifier), startPoint: .top, endPoint: .bottom)
                Text(game.bpTitle)
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
    /// A game page has more to show (saves, about), so its hero is shorter and the first shelf is already on screen.
    static let detailHeroHeight: CGFloat = 340
    static let headerHeight: CGFloat = 56
    static let posterBody: CGFloat = 262
    static let stateBody: CGFloat = 228
    static let iconBody: CGFloat = 176
    static let featuredBody: CGFloat = 372
    static let gridBody: CGFloat = 372
    static let genreBody: CGFloat = 116
    static let recentBody: CGFloat = BP.recentSize.height + 16
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
            case .banner: return 108 + laneGap
            case .recent: return header + recentBody + laneGap
            default: return header + gridBody + laneGap
            }
        case .saveStates: return header + stateBody + laneGap
        case .genres: return header + genreBody + laneGap
        case .filters: return 64
        case .keys: return header + 52
        case .achievements: return header + BP.badgeCard.height + 20 + laneGap
        }
    }
}

private struct BPPage: View {
    @Environment(\.bpCanvasHeight) private var canvasHeight

    @ObservedObject var model: BigPictureModel
    @ObservedObject var art: OEBigPictureArt

    private var heroHeight: CGFloat {
        if case .detail = model.screen { return BPMetrics.detailHeroHeight }
        return BPMetrics.heroHeight
    }

    private var showsHero: Bool {
        if case .detail = model.screen { return true }
        return model.tab == .home && model.heroGame != nil
    }

    private var laneTops: [CGFloat] {
        var y = BPMetrics.top + (showsHero ? heroHeight : 0)
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
        // Moving around the search keyboard must not move the page: the whole keyboard stays in view.
        if model.tab == .search, model.screen == .browse, case .keys = model.lanes[model.lane].kind { return 0 }
        let wanted = max(0, laneTops[model.lane] - BPMetrics.focusTarget)
        // On a game page the closing sections scroll separately (see detailScrolled), so only the browsing screens stop
        // at the end: once the bottom of the content reaches the bottom of the screen, the last shelves stay where they
        // are instead of scrolling up and leaving the lower half of the screen empty.
        if case .detail = model.screen { return -wanted }
        guard let lastTop = laneTops.last, let last = model.lanes.last else { return -wanted }
        let contentBottom = lastTop + BPMetrics.height(of: last) - BPMetrics.laneGap + 32
        return -min(wanted, max(0, contentBottom - canvasHeight))
    }

    var body: some View {
        let tops = laneTops
        ZStack(alignment: .topLeading) {
            // The hero art scrolls with the page but is not faded under the tab bar: it should run to the top edge.
            if showsHero, let game = model.heroGame {
                BPBackdrop(game: game, art: art, heroHeight: heroHeight)
                    .frame(width: BP.canvas.width, height: canvasHeight, alignment: .topLeading)
                    .offset(y: pageOffset)
                    .animation(.easeOut(duration: 0.22), value: pageOffset)
            }

            ZStack(alignment: .topLeading) {
                if showsHero, let game = model.heroGame {
                    BPHero(model: model, game: game, art: art)
                        .frame(width: BP.canvas.width, height: heroHeight, alignment: .topLeading)
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

                if model.lanes.isEmpty || model.hasNoItems {
                    BPEmpty(model: model).offset(y: BPMetrics.top + (model.tab == .search ? 230 : (model.lanes.isEmpty ? 0 : 56)))
                }
            }
            .frame(width: BP.canvas.width, height: canvasHeight, alignment: .topLeading)
            .offset(y: pageOffset)
            .animation(.easeOut(duration: 0.22), value: pageOffset)
            .bpFadeUnderTabBar(canvasHeight: canvasHeight)
        }
        .frame(width: BP.canvas.width, height: canvasHeight, alignment: .topLeading)
        .clipped()
    }
}

/// Content fades out under the tab bar instead of running through it.
private extension View {
    func bpFadeUnderTabBar(canvasHeight: CGFloat) -> some View {
        mask(LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .clear, location: 64 / canvasHeight),
            .init(color: .black, location: 100 / canvasHeight),
            .init(color: .black, location: 1),
        ], startPoint: .top, endPoint: .bottom))
    }
}

private struct BPEmpty: View {

    @ObservedObject var model: BigPictureModel

    var body: some View {
        let message: String
        switch model.tab {
        case .saveStates: message = model.hasActiveFilters ? "No save states match these filters." : "No save states yet."
        case .search: message = model.searchQuery.isEmpty ? "" : "No games match \u{201C}\(model.searchQuery)\u{201D}."
        case .favorites: message = "Rate a game 4 stars or more to see it here."
        case .library: message = model.hasActiveFilters ? "No games match these filters." : "No games in the library yet."
        default: message = "No games in the library yet."
        }
        return Text(message)
            .font(BP.callout)
            .foregroundColor(BP.secondary)
            .padding(.horizontal, BP.margin)
            .padding(.top, 24)
    }
}

private struct BPBackdrop: View {

    let game: OEDBGame
    @ObservedObject var art: OEBigPictureArt

    let heroHeight: CGFloat

    private var height: CGFloat { BPMetrics.top + heroHeight }

    var body: some View {
        ZStack {
            // No hero art (no SteamGridDB, or none for this game): just the page's black, nothing in its place.
            if let hero = art.hero(for: OEBigPictureArt.GameKey(game)) {
                Image(nsImage: hero).resizable().aspectRatio(contentMode: .fill).opacity(0.6)
                // Dim under the tab bar, a soft pool behind the text, and a fade into the page below.
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 90).frame(maxHeight: .infinity, alignment: .top)
                LinearGradient(colors: [BP.background.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, BP.background], startPoint: .top, endPoint: .bottom)
                    .frame(height: 170).frame(maxHeight: .infinity, alignment: .bottom)
            }
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

            Group {
                if let logo = art.logo(for: key) {
                    // The title lettering from SteamGridDB, when it has one.
                    Image(nsImage: logo).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 560, maxHeight: 60, alignment: .leading)
                } else {
                    Text(game.bpTitle)
                        .font(BP.display).tracking(-0.5).foregroundColor(BP.primary)
                        .lineLimit(1).minimumScaleFactor(0.65)
                }
            }
            .frame(width: 800, height: 60, alignment: .topLeading)
            .offset(x: heroTextX, y: 130)

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
        .overlay(alignment: .topLeading) {
            if model.heroIsFeatured, model.featured.count > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<model.featured.count, id: \.self) { dot in
                        let current = dot == model.heroIndex % model.featured.count
                        Capsule().fill(current ? Color.white : Color.white.opacity(0.35))
                            .frame(width: current ? 22 : 6, height: 6)
                            .overlay(Capsule().strokeBorder(BP.focusRing, lineWidth: actionsFocused && model.column == 2 + dot ? BP.focusLine : 0).padding(-4))
                            .onTapGesture { model.click(lane: 0, column: 2 + dot) }
                    }
                }
                .frame(width: BP.canvas.width - 2 * BP.margin, alignment: .trailing)
                .offset(x: BP.margin, y: 298)
                .animation(.easeInOut(duration: 0.2), value: model.heroIndex)
            }
        }
        .onReceive(Timer.publish(every: 8, on: .main, in: .common).autoconnect()) { _ in model.advanceHero() }
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
    private var coverImage: NSImage? { art.poster(for: game) }

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
    enum Style { case icons, grid, featured, wide, genre, filters, banner, keys, recent, badges }

    /// How a shelf draws its items: icon tiles for what you just played, large cards for favorites, else posters.
    var style: Style {
        switch kind {
        case .saveStates: return .wide
        case .genres: return .genre
        case .filters: return .filters
        case .keys: return .keys
        case .achievements: return .badges
        default:
            switch id {
            case "recent": return .icons
            case "most-played": return .featured
            case "added": return .recent
            case "rediscover": return .banner
            default: return .grid
            }
        }
    }

    var itemWidth: CGFloat {
        switch style {
        case .icons: return BP.iconSize
        case .grid: return BP.gridSize.width
        case .featured: return BP.featuredSize.width
        case .wide: return BP.wideCard.width
        case .genre: return 180
        case .filters: return 210
        case .keys: return 40
        case .banner: return BP.canvas.width - 2 * BP.margin
        case .recent: return BP.recentSize.width
        case .badges: return BP.badgeCard.width
        }
    }

    var itemGap: CGFloat { style == .icons ? 18 : (style == .featured ? 14 : (style == .grid ? 20 : (style == .genre ? 14 : (style == .filters ? 12 : (style == .banner ? 0 : (style == .keys ? 8 : (style == .recent ? 18 : (style == .badges ? 14 : BP.gutter)))))))) }

    /// Columns that fit on screen before the shelf starts to slide.
    var visibleColumns: Int {
        switch style {
        case .icons: return 8
        case .grid: return 5
        case .featured: return 5
        case .wide: return 4
        case .genre: return 6
        case .filters: return 4
        case .banner: return 1
        case .keys: return 14
        case .recent: return 3
        case .badges: return 4
        }
    }

    /// The filter bar sits in the middle of the page; everything else starts at the margin.
    var leadingInset: CGFloat {
        guard case .filters(let filters) = kind else { return BP.margin }
        let buttons = filters.filter { $0.menu != nil }.count
        let width = CGFloat(buttons) * 210 + CGFloat(max(buttons - 1, 0)) * 12 + (filters.contains { $0.menu == nil } ? 12 + 96 : 0)
        return (BP.canvas.width - width) / 2
    }

    var isWide: Bool {
        switch kind {
        case .saveStates: return true
        default: return false
        }
    }
}

private struct BPLane: View {

    @ObservedObject var model: BigPictureModel
    @ObservedObject var art: OEBigPictureArt
    /// Observed so the shelf redraws the moment a badge image finishes downloading.
    @ObservedObject private var badgeImages = BigPictureRemoteImages.shared
    let lane: BigPictureLane
    let index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = lane.title {
                HStack(spacing: 12) {
                    if let game = lane.game, let tile = art.tile(for: game) {
                        Image(nsImage: tile).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 40, height: 40).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(BP.headline).foregroundColor(BP.primary)
                        if let subtitle = lane.subtitle {
                            Text(subtitle).font(BP.callout).foregroundColor(BP.secondary)
                        }
                        if let progress = lane.progress {
                            GeometryReader { bar in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(BP.border)
                                    Capsule().fill(BP.accent).frame(width: bar.size.width * CGFloat(min(max(progress, 0), 1)))
                                }
                            }
                            .frame(width: 420, height: 4).padding(.top, 4)
                        }
                    }
                }
                .padding(.horizontal, BP.margin)
                .frame(height: BPMetrics.headerHeight, alignment: .bottomLeading)
            }

            let step = lane.itemWidth + lane.itemGap
            let shift: CGFloat = {
                guard model.lane == index else { return 0 }
                return -CGFloat(max(0, model.column - (lane.visibleColumns - 1))) * step
            }()
            HStack(alignment: .top, spacing: lane.itemGap) {
                switch lane.kind {
                case .games(let games):
                    ForEach(Array(games.enumerated()), id: \.offset) { column, game in
                        switch lane.style {
                        case .icons: iconTile(game, column: column)
                        case .featured: featuredCard(game, column: column)
                        case .banner: bannerCard(game, column: column)
                        case .recent: recentCard(game, column: column)
                        default: poster(game, column: column)
                        }
                    }
                case .saveStates(let states):
                    ForEach(Array(states.enumerated()), id: \.offset) { column, state in
                        stateCard(state, column: column)
                    }
                case .genres(let genres):
                    ForEach(Array(genres.enumerated()), id: \.offset) { column, genre in
                        genreTile(genre, column: column)
                    }
                case .filters(let filters):
                    ForEach(Array(filters.enumerated()), id: \.offset) { column, filter in
                        filterButton(filter, column: column)
                    }
                case .keys(let keys):
                    ForEach(Array(keys.enumerated()), id: \.offset) { column, key in
                        keyButton(key, column: column)
                    }
                case .achievements(let items):
                    ForEach(Array(items.enumerated()), id: \.offset) { column, item in
                        achievementCard(item, column: column)
                    }
                case .heroActions:
                    EmptyView()
                }
            }
            .padding(.leading, lane.leadingInset)
            .padding(.top, BP.space12)
            .offset(x: shift)
            .animation(.easeOut(duration: 0.2), value: shift)
        }
    }

    /// A save-state preview that is all black (some cores write one) tells the player nothing.
    /// "Dragon Quest VIII - Journey of the Cursed King" becomes "DQV".
    private static func initials(_ name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }.filter { !["of", "the", "a", "an", "and"].contains($0.lowercased()) }
        return String(words.prefix(3).compactMap { $0.first }).uppercased()
    }

    private static func isBlank(_ image: NSImage?) -> Bool {
        guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        var pixels = [UInt8](repeating: 0, count: 64)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            return true
        }
        return drew && pixels.reduce(0) { $0 + Int($1) } / 64 < 6
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
        let formatter = BPRelativeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// A colored tile with the genre name and a small fan of covers, like the AltUI Browse by Genre row.
    private func genreTile(_ genre: BigPictureGenre, column: Int) -> some View {
        let focused = isFocused(column)
        return ZStack(alignment: .bottomLeading) {
            BP.genreColor(genre.name)
            HStack(spacing: -16) {
                ForEach(Array(genre.games.prefix(3).enumerated()), id: \.offset) { offset, game in
                    if let image = art.tile(for: game) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 50, height: 50).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                            .rotationEffect(.degrees(Double(offset - 1) * 7))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 10).padding(.trailing, 12)
            Text(genre.name).font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                .lineLimit(1).padding(.horizontal, 14).padding(.bottom, 12)
        }
        .frame(width: 180, height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(focused ? BP.focusRing : BP.border, lineWidth: focused ? BP.focusLine : 1))
        .scaleEffect(focused ? 1.05 : 1, anchor: .top)
        .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 14, y: 8)
        .animation(.easeOut(duration: 0.12), value: focused)
        .onHover { inside in if inside { model.hover(lane: index, column: column) } }
        .onTapGesture { model.click(lane: index, column: column) }
    }

    /// A drop-down button: white when a filter is on, like the selected system in the AltUI library bar.
    /// The last button, when any filter is on, is Clear.
    private func filterButton(_ filter: BigPictureFilter, column: Int) -> some View {
        let focused = isFocused(column)
        let isClear = filter.menu == nil
        return HStack(spacing: 8) {
            if isClear {
                Image(systemName: "xmark.circle.fill").font(.system(size: 13, weight: .semibold))
            } else if let icon = filter.icon {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 18, height: 18)
            } else if filter.menu == .sort {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 12, weight: .semibold))
            }
            Text(filter.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if !isClear {
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).opacity(0.7)
            }
        }
        .foregroundColor(filter.active ? Color.black.opacity(0.88) : BP.primary)
        .padding(.horizontal, 14).frame(width: isClear ? 96 : 210, height: 32)
        .background(Capsule().fill(filter.active ? Color.white : BP.surface))
        .overlay(Capsule().strokeBorder(focused ? BP.focusRing : BP.border, lineWidth: focused ? BP.focusLine : 1))
        .scaleEffect(focused ? 1.03 : 1)
        .animation(.easeOut(duration: 0.12), value: focused)
        .onHover { inside in if inside { model.hover(lane: index, column: column) } }
        .onTapGesture { model.click(lane: index, column: column) }
    }

    /// A key on the Search tab's on-screen keyboard.
    private func keyButton(_ key: BigPictureKey, column: Int) -> some View {
        let focused = isFocused(column)
        return Text(key.label).font(.system(size: 14, weight: .semibold)).foregroundColor(BP.primary)
            .frame(width: key.label.count > 1 ? 84 : 40, height: 40)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(BP.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(focused ? BP.focusRing : BP.border, lineWidth: focused ? BP.focusLine : 1))
            .scaleEffect(focused ? 1.06 : 1)
            .animation(.easeOut(duration: 0.12), value: focused)
            .onHover { inside in if inside { model.hover(lane: index, column: column) } }
            .onTapGesture { model.click(lane: index, column: column) }
    }

    /// "Rediscover": a game you spent time in and have left alone for a while. A wide, blue-tinted card with a
    /// "Played 6 mos. ago" pill, the title, play time and last save, and a Play Now button.
    private func bannerCard(_ game: OEDBGame, column: Int) -> some View {
        let focused = isFocused(column)
        let key = OEBigPictureArt.GameKey(game)
        let width = BP.canvas.width - 2 * BP.margin
        let ago = game.lastPlayed.map { Self.ago.localizedString(for: $0, relativeTo: Date()) }
        let hours = game.playTime / 3600
        let played = hours >= 1 ? String(format: "%.0fh played", hours) : String(format: "%.0fm played", max(game.playTime / 60, 1))
        let lastSave = (game.defaultROM?.normalSaveStates ?? []).max { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
        let saveName = lastSave.flatMap { $0.displayName.split(separator: " ").first.map { $0.replacingOccurrences(of: "-", with: " ") } }
        let accent = Color(hex: 0x3B82F6)
        return ZStack(alignment: .leading) {
            Color(hex: 0x0E1B52)
            if let hero = art.hero(for: key) {
                Image(nsImage: hero).resizable().aspectRatio(contentMode: .fill).frame(width: width, height: 108).clipped().opacity(0.4)
            }
            LinearGradient(colors: [Color(hex: 0x0E1B52).opacity(0.95), Color(hex: 0x0E1B52).opacity(0.35)], startPoint: .leading, endPoint: .trailing)
            HStack(spacing: 18) {
                if let cover = art.poster(for: game) {
                    Image(nsImage: cover).resizable().aspectRatio(contentMode: .fit).frame(width: 88, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(ago.map { "Played \($0)" } ?? "Played a while ago")
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(Color(hex: 0x7DB3FF))
                        .padding(.horizontal, 10).frame(height: 22)
                        .background(Capsule().fill(accent.opacity(0.28)))
                        .overlay(Capsule().strokeBorder(accent.opacity(0.7), lineWidth: 1))
                    Text(game.bpTitle).font(.system(size: 22, weight: .bold)).foregroundColor(BP.primary).lineLimit(1)
                    Text([played, saveName.map { "Last save: \($0)" }].compactMap { $0 }.joined(separator: "  ·  "))
                        .font(BP.callout).foregroundColor(BP.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Image(systemName: "play.fill").font(.system(size: 12, weight: .bold))
                    Text("Play Now").font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(BP.primary)
                .padding(.horizontal, 22).frame(height: 38)
                .background(Capsule().fill(Color.white.opacity(0.14)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
            }
            .padding(.horizontal, 20)
        }
        .frame(width: width, height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(focused ? BP.focusRing : accent.opacity(0.25), lineWidth: focused ? BP.focusLine : 1))
        .scaleEffect(focused ? 1.01 : 1)
        .animation(.easeOut(duration: 0.12), value: focused)
        .onAppear { art.load(key) }
        .onHover { inside in if inside { model.hover(lane: index, column: column) } }
        .onTapGesture { model.click(lane: index, column: column) }
    }

    /// Recently Added: a wide card with the game's art on top and an info bar with its box art, name, system and genre,
    /// when it was added, and a Play pill. "New" marks anything added in the last two weeks.
    private func recentCard(_ game: OEDBGame, column: Int) -> some View {
        let focused = isFocused(column)
        let key = OEBigPictureArt.GameKey(game)
        let details = art.details(for: key)
        let facts = [game.system?.name, details?.primaryGenre].compactMap { $0 }.joined(separator: " · ")
        let added = game.importDate.map { date -> String in
            if Calendar.current.isDateInToday(date) { return "Added today" }
            return "Added " + Self.ago.localizedString(for: date, relativeTo: Date())
        }
        let size = BP.recentSize
        return VStack(spacing: 0) {
            ZStack {
                BP.material
                if let hero = art.hero(for: key) {
                    Image(nsImage: hero).resizable().aspectRatio(contentMode: .fill)
                } else {
                    // No wide art: the system's color with the box art kept sharp, instead of a blurred smear.
                    LinearGradient(colors: BP.systemColors(game.system?.systemIdentifier), startPoint: .top, endPoint: .bottom).opacity(0.8)
                    if let cover = art.poster(for: game) {
                        Image(nsImage: cover).resizable().aspectRatio(contentMode: .fit).padding(14)
                            .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                    }
                }
            }
            .frame(width: size.width, height: size.height - BP.recentBarHeight).clipped()
            .overlay(alignment: .topLeading) {
                if isNew(game) {
                    HStack(spacing: 5) {
                        Image(systemName: "star.fill").font(.system(size: 9, weight: .bold))
                        Text("New").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(BP.primary).padding(.horizontal, 10).frame(height: 24)
                    .background(Capsule().fill(Color.black.opacity(0.55))).padding(10)
                }
            }
            HStack(spacing: 12) {
                if let tile = art.tile(for: game) {
                    Image(nsImage: tile).resizable().aspectRatio(contentMode: .fill).frame(width: 48, height: 48).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.bpTitle).font(BP.calloutBold).foregroundColor(BP.primary).lineLimit(1)
                    if !facts.isEmpty { Text(facts).font(.system(size: 11)).foregroundColor(BP.secondary).lineLimit(1) }
                    if let added = added { Text(added).font(.system(size: 11)).foregroundColor(BP.tertiary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                    Text("Play").font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(BP.primary).padding(.horizontal, 14).frame(height: 28)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            }
            .padding(.horizontal, 12)
            .frame(width: size.width, height: BP.recentBarHeight)
            .background(BP.material)
        }
        .clipShape(RoundedRectangle(cornerRadius: BP.cardRadius + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BP.cardRadius + 2, style: .continuous)
            .strokeBorder(focused ? BP.focusRing : BP.border, lineWidth: focused ? BP.focusLine : 1))
        .scaleEffect(focused ? 1.03 : 1, anchor: .top)
        .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 14, y: 8)
        .animation(.easeOut(duration: 0.12), value: focused)
        .onAppear { art.load(key) }
        .onHover { inside in if inside { model.hover(lane: index, column: column) } }
        .onTapGesture { model.click(lane: index, column: column) }
    }

    /// An achievement: its badge (dimmed while locked), title, description and points.
    private func achievementCard(_ item: BigPictureAchievement, column: Int) -> some View {
        let focused = isFocused(column)
        let images = badgeImages
        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                BP.surface
                if let badge = images.image(item.badgeURL) {
                    Image(nsImage: badge).resizable().aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: 60, height: 60).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(item.earned ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 13, weight: .semibold))
                    .foregroundColor(item.earned ? BP.primary : BP.secondary).lineLimit(1)
                Text(item.detail).font(.system(size: 11)).foregroundColor(BP.tertiary).lineLimit(2)
                Spacer(minLength: 0)
                Text("\(item.points) PTS").font(.system(size: 10, weight: .bold)).tracking(0.6)
                    .foregroundColor(item.earned ? BP.accent : BP.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: BP.badgeCard.width, height: BP.badgeCard.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: BP.cardRadius, style: .continuous).fill(BP.material))
        .overlay(RoundedRectangle(cornerRadius: BP.cardRadius, style: .continuous)
            .strokeBorder(focused ? BP.focusRing : BP.border, lineWidth: focused ? BP.focusLine : 1))
        .opacity(item.earned ? 1 : 0.8)
        .scaleEffect(focused ? 1.03 : 1, anchor: .top)
        .animation(.easeOut(duration: 0.12), value: focused)
        .onAppear { images.load(item.badgeURL) }
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
        let image = art.tile(for: game)
        return VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let image = image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    // No art at all: the system's color with the game's initials.
                    LinearGradient(colors: BP.systemColors(game.system?.systemIdentifier), startPoint: .top, endPoint: .bottom)
                    Text(Self.initials(game.bpTitle))
                        .font(.system(size: 30, weight: .heavy)).foregroundColor(BP.primary.opacity(0.85))
                }
            }
            .frame(width: BP.iconSize, height: BP.iconSize).clipped()
            .clipShape(RoundedRectangle(cornerRadius: BP.iconRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BP.iconRadius, style: .continuous)
                .strokeBorder(BP.focusRing, lineWidth: focused ? BP.focusLine : 0).padding(-3))
            .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
            Text(game.bpTitle).font(BP.captionBold).foregroundColor(BP.primary)
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
                .overlay(alignment: .topLeading) {
                    if lane.id == "added", column < 4, isNew(game) {
                        Text("NEW").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Capsule().fill(BP.accent)).padding(8)
                    }
                }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.bpTitle).font(BP.calloutBold).foregroundColor(BP.primary).lineLimit(1)
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

    /// A large bare poster with a time-played badge and a "developer · year · genre" caption, like the AltUI library.
    private func poster(_ game: OEDBGame, column: Int) -> some View {
        let focused = isFocused(column)
        let details = art.details(for: OEBigPictureArt.GameKey(game))
        let facts = [details?.developer, details?.releaseDate.map { String($0.suffix(4)) }, details?.primaryGenre]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let caption = facts.isEmpty ? game.systemName : facts
        return VStack(alignment: .leading, spacing: BP.space8) {
            BPPoster(game: game, size: BP.gridSize, coverTick: model.coverTick, art: art)
                .overlay(alignment: .topTrailing) {
                    if let played = game.lastPlayed {
                        Text(Self.shortAgo(played)).font(.system(size: 9, weight: .bold)).tracking(0.6)
                            .foregroundColor(BP.primary)
                            .padding(.horizontal, 7).frame(height: 18)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                            .padding(7)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(game.bpTitle).font(BP.calloutBold).foregroundColor(BP.primary).lineLimit(1)
                if !caption.isEmpty {
                    Text(caption).font(.system(size: 11)).foregroundColor(BP.tertiary).lineLimit(1)
                }
            }
            .frame(width: BP.gridSize.width, alignment: .leading)
            .opacity(focused ? 1 : 0.85)
        }
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: BP.posterRadius + 3, style: .continuous)
                .strokeBorder(BP.focusRing, lineWidth: focused ? BP.focusLine : 0)
                .frame(width: BP.gridSize.width + 8, height: BP.gridSize.height + 8)
                .offset(y: -4)
        }
        .scaleEffect(focused ? 1.04 : 1, anchor: .top)
        .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 14, y: 8)
        .animation(.easeOut(duration: 0.12), value: focused)
        .onAppear { art.load(OEBigPictureArt.GameKey(game)) }
        .onHover { inside in if inside { model.hover(lane: index, column: column) } }
        .onTapGesture { model.click(lane: index, column: column) }
    }

    /// "2H AGO", "YESTERDAY", "3D AGO", "1W AGO".
    private static func shortAgo(_ date: Date) -> String {
        let seconds = max(Date().timeIntervalSince(date), 0)
        let hours = Int(seconds / 3600), days = Int(seconds / 86400)
        if seconds < 3600 { return "JUST NOW" }
        if hours < 24 { return "\(hours)H AGO" }
        if days == 1 { return "YESTERDAY" }
        if days < 7 { return "\(days)D AGO" }
        if days < 60 { return "\(days / 7)W AGO" }
        return "\(days / 30)MO AGO"
    }

    private func stateCard(_ state: OEDBSaveState, column: Int) -> some View {
        let focused = isFocused(column)
        let shot = NSImage(contentsOf: state.screenshotURL)
        let image = Self.isBlank(shot) ? nil : shot
        let game = state.rom?.game
        let fallback = game.flatMap { art.poster(for: $0) }
        // Save names carry a long timestamp ("Save-Game-2 2026-10-26 11:42:15 -0700"); show the name and a short date.
        let label = state.displayName.split(separator: " ").first.map { $0.replacingOccurrences(of: "-", with: " ") } ?? state.displayName
        let title = lane.showsGame ? (game?.bpTitle ?? label) : label
        let detail = [lane.showsGame ? label : nil, state.timestamp.map { $0.formatted(.dateTime.month().day().hour().minute()) }]
            .compactMap { $0 }.joined(separator: "  ·  ")
        return VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.white.opacity(0.06)
                if let image = image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else if let fallback = fallback {
                    // Some cores save an all-black preview; show the game's art instead.
                    Image(nsImage: fallback).resizable().aspectRatio(contentMode: .fill).blur(radius: 18).opacity(0.5)
                } else {
                    LinearGradient(colors: BP.systemColors(game?.system?.systemIdentifier), startPoint: .top, endPoint: .bottom).opacity(0.7)
                }
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
        let formatter = BPRelativeFormatter()
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
                    Text(game.bpTitle).font(.system(size: 18, weight: .bold)).foregroundColor(BP.primary)
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
    @Environment(\.bpCanvasHeight) private var canvasHeight

    @ObservedObject var model: BigPictureModel

    private func symbol(_ entry: BigPictureModel.SidebarEntry) -> String {
        switch entry {
        case .tab(.home): return "house"
        case .tab(.recent): return "clock"
        case .tab(.favorites): return "heart"
        case .settings: return "slider.horizontal.3"
        case .exit: return "rectangle.portrait.and.arrow.right"
        default: return "circle"
        }
    }

    private func title(_ entry: BigPictureModel.SidebarEntry) -> String {
        switch entry {
        case .tab(let tab): return tab.title
        case .settings: return "Settings"
        case .exit: return "Exit Big Picture"
        case .system(let id): return model.systems.first { $0.id == id }?.name ?? id
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.35).onTapGesture { model.perform(.back, source: "mouse") }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OpenEmu").font(BP.headline).foregroundColor(BP.primary)
                        Text(model.librarySummary).font(BP.caption).foregroundColor(BP.secondary)
                    }
                }
                .frame(height: 56, alignment: .leading).padding(.leading, 12)

                ForEach(Array(model.sidebarEntries.enumerated()), id: \.offset) { index, entry in
                    if index == 5 {
                        Text("SYSTEMS").font(BP.captionBold).tracking(1.2).foregroundColor(BP.tertiary)
                            .padding(.leading, 12).padding(.top, 14).padding(.bottom, 4)
                    }
                    row(index: index, entry: entry)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 16)
            .offset(y: -CGFloat(max(0, model.sidebarIndex - 9)) * 44)
            .animation(.easeOut(duration: 0.15), value: model.sidebarIndex)
            .frame(width: BP.sidebarWidth, height: canvasHeight - 16, alignment: .topLeading)
            .clipped()
            .background(BP.material)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(BP.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 48, y: 12)
            .offset(x: 12, y: 8)
        }
        .frame(width: BP.canvas.width, height: canvasHeight)
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

// MARK: - Pause menu

/// The pause menu drawn over a running game, in a window of its own that sits on the game's window, so it never has to
/// switch Spaces to get to or back from the game.
struct BigPicturePauseRoot: View {

    @ObservedObject var model: BigPictureModel
    @ObservedObject private var art = OEBigPictureArt.shared

    var body: some View {
        BigPictureCanvas(opaque: false) {
            if case .game(let game)? = model.pauseKind {
                BPPauseMenu(model: model, kind: .game(game), art: art)
            } else {
                Color.clear
            }
        }
    }
}

/// A two-choice dialog: Resume Game / Quit Game while a game runs, or Stay / Exit Big Picture. The first choice is the
/// safe one and is where the highlight starts; Back and Home choose it too.
private struct BPPauseMenu: View {
    @Environment(\.bpCanvasHeight) private var canvasHeight

    @ObservedObject var model: BigPictureModel
    let kind: BigPictureModel.PauseKind
    @ObservedObject var art: OEBigPictureArt

    private var choices: [(String, String)] {
        switch kind {
        case .game: return [("Resume Game", "play.fill"), ("Quit Game", "xmark.circle")]
        case .exit: return [("Stay in Big Picture", "arrow.uturn.backward"), ("Exit Big Picture", "rectangle.portrait.and.arrow.right")]
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).onTapGesture { model.choosePause(0) }

            VStack(spacing: 22) {
                HStack(spacing: 14) {
                    header
                    Spacer(minLength: 0)
                }
                .frame(width: 340)

                VStack(spacing: 10) {
                    ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                        row(choice.0, symbol: choice.1, index: index)
                    }
                }
                if case .game = kind {
                    Text("Your progress is saved when you quit.").font(BP.caption).foregroundColor(BP.tertiary)
                }
            }
            .padding(30)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(BP.material))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(BP.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        }
        .frame(width: BP.canvas.width, height: canvasHeight)
    }

    @ViewBuilder private var header: some View {
        switch kind {
        case .game(let game):
            if let game = game, let tile = art.tile(for: game) {
                Image(nsImage: tile).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(game?.bpTitle ?? "Game").font(BP.headline).foregroundColor(BP.primary).lineLimit(1)
                Text("Game paused").font(BP.callout).foregroundColor(BP.secondary)
            }
        case .exit:
            Image(nsImage: NSApp.applicationIconImage).resizable().aspectRatio(contentMode: .fit).frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("Big Picture").font(BP.headline).foregroundColor(BP.primary)
                Text("Leave big picture mode?").font(BP.callout).foregroundColor(BP.secondary)
            }
        }
    }

    private func row(_ title: String, symbol: String, index: Int) -> some View {
        let focused = model.pauseIndex == index
        return HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
            Text(title).font(.system(size: 15, weight: .semibold))
        }
        .foregroundColor(focused ? BP.focusText : BP.primary)
        .frame(width: 340, height: 44)
        .background(Capsule().fill(focused ? BP.focusFill : BP.surface))
        .overlay(Capsule().strokeBorder(BP.border, lineWidth: focused ? 0 : 1))
        .onTapGesture { model.choosePause(index) }
    }
}

// MARK: - Filter drop-down

/// The list a filter button opens, under that button. Up and down move, Select chooses, Back closes.
private struct BPFilterMenu: View {
    @Environment(\.bpCanvasHeight) private var canvasHeight

    @ObservedObject var model: BigPictureModel
    let menu: BigPictureModel.FilterMenu

    private let rowHeight: CGFloat = 38
    private let maxRows = 9

    var body: some View {
        let options = model.menuOptions(menu)
        let visible = min(options.count, maxRows)
        let inset = model.lanes.first { $0.id == "filters" }?.leadingInset ?? BP.margin
        let x = inset + CGFloat(model.filterMenus.firstIndex(of: menu) ?? 0) * (210 + 12)
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.35).onTapGesture { model.closeFilterMenu() }

            VStack(spacing: 2) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    let focused = model.menuIndex == index
                    HStack(spacing: 10) {
                        if let icon = option.icon {
                            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 20, height: 20)
                        }
                        Text(option.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        if option.selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)) }
                    }
                    .foregroundColor(focused ? BP.focusText : BP.primary)
                    .padding(.horizontal, 12).frame(height: rowHeight - 2)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(focused ? BP.focusFill : Color.clear))
                    .onTapGesture { model.clickMenu(index) }
                }
            }
            .padding(8)
            .offset(y: -CGFloat(max(0, model.menuIndex - (maxRows - 1))) * rowHeight)
            .animation(.easeOut(duration: 0.12), value: model.menuIndex)
            .frame(width: 280, height: CGFloat(visible) * rowHeight + 16, alignment: .topLeading)
            .clipped()
            .background(BP.material)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(BP.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
            .offset(x: x, y: BPMetrics.top + 52)
        }
        .frame(width: BP.canvas.width, height: canvasHeight)
    }
}

// MARK: - Settings

private struct BPSettingsPage: View {
    @Environment(\.bpCanvasHeight) private var canvasHeight

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
        .frame(width: BP.canvas.width, height: canvasHeight, alignment: .topLeading)
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
