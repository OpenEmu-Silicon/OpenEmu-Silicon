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

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 468, height: 380))
        buildUI()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    private func buildUI() {
        let header = NSTextField(labelWithString: "Big Picture Artwork")
        header.font = .boldSystemFont(ofSize: 15)

        let description = NSTextField(wrappingLabelWithString: "Big-picture mode uses your library's cover art as a fallback. Add a SteamGridDB key below to also fetch posters and backdrops. It is optional.")
        description.font = .systemFont(ofSize: 12)
        description.textColor = .secondaryLabelColor

        steamGridKey.placeholderString = "SteamGridDB API key"

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
            label("SteamGridDB — posters and backdrops"), steamGridKey,
            buttons, statusLabel, links,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(18, after: description)
        stack.setCustomSpacing(16, after: steamGridKey)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let fields: [NSView] = [description, steamGridKey, links]
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

        var active = [String]()
        if SteamGridDBClient.isConfigured { active.append("SteamGridDB") }
        statusLabel.stringValue = active.isEmpty ? "No online providers — using library cover art only." : "Active: " + active.joined(separator: ", ")
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
        refresh()
    }
}

extension PrefArtworkProvidersController: PreferencePane {

    var icon: NSImage? {
        NSImage(systemSymbolName: "photo.stack", accessibilityDescription: "Artwork")
    }

    var panelTitle: String { "Artwork" }

    var viewSize: NSSize { NSSize(width: 468, height: 380) }
}
