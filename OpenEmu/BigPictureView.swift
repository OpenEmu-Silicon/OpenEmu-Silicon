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

import Cocoa
import SwiftUI
import os
import OpenEmuSystem

// MARK: - Model

enum BigPictureTab: Int, CaseIterable {
    case home, recent, favorites, saveStates, library, search

    var title: String {
        switch self {
        case .home: return "Home"
        case .recent: return "Recent"
        case .favorites: return "Favorites"
        case .saveStates: return "Save States"
        case .library: return "Library"
        case .search: return "Search"
        }
    }
}

extension BigPictureTab {

    /// The tab `delta` steps away, wrapping around at either end. Used by the shoulder buttons.
    static func cycled(from tab: BigPictureTab, by delta: Int) -> BigPictureTab {
        let all = BigPictureTab.allCases
        let index = ((tab.rawValue + delta) % all.count + all.count) % all.count
        return all[index]
    }
}

/// One row of focusable content: the hero's buttons, or a shelf of posters or save states.
struct BigPictureLane: Identifiable {

    enum Kind {
        case heroActions
        case games([OEDBGame])
        case saveStates([OEDBSaveState])
        case genres([BigPictureGenre])
        case filters([BigPictureFilter])
        case keys([BigPictureKey])
        case achievements([BigPictureAchievement])
    }

    let id: String
    let title: String?
    let subtitle: String?
    let kind: Kind
    /// Save-state cards name their game, for lists that span the library.
    var showsGame = false
    /// The game a shelf belongs to (Save States groups by game), shown as a small icon beside the title.
    var game: OEDBGame?
    /// How many pager dots follow the hero buttons as extra stops (Home only).
    var heroDots = 0
    /// Progress through a game's achievements, drawn as a bar under the shelf title.
    var progress: Double?

    var count: Int {
        switch kind {
        case .heroActions: return 2 + heroDots
        case .games(let games): return games.count
        case .saveStates(let states): return states.count
        case .genres(let genres): return genres.count
        case .filters(let filters): return filters.count
        case .keys(let keys): return keys.count
        case .achievements(let items): return items.count
        }
    }
}

/// One button in the filter bar: a drop-down (`menu`), or the Clear button (`menu == nil`).
struct BigPictureFilter: Identifiable {
    let menu: BigPictureModel.FilterMenu?
    let label: String
    let icon: NSImage?
    let active: Bool
    var id: Int { menu?.rawValue ?? 99 }
}

/// One choice inside a drop-down.
struct BigPictureChip: Identifiable {
    enum Action {
        case toggleSystem(String)
        case toggleGenre(String)
        case clear(BigPictureModel.FilterMenu)
        case sort(BigPictureModel.SortOrder)
    }
    let id: String
    let title: String
    let icon: NSImage?
    let selected: Bool
    let action: Action
}

/// A key on the Search tab's on-screen keyboard.
struct BigPictureKey: Identifiable {
    enum Action { case character(Character), space, delete, clear }
    let label: String
    let action: Action
    var id: String { label }
}

/// A group of games that share a genre, for the Browse by Genre tiles.
struct BigPictureGenre: Identifiable {
    let name: String
    let games: [OEDBGame]
    var id: String { name }
}

/// What is on screen and which item is highlighted.
///
/// The highlight lives here as plain (lane, column) numbers rather than in SwiftUI's focus system. That keeps
/// controller navigation predictable on the macOS 12 deployment target, where focus tools are limited.
@MainActor
final class BigPictureModel: ObservableObject {

    enum Screen: Equatable {
        case browse
        case detail(OEDBGame)
        case settings

        static func == (lhs: Screen, rhs: Screen) -> Bool {
            switch (lhs, rhs) {
            case (.browse, .browse), (.settings, .settings): return true
            case (.detail(let a), .detail(let b)): return a.objectID == b.objectID
            default: return false
            }
        }
    }

    enum SidebarEntry: Hashable {
        case tab(BigPictureTab)
        case settings
        case exit
        case system(String)
    }

    struct SystemInfo: Identifiable {
        let id: String
        let name: String
        let icon: NSImage?
        let count: Int
    }

    @Published private(set) var screen = Screen.browse
    @Published private(set) var tab = BigPictureTab.home
    /// A system chosen in the sidebar. Filters the library tab.
    @Published private(set) var systemFilters = Set<String>()
    @Published private(set) var genreFilters = Set<String>()
    @Published private(set) var searchQuery = ""
    @Published private(set) var heroIndex = 0
    /// The game shown in the pause menu while a game runs behind big picture, and the highlighted choice.
    /// What the dialog over the screen is about, if one is open: a running game (Resume or Quit) or leaving big picture.
    enum PauseKind { case game(OEDBGame?), exit }
    @Published private(set) var pauseKind: PauseKind?
    @Published private(set) var pauseIndex = 0
    var onResumeGame: (() -> Void)?
    var onQuitGame: (() -> Void)?
    @Published private(set) var sortOrder = SortOrder.recentlyPlayed

    enum SortOrder: String, CaseIterable {
        case recentlyPlayed = "Recently Played"
        case name = "A–Z"
        case added = "Recently Added"
        case favorites = "Favorites First"
        case rating = "Top Rated"
    }

    enum FilterMenu: Int { case system, genre, sort }
    @Published private(set) var openMenu: FilterMenu?
    @Published private(set) var menuIndex = 0
    @Published private(set) var lanes = [BigPictureLane]()
    /// -1 is the tab bar.
    @Published private(set) var lane = 0
    @Published private(set) var column = 0
    /// Position in the tab bar: 0 is the sidebar button, 1... are the tabs.
    @Published private(set) var tabBarIndex = 1
    /// On a detail page: the view has moved down past the last shelf to the About section.
    @Published private(set) var detailScrolled = false
    @Published private(set) var sidebarOpen = false
    @Published private(set) var sidebarIndex = 0
    @Published private(set) var systems = [SystemInfo]()
    /// Bumped when a cover finishes decoding so cards redraw.
    @Published private(set) var coverTick = 0
    @Published private(set) var lastInput = "—"
    @Published private(set) var controllers = [String]()
    @Published private(set) var gameRunning = false

    var onLaunch: ((OEDBGame) -> Void)?
    var onLaunchState: ((OEDBSaveState) -> Void)?
    var onExit: (() -> Void)?

    /// True while the mouse or trackpad is driving the view. Hovering then only moves the highlight: the page and the
    /// shelves stay where they are, and the wheel scrolls them. Any key or controller press hands the view back to the
    /// highlight, which scrolls it into place the way it always did.
    @Published private(set) var pointerDriven = false
    /// How far the wheel has moved the page beyond where the highlight put it. The page clamps it to its ends.
    @Published private(set) var pageNudge: CGFloat = 0
    @Published private(set) var laneNudges = [Int: CGFloat]()
    private var frozenLane = 0
    private var frozenColumn = 0

    private var allGames = [OEDBGame]()
    private var mouseAnchor = NSEvent.mouseLocation
    private var coverObserver: NSObjectProtocol?

    init() {
        coverObserver = NotificationCenter.default.addObserver(forName: .oeDBImageDidBecomeAvailable, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.coverTick += 1 }
        }
    }

    deinit {
        if let coverObserver = coverObserver { NotificationCenter.default.removeObserver(coverObserver) }
    }

    // MARK: Data

    func reload() {
        guard let database = OELibraryDatabase.default else { return }
        let context = database.mainThreadContext

        let all = OEDBSystem.allSystems(in: context).filter { !$0.games.isEmpty }
        systems = all
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { SystemInfo(id: $0.systemIdentifier, name: $0.name, icon: $0.icon, count: $0.games.count) }
        allGames = all.flatMap { Array($0.games) }

        // Ask for every game's artwork now, so posters do not wait for a card to scroll into view.
        // The games most likely to show first are loaded now; the rest load as their cards appear. Loading is cheap (small
        // saved files, read in the background), so this is about not starting hundreds of first-time lookups at once.
        let eager = Array((sortedByRecent(allGames) + allGames.sorted { ($0.importDate ?? .distantPast) > ($1.importDate ?? .distantPast) }).prefix(40))
        eager.forEach { OEBigPictureArt.shared.load(OEBigPictureArt.GameKey($0)) }

        screen = .browse
        tab = .home
        systemFilters = []
        genreFilters = []
        searchQuery = ""
        sidebarOpen = false
        tabBarIndex = 1
        rebuildLanes()
        lane = lanes.isEmpty ? -1 : 0
        column = 0
    }

    func setControllers(_ names: [String]) { controllers = names }
    func setGameRunning(_ running: Bool) {
        gameRunning = running
        // Back from a game: the one just played is now the most recent, so start the hero on it.
        if !running {
            if case .game? = pauseKind { pauseKind = nil }
            heroIndex = 0
            if tab == .home, screen == .browse { rebuildLanes() }
        }
    }

    private func sortedByRecent(_ games: [OEDBGame]) -> [OEDBGame] {
        games.filter { $0.lastPlayed != nil }.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
    }

    private func byName(_ games: [OEDBGame]) -> [OEDBGame] {
        games.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func grid(_ games: [OEDBGame], id: String, title: String?, subtitle: String?) -> [BigPictureLane] {
        let perRow = 5
        return stride(from: 0, to: games.count, by: perRow).enumerated().map { index, start in
            BigPictureLane(id: "\(id)-\(index)", title: index == 0 ? title : nil, subtitle: index == 0 ? subtitle : nil,
                           kind: .games(Array(games[start..<min(start + perRow, games.count)])))
        }
    }

    private func rebuildLanes() {
        endPointerDriving()
        switch screen {
        case .settings:
            lanes = []
        case .detail(let game):
            var built = [BigPictureLane(id: "actions", title: nil, subtitle: nil, kind: .heroActions)]
            let states = (game.defaultROM?.normalSaveStates ?? []).sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
            if !states.isEmpty {
                built.append(BigPictureLane(id: "states", title: "Save States", subtitle: "\(states.count) saved", kind: .saveStates(states)))
            }
            if let summary = OEBigPictureAchievements.shared.summary(for: game) {
                // Start downloading the badges now, so they are ready when the shelf first draws.
                summary.achievements.forEach { BigPictureRemoteImages.shared.load($0.badgeURL) }
                var lane = BigPictureLane(id: "achievements", title: "Achievements",
                                          subtitle: "\(summary.unlocked) of \(summary.total) earned  ·  \(summary.unlockedPoints) of \(summary.totalPoints) points",
                                          kind: .achievements(summary.achievements))
                lane.progress = summary.total > 0 ? Double(summary.unlocked) / Double(summary.total) : 0
                built.append(lane)
            }
            lanes = built
        case .browse:
            switch tab {
            case .home:
                var built = [BigPictureLane]()
                let recent = sortedByRecent(allGames)
                if !allGames.isEmpty { built.append(BigPictureLane(id: "actions", title: nil, subtitle: nil, kind: .heroActions, heroDots: featured.count > 1 ? featured.count : 0)) }
                if !recent.isEmpty {
                    built.append(BigPictureLane(id: "recent", title: "Continue Playing", subtitle: nil, kind: .games(Array(recent.prefix(20)))))
                }
                // Most Played comes straight after Continue Playing; Recent Saves, the quietest shelf, goes last.
                let mostPlayed = allGames.filter { $0.playTime > 0 }.sorted { $0.playTime > $1.playTime }
                if !mostPlayed.isEmpty {
                    built.append(BigPictureLane(id: "most-played", title: "Most Played", subtitle: nil, kind: .games(Array(mostPlayed.prefix(12)))))
                }
                let groups = Dictionary(grouping: allGames) { genre(of: $0) ?? "" }.filter { !$0.key.isEmpty }
                let tiles = groups
                    .map { BigPictureGenre(name: $0.key, games: byName($0.value)) }
                    .sorted { $0.games.count != $1.games.count ? $0.games.count > $1.games.count : $0.name < $1.name }
                if tiles.count >= 2 {
                    built.append(BigPictureLane(id: "genres", title: "Browse by Genre", subtitle: nil, kind: .genres(Array(tiles.prefix(12)))))
                }
                let added = allGames.filter { $0.importDate != nil }.sorted { ($0.importDate ?? .distantPast) > ($1.importDate ?? .distantPast) }
                if !added.isEmpty {
                    built.append(BigPictureLane(id: "added", title: "Recently Added", subtitle: nil, kind: .games(Array(added.prefix(12)))))
                }
                // A game you put plenty of time into and have not touched for a while.
                var quietDays = 14.0
                #if DEBUG
                if UserDefaults.standard.object(forKey: "OEBigPictureRediscoverDays") != nil { quietDays = UserDefaults.standard.double(forKey: "OEBigPictureRediscoverDays") }
                #endif
                let cutoff = Date().addingTimeInterval(-quietDays * 24 * 3600)
                if let again = mostPlayed.first(where: { ($0.lastPlayed ?? .distantFuture) < cutoff }) {
                    built.append(BigPictureLane(id: "rediscover", title: nil, subtitle: nil, kind: .games([again])))
                }
                let recentStates = allGames
                    .flatMap { $0.defaultROM?.normalSaveStates ?? [] }
                    .sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
                if !recentStates.isEmpty {
                    built.append(BigPictureLane(id: "recent-saves", title: "Recent Saves", subtitle: nil, kind: .saveStates(Array(recentStates.prefix(8))), showsGame: true))
                }
                lanes = built
            case .recent:
                lanes = grid(Array(sortedByRecent(allGames).prefix(60)), id: "recent", title: "Recent", subtitle: nil)
            case .favorites:
                let rated = byName(allGames.filter { ($0.rating?.intValue ?? 0) >= 4 })
                lanes = grid(rated, id: "favorites", title: "Favorites", subtitle: "Games you rated 4 stars or more")
            case .library:
                var inScope = allGames
                if !systemFilters.isEmpty { inScope = inScope.filter { systemFilters.contains($0.system?.systemIdentifier ?? "") } }
                if !genreFilters.isEmpty { inScope = inScope.filter { genreFilters.contains(genre(of: $0) ?? "") } }
                lanes = [filterLane()] + grid(sorted(inScope), id: "library", title: nil, subtitle: nil)
            case .saveStates:
                var withSaves = allGames.filter { !($0.defaultROM?.normalSaveStates.isEmpty ?? true) }
                if !systemFilters.isEmpty { withSaves = withSaves.filter { systemFilters.contains($0.system?.systemIdentifier ?? "") } }
                if !genreFilters.isEmpty { withSaves = withSaves.filter { genreFilters.contains(genre(of: $0) ?? "") } }
                // Same sort choices as the Library, applied to the games; each game's own saves stay newest first.
                let groups = sorted(withSaves).map { game -> (game: OEDBGame, states: [OEDBSaveState]) in
                    (game, Array(game.defaultROM?.normalSaveStates ?? []).sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) })
                }
                lanes = [filterLane()] + groups.map { group in
                    let count = group.states.count == 1 ? "1 save" : "\(group.states.count) saves"
                    return BigPictureLane(id: "game-\(group.game.objectID.uriRepresentation().absoluteString)",
                                          title: group.game.cleanDisplayName,
                                          subtitle: [group.game.system?.name, count].compactMap { $0 }.joined(separator: " · "),
                                          kind: .saveStates(group.states), game: group.game)
                }
            case .search:
                lanes = searchLanes()
            }
        }
    }

    // MARK: Derived

    /// The game the hero describes: the game being viewed on a game page, otherwise the featured game. The hero
    /// does not follow the highlight on the shelves below; it only changes with its own pager dots.
    var heroGame: OEDBGame? {
        if case .detail(let game) = screen { return game }
        let featured = self.featured
        if !featured.isEmpty { return featured[heroIndex % featured.count] }
        return byName(allGames).first
    }

    /// The games the hero rotates through.
    var featured: [OEDBGame] { Array(sortedByRecent(allGames).prefix(5)) }

    /// True when the hero shows a featured game (and its pager dots) rather than a game page.
    var heroIsFeatured: Bool {
        if case .detail = screen { return false }
        return true
    }

    /// True while the highlight is on one of the hero's pager dots; the hero then stops rotating by itself.
    var heroDotFocused: Bool {
        guard lane >= 0, lanes.indices.contains(lane), case .heroActions = lanes[lane].kind else { return false }
        return column >= 2
    }

    func advanceHero() {
        guard tab == .home, screen == .browse, !gameRunning, openMenu == nil, !sidebarOpen, heroIsFeatured, !heroDotFocused,
              featured.count > 1 else { return }
        heroIndex = (heroIndex + 1) % featured.count
    }

    var sidebarEntries: [SidebarEntry] {
        [.tab(.home), .tab(.recent), .tab(.favorites), .settings, .exit] + systems.map { .system($0.id) }
    }

    /// "77 games · 18 systems", for the sidebar header.
    var librarySummary: String {
        "\(allGames.count) \(allGames.count == 1 ? "game" : "games") · \(systems.count) \(systems.count == 1 ? "system" : "systems")"
    }

    var isTabBarFocused: Bool { lane < 0 && !sidebarOpen }

    // MARK: Navigation

    /// Handles an action from any input device.
    func perform(_ action: BigPictureAction, source: String) {
        lastInput = "\(action.rawValue)  ·  \(source)"
        mouseAnchor = NSEvent.mouseLocation
        if source != "mouse" { endPointerDriving() }

        if pauseKind != nil { performPause(action); return }
        if openMenu != nil { performMenu(action); return }
        if sidebarOpen { performSidebar(action); return }

        switch action {
        case .up: moveLane(-1)
        case .down: moveLane(1)
        case .left: moveColumn(-1)
        case .right: moveColumn(1)
        case .tabPrevious: switchTab(by: -1)
        case .tabNext: switchTab(by: 1)
        case .delete: if isSearching { deleteSearch() }
        case .select: activate()
        case .back: goBack()
        case .menu: openSidebar()
        case .home: break
        }
    }

    private func performSidebar(_ action: BigPictureAction) {
        let entries = sidebarEntries
        switch action {
        case .up: sidebarIndex = max(sidebarIndex - 1, 0)
        case .down: sidebarIndex = min(sidebarIndex + 1, entries.count - 1)
        case .select: chooseSidebar(entries[sidebarIndex])
        case .back, .menu, .right: sidebarOpen = false
        case .tabPrevious: sidebarOpen = false; switchTab(by: -1)
        case .tabNext: sidebarOpen = false; switchTab(by: 1)
        default: break
        }
    }

    private func chooseSidebar(_ entry: SidebarEntry) {
        sidebarOpen = false
        switch entry {
        case .tab(let tab): show(tab: tab, system: nil)
        case .system(let id): show(tab: .library, system: id)
        case .exit: onExit?()
        case .settings:
            screen = .settings
            lanes = []
            lane = 0
            column = 0
        }
    }

    private func sorted(_ games: [OEDBGame]) -> [OEDBGame] {
        switch sortOrder {
        case .recentlyPlayed:
            return games.sorted { ($0.lastPlayed ?? .distantPast) != ($1.lastPlayed ?? .distantPast)
                ? ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast)
                : $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .name:
            return byName(games)
        case .added:
            return games.sorted { ($0.importDate ?? .distantPast) > ($1.importDate ?? .distantPast) }
        case .favorites:
            func loved(_ game: OEDBGame) -> Bool { (game.rating?.intValue ?? 0) >= 4 }
            return games.sorted { loved($0) != loved($1) ? loved($0) : ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        case .rating:
            return games.sorted { ($0.rating?.intValue ?? 0) != ($1.rating?.intValue ?? 0)
                ? ($0.rating?.intValue ?? 0) > ($1.rating?.intValue ?? 0)
                : $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
    }

    // MARK: Filters

    /// The drop-downs for the tab being shown. Library filters by system and genre; Save States by system and game.
    var filterMenus: [FilterMenu] { [.system, .genre, .sort] }

    var hasActiveFilters: Bool {
        !systemFilters.isEmpty || !genreFilters.isEmpty || sortOrder != .recentlyPlayed
    }

    private func filterLane() -> BigPictureLane {
        func summary(_ names: [String], none: String, many: String) -> String {
            names.isEmpty ? none : (names.count == 1 ? names[0] : "\(names.count) \(many)")
        }
        var items = filterMenus.map { menu -> BigPictureFilter in
            switch menu {
            case .system:
                let chosen = systems.filter { systemFilters.contains($0.id) }
                return BigPictureFilter(menu: menu, label: summary(chosen.map { $0.name }, none: "All Systems", many: "Systems"),
                                        icon: chosen.count == 1 ? chosen[0].icon : nil, active: !chosen.isEmpty)
            case .genre:
                return BigPictureFilter(menu: menu, label: summary(genreFilters.sorted(), none: "Any Genre", many: "Genres"),
                                        icon: nil, active: !genreFilters.isEmpty)
            case .sort:
                return BigPictureFilter(menu: menu, label: sortOrder.rawValue, icon: nil, active: false)
            }
        }
        if hasActiveFilters { items.append(BigPictureFilter(menu: nil, label: "Clear", icon: nil, active: false)) }
        return BigPictureLane(id: "filters", title: nil, subtitle: nil, kind: .filters(items))
    }

    /// What a drop-down offers, with the current choices marked. System and genre stack; sort picks one.
    func menuOptions(_ menu: FilterMenu) -> [BigPictureChip] {
        switch menu {
        case .system:
            return [BigPictureChip(id: "sys-all", title: "All Systems", icon: nil, selected: systemFilters.isEmpty, action: .clear(.system))]
                + systems.map { BigPictureChip(id: "sys-\($0.id)", title: $0.name, icon: $0.icon, selected: systemFilters.contains($0.id), action: .toggleSystem($0.id)) }
        case .genre:
            // Only genres that exist among what this tab lists (Save States lists games with saves).
            var scope = tab == .saveStates ? allGames.filter { !($0.defaultROM?.normalSaveStates.isEmpty ?? true) } : allGames
            if !systemFilters.isEmpty { scope = scope.filter { systemFilters.contains($0.system?.systemIdentifier ?? "") } }
            let names = Set(scope.compactMap { genre(of: $0) }).sorted()
            return [BigPictureChip(id: "genre-all", title: "Any Genre", icon: nil, selected: genreFilters.isEmpty, action: .clear(.genre))]
                + names.map { BigPictureChip(id: "genre-\($0)", title: $0, icon: nil, selected: genreFilters.contains($0), action: .toggleGenre($0)) }
        case .sort:
            return SortOrder.allCases.map { BigPictureChip(id: "sort-\($0.rawValue)", title: $0.rawValue, icon: nil, selected: sortOrder == $0, action: .sort($0)) }
        }
    }

    private func apply(_ action: BigPictureChip.Action) {
        func toggle<T: Hashable>(_ set: inout Set<T>, _ value: T) {
            if set.contains(value) { set.remove(value) } else { set.insert(value) }
        }
        switch action {
        case .toggleSystem(let id): toggle(&systemFilters, id)
        case .toggleGenre(let name): toggle(&genreFilters, name)
        case .clear(let menu):
            switch menu {
            case .system: systemFilters = []
            case .genre: genreFilters = []
            case .sort: sortOrder = .recentlyPlayed
            }
        case .sort(let order): sortOrder = order
        }
        rebuildLanes()
    }

    /// Turns every filter off and puts the sort back to its default.
    func clearFilters() {
        systemFilters = []; genreFilters = []
        sortOrder = .recentlyPlayed
        rebuildLanes()
        column = min(column, max((lanes.indices.contains(lane) ? lanes[lane].count : 1) - 1, 0))
    }

    func openFilterMenu(_ menu: FilterMenu) {
        let options = menuOptions(menu)
        menuIndex = options.firstIndex { $0.selected && !({ if case .clear = $0.action { return true } else { return false } }($0)) } ?? 0
        openMenu = menu
    }

    func closeFilterMenu() { openMenu = nil }

    /// Choosing in a stacking drop-down keeps it open so several can be ticked; sort closes it.
    func clickMenu(_ index: Int) {
        guard let menu = openMenu, menuOptions(menu).indices.contains(index) else { return }
        apply(menuOptions(menu)[index].action)
        if menu == .sort { openMenu = nil }
        else { menuIndex = min(index, max(menuOptions(menu).count - 1, 0)) }
    }

    private func performMenu(_ action: BigPictureAction) {
        guard let menu = openMenu else { return }
        let options = menuOptions(menu)
        switch action {
        case .up: menuIndex = max(menuIndex - 1, 0)
        case .down: menuIndex = min(menuIndex + 1, options.count - 1)
        case .select: clickMenu(menuIndex)
        case .back, .menu, .left, .right: openMenu = nil
        case .tabPrevious: openMenu = nil; switchTab(by: -1)
        case .tabNext: openMenu = nil; switchTab(by: 1)
        default: break
        }
    }

    // MARK: Search

    var isSearching: Bool { tab == .search && screen == .browse && !sidebarOpen && openMenu == nil }

    func typeSearch(_ character: Character) { searchQuery.append(character); refreshSearch() }
    func deleteSearch() { if !searchQuery.isEmpty { searchQuery.removeLast(); refreshSearch() } }
    func clearSearch() { searchQuery = ""; refreshSearch() }

    private func refreshSearch() {
        rebuildLanes()
        column = min(column, max((lanes.indices.contains(lane) ? lanes[lane].count : 1) - 1, 0))
    }

    private func searchLanes() -> [BigPictureLane] {
        func row(_ letters: String) -> [BigPictureKey] { letters.map { BigPictureKey(label: String($0), action: .character($0)) } }
        var third = row("0123456789")
        third += [BigPictureKey(label: "Space", action: .space), BigPictureKey(label: "Delete", action: .delete), BigPictureKey(label: "Clear", action: .clear)]
        var built = [
            BigPictureLane(id: "keys-1", title: "Search", subtitle: searchQuery.isEmpty ? "Type, or choose letters" : "\u{201C}\(searchQuery)\u{201D}", kind: .keys(row("ABCDEFGHIJKLM"))),
            BigPictureLane(id: "keys-2", title: nil, subtitle: nil, kind: .keys(row("NOPQRSTUVWXYZ"))),
            BigPictureLane(id: "keys-3", title: nil, subtitle: nil, kind: .keys(third)),
        ]
        let needle = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            let matches = byName(allGames.filter { $0.displayName.lowercased().contains(needle) || ($0.system?.name.lowercased().contains(needle) ?? false) })
            built += grid(matches, id: "results", title: "Results", subtitle: matches.count == 1 ? "1 game" : "\(matches.count) games")
        }
        return built
    }

    /// True when a tab that normally lists games or saves has nothing to show under its filter bar or keyboard.
    var hasNoItems: Bool {
        lanes.allSatisfy { lane in
            switch lane.kind {
            case .filters, .keys: return true
            default: return false
            }
        }
    }

    /// The game's main genre, from OpenVGDB.
    private func genre(of game: OEDBGame) -> String? {
        OEBigPictureArt.shared.details(for: OEBigPictureArt.GameKey(game))?.primaryGenre
    }

    private func show(tab newTab: BigPictureTab, system: String?, genre: String? = nil) {
        detailScrolled = false
        screen = .browse
        tab = newTab
        systemFilters = system.map { [$0] } ?? []
        genreFilters = genre.map { [$0] } ?? []
        tabBarIndex = newTab.rawValue + 1
        rebuildLanes()
        // Start on the games (or the keyboard), not the filter bar.
        lane = lanes.isEmpty ? -1 : (lanes.firstIndex { if case .filters = $0.kind { return false } else { return true } } ?? 0)
        column = 0
    }

    func openSidebar() {
        sidebarIndex = sidebarEntries.firstIndex(of: screen == .settings ? .settings : .tab(tab)) ?? 0
        sidebarOpen = true
    }

    /// Shoulder buttons: move to the next or previous tab from wherever you are (a game page, a menu, the keyboard).
    /// The filters you set stay as they were, and the highlight stays on the tab bar if that is where it was.
    func switchTab(by delta: Int) {
        let wasOnTabBar = lane < 0
        let kept = (systemFilters, genreFilters)
        show(tab: BigPictureTab.cycled(from: tab, by: delta), system: nil)
        systemFilters = kept.0
        genreFilters = kept.1
        rebuildLanes()
        if wasOnTabBar {
            lane = -1
        } else {
            lane = lanes.firstIndex { if case .filters = $0.kind { return false } else { return true } } ?? (lanes.isEmpty ? -1 : 0)
        }
        column = 0
    }

    // MARK: Pause menu

    /// Opens the pause menu (a game is running behind big picture).
    func showPauseMenu(for game: OEDBGame?) {
        sidebarOpen = false
        openMenu = nil
        pauseIndex = 0
        pauseKind = .game(game ?? heroGame)
    }

    /// Opens "Exit Big Picture?", the same dialog design for leaving the mode.
    func showExitDialog() {
        sidebarOpen = false
        openMenu = nil
        pauseIndex = 0
        pauseKind = .exit
    }

    func closePauseMenu() { pauseKind = nil }

    private func performPause(_ action: BigPictureAction) {
        switch action {
        case .up: pauseIndex = max(pauseIndex - 1, 0)
        case .down: pauseIndex = min(pauseIndex + 1, 1)
        case .select: choosePause(pauseIndex)
        case .back, .menu, .home: choosePause(0)
        default: break
        }
    }

    /// Choice 0 is the safe one (Resume Game, or stay), choice 1 is Quit Game or Exit Big Picture.
    func choosePause(_ index: Int) {
        let kind = pauseKind
        pauseKind = nil
        switch kind {
        case .game?: if index == 0 { onResumeGame?() } else { onQuitGame?() }
        case .exit?: if index == 1 { onExit?() }
        case nil: break
        }
    }

    private func moveLane(_ delta: Int) {
        if screen == .settings {
            if delta < 0 { return }
            return
        }
        let target = lane + delta
        if case .detail = screen {
            if delta > 0, target >= lanes.count, !detailScrolled { detailScrolled = true; return }
            if delta < 0, detailScrolled { detailScrolled = false; return }
        }
        if target < 0 {
            guard lane >= 0 else { return }
            lane = -1
            return
        }
        guard target < lanes.count else { return }
        lane = target
        column = min(column, max(lanes[target].count - 1, 0))
    }

    private func moveColumn(_ delta: Int) {
        if lane < 0 {
            let target = min(max(tabBarIndex + delta, 0), BigPictureTab.allCases.count)
            guard target != tabBarIndex else { return }
            tabBarIndex = target
            if target > 0, let newTab = BigPictureTab(rawValue: target - 1), newTab != tab || screen != .browse {
                show(tab: newTab, system: nil)
                lane = -1
            }
            return
        }
        guard lanes.indices.contains(lane) else { return }
        column = min(max(column + delta, 0), max(lanes[lane].count - 1, 0))
        // Landing on a pager dot shows that featured game.
        if case .heroActions = lanes[lane].kind, column >= 2 { heroIndex = column - 2 }
    }

    private func goBack() {
        switch screen {
        case .detail, .settings:
            detailScrolled = false
            screen = .browse
            rebuildLanes()
            lane = lanes.isEmpty ? -1 : 0
            column = 0
        case .browse:
            if lane >= 0 && tab != .home {
                show(tab: .home, system: nil)
            } else if lane >= 0 {
                lane = -1
            } else {
                onExit?()
            }
        }
    }

    private func activate() {
        if lane < 0 {
            if tabBarIndex == 0 { openSidebar() }
            else if !lanes.isEmpty { lane = 0; column = 0 }
            return
        }
        guard lanes.indices.contains(lane) else { return }
        switch lanes[lane].kind {
        case .heroActions:
            if column >= 2 { heroIndex = column - 2; return }
            guard let game = heroGame else { return }
            if column == 0 { onLaunch?(game) }
            else if case .detail = screen, lanes.indices.contains(1) { lane = 1; column = 0 }   // jump to this game's saves
            else { open(game) }
        case .games(let games):
            guard games.indices.contains(column) else { return }
            // The Rediscover banner says "Play Now": it launches the game; every other shelf opens its page.
            if lanes[lane].id == "rediscover" { onLaunch?(games[column]) } else { open(games[column]) }
        case .achievements:
            return
        case .saveStates(let states):
            guard states.indices.contains(column) else { return }
            onLaunchState?(states[column])
        case .genres(let genres):
            guard genres.indices.contains(column) else { return }
            show(tab: .library, system: nil, genre: genres[column].name)
        case .filters(let filters):
            guard filters.indices.contains(column) else { return }
            if let menu = filters[column].menu { openFilterMenu(menu) } else { clearFilters() }
        case .keys(let keys):
            guard keys.indices.contains(column) else { return }
            switch keys[column].action {
            case .character(let character): typeSearch(character)
            case .space: typeSearch(" ")
            case .delete: deleteSearch()
            case .clear: clearSearch()
            }
        }
    }

    private func open(_ game: OEDBGame) {
        detailScrolled = false
        screen = .detail(game)
        rebuildLanes()
        lane = 0
        column = 0
    }

    /// The lane and column the page and shelves are positioned from: the highlight, unless the pointer is driving.
    var viewLane: Int { pointerDriven ? frozenLane : lane }
    var viewColumn: Int { pointerDriven ? frozenColumn : column }

    private func beginPointerDriving() {
        guard !pointerDriven else { return }
        frozenLane = lane
        frozenColumn = column
        pointerDriven = true
    }

    private func endPointerDriving() {
        pointerDriven = false
        pageNudge = 0
        if !laneNudges.isEmpty { laneNudges = [:] }
    }

    /// Mouse hover moves the highlight, but only when the pointer really moved, and never scrolls anything.
    /// Without the check, items scrolling under a resting pointer would steal the highlight from the controller.
    func hover(lane newLane: Int, column newColumn: Int) {
        let location = NSEvent.mouseLocation
        guard hypot(location.x - mouseAnchor.x, location.y - mouseAnchor.y) > 4 else { return }
        mouseAnchor = location
        beginPointerDriving()
        lane = newLane
        column = newColumn
        lastInput = "hover  ·  mouse"
    }

    #if DEBUG
    /// Hover without the "pointer really moved" check, for the play-test driver.
    func playtestHover(lane newLane: Int, column newColumn: Int) {
        beginPointerDriving()
        lane = newLane
        column = newColumn
        lastInput = "hover  ·  playtest"
    }
    #endif

    func click(lane newLane: Int, column newColumn: Int) {
        beginPointerDriving()
        lane = newLane
        column = newColumn
        lastInput = "click  ·  mouse"
        activate()
    }

    /// Whether the wheel can move the page right now (not under a menu, the sidebar, the pause menu or a running game).
    var acceptsScrolling: Bool {
        !gameRunning && openMenu == nil && !sidebarOpen && pauseKind == nil && screen != .settings && !lanes.isEmpty
    }

    /// Wheel or trackpad, vertical: positive moves the page down, in design-canvas points.
    func scrollPage(by delta: CGFloat) {
        guard acceptsScrolling else { return }
        beginPointerDriving()
        pageNudge += delta
    }

    /// Called by the page when it clamped the nudge to the ends of its content.
    func setPageNudge(_ value: CGFloat) { pageNudge = value }

    /// Where the highlight alone puts a shelf, and the furthest it can slide.
    private func shiftRange(_ index: Int) -> (base: CGFloat, limit: CGFloat) {
        let shelf = lanes[index]
        let step = shelf.itemWidth + shelf.itemGap
        let base = index == viewLane ? -CGFloat(max(0, viewColumn - (shelf.visibleColumns - 1))) * step : 0
        return (base, CGFloat(max(0, shelf.count - shelf.visibleColumns)) * step)
    }

    /// How far a shelf is slid to the left: the highlight's position, or the highlight's plus the wheel's.
    func laneShift(_ index: Int) -> CGFloat {
        guard lanes.indices.contains(index) else { return 0 }
        let range = shiftRange(index)
        return min(0, max(-range.limit, range.base + (laneNudges[index] ?? 0)))
    }

    /// Trackpad or wheel, horizontal, over the shelf the pointer is on: positive moves the items to the right.
    func scrollLane(by delta: CGFloat) {
        guard acceptsScrolling else { return }
        beginPointerDriving()
        guard lanes.indices.contains(lane) else { return }
        let range = shiftRange(lane)
        laneNudges[lane] = min(0, max(-range.limit, laneShift(lane) + delta)) - range.base
    }

    func clickTab(_ index: Int) {
        tabBarIndex = index
        lane = -1
        if index == 0 { openSidebar() }
        else if let newTab = BigPictureTab(rawValue: index - 1) { show(tab: newTab, system: nil); lane = -1 }
    }

    func clickSidebar(_ index: Int) {
        let entries = sidebarEntries
        guard entries.indices.contains(index) else { return }
        sidebarIndex = index
        chooseSidebar(entries[index])
    }
}

// MARK: - Window

/// Draws edge to edge. Without this the notch's safe area pushes the design down and clips its bottom.
private final class BigPictureHostingView<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var safeAreaRect: NSRect { bounds }
}

/// The pause menu's window. Borderless windows refuse key status by default, and this one needs it for the keyboard.
private final class BigPicturePauseWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class BigPictureWindow: NSWindow {
    // Borderless windows refuse key status by default.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns the fullscreen big-picture window, the input layer, and the hand-off to and from a running game.
@MainActor
final class BigPictureWindowController: NSWindowController, NSWindowDelegate {

    static let shared = BigPictureWindowController()

    private let model = BigPictureModel()
    private let input = BigPictureInput()
    private let gestures = BigPictureSystemGestures()
    private weak var pausedDocument: OEGameDocument?
    /// The pause menu, drawn in its own window on top of the running game.
    private var pauseOverlay: NSWindow?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var closeObserver: NSObjectProtocol?
    private var launchedFromBigPicture = false
    /// Keys typed into the quit confirmation or the closing game must not land on the menu and leave the mode.
    private var ignoreInputUntil = Date.distantPast

    private init() {
        // A normal window that goes native fullscreen, so big picture is its own Space like a fullscreen game or app:
        // it shows in Mission Control, Cmd-Tab and the Space switcher, and the desktop stays reachable if it hangs.
        let window = BigPictureWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
        window.backgroundColor = NSColor(red: 0.039, green: 0.039, blue: 0.047, alpha: 1)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.title = "Big Picture"
        window.identifier = NSUserInterfaceItemIdentifier("BigPictureWindow")
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        super.init(window: window)

        window.delegate = self
        window.contentView = BigPictureHostingView(rootView: BigPictureView(model: model))

        model.onLaunch = { [weak self] game in
            self?.launch { handler in GameDocumentController.shared.openGameDocument(with: game, display: true, fullScreen: true, completionHandler: handler) }
        }
        model.onLaunchState = { [weak self] state in
            self?.launch { handler in GameDocumentController.shared.openGameDocument(with: state, display: true, fullScreen: true, completionHandler: handler) }
        }
        model.onExit = { [weak self] in self?.hide() }
        model.onResumeGame = { [weak self] in self?.resumeGame() }
        model.onQuitGame = { [weak self] in self?.quitGame() }

        input.isActive = { [weak self] in self?.interactive ?? false }
        input.onControllersChanged = { [weak self] in self?.refreshControllers() }
        input.onAction = { [weak self] action, source in self?.handle(action, source: source) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// True while big picture, or the pause menu over a game, is the window receiving input.
    private var interactive: Bool {
        window?.isKeyWindow == true || pauseOverlay?.isKeyWindow == true
    }

    var isShown: Bool { window?.isVisible ?? false }

    func toggle() {
        isShown ? hide() : show()
    }

    func show() {
        guard let window = window else { return }

        model.reload()
        refreshControllers()

        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        if !window.isVisible { window.setFrame(screen.visibleFrame, display: true) }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }

        input.start()
        gestures.claim()
        installKeyMonitor()
        installScrollMonitor()
        startWatchingForGameEnd()
    }

    func hide() {
        input.releaseAll()
        input.stop()
        gestures.release()
        removeKeyMonitor()
        removeScrollMonitor()
        stopWatchingForGameEnd()
        dismissPauseOverlay()
        launchedFromBigPicture = false
        model.setGameRunning(false)
        // Closing a fullscreen window leaves its Space.
        window?.close()
    }

    // MARK: Actions

    private func handle(_ action: BigPictureAction, source: String) {
        if Date() < ignoreInputUntil, action != .home { return }
        if action == .home {
            if model.pauseKind != nil {
                // A second press while a dialog is up closes it (Resume Game, or stay in big picture).
                model.perform(.back, source: source)
            } else if launchedFromBigPicture, !GameDocumentController.shared.gameDocuments.isEmpty {
                returnFromGame(source: source)
            } else if window?.isKeyWindow == true {
                model.showExitDialog()
            }
            return
        }
        model.perform(action, source: source)
    }

    private func refreshControllers() {
        model.setControllers(input.connectedControllerNames)
    }

    // MARK: Launching a game and coming back

    private func launch(_ open: (@escaping (OEGameDocument?, Error?) -> Void) -> Void) {
        launchedFromBigPicture = true
        model.setGameRunning(true)

        open { [weak self] document, error in
            guard let self = self else { return }
            if document == nil {
                os_log(.error, log: .default, "Big picture could not start game: %{public}@", String(describing: error))
                self.launchedFromBigPicture = false
                self.model.setGameRunning(false)
                return
            }
            // The game opens in its own fullscreen Space and owns the controller. Big picture stays in its Space behind it.
            self.input.releaseAll()
        }
    }

    /// Home or the Start + Select hold while a game runs: pause it and show the pause menu (Resume or Quit Game) over
    /// the game itself, so a controller alone can get out of a game.
    ///
    /// The menu is a window on top of the game window, in the game's own Space. Going to and from big picture's Space
    /// to show it was unreliable: Resume could leave the player looking at the library while the game ran unseen.
    private func returnFromGame(source: String) {
        guard launchedFromBigPicture, pauseOverlay == nil,
              let document = GameDocumentController.shared.gameDocuments.first,
              let gameWindow = document.windowControllers.first?.window else {
            os_log(.default, log: .default, "Big picture: pause menu not opened (no running game window)")
            return
        }
        os_log(.default, log: .default, "Big picture: pause menu opened over the game")
        pausedDocument = document
        document.requestEmulationPauseRespectingRetroAchievementsHardcore(showBlockedToast: false)
        model.showPauseMenu(for: document.rom.game)

        let overlay = BigPicturePauseWindow(contentRect: gameWindow.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.isReleasedWhenClosed = false
        overlay.contentView = BigPictureHostingView(rootView: BigPicturePauseRoot(model: model))
        overlay.setFrame(gameWindow.frame, display: true)
        gameWindow.addChildWindow(overlay, ordered: .above)
        overlay.makeKeyAndOrderFront(nil)
        pauseOverlay = overlay
    }

    private func dismissPauseOverlay() {
        guard let overlay = pauseOverlay else { return }
        overlay.parent?.removeChildWindow(overlay)
        overlay.orderOut(nil)
        pauseOverlay = nil
    }

    private func resumeGame() {
        os_log(.default, log: .default, "Big picture: resuming the game")
        dismissPauseOverlay()
        guard let document = pausedDocument ?? GameDocumentController.shared.gameDocuments.first else { return }
        pausedDocument = nil
        document.isEmulationPaused = false
        document.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
        // If the game is somehow still paused a moment later, say so in the log instead of leaving it silent.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak document] in
            if let document = document, document.isEmulationPaused {
                os_log(.error, log: .default, "Big picture: the game is still paused after Resume Game")
            }
        }
    }

    /// Closes the game without the "Are you sure?" alert, which a controller cannot answer. Choosing Quit Game in the
    /// pause menu is the confirmation, and the auto save is still written.
    private func quitGame() {
        os_log(.default, log: .default, "Big picture: quitting the game from the pause menu")
        dismissPauseOverlay()
        guard let document = pausedDocument ?? GameDocumentController.shared.gameDocuments.first else { return }
        pausedDocument = nil
        document.stopEmulationWithoutConfirmation()
    }

    /// When the last game window closes, return to the menu.
    private func startWatchingForGameEnd() {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            // `queue: .main` runs this on the main thread.
            MainActor.assumeIsolated {
                guard let self = self, self.launchedFromBigPicture, note.object as? NSWindow !== self.window else { return }
                // Let the document finish tearing down, and the game's fullscreen Space finish closing, before checking.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    MainActor.assumeIsolated { self.showAfterGameEnded() }
                }
            }
        }
    }

    private func stopWatchingForGameEnd() {
        if let closeObserver = closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }

    private func showAfterGameEnded() {
        dismissPauseOverlay()
        guard launchedFromBigPicture, GameDocumentController.shared.gameDocuments.isEmpty, let window = window else { return }
        launchedFromBigPicture = false
        ignoreInputUntil = Date().addingTimeInterval(1.5)
        model.setGameRunning(false)
        // macOS usually returns to the menu's Space by itself when the game's Space closes; this covers the rest.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        input.start()
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self = self, self.interactive else { return event }
                if Date() < self.ignoreInputUntil { return nil }
                // On the Search tab, letters and digits type into the search box.
                if self.model.isSearching, event.modifierFlags.intersection([.command, .control]).isEmpty {
                    if event.keyCode == 51 { self.model.deleteSearch(); return nil }
                    if let typed = event.charactersIgnoringModifiers, typed.count == 1, let character = typed.first,
                       character.isLetter || character.isNumber || character == " " {
                        self.model.typeSearch(Character(character.uppercased()))
                        return nil
                    }
                }
                let action: BigPictureAction?
                switch event.keyCode {
                case 126: action = .up
                case 125: action = .down
                case 123: action = .left
                case 124: action = .right
                case 36, 76: action = .select
                case 53: action = .back
                case 46: action = .menu
                case 48: action = event.modifierFlags.contains(.shift) ? .tabPrevious : .tabNext
                default: action = nil
                }
                guard let action = action else { return event }
                self.model.perform(action, source: "keyboard")
                return nil
            }
        }
    }

    /// Mouse wheel and trackpad scroll the page and the shelf under the pointer, like any other scrolling view.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self = self, self.window?.isKeyWindow == true, event.window === self.window,
                      let width = self.window?.contentView?.bounds.width, width > 0, self.model.acceptsScrolling else { return event }
                // Trackpads report points on screen; a wheel reports lines, which are worth about ten points each.
                let unit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                // The design is drawn on a fixed-width canvas that is scaled to the window.
                let scale = width / BP.canvas.width
                let dx = event.scrollingDeltaX * unit / scale
                let dy = event.scrollingDeltaY * unit / scale
                if abs(dx) > abs(dy) {
                    self.model.scrollLane(by: dx)
                } else {
                    // A positive delta means the content moves down, which is the page moving up.
                    self.model.scrollPage(by: -dy)
                }
                return nil
            }
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor = scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    private func removeKeyMonitor() {
        if let keyMonitor = keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    #if DEBUG
    // MARK: Play-test hooks (PlaytestDriver)

    /// "scroll:<points>" and "hscroll:<points>" move the page or the shelf under the pointer as the wheel would;
    /// "hover:<lane>:<column>" moves the pointer onto a card.
    func playtestPointer(_ step: String) {
        let parts = step.split(separator: ":").map(String.init)
        switch parts.first {
        case "scroll": model.scrollPage(by: CGFloat(Double(parts.dropFirst().first ?? "") ?? 0))
        case "hscroll": model.scrollLane(by: CGFloat(Double(parts.dropFirst().first ?? "") ?? 0))
        case "hover": model.playtestHover(lane: Int(parts.dropFirst().first ?? "") ?? 0, column: Int(parts.dropFirst(2).first ?? "") ?? 0)
        default: break
        }
    }

    /// Sends one action ("up", "select", "back", ...) as if it came from a controller.
    func playtestPerform(_ name: String) {
        guard let action = BigPictureAction(rawValue: name) else { return }
        model.perform(action, source: "playtest")
    }

    /// How the window sits on its screen, for the play-test driver: "fullscreen window=WxH screen=WxH visible=WxH".
    func playtestGeometry() -> String {
        guard let window = window else { return "no window" }
        let screen = window.screen
        func size(_ rect: NSRect?) -> String { rect.map { "\(Int($0.width))x\(Int($0.height))" } ?? "none" }
        return "\(window.styleMask.contains(.fullScreen) ? "fullscreen" : "NOT-fullscreen") window=\(size(window.frame)) content=\(size(window.contentView?.frame)) screen=\(size(screen?.frame)) screens=\(NSScreen.screens.count)"
    }

    /// The window the pause menu is drawn in, while it is open.
    var playtestPauseOverlay: NSWindow? { pauseOverlay }

    /// The Home button, as the window controller handles it while a game runs.
    func playtestHome() { handle(.home, source: "playtest") }

    /// A picture of the big-picture window as it is on screen.
    func playtestSnapshot() -> NSImage? {
        guard let window = pauseOverlay ?? window,
              let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]) else { return nil }
        return NSImage(cgImage: image, size: window.frame.size)
    }
    #endif

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        input.releaseAll()
    }

    /// Closed with the red button or Cmd-W: leave the mode cleanly.
    func windowWillClose(_ notification: Notification) {
        input.releaseAll()
        input.stop()
        removeKeyMonitor()
        removeScrollMonitor()
        stopWatchingForGameEnd()
        launchedFromBigPicture = false
        model.setGameRunning(false)
    }
}
