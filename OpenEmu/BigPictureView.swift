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

/// One row of focusable content: the hero's buttons, or a shelf of posters or save states.
struct BigPictureLane: Identifiable {

    enum Kind {
        case heroActions
        case games([OEDBGame])
        case saveStates([OEDBSaveState])
        case genres([BigPictureGenre])
    }

    let id: String
    let title: String?
    let subtitle: String?
    let kind: Kind
    /// Save-state cards name their game, for lists that span the library.
    var showsGame = false

    var count: Int {
        switch kind {
        case .heroActions: return 2
        case .games(let games): return games.count
        case .saveStates(let states): return states.count
        case .genres(let genres): return genres.count
        }
    }
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
    @Published private(set) var systemFilter: String?
    @Published private(set) var genreFilter: String?
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
        allGames.forEach { OEBigPictureArt.shared.load(OEBigPictureArt.GameKey($0)) }

        screen = .browse
        tab = .home
        systemFilter = nil
        genreFilter = nil
        sidebarOpen = false
        tabBarIndex = 1
        rebuildLanes()
        lane = lanes.isEmpty ? -1 : 0
        column = 0
    }

    func setControllers(_ names: [String]) { controllers = names }
    func setGameRunning(_ running: Bool) { gameRunning = running }

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
        switch screen {
        case .settings:
            lanes = []
        case .detail(let game):
            var built = [BigPictureLane(id: "actions", title: nil, subtitle: nil, kind: .heroActions)]
            let states = (game.defaultROM?.normalSaveStates ?? []).sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
            if !states.isEmpty {
                built.append(BigPictureLane(id: "states", title: "Save States", subtitle: "\(states.count) saved", kind: .saveStates(states)))
            }
            lanes = built
        case .browse:
            switch tab {
            case .home:
                var built = [BigPictureLane]()
                let recent = sortedByRecent(allGames)
                if !allGames.isEmpty { built.append(BigPictureLane(id: "actions", title: nil, subtitle: nil, kind: .heroActions)) }
                if !recent.isEmpty {
                    built.append(BigPictureLane(id: "recent", title: "Continue Playing", subtitle: nil, kind: .games(Array(recent.prefix(20)))))
                }
                let recentStates = allGames
                    .flatMap { $0.defaultROM?.normalSaveStates ?? [] }
                    .sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
                if !recentStates.isEmpty {
                    built.append(BigPictureLane(id: "recent-saves", title: "Recent Saves", subtitle: nil, kind: .saveStates(Array(recentStates.prefix(8))), showsGame: true))
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
                let mostPlayed = allGames.filter { $0.playTime > 0 }.sorted { $0.playTime > $1.playTime }
                if !mostPlayed.isEmpty {
                    built.append(BigPictureLane(id: "most-played", title: "Most Played", subtitle: nil, kind: .games(Array(mostPlayed.prefix(12)))))
                }
                lanes = built
            case .recent:
                lanes = grid(Array(sortedByRecent(allGames).prefix(60)), id: "recent", title: "Recent", subtitle: nil)
            case .favorites:
                let rated = byName(allGames.filter { ($0.rating?.intValue ?? 0) >= 4 })
                lanes = grid(rated, id: "favorites", title: "Favorites", subtitle: "Games you rated 4 stars or more")
            case .library:
                var inScope = systemFilter.map { id in allGames.filter { $0.system?.systemIdentifier == id } } ?? allGames
                if let genreFilter = genreFilter { inScope = inScope.filter { genre(of: $0) == genreFilter } }
                let games = byName(inScope)
                let name = genreFilter ?? systems.first { $0.id == systemFilter }?.name ?? "Library"
                lanes = grid(games, id: "library", title: name, subtitle: games.count == 1 ? "1 game" : "\(games.count) games")
            case .saveStates:
                let states = allGames
                    .flatMap { $0.defaultROM?.normalSaveStates ?? [] }
                    .sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
                let perRow = 4
                lanes = stride(from: 0, to: states.count, by: perRow).enumerated().map { index, start in
                    BigPictureLane(id: "states-\(index)", title: index == 0 ? "Save States" : nil,
                                   subtitle: index == 0 ? "\(states.count) saved" : nil,
                                   kind: .saveStates(Array(states[start..<min(start + perRow, states.count)])), showsGame: true)
                }
            case .search:
                lanes = []
            }
        }
    }

    // MARK: Derived

    /// The game the hero describes: what is highlighted, else the one played most recently.
    var heroGame: OEDBGame? {
        if case .detail(let game) = screen { return game }
        if lane >= 0, lanes.indices.contains(lane), case .games(let games) = lanes[lane].kind, games.indices.contains(column) {
            return games[column]
        }
        return sortedByRecent(allGames).first ?? byName(allGames).first
    }

    var sidebarEntries: [SidebarEntry] {
        [.tab(.home), .tab(.recent), .tab(.favorites), .settings] + systems.map { .system($0.id) }
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

        if sidebarOpen { performSidebar(action); return }

        switch action {
        case .up: moveLane(-1)
        case .down: moveLane(1)
        case .left: moveColumn(-1)
        case .right: moveColumn(1)
        case .tabPrevious: moveColumn(-5)
        case .tabNext: moveColumn(5)
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
        default: break
        }
    }

    private func chooseSidebar(_ entry: SidebarEntry) {
        sidebarOpen = false
        switch entry {
        case .tab(let tab): show(tab: tab, system: nil)
        case .system(let id): show(tab: .library, system: id)
        case .settings:
            screen = .settings
            lanes = []
            lane = 0
            column = 0
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
        systemFilter = system
        genreFilter = genre
        tabBarIndex = newTab.rawValue + 1
        rebuildLanes()
        lane = lanes.isEmpty ? -1 : 0
        column = 0
    }

    func openSidebar() {
        sidebarIndex = sidebarEntries.firstIndex(of: screen == .settings ? .settings : .tab(tab)) ?? 0
        sidebarOpen = true
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
            guard lane >= 0, screen == .browse else { return }
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
            guard let game = heroGame else { return }
            if column == 0 { onLaunch?(game) } else { open(game) }
        case .games(let games):
            guard games.indices.contains(column) else { return }
            open(games[column])
        case .saveStates(let states):
            guard states.indices.contains(column) else { return }
            onLaunchState?(states[column])
        case .genres(let genres):
            guard genres.indices.contains(column) else { return }
            show(tab: .library, system: nil, genre: genres[column].name)
        }
    }

    private func open(_ game: OEDBGame) {
        detailScrolled = false
        screen = .detail(game)
        rebuildLanes()
        lane = 0
        column = 0
    }

    /// Mouse hover moves the highlight, but only when the pointer really moved.
    /// Without the check, items scrolling under a resting pointer would steal
    /// the highlight from the controller.
    func hover(lane newLane: Int, column newColumn: Int) {
        let location = NSEvent.mouseLocation
        guard hypot(location.x - mouseAnchor.x, location.y - mouseAnchor.y) > 4 else { return }
        mouseAnchor = location
        lane = newLane
        column = newColumn
        lastInput = "hover  ·  mouse"
    }

    func click(lane newLane: Int, column newColumn: Int) {
        lane = newLane
        column = newColumn
        lastInput = "click  ·  mouse"
        activate()
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
    private var keyMonitor: Any?
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

        input.isActive = { [weak window] in window?.isKeyWindow ?? false }
        input.onControllersChanged = { [weak self] in self?.refreshControllers() }
        input.onAction = { [weak self] action, source in self?.handle(action, source: source) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
        installKeyMonitor()
        startWatchingForGameEnd()
    }

    func hide() {
        input.releaseAll()
        input.stop()
        removeKeyMonitor()
        stopWatchingForGameEnd()
        launchedFromBigPicture = false
        model.setGameRunning(false)
        // Closing a fullscreen window leaves its Space.
        window?.close()
    }

    // MARK: Actions

    private func handle(_ action: BigPictureAction, source: String) {
        if Date() < ignoreInputUntil, action != .home { return }
        if action == .home {
            returnFromGame(source: source)
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

    /// Guide / Home while a game runs: switch back to the menu's Space without quitting the game.
    private func returnFromGame(source: String) {
        guard launchedFromBigPicture, let window = window, !window.isKeyWindow else { return }
        model.perform(.home, source: source)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
                guard let self = self, self.window?.isKeyWindow == true else { return event }
                if Date() < self.ignoreInputUntil { return nil }
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

    private func removeKeyMonitor() {
        if let keyMonitor = keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        input.releaseAll()
    }

    /// Closed with the red button or Cmd-W: leave the mode cleanly.
    func windowWillClose(_ notification: Notification) {
        input.releaseAll()
        input.stop()
        removeKeyMonitor()
        stopWatchingForGameEnd()
        launchedFromBigPicture = false
        model.setGameRunning(false)
    }
}
