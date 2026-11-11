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

/// Top-left origin, so scrolled content starts at its top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Preferences pane for the online artwork providers used by big-picture mode.
///
/// Keys are stored in `OECredentialStore`; a provider with no key is simply skipped.
final class PrefArtworkProvidersController: NSViewController {

    private let steamGridKey = NSSecureTextField()
    private let steamGridStatus = NSTextField(labelWithString: "")
    private let scraperUser = NSTextField()
    private let scraperPassword = NSSecureTextField()
    private let scraperStatus = NSTextField(wrappingLabelWithString: "")
    private let scraperSave = NSButton()
    private let scraperClear = NSButton()
    private let statusLabel  = NSTextField(labelWithString: "")
    private let sourcePopUp  = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fallbackCheck = NSButton(checkboxWithTitle: "Use the other sources when this one has nothing", target: nil, action: nil)
    private let folderPath   = NSTextField(labelWithString: "")
    private let folderStatus = NSTextField(wrappingLabelWithString: "")
    private var folderButtons = [NSButton]()
    private let bulkStatus = NSTextField(wrappingLabelWithString: "")
    private let bulkStart = NSButton(title: "Fetch Missing Artwork", target: nil, action: nil)
    private let bulkPause = NSButton(title: "Pause", target: nil, action: nil)
    private let bulkStop = NSButton(title: "Stop", target: nil, action: nil)
    private var bulk: OEArtworkBulkFetch?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 468, height: 600))
        buildUI()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    private func buildUI() {
        let header = NSTextField(labelWithString: "Artwork")
        header.font = .boldSystemFont(ofSize: 15)

        let description = NSTextField(wrappingLabelWithString: "Covers for your library and the posters, backdrops and logos in big-picture mode come from the sources below. OpenEmu looks in its built-in OpenVGDB database first, then in each source you have set up. Every source is optional, and what you choose yourself is never replaced.")
        description.font = .systemFont(ofSize: 12)
        description.textColor = .secondaryLabelColor

        steamGridKey.placeholderString = "SteamGridDB API key"
        scraperUser.placeholderString = "screenscraper.fr username"
        scraperPassword.placeholderString = "screenscraper.fr password"
        scraperStatus.font = .systemFont(ofSize: 11)
        scraperStatus.textColor = .secondaryLabelColor
        steamGridStatus.font = .systemFont(ofSize: 11)
        steamGridStatus.textColor = .secondaryLabelColor

        OEBigPictureArtSource.allCases.forEach { sourcePopUp.addItem(withTitle: $0.title) }
        sourcePopUp.target = self
        sourcePopUp.action = #selector(sourceChanged)

        fallbackCheck.target = self
        fallbackCheck.action = #selector(fallbackChanged)

        folderPath.font = .systemFont(ofSize: 12)
        folderPath.lineBreakMode = .byTruncatingMiddle
        folderPath.isSelectable = true
        folderStatus.font = .systemFont(ofSize: 11)
        folderStatus.textColor = .secondaryLabelColor
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        let reveal = NSButton(title: "Show in Finder", target: self, action: #selector(revealFolder))
        let reset = NSButton(title: "Use Default", target: self, action: #selector(useDefaultFolder))
        folderButtons = [choose, reveal, reset]
        folderButtons.forEach { $0.bezelStyle = .rounded }
        let folderRow = NSStackView(views: folderButtons)
        folderRow.spacing = 8

        bulkStatus.font = .systemFont(ofSize: 11)
        bulkStatus.textColor = .secondaryLabelColor
        bulkStatus.stringValue = "Fetches posters, backdrops, icons and logos for every game that does not have them yet. Games that do are skipped, so it is safe to stop and run again."
        bulkStart.target = self; bulkStart.action = #selector(startBulk)
        bulkPause.target = self; bulkPause.action = #selector(togglePauseBulk)
        bulkStop.target = self; bulkStop.action = #selector(stopBulk)
        let cleanUp = NSButton(title: "Clean Up Unused Artwork…", target: self, action: #selector(cleanUp))
        for button in [bulkStart, bulkPause, bulkStop, cleanUp] { button.bezelStyle = .rounded }
        bulkPause.isEnabled = false; bulkStop.isEnabled = false
        let bulkRow = NSStackView(views: [bulkStart, bulkPause, bulkStop])
        bulkRow.spacing = 8

        let steamSave = NSButton(title: "Save", target: self, action: #selector(saveSteamGrid))
        steamSave.bezelStyle = .rounded
        let steamClear = NSButton(title: "Clear", target: self, action: #selector(clearSteamGrid))
        steamClear.bezelStyle = .rounded
        let steamButtons = NSStackView(views: [steamClear, steamSave])
        steamButtons.spacing = 8

        scraperSave.title = "Sign In"
        scraperSave.bezelStyle = .rounded
        scraperSave.target = self
        scraperSave.action = #selector(saveScreenScraper)
        scraperClear.title = "Sign Out"
        scraperClear.bezelStyle = .rounded
        scraperClear.target = self
        scraperClear.action = #selector(clearScreenScraper)
        let scraperButtons = NSStackView(views: [scraperClear, scraperSave])
        scraperButtons.spacing = 8

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor

        let builtIn = NSTextField(wrappingLabelWithString: "libretro-thumbnails and OpenVGDB need no key or login. libretro-thumbnails supplies posters only.")
        builtIn.font = .systemFont(ofSize: 11)
        builtIn.textColor = .tertiaryLabelColor

        let links = NSTextField(wrappingLabelWithString: "SteamGridDB keys are at steamgriddb.com/profile/preferences/api. ScreenScraper registration is free at screenscraper.fr.")
        links.font = .systemFont(ofSize: 11)
        links.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [
            header, description,
            label("SteamGridDB — posters and backdrops"), steamGridKey, steamButtons, steamGridStatus,
            label("ScreenScraper — covers, posters and logos"), scraperUser, scraperPassword, scraperButtons, scraperStatus,
            builtIn, links,
            label("Preferred source"), sourcePopUp, fallbackCheck, statusLabel,
            label("Artwork folder"), folderPath, folderRow, folderStatus,
            label("Whole library"), bulkRow, bulkStatus, cleanUp,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: description)
        stack.setCustomSpacing(16, after: steamGridStatus)
        stack.setCustomSpacing(16, after: scraperStatus)
        stack.setCustomSpacing(16, after: links)
        stack.setCustomSpacing(16, after: statusLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The pane is taller than a small screen, so it scrolls.
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        scroll.documentView = content
        view.addSubview(scroll)

        let fields: [NSView] = [bulkStatus, description, steamGridKey, scraperUser, scraperPassword, scraperStatus, builtIn, links, folderPath, folderStatus]
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -36),
            steamButtons.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            scraperButtons.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ] + fields.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13, weight: .medium)
        return field
    }

    private func refresh() {
        let hasKey = OECredentialStore.shared.has(.steamGridDBAPIKey)
        steamGridKey.placeholderString = hasKey ? "••••••••  (saved)" : "SteamGridDB API key"
        steamGridStatus.stringValue = hasKey ? "✓  Key saved" : "No key saved — SteamGridDB is skipped."
        refreshScreenScraper()

        if let index = OEBigPictureArtSource.allCases.firstIndex(of: OEBigPictureArtSource.chosen) { sourcePopUp.selectItem(at: index) }
        fallbackCheck.state = OEBigPictureArtSource.fallbackEnabled ? .on : .off
        let single: Set<OEBigPictureArtSource> = [.steamGridDB, .screenScraper, .libretro]
        fallbackCheck.isEnabled = single.contains(OEBigPictureArtSource.chosen)
        folderPath.stringValue = OEArtworkStore.shared.root.path
        let inUse = !OEBigPictureArtSource.providers().isEmpty
        statusLabel.stringValue = inUse ? "Order: \(OEBigPictureArtSource.inUseTitle)."
            : "No online source ready (SteamGridDB needs a key, ScreenScraper needs a sign-in) — using library cover art only."
    }

    @objc private func sourceChanged() {
        let index = sourcePopUp.indexOfSelectedItem
        guard OEBigPictureArtSource.allCases.indices.contains(index) else { return }
        UserDefaults.standard.set(OEBigPictureArtSource.allCases[index].rawValue, forKey: OEBigPictureArtSource.defaultsKey)
        Task { @MainActor in OEBigPictureArt.shared.reset() }
        refresh()
    }

    @objc private func fallbackChanged() {
        UserDefaults.standard.set(fallbackCheck.state == .on, forKey: OEBigPictureArtSource.fallbackKey)
        Task { @MainActor in OEBigPictureArt.shared.reset() }
        refresh()
    }

    // MARK: Whole library

    @objc private func startBulk() {
        guard bulk == nil, let database = OELibraryDatabase.default else { return }
        let providers = OEBigPictureArtSource.providers()
        guard !providers.isEmpty else {
            bulkStatus.stringValue = "No online source is ready. Set up SteamGridDB or ScreenScraper above, or choose libretro-thumbnails."
            return
        }
        let games = libraryGames(database)
        let keys = games.map { OEBigPictureArt.GameKey($0) }.filter { !$0.md5.isEmpty }
        guard !keys.isEmpty else {
            bulkStatus.stringValue = "No games in the library to fetch artwork for."
            return
        }
        // ScreenScraper has a shared request limit, so it goes one game at a time; the others can overlap.
        let run = OEArtworkBulkFetch(keys: keys, workers: providers.contains { $0.isThrottled } ? 1 : 3,
                                     fetch: OEArtworkBulkFetch.libraryFetch(providers: providers, preferred: OEBigPictureArtSource.preferredID))
        run.onProgress = { [weak self] progress in
            DispatchQueue.main.async { self?.showBulk(progress) }
        }
        bulk = run
        bulkStart.isEnabled = false; bulkPause.isEnabled = true; bulkStop.isEnabled = true
        showBulk(run.current)
        Task { @MainActor [weak self] in
            let finish = await run.run()
            self?.finishBulk(finish, progress: run.current)
        }
    }

    /// Every game in the library, read on the main thread from the main context.
    private func libraryGames(_ database: OELibraryDatabase) -> [OEDBGame] {
        let request = OEDBGame.fetchRequest()
        request.fetchBatchSize = 200
        return ((try? database.mainThreadContext.fetch(request)) as? [OEDBGame]) ?? []
    }

    private func showBulk(_ p: OEArtworkBulkFetch.Progress) {
        guard bulk != nil else { return }
        let paused = bulk?.isPaused == true ? " (paused)" : ""
        bulkStatus.stringValue = "\(p.processed) of \(p.total) games\(paused): \(p.filled) fetched, \(p.alreadyHad) already had art, \(p.noArt) with none found."
    }

    private func finishBulk(_ finish: OEArtworkBulkFetch.Finish, progress p: OEArtworkBulkFetch.Progress) {
        bulk = nil
        bulkStart.isEnabled = true; bulkPause.isEnabled = false; bulkStop.isEnabled = false
        bulkPause.title = "Pause"
        let counts = "\(p.filled) fetched, \(p.alreadyHad) already had art, \(p.noArt) with none found, \(p.total - p.processed) not done."
        switch finish {
        case .finished: bulkStatus.stringValue = "Done. " + counts
        case .stopped: bulkStatus.stringValue = "Stopped. " + counts + " Run it again to carry on."
        case .outOfQuota: bulkStatus.stringValue = "Stopped: the source says its limit is used up for now. " + counts + " Run it again later; finished games are skipped."
        case .unreachable: bulkStatus.stringValue = "Stopped: no source answered several games in a row (offline, or a bad login). " + counts
        }
        Task { @MainActor in OEBigPictureArt.shared.reset() }
    }

    @objc private func togglePauseBulk() {
        guard let run = bulk else { return }
        if run.isPaused { run.resume(); bulkPause.title = "Pause" } else { run.pause(); bulkPause.title = "Resume" }
        showBulk(run.current)
    }

    @objc private func stopBulk() {
        bulk?.resume()
        bulk?.stop()
    }

    @objc private func cleanUp() {
        guard let database = OELibraryDatabase.default else { return }
        let games = libraryGames(database)
        let alert = NSAlert()
        // An empty list means the library did not load, not that every picture is unused.
        guard !games.isEmpty else {
            alert.messageText = "The library has no games loaded"
            alert.informativeText = "Nothing was moved. Try again once your library is showing."
            alert.runModal()
            return
        }
        // Every disc or version of a game counts, not only the default one: changing the default must not make the
        // pictures filed under the other look unused.
        var inLibrary = Set<String>()
        for game in games {
            inLibrary.insert(OEArtworkStore.Game(game).md5)
            for rom in game.roms { if let hash = rom.md5Hash, !hash.isEmpty { inLibrary.insert(hash); inLibrary.insert(hash.lowercased()) } }
        }
        let plan = OEArtworkCleanup.plan(inLibrary: inLibrary)
        if plan.isEmpty {
            alert.messageText = "Nothing to clean up"
            alert.informativeText = "Every automatic picture in the artwork folder belongs to a game that is still in your library."
            alert.runModal()
            return
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(plan.reduce(0) { $0 + $1.bytes }), countStyle: .file)
        alert.messageText = "Move \(plan.count) unused pictures?"
        alert.informativeText = "These are automatic pictures for games that are no longer in your library (\(size)). They are moved into a dated \"Cleaned\" folder inside the artwork folder. Nothing is deleted, and pictures you picked or added yourself are left alone."
        alert.addButton(withTitle: "Move Them")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let outcome = OEArtworkCleanup.perform(plan)
        folderStatus.stringValue = "Moved \(outcome.moved) pictures to \(outcome.folder?.lastPathComponent ?? "—")" + (outcome.failed > 0 ? "; \(outcome.failed) could not be moved and were left in place." : ".")
    }

    // MARK: Artwork folder

    @objc private func revealFolder() {
        let root = OEArtworkStore.shared.root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    @objc private func useDefaultFolder() {
        moveFolder(to: OEArtworkStore.defaultRoot)
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose where artwork is kept. Everything is copied there and checked first. The current folder is not deleted."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        moveFolder(to: url)
    }

    private func moveFolder(to destination: URL) {
        folderButtons.forEach { $0.isEnabled = false }
        folderStatus.textColor = .secondaryLabelColor
        folderStatus.stringValue = "Checking the folder…"
        // Looking at a network drive can stall, so the warnings are found off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let warnings = OEArtworkLocation.warnings(for: destination)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !warnings.isEmpty, !self.confirm(warnings) {
                    self.folderButtons.forEach { $0.isEnabled = true }
                    self.folderStatus.stringValue = ""
                    return
                }
                self.runMove(to: destination)
            }
        }
    }

    private func confirm(_ warnings: [OEArtworkLocation.Warning]) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Use this folder anyway?"
        alert.informativeText = warnings.map { warning -> String in
            switch warning {
            case .network: return "It is on a network or external drive. Artwork would be missing whenever that drive is not connected."
            case .iCloud: return "It is in a cloud-synced folder. Pictures that are not downloaded yet may be slow or missing."
            }
        }.joined(separator: "\n\n")
        alert.addButton(withTitle: "Use Folder")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func runMove(to destination: URL) {
        let old = OEArtworkStore.shared.root
        folderStatus.stringValue = "Copying and checking…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = OEArtworkLocation.move(to: destination)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.folderButtons.forEach { $0.isEnabled = true }
                switch result {
                case .success(let count):
                    self.folderStatus.stringValue = "Done. Copied \(count) file\(count == 1 ? "" : "s") and checked each one. The old folder is still at \(old.path); delete it when you like."
                case .failure(let problem):
                    self.folderStatus.textColor = .systemRed
                    self.folderStatus.stringValue = Self.message(for: problem) + " The artwork folder in use was not changed."
                }
                self.refresh()
            }
        }
    }

    private static func message(for problem: OEArtworkLocation.Problem) -> String {
        switch problem {
        case .sameFolder: return "That is already the artwork folder."
        case .nested: return "That folder is inside the current one, or the current one is inside it."
        case .notWritable: return "That folder cannot be written to."
        case .conflict(let names): return "That folder already has \(names.count) different file\(names.count == 1 ? "" : "s") with the same name, such as \(names[0])."
        case .copyFailed(let name): return "Could not copy \(name)."
        case .verifyFailed(let name): return "A copy of \(name) did not match the original."
        }
    }

    @objc private func saveSteamGrid() {
        let value = steamGridKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { OECredentialStore.shared.set(value, forKey: .steamGridDBAPIKey) }
        steamGridKey.stringValue = ""
        Task { @MainActor in OEBigPictureArt.shared.reset() }
        refresh()
    }

    @objc private func clearSteamGrid() {
        OECredentialStore.shared.remove(.steamGridDBAPIKey)
        steamGridKey.stringValue = ""
        Task { @MainActor in OEBigPictureArt.shared.reset() }
        refresh()
    }

    // MARK: ScreenScraper

    private static let scraperUserKey = "ScreenScraperUsername"
    private static let red = NSColor(red: 0.87, green: 0.20, blue: 0.18, alpha: 1)
    private static let green = NSColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1)

    private func showScraper(_ text: String, _ color: NSColor = .secondaryLabelColor) {
        scraperStatus.stringValue = text
        scraperStatus.textColor = color
    }

    private func refreshScreenScraper() {
        let username = UserDefaults.standard.string(forKey: Self.scraperUserKey) ?? ""
        if scraperUser.stringValue.isEmpty { scraperUser.stringValue = username }
        let hasPassword = OECredentialStore.shared.has(.screenScraperPassword)
        scraperPassword.placeholderString = hasPassword ? "••••••••  (saved)" : "screenscraper.fr password"
        guard !username.isEmpty, hasPassword else {
            showScraper("Not signed in — ScreenScraper is skipped.")
            return
        }
        if let description = ScreenScraperClient.shared.lastFetchError?.errorDescription {
            showScraper(description, Self.red)
        } else if ScreenScraperClient.shared.hasVerifiedCredentials {
            showScraper("✓  Signed in as \(username)", Self.green)
        } else {
            showScraper("Verifying…")
            silentlyVerify(username: username)
        }
    }

    /// Checks saved credentials in the background so the pane shows the true state without a Save.
    private func silentlyVerify(username: String) {
        guard let password = OECredentialStore.shared.get(.screenScraperPassword) else { return }
        Task { @MainActor in
            do {
                if try await ScreenScraperClient.shared.verifyCredentials(username: username, password: password) {
                    ScreenScraperClient.shared.clearLastFetchError()
                    self.showScraper("✓  Signed in as \(username)", Self.green)
                } else {
                    self.showScraper("ScreenScraper rejected these credentials. Re-enter your password and sign in.", Self.red)
                }
            } catch {
                self.showScraper("Could not reach ScreenScraper — check your connection.")
            }
        }
    }

    @objc private func saveScreenScraper() {
        let username = scraperUser.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let typed = scraperPassword.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return showScraper("Username cannot be empty.", Self.red) }
        guard let password = typed.isEmpty ? OECredentialStore.shared.get(.screenScraperPassword) : typed else {
            return showScraper("Password cannot be empty.", Self.red)
        }
        UserDefaults.standard.set(username, forKey: Self.scraperUserKey)
        OECredentialStore.shared.set(password, forKey: .screenScraperPassword)
        scraperPassword.stringValue = ""
        scraperPassword.placeholderString = "••••••••  (saved)"
        scraperSave.isEnabled = false
        scraperClear.isEnabled = false
        showScraper("Verifying credentials…")
        Task { @MainActor in
            do {
                if try await ScreenScraperClient.shared.verifyCredentials(username: username, password: password) {
                    ScreenScraperClient.shared.clearLastFetchError()
                    self.showScraper("✓  Signed in as \(username)", Self.green)
                } else {
                    self.showScraper("ScreenScraper rejected these credentials. Check your username and password.", Self.red)
                }
            } catch {
                self.showScraper("Could not reach ScreenScraper — check your connection.", Self.red)
            }
            self.scraperSave.isEnabled = true
            self.scraperClear.isEnabled = true
            OEBigPictureArt.shared.reset()
            self.statusLabel.stringValue = OEBigPictureArtSource.providers().isEmpty
                ? "No online source ready — using library cover art only." : "Order: \(OEBigPictureArtSource.inUseTitle)."
        }
    }

    @objc private func clearScreenScraper() {
        UserDefaults.standard.removeObject(forKey: Self.scraperUserKey)
        OECredentialStore.shared.remove(.screenScraperPassword)
        scraperUser.stringValue = ""
        scraperPassword.stringValue = ""
        Task { @MainActor in OEBigPictureArt.shared.reset() }
        refresh()
    }
}

extension PrefArtworkProvidersController: PreferencePane {

    var icon: NSImage? {
        NSImage(systemSymbolName: "photo.stack", accessibilityDescription: "Artwork")
    }

    var panelTitle: String { "Artwork" }

    var viewSize: NSSize { NSSize(width: 468, height: 600) }
}
