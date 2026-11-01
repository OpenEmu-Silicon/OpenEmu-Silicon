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

/// Preferences pane for the online artwork providers used by big-picture mode.
///
/// Keys are stored in `OECredentialStore`; a provider with no key is simply skipped.
final class PrefArtworkProvidersController: NSViewController {

    private let steamGridKey = NSSecureTextField()
    private let statusLabel  = NSTextField(labelWithString: "")
    private let sourcePopUp  = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fallbackCheck = NSButton(checkboxWithTitle: "Use the other sources when this one has nothing", target: nil, action: nil)
    private let folderPath   = NSTextField(labelWithString: "")
    private let folderStatus = NSTextField(wrappingLabelWithString: "")
    private var folderButtons = [NSButton]()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 468, height: 600))
        buildUI()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    private func buildUI() {
        let header = NSTextField(labelWithString: "Big Picture Artwork")
        header.font = .boldSystemFont(ofSize: 15)

        let description = NSTextField(wrappingLabelWithString: "Big-picture mode shows your library's cover art. It can also fetch posters, backdrops and logos from online sources: SteamGridDB (needs a key, below), ScreenScraper (sign in on the ScreenScraper tab) and libretro-thumbnails (no key or login, posters only). Automatic uses every one that is ready, in that order. All are optional.")
        description.font = .systemFont(ofSize: 12)
        description.textColor = .secondaryLabelColor

        steamGridKey.placeholderString = "SteamGridDB API key"

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

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let clear = NSButton(title: "Clear", target: self, action: #selector(clear))
        clear.bezelStyle = .rounded
        let buttons = NSStackView(views: [clear, save])
        buttons.spacing = 8

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor

        let links = NSTextField(wrappingLabelWithString: "Get a key at steamgriddb.com/profile/preferences/api. Game details come from the built-in OpenVGDB database.")
        links.font = .systemFont(ofSize: 11)
        links.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [
            header, description,
            label("Artwork source"), sourcePopUp, fallbackCheck,
            label("SteamGridDB — posters and backdrops"), steamGridKey,
            buttons, statusLabel,
            label("Artwork folder"), folderPath, folderRow, folderStatus,
            links,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(18, after: description)
        stack.setCustomSpacing(8, after: sourcePopUp)
        stack.setCustomSpacing(16, after: fallbackCheck)
        stack.setCustomSpacing(18, after: statusLabel)
        stack.setCustomSpacing(18, after: folderStatus)
        stack.setCustomSpacing(16, after: steamGridKey)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let fields: [NSView] = [description, steamGridKey, links, folderPath, folderStatus]
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 32),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ] + fields.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13, weight: .medium)
        return field
    }

    private func refresh() {
        steamGridKey.placeholderString = OECredentialStore.shared.has(.steamGridDBAPIKey) ? "••••••••  (saved)" : "SteamGridDB API key"

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

    @objc private func save() {
        let store = OECredentialStore.shared
        let values: [(NSTextField, OECredentialKey)] = [
            (steamGridKey, .steamGridDBAPIKey),
        ]
        for (field, key) in values {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { store.set(value, forKey: key) }
            field.stringValue = ""
        }
        Task { @MainActor in OEBigPictureArt.shared.reset() }
        refresh()
    }

    @objc private func clear() {
        OECredentialStore.shared.remove(.steamGridDBAPIKey)
        steamGridKey.stringValue = ""
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
