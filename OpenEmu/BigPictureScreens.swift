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
                    .padding(20)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: BP.posterRadius, style: .continuous))
        .onAppear { art.load(key) }
        .id("\(game.objectID)-\(coverTick)")
    }
}

private struct BPButton: View {

    let title: String
    let symbol: String
    let isPrimary: Bool
    let focused: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 26, weight: .semibold))
            Text(title).font(BP.calloutBold)
        }
        .foregroundColor(isPrimary ? Color.black.opacity(0.9) : BP.primary)
        .frame(width: BP.buttonSize.width, height: BP.buttonSize.height)
        .background(Capsule().fill(isPrimary ? Color.white : BP.surfaceStrong))
        .overlay(Capsule().strokeBorder(BP.focusRing, lineWidth: focused ? 5 : 0).padding(-7))
        .scaleEffect(focused ? 1.06 : 1)
        .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 20, y: 10)
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

// MARK: - Tab bar

private struct BPTabBar: View {

    @ObservedObject var model: BigPictureModel

    var body: some View {
        HStack(spacing: 20) {
            let sidebarFocused = model.isTabBarFocused && model.tabBarIndex == 0
            Image(systemName: "sidebar.left")
                .font(.system(size: 30, weight: .medium))
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
                        .padding(.horizontal, 36)
                        .frame(height: BP.tabBarHeight - 12)
                        .background(Capsule().fill(focused ? BP.focusFill : (current ? BP.surfaceStrong : Color.clear)))
                        .onTapGesture { model.clickTab(tab.rawValue + 1) }
                }
            }
            .padding(6)
            .background(Capsule().fill(BP.surface))
            .overlay(Capsule().strokeBorder(BP.border, lineWidth: 1))
        }
        .frame(width: BP.canvas.width)
        .offset(y: 56)
        .animation(.easeOut(duration: 0.12), value: model.tabBarIndex)
    }
}

// MARK: - Page (hero + shelves)

/// Heights are fixed so the page can be positioned from the highlight alone. SwiftUI's scroll views are avoided on
/// purpose: inside the scaled design canvas they mis-position their content.
private enum BPMetrics {
    static let top: CGFloat = 170
    static let heroHeight: CGFloat = 580
    static let headerHeight: CGFloat = 100
    static let posterBody: CGFloat = 480
    static let stateBody: CGFloat = 400
    /// Air between one shelf and the next.
    static let laneGap: CGFloat = 64
    static let focusTarget: CGFloat = 150

    static func height(of lane: BigPictureLane) -> CGFloat {
        let header = lane.title == nil ? 0 : headerHeight
        switch lane.kind {
        case .heroActions: return 0
        case .games: return header + posterBody + laneGap
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
            if showsHero, let game = model.heroGame {
                BPBackdrop(game: game, art: art)
            }

            ZStack(alignment: .topLeading) {
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
            .init(color: .clear, location: 120 / BP.canvas.height),
            .init(color: .black, location: 190 / BP.canvas.height),
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
            .padding(.top, 40)
    }
}

private struct BPBackdrop: View {

    let game: OEDBGame
    @ObservedObject var art: OEBigPictureArt

    var body: some View {
        ZStack {
            let key = OEBigPictureArt.GameKey(game)
            if let hero = art.hero(for: key) {
                Image(nsImage: hero).resizable().aspectRatio(contentMode: .fill)
            } else if let cover = game.boxImage?.image {
                Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill).blur(radius: 60).opacity(0.5)
            } else {
                LinearGradient(colors: BP.systemColors(game.system?.systemIdentifier), startPoint: .topTrailing, endPoint: .bottomLeading).opacity(0.5)
            }
            LinearGradient(stops: [
                .init(color: BP.background.opacity(0.95), location: 0),
                .init(color: BP.background.opacity(0.82), location: 0.5),
                .init(color: BP.background.opacity(0.3), location: 1),
            ], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [
                .init(color: .clear, location: 0.35),
                .init(color: BP.background, location: 0.72),
            ], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: BP.canvas.width, height: BP.canvas.height)
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
                .frame(width: 396, height: 330, alignment: .bottomLeading)
                .offset(x: BP.margin, y: 68 - 41)

            Text(eyebrow)
                .font(BP.captionBold).tracking(3).foregroundColor(BP.secondary)
                .lineLimit(1).frame(width: 1200, alignment: .leading)
                .offset(x: 560, y: 58)

            Text(game.cleanDisplayName)
                .font(BP.display).tracking(-1.5).foregroundColor(BP.primary)
                .lineLimit(1).minimumScaleFactor(0.6).frame(width: 1240, alignment: .leading)
                .offset(x: 560, y: 94)

            metaRow(details: details).offset(x: 560, y: 180)

            Text(details?.summary ?? game.gameDescription ?? "")
                .font(BP.callout).foregroundColor(BP.secondary)
                .lineLimit(2).frame(width: 980, alignment: .topLeading)
                .offset(x: 560, y: 232)

            HStack(spacing: 24) {
                BPButton(title: "Resume", symbol: "play.fill", isPrimary: true, focused: actionsFocused && model.column == 0)
                    .onTapGesture { model.click(lane: 0, column: 0) }
                BPButton(title: "Save States", symbol: "square.and.arrow.down", isPrimary: false, focused: actionsFocused && model.column == 1)
                    .onTapGesture { model.click(lane: 0, column: 1) }
            }
            .offset(x: 560, y: 340)
        }
        .onAppear { art.load(key) }
    }

    private var eyebrow: String {
        let place: String
        if case .detail = model.screen { place = game.systemName } else { place = "\(game.systemName) · RECENTLY PLAYED" }
        return place.uppercased()
    }

    /// The same poster as the shelves, so a game looks the same everywhere.
    private var heroCover: some View {
        BPPoster(game: game, size: CGSize(width: 220, height: 330), coverTick: model.coverTick, art: art)
            .overlay(RoundedRectangle(cornerRadius: BP.posterRadius, style: .continuous).strokeBorder(BP.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
    }

    private func metaRow(details: OEBigPictureArt.Details?) -> some View {
        HStack(spacing: 28) {
            let facts = [details?.genres.first, details?.releaseDate.map { String($0.suffix(4)) }, details?.developer].compactMap { $0 }
            if !facts.isEmpty {
                Text(facts.joined(separator: "  ·  ")).font(BP.callout).foregroundColor(BP.secondary)
            }
            if let stars = game.rating?.intValue, stars > 0 {
                Text(String(repeating: "★", count: min(stars, 5)) + String(repeating: "☆", count: max(5 - stars, 0)))
                    .font(BP.callout).foregroundColor(Color(hex: 0xF5A524))
            }
            let played = game.playedSummary
            if !played.isEmpty {
                Text(played).font(BP.callout).foregroundColor(BP.secondary)
            }
        }
        .lineLimit(1)
    }
}

// MARK: - Shelves

private extension BigPictureLane {
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
                .frame(height: 100, alignment: .bottomLeading)
            }

            let step = (lane.isWide ? 410 : BP.posterSize.width) + BP.gutter
            let shift = model.lane == index ? -CGFloat(max(0, model.column - 4)) * step : 0
            HStack(alignment: .top, spacing: BP.gutter) {
                switch lane.kind {
                case .games(let games):
                    ForEach(Array(games.enumerated()), id: \.offset) { column, game in
                        poster(game, column: column)
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
            .padding(.top, 28)
            .offset(x: shift)
            .animation(.easeOut(duration: 0.2), value: shift)
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
        .frame(width: 410, height: 231).clipped()
        .clipShape(RoundedRectangle(cornerRadius: BP.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BP.cardRadius, style: .continuous).strokeBorder(focused ? BP.focusRing : BP.border, lineWidth: focused ? 5 : 1))
        .scaleEffect(focused ? 1.05 : 1, anchor: .top)
        .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 24, y: 14)
        .animation(.easeOut(duration: 0.12), value: focused)
        .onHover { inside in if inside { model.hover(lane: index, column: column) } }
        .onTapGesture { model.click(lane: index, column: column) }
    }

    private func isFocused(_ column: Int) -> Bool {
        !model.sidebarOpen && model.lane == index && model.column == column
    }

    private func poster(_ game: OEDBGame, column: Int) -> some View {
        let focused = isFocused(column)
        return VStack(alignment: .leading, spacing: 12) {
            BPPoster(game: game, size: BP.posterSize, coverTick: model.coverTick, art: art)
            VStack(alignment: .leading, spacing: 4) {
                Text(game.cleanDisplayName)
                    .font(BP.captionBold).foregroundColor(BP.primary)
                    .lineLimit(1)
                if lane.id == "recent", let played = game.lastPlayed {
                    Text(Self.ago.localizedString(for: played, relativeTo: Date()))
                        .font(BP.caption).foregroundColor(BP.tertiary).lineLimit(1)
                }
            }
            .frame(width: BP.posterSize.width, alignment: .leading)
            .opacity(focused ? 1 : 0.8)
        }
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: BP.posterRadius + 5, style: .continuous)
                .strokeBorder(BP.focusRing, lineWidth: focused ? 5 : 0)
                .frame(width: BP.posterSize.width + 14, height: BP.posterSize.height + 14)
                .offset(y: -7)
        }
        .scaleEffect(focused ? 1.08 : 1, anchor: .top)
        .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 24, y: 14)
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
            .frame(width: 410, height: 231).clipped()
            HStack(spacing: 16) {
                if let cover = state.rom?.game?.boxImage?.image {
                    Image(nsImage: cover).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 56, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(BP.calloutBold).foregroundColor(BP.primary).lineLimit(1)
                    Text(detail).font(BP.caption).foregroundColor(BP.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .frame(width: 410, height: 100, alignment: .leading)
        }
        .background(BP.material)
        .clipShape(RoundedRectangle(cornerRadius: BP.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BP.cardRadius, style: .continuous).strokeBorder(focused ? BP.focusRing : BP.border, lineWidth: focused ? 5 : 1))
        .frame(width: 410, alignment: .leading)
        .scaleEffect(focused ? 1.05 : 1, anchor: .top)
        .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 24, y: 14)
        .animation(.easeOut(duration: 0.12), value: focused)
        .onHover { inside in if inside { model.hover(lane: index, column: column) } }
        .onTapGesture { model.click(lane: index, column: column) }
    }
}

// MARK: - Detail sections

private struct BPDetailSections: View {

    let game: OEDBGame
    @ObservedObject var art: OEBigPictureArt

    var body: some View {
        let details = art.details(for: OEBigPictureArt.GameKey(game))
        VStack(alignment: .leading, spacing: 20) {
            Text("About").font(BP.headline).foregroundColor(BP.primary)
            Text(details?.summary ?? game.gameDescription ?? "No description yet.")
                .font(BP.callout).foregroundColor(BP.secondary)
                .lineSpacing(6).lineLimit(4).frame(width: 980, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
            keyValue("DEVELOPER", details?.developer)
            keyValue("PUBLISHER", details?.publisher)
            keyValue("RELEASED", details?.releaseDate)
            keyValue("GENRE", details.map { $0.genres.joined(separator: " · ") })
            keyValue("PLATFORM", game.systemName)
        }
        .padding(.horizontal, BP.margin)
        .padding(.top, 60)
    }

    @ViewBuilder private func keyValue(_ key: String, _ value: String?) -> some View {
        if let value = value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(key).font(BP.caption).foregroundColor(BP.tertiary).frame(width: 200, alignment: .leading)
                Text(value).font(BP.callout).foregroundColor(BP.primary).lineLimit(2)
            }
        }
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

            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenEmu").font(BP.headline).foregroundColor(BP.primary)
                    Text(model.librarySummary).font(BP.caption).foregroundColor(BP.secondary)
                }
                .frame(height: 96, alignment: .leading).padding(.leading, 28)

                ForEach(Array(model.sidebarEntries.enumerated()), id: \.offset) { index, entry in
                    if index == 4 {
                        Text("SYSTEMS").font(BP.captionBold).tracking(3).foregroundColor(BP.tertiary)
                            .padding(.leading, 28).padding(.top, 24).padding(.bottom, 6)
                    }
                    row(index: index, entry: entry)
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 28)
            .offset(y: -CGFloat(max(0, model.sidebarIndex - 8)) * 78)
            .animation(.easeOut(duration: 0.15), value: model.sidebarIndex)
            .frame(width: BP.sidebarWidth, height: 1056, alignment: .topLeading)
            .clipped()
            .background(BP.material)
            .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 36, style: .continuous).strokeBorder(BP.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 48, y: 12)
            .offset(x: 28, y: 12)
        }
        .frame(width: BP.canvas.width, height: BP.canvas.height)
    }

    private func row(index: Int, entry: BigPictureModel.SidebarEntry) -> some View {
        let focused = model.sidebarIndex == index
        return HStack(spacing: 20) {
            if case .system(let id) = entry {
                ZStack {
                    Circle().fill(LinearGradient(colors: BP.systemColors(id), startPoint: .top, endPoint: .bottom))
                    if let icon = model.systems.first(where: { $0.id == id })?.icon {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).padding(9)
                    }
                }
                .frame(width: 44, height: 44)
            } else {
                Image(systemName: symbol(entry)).font(.system(size: 28)).frame(width: 44)
            }
            Text(title(entry)).font(BP.callout).lineLimit(1)
            Spacer(minLength: 0)
            if case .system(let id) = entry, let count = model.systems.first(where: { $0.id == id })?.count {
                Text("\(count)").font(BP.caption).foregroundColor(focused ? BP.focusText.opacity(0.8) : BP.tertiary)
            }
        }
        .foregroundColor(focused ? BP.focusText : BP.primary)
        .padding(.horizontal, 20)
        .frame(height: 72)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(focused ? BP.focusFill : Color.clear))
        .onTapGesture { model.clickSidebar(index) }
    }
}

// MARK: - Settings

private struct BPSettingsPage: View {

    @ObservedObject var model: BigPictureModel

    private func status(_ on: Bool, detail: String) -> String { on ? "Connected" : detail }

    var body: some View {
        let screenScraper = !(UserDefaults.standard.string(forKey: "ScreenScraperUsername") ?? "").isEmpty && OECredentialStore.shared.has(.screenScraperPassword)
        VStack(alignment: .leading, spacing: 28) {
            Text("Settings").font(BP.headline).foregroundColor(BP.primary).padding(.top, 190)

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
        .padding(.horizontal, 480)
        .frame(width: BP.canvas.width, height: BP.canvas.height, alignment: .topLeading)
    }

    private func group(_ title: String, rows: [(String, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(BP.captionBold).tracking(3).foregroundColor(BP.tertiary).padding(.leading, 8)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.horizontal, 28) }
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.0).font(BP.calloutBold).foregroundColor(BP.primary)
                            Text(row.2).font(BP.caption).foregroundColor(BP.secondary)
                        }
                        Spacer()
                        Text(row.1).font(BP.callout).foregroundColor(row.1 == "Connected" || row.1 == "Always on" ? BP.success : BP.secondary)
                    }
                    .padding(.horizontal, 28).padding(.vertical, 22)
                }
            }
            .background(RoundedRectangle(cornerRadius: BP.cardRadius, style: .continuous).fill(BP.material))
            .overlay(RoundedRectangle(cornerRadius: BP.cardRadius, style: .continuous).strokeBorder(BP.border, lineWidth: 1))
        }
    }
}
