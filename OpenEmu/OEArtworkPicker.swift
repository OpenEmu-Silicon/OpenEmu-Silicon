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

/// What choosing a picture for one game does. The picture is stored as it arrived, pinned, and the one it replaces
/// moves to `History`. Nothing is deleted.
enum OEArtworkChoice {

    /// Pins `data` as the game's picture for `slot`. `provider` names where it came from; nil means the person's own file.
    @discardableResult
    static func choose(_ data: Data, for game: OEArtworkStore.Game, slot: OEArtworkStore.Slot, provider: String?,
                       store: OEArtworkStore = .shared) -> OEArtworkStore.Outcome {
        let outcome = store.choose(data, for: game, slot: slot, origin: provider.map { .provider($0) } ?? .user)
        store.flush()
        return outcome
    }

    /// Lets automatic fetching replace this slot again. The picture stays where it is.
    static func resetToAutomatic(_ game: OEArtworkStore.Game, slot: OEArtworkStore.Slot, store: OEArtworkStore = .shared) {
        store.unpin(game, slot)
        store.flush()
    }
}

/// The "Choose Artwork…" window for one game: a tab per slot, SteamGridDB's pictures as a grid, and a file option.
@objc(OEArtworkPickerController)
final class OEArtworkPickerController: NSWindowController, NSCollectionViewDataSource, NSCollectionViewDelegate {

    private let game: OEDBGame
    private let artworkGame: OEArtworkStore.Game
    private let slots: [OEArtworkStore.Slot] = [.cover, .poster, .hero, .icon, .logo]
    private let slotPicker = NSSegmentedControl()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let grid = NSCollectionView()
    private let useButton = NSButton(title: "Use This Picture", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset to Automatic", target: nil, action: nil)
    private var candidates = [SteamGridDBItem]()
    private var thumbnails = [URL: NSImage]()
    private var loading: Task<Void, Never>?
    private static var open = [OEArtworkPickerController]()

    @objc(showFor:)
    static func show(for game: OEDBGame) {
        let controller = OEArtworkPickerController(game: game)
        open.append(controller)
        controller.showWindow(nil)
        controller.window?.center()
    }

    private init(game: OEDBGame) {
        self.game = game
        self.artworkGame = OEArtworkStore.Game(game)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Choose Artwork — \(game.displayName)"
        window.minSize = NSSize(width: 520, height: 420)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.loading?.cancel()
            Self.open.removeAll { $0 === self }
        }
        buildUI(in: window)
        slotChanged()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var slot: OEArtworkStore.Slot { slots[max(0, slotPicker.selectedSegment)] }

    private func buildUI(in window: NSWindow) {
        slotPicker.segmentCount = slots.count
        for (index, slot) in slots.enumerated() { slotPicker.setLabel(slot.rawValue.capitalized, forSegment: index) }
        slotPicker.selectedSegment = 0
        slotPicker.target = self
        slotPicker.action = #selector(slotChanged)

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 120, height: 170)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        grid.collectionViewLayout = layout
        grid.isSelectable = true
        grid.allowsMultipleSelection = false
        grid.dataSource = self
        grid.delegate = self
        grid.register(PickerItem.self, forItemWithIdentifier: PickerItem.identifier)
        grid.backgroundColors = [.clear]
        let scroll = NSScrollView()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .bezelBorder

        useButton.target = self
        useButton.action = #selector(useSelected)
        useButton.bezelStyle = .rounded
        useButton.keyEquivalent = "\r"
        useButton.isEnabled = false
        resetButton.target = self
        resetButton.action = #selector(resetSlot)
        resetButton.bezelStyle = .rounded
        let fileButton = NSButton(title: "From File…", target: self, action: #selector(chooseFile))
        fileButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [resetButton, fileButton, NSView(), useButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [slotPicker, status, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        guard let content = window.contentView else { return }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    // MARK: Loading

    @objc private func slotChanged() {
        loading?.cancel()
        candidates = []
        useButton.isEnabled = false
        grid.reloadData()
        let entry = OEArtworkStore.shared.entry(artworkGame, slot)
        resetButton.isEnabled = entry?.pinned == true
        let current = entry.map { $0.pinned ? "A picture you chose is pinned for this slot." : "This slot is filled automatically." }
            ?? "This slot has no picture yet."
        guard SteamGridDBClient.isConfigured else {
            status.stringValue = current + " Add a SteamGridDB key in Preferences → Artwork to browse pictures, or use From File…"
            return
        }
        status.stringValue = current + " Looking up pictures on SteamGridDB…"
        let slot = self.slot, name = game.displayName
        loading = Task { @MainActor [weak self] in
            let id = await SteamGridDBClient.shared.gameID(for: name)
            let found = id == nil ? [] : await SteamGridDBClient.shared.candidates(gameID: id!, slot: slot)
            guard let self = self, !Task.isCancelled, self.slot == slot else { return }
            self.candidates = found
            self.grid.reloadData()
            self.status.stringValue = current + (found.isEmpty ? " SteamGridDB has nothing for this slot." : " \(found.count) pictures from SteamGridDB, best first.")
        }
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { candidates.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: PickerItem.identifier, for: indexPath)
        guard let picker = item as? PickerItem, candidates.indices.contains(indexPath.item) else { return item }
        let candidate = candidates[indexPath.item]
        picker.configure(text: "\(candidate.width)×\(candidate.height) · ★\(candidate.score)\n\(candidate.authorName ?? "")")
        picker.setImage(thumbnails[candidate.thumbURL])
        if thumbnails[candidate.thumbURL] == nil {
            Task { @MainActor [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: candidate.thumbURL), let image = NSImage(data: data) else { return }
                self?.thumbnails[candidate.thumbURL] = image
                (self?.grid.item(at: indexPath) as? PickerItem)?.setImage(image)
            }
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { useButton.isEnabled = true }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { useButton.isEnabled = !collectionView.selectionIndexPaths.isEmpty }

    // MARK: Choosing

    @objc private func useSelected() {
        guard let index = grid.selectionIndexPaths.first?.item, candidates.indices.contains(index) else { return }
        let candidate = candidates[index]
        status.stringValue = "Downloading…"
        useButton.isEnabled = false
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            guard let (data, response) = try? await URLSession.shared.data(from: candidate.url),
                  (response as? HTTPURLResponse)?.statusCode == 200, NSImage(data: data) != nil else {
                self.status.stringValue = "Could not download that picture. Nothing was changed."
                self.useButton.isEnabled = true
                return
            }
            self.apply(data, provider: "steamgriddb")
        }
    }

    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = NSImage.imageTypes
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window!) { [weak self] result in
            guard result == .OK, let url = panel.url, let data = try? Data(contentsOf: url), NSImage(data: data) != nil else { return }
            self?.apply(data, provider: nil)
        }
    }

    private func apply(_ data: Data, provider: String?) {
        let outcome = OEArtworkChoice.choose(data, for: artworkGame, slot: slot, provider: provider)
        if case .failed = outcome {
            status.stringValue = "Could not save that picture. Nothing was changed."
            useButton.isEnabled = true
            return
        }
        // The library's own cover is the game's box art. The other slots are read from the artwork folder.
        if slot == .cover, let image = NSImage(data: data) {
            game.setBoxImage(image: image)
            try? game.managedObjectContext?.save()
        }
        Task { @MainActor in OEBigPictureArt.shared.reset() }
        status.stringValue = "Saved and pinned. Anything it replaced is kept in the artwork folder's History."
        resetButton.isEnabled = true
    }

    @objc private func resetSlot() {
        OEArtworkChoice.resetToAutomatic(artworkGame, slot: slot)
        Task { @MainActor in OEBigPictureArt.shared.reset() }
        resetButton.isEnabled = false
        status.stringValue = "Reset. The picture stays in the artwork folder; automatic fetching can replace it now."
    }

    // MARK: Cell

    private final class PickerItem: NSCollectionViewItem {
        static let identifier = NSUserInterfaceItemIdentifier("PickerItem")
        private let picture = NSImageView()
        private let caption = NSTextField(wrappingLabelWithString: "")

        override func loadView() {
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 170))
            picture.imageScaling = .scaleProportionallyUpOrDown
            picture.frame = NSRect(x: 4, y: 40, width: 112, height: 126)
            caption.font = .systemFont(ofSize: 10)
            caption.textColor = .secondaryLabelColor
            caption.frame = NSRect(x: 4, y: 0, width: 112, height: 38)
            container.addSubview(picture)
            container.addSubview(caption)
            container.wantsLayer = true
            container.layer?.cornerRadius = 6
            view = container
        }

        override var isSelected: Bool {
            didSet { view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor : nil }
        }

        func configure(text: String) { caption.stringValue = text }
        func setImage(_ image: NSImage?) { picture.image = image }
    }
}
