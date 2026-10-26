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

/// What is on screen and which item is highlighted.
///
/// The highlight lives here as a plain (row, column) pair rather than in
/// SwiftUI's focus system. That keeps controller navigation predictable on the
/// macOS 12 deployment target, where focus tools are limited.
@MainActor
final class BigPictureModel: ObservableObject {

    struct Item: Identifiable {
        let id = UUID()
        let game: OEDBGame
    }

    struct Row: Identifiable {
        let id: String
        let title: String
        let items: [Item]
    }

    @Published private(set) var rows = [Row]()
    @Published private(set) var selectedRow = 0
    @Published private(set) var selectedColumn = 0
    /// Bumped when a cover finishes decoding so cards redraw.
    @Published private(set) var coverTick = 0
    /// Shown in the on-screen test readout.
    @Published private(set) var lastInput = "—"
    @Published private(set) var controllers = [String]()
    @Published private(set) var gameRunning = false

    var onLaunch: ((OEDBGame) -> Void)?
    var onExit: (() -> Void)?

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

    func reload() {
        guard let database = OELibraryDatabase.default else { return }
        let context = database.mainThreadContext

        let systems = OEDBSystem.allSystems(in: context).filter { !$0.games.isEmpty }
        let allGames = systems.flatMap { Array($0.games) }

        var built = [Row]()

        let recent = allGames
            .filter { $0.lastPlayed != nil }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            .prefix(20)
        if !recent.isEmpty {
            built.append(Row(id: "recent", title: "Recently Played", items: recent.map { Item(game: $0) }))
        }

        for system in systems.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            let games = system.games.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            built.append(Row(id: system.systemIdentifier, title: system.name, items: games.map { Item(game: $0) }))
        }

        rows = built
        selectedRow = 0
        selectedColumn = 0
    }

    func setControllers(_ names: [String]) {
        controllers = names
    }

    func setGameRunning(_ running: Bool) {
        gameRunning = running
    }

    // MARK: Navigation

    /// Handles an action from any input device.
    func perform(_ action: BigPictureAction, source: String) {
        lastInput = "\(action.rawValue)  ·  \(source)"
        mouseAnchor = NSEvent.mouseLocation

        guard !rows.isEmpty else {
            if action == .back { onExit?() }
            return
        }

        switch action {
        case .up: moveRow(-1)
        case .down: moveRow(1)
        case .left: moveColumn(-1)
        case .right: moveColumn(1)
        case .tabPrevious: moveColumn(-5)
        case .tabNext: moveColumn(5)
        case .select: launchSelected()
        case .back: onExit?()
        case .menu, .home: break
        }
    }

    private func moveRow(_ delta: Int) {
        let target = min(max(selectedRow + delta, 0), rows.count - 1)
        guard target != selectedRow else { return }
        selectedRow = target
        selectedColumn = min(selectedColumn, max(rows[target].items.count - 1, 0))
    }

    private func moveColumn(_ delta: Int) {
        let count = rows[selectedRow].items.count
        selectedColumn = min(max(selectedColumn + delta, 0), max(count - 1, 0))
    }

    /// Mouse hover moves the highlight, but only when the pointer really moved.
    /// Without the check, items scrolling under a resting pointer would steal
    /// the highlight from the controller.
    func hover(row: Int, column: Int) {
        let location = NSEvent.mouseLocation
        guard hypot(location.x - mouseAnchor.x, location.y - mouseAnchor.y) > 4 else { return }
        mouseAnchor = location
        selectedRow = row
        selectedColumn = column
        lastInput = "hover  ·  mouse"
    }

    func click(row: Int, column: Int) {
        selectedRow = row
        selectedColumn = column
        lastInput = "click  ·  mouse"
        launchSelected()
    }

    private func launchSelected() {
        guard rows.indices.contains(selectedRow), rows[selectedRow].items.indices.contains(selectedColumn) else { return }
        onLaunch?(rows[selectedRow].items[selectedColumn].game)
    }
}

// MARK: - View

struct BigPictureView: View {

    @ObservedObject var model: BigPictureModel

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.07).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text("Big Picture")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 64)
                    .padding(.top, 48)
                    .padding(.bottom, 24)

                if model.rows.isEmpty {
                    Spacer()
                    Text("No games in the library yet.")
                        .font(.system(size: 22))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: 40) {
                                ForEach(Array(model.rows.enumerated()), id: \.element.id) { rowIndex, row in
                                    BigPictureRowView(model: model, row: row, rowIndex: rowIndex)
                                        .id(row.id)
                                }
                            }
                            .padding(.vertical, 24)
                        }
                        .onChange(of: model.selectedRow) { newRow in
                            guard model.rows.indices.contains(newRow) else { return }
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(model.rows[newRow].id, anchor: .center)
                            }
                        }
                    }
                }

                TestReadout(model: model)
            }
        }
    }
}

private struct BigPictureRowView: View {

    @ObservedObject var model: BigPictureModel
    let row: BigPictureModel.Row
    let rowIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(row.title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .padding(.horizontal, 64)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 28) {
                        ForEach(Array(row.items.enumerated()), id: \.element.id) { column, item in
                            BigPictureCard(
                                game: item.game,
                                isSelected: rowIndex == model.selectedRow && column == model.selectedColumn,
                                coverTick: model.coverTick
                            )
                            .id(item.id)
                            .onHover { inside in
                                if inside { model.hover(row: rowIndex, column: column) }
                            }
                            .onTapGesture { model.click(row: rowIndex, column: column) }
                        }
                    }
                    // Room for the selected card to scale up without clipping.
                    .padding(.horizontal, 64)
                    .padding(.vertical, 24)
                }
                .onChange(of: model.selectedColumn) { newColumn in
                    guard rowIndex == model.selectedRow, row.items.indices.contains(newColumn) else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(row.items[newColumn].id, anchor: .center)
                    }
                }
                .onChange(of: model.selectedRow) { newRow in
                    guard newRow == rowIndex, row.items.indices.contains(model.selectedColumn) else { return }
                    proxy.scrollTo(row.items[model.selectedColumn].id, anchor: .center)
                }
            }
        }
    }
}

private struct BigPictureCard: View {

    let game: OEDBGame
    let isSelected: Bool
    let coverTick: Int

    private let width: CGFloat = 200
    private let height: CGFloat = 200

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08))
                if let image = game.boxImage?.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                } else {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.white.opacity(0.25))
                }
            }
            .frame(width: width, height: height)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white, lineWidth: isSelected ? 4 : 0)
            )

            Text(game.displayName)
                .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                .foregroundColor(.white.opacity(isSelected ? 1 : 0.65))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: width)
        }
        .scaleEffect(isSelected ? 1.12 : 1)
        .shadow(color: .black.opacity(isSelected ? 0.6 : 0), radius: 18, y: 8)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        // Read so SwiftUI redraws when a cover finishes decoding.
        .id("\(game.objectID)-\(coverTick)")
    }
}

/// Spike-only: shows what the app thinks the input is doing, for hardware testing.
private struct TestReadout: View {

    @ObservedObject var model: BigPictureModel

    var body: some View {
        HStack(spacing: 24) {
            Text("Last input: \(model.lastInput)")
            Text(model.controllers.isEmpty ? "No controller detected" : "Controllers: \(model.controllers.joined(separator: ", "))")
            if model.gameRunning {
                Text("Game running — press Guide/Home to return here")
            }
            Spacer()
            Text("Arrows / D-pad move · Return / A play · Esc / B exit")
        }
        .font(.system(size: 13, design: .monospaced))
        .foregroundColor(.white.opacity(0.55))
        .padding(.horizontal, 64)
        .padding(.vertical, 14)
    }
}

// MARK: - Window

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

    private init() {
        let window = BigPictureWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .black
        // Above the menu bar and Dock, so the mode covers the whole screen without changing system presentation
        // options (AppKit raises an exception if those conflict with a fullscreen game window).
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.identifier = NSUserInterfaceItemIdentifier("BigPictureWindow")
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary]
        super.init(window: window)

        window.delegate = self
        window.contentView = NSHostingView(rootView: BigPictureView(model: model))

        model.onLaunch = { [weak self] game in self?.launch(game) }
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
        window.setFrame(screen.frame, display: true)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        input.start()
        installKeyMonitor()
        startWatchingForGameEnd()
    }

    func hide() {
        input.releaseAll()
        input.stop()
        removeKeyMonitor()
        stopWatchingForGameEnd()
        window?.orderOut(nil)
        launchedFromBigPicture = false
        model.setGameRunning(false)
    }

    // MARK: Actions

    private func handle(_ action: BigPictureAction, source: String) {
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

    private func launch(_ game: OEDBGame) {
        launchedFromBigPicture = true
        model.setGameRunning(true)

        GameDocumentController.shared.openGameDocument(with: game, display: true, fullScreen: true) { [weak self] document, error in
            guard let self = self else { return }
            if document == nil {
                os_log(.error, log: .default, "Big picture could not start game: %{public}@", String(describing: error))
                self.launchedFromBigPicture = false
                self.model.setGameRunning(false)
                return
            }
            // The game owns the screen and the controller now. Step aside.
            self.input.releaseAll()
            self.window?.orderOut(nil)
        }
    }

    /// Guide / Home while a game runs: bring the menu back in front without quitting the game.
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
                // Let the document finish tearing down before checking.
                DispatchQueue.main.async {
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
        model.setGameRunning(false)
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
                let action: BigPictureAction?
                switch event.keyCode {
                case 126: action = .up
                case 125: action = .down
                case 123: action = .left
                case 124: action = .right
                case 36, 76: action = .select
                case 53: action = .back
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
}
