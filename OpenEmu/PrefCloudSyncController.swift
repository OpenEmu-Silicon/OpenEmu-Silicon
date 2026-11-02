// Copyright (c) 2024, OpenEmu Team
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

/// Preferences pane for choosing the Cloud Sync backup folder and seeing its status.
final class PrefCloudSyncController: NSViewController {
    
    // MARK: - Backup Folder UI

    private let bkHeaderLabel     = NSTextField(labelWithString: "")
    private let bkDescLabel       = NSTextField(wrappingLabelWithString: "")
    private let bkStatusDot       = NSTextField(labelWithString: "●")
    private let bkStatusLabel     = NSTextField(labelWithString: "")
    private let bkFolderPathLabel = NSTextField(labelWithString: "")
    private let bkChooseButton    = NSButton()
    private let bkOpenFinderButton = NSButton()
    private let bkRemoveButton    = NSButton()
    private let bkLastSyncedLabel = NSTextField(labelWithString: "")
    private let bkNoteLabel       = NSTextField(wrappingLabelWithString: "")
    private let awHeaderLabel     = NSTextField(labelWithString: "Artwork")
    private let awScopePopup      = NSPopUpButton(frame: .zero, pullsDown: false)
    private let awRestoreButton   = NSButton()
    private let awStatusLabel     = NSTextField(wrappingLabelWithString: "")
    private var bkStatusToken: NSObjectProtocol?
    
    private lazy var dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df
    }()
    
    // MARK: - Lifecycle
    
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 468, height: 440))
        buildUI()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        updateBackupStatus()

        bkStatusToken = NotificationCenter.default.addObserver(
            forName: .OEFolderBackupStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateBackupStatus()
        }
    }
    
    deinit {
        if let token = bkStatusToken    { NotificationCenter.default.removeObserver(token) }
    }
    
    // MARK: - Build UI
    
    private func buildUI() {
        // ── Header ──────────────────────────────────────────────────
        bkHeaderLabel.stringValue = "Backup Folder"
        bkHeaderLabel.font = .boldSystemFont(ofSize: 15)
        bkHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bkHeaderLabel)

        // ── Description ─────────────────────────────────────────────
        bkDescLabel.stringValue = "Automatically back up save states, battery saves, and BIOS files to any folder. Choose a folder inside iCloud Drive to sync across your Macs, or use Dropbox, an external drive, or any local path."
        bkDescLabel.font = .systemFont(ofSize: 12)
        bkDescLabel.textColor = .secondaryLabelColor
        bkDescLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bkDescLabel)

        // ── Status row ───────────────────────────────────────────────
        bkStatusDot.font = .systemFont(ofSize: 14)
        bkStatusDot.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bkStatusDot)

        bkStatusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        bkStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bkStatusLabel)

        // ── Folder path ──────────────────────────────────────────────
        bkFolderPathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        bkFolderPathLabel.textColor = .secondaryLabelColor
        bkFolderPathLabel.lineBreakMode = .byTruncatingMiddle
        bkFolderPathLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bkFolderPathLabel)

        // ── Buttons ──────────────────────────────────────────────────
        bkChooseButton.title = "Choose Folder…"
        bkChooseButton.bezelStyle = .rounded
        bkChooseButton.controlSize = .regular
        bkChooseButton.font = .systemFont(ofSize: 13)
        bkChooseButton.target = self
        bkChooseButton.action = #selector(chooseBackupFolder)
        bkChooseButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bkChooseButton)

        bkOpenFinderButton.title = "Show in Finder"
        bkOpenFinderButton.bezelStyle = .rounded
        bkOpenFinderButton.controlSize = .regular
        bkOpenFinderButton.font = .systemFont(ofSize: 13)
        bkOpenFinderButton.target = self
        bkOpenFinderButton.action = #selector(openBackupInFinder)
        bkOpenFinderButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bkOpenFinderButton)

        bkRemoveButton.title = "Remove"
        bkRemoveButton.bezelStyle = .rounded
        bkRemoveButton.controlSize = .regular
        bkRemoveButton.font = .systemFont(ofSize: 13)
        bkRemoveButton.target = self
        bkRemoveButton.action = #selector(removeBackupFolder)
        bkRemoveButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bkRemoveButton)

        // ── Last synced ──────────────────────────────────────────────
        bkLastSyncedLabel.font = .systemFont(ofSize: 11)
        bkLastSyncedLabel.textColor = .secondaryLabelColor
        bkLastSyncedLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bkLastSyncedLabel)

        // ── Note ─────────────────────────────────────────────────────
        bkNoteLabel.stringValue = "ROMs are not included in the backup."
        bkNoteLabel.font = .systemFont(ofSize: 11)
        bkNoteLabel.textColor = .tertiaryLabelColor
        bkNoteLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bkNoteLabel)

        // ── Artwork ──────────────────────────────────────────────────
        awHeaderLabel.font = .boldSystemFont(ofSize: 15)
        awScopePopup.addItems(withTitles: ["Don't back up artwork", "Pinned picks and history", "All artwork"])
        awScopePopup.item(at: 0)?.tag = OEArtworkBackup.Scope.off.rawValue
        awScopePopup.item(at: 1)?.tag = OEArtworkBackup.Scope.pinnedAndHistory.rawValue
        awScopePopup.item(at: 2)?.tag = OEArtworkBackup.Scope.everything.rawValue
        awScopePopup.selectItem(withTag: OEArtworkBackup.configuredScope.rawValue)
        awScopePopup.target = self
        awScopePopup.action = #selector(artworkScopeChanged)
        awRestoreButton.title = "Restore Artwork from Backup"
        awRestoreButton.bezelStyle = .rounded
        awRestoreButton.target = self
        awRestoreButton.action = #selector(restoreArtwork)
        awStatusLabel.stringValue = "Artwork is only ever added to the backup. Deleting a picture here removes nothing there, and a restore never replaces a picture you have; when two differ, both are kept."
        awStatusLabel.font = .systemFont(ofSize: 11)
        awStatusLabel.textColor = .secondaryLabelColor
        for item in [awHeaderLabel, awScopePopup, awRestoreButton, awStatusLabel] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            awHeaderLabel.topAnchor.constraint(equalTo: bkNoteLabel.bottomAnchor, constant: 22),
            awHeaderLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            awScopePopup.topAnchor.constraint(equalTo: awHeaderLabel.bottomAnchor, constant: 10),
            awScopePopup.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 34),
            awRestoreButton.centerYAnchor.constraint(equalTo: awScopePopup.centerYAnchor),
            awRestoreButton.leadingAnchor.constraint(equalTo: awScopePopup.trailingAnchor, constant: 8),
            awStatusLabel.topAnchor.constraint(equalTo: awScopePopup.bottomAnchor, constant: 10),
            awStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            awStatusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),
        ])

        // ── Layout ───────────────────────────────────────────────────
        NSLayoutConstraint.activate([
            bkHeaderLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            bkHeaderLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            bkHeaderLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),

            bkDescLabel.topAnchor.constraint(equalTo: bkHeaderLabel.bottomAnchor, constant: 8),
            bkDescLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            bkDescLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),

            bkStatusDot.topAnchor.constraint(equalTo: bkDescLabel.bottomAnchor, constant: 18),
            bkStatusDot.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),

            bkStatusLabel.centerYAnchor.constraint(equalTo: bkStatusDot.centerYAnchor),
            bkStatusLabel.leadingAnchor.constraint(equalTo: bkStatusDot.trailingAnchor, constant: 6),

            bkFolderPathLabel.topAnchor.constraint(equalTo: bkStatusDot.bottomAnchor, constant: 10),
            bkFolderPathLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            bkFolderPathLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),

            bkChooseButton.topAnchor.constraint(equalTo: bkFolderPathLabel.bottomAnchor, constant: 14),
            bkChooseButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 34),

            bkOpenFinderButton.centerYAnchor.constraint(equalTo: bkChooseButton.centerYAnchor),
            bkOpenFinderButton.leadingAnchor.constraint(equalTo: bkChooseButton.trailingAnchor, constant: 8),

            bkRemoveButton.centerYAnchor.constraint(equalTo: bkChooseButton.centerYAnchor),
            bkRemoveButton.leadingAnchor.constraint(equalTo: bkOpenFinderButton.trailingAnchor, constant: 8),

            bkLastSyncedLabel.topAnchor.constraint(equalTo: bkChooseButton.bottomAnchor, constant: 12),
            bkLastSyncedLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            bkLastSyncedLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),

            bkNoteLabel.topAnchor.constraint(equalTo: bkLastSyncedLabel.bottomAnchor, constant: 8),
            bkNoteLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            bkNoteLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),
        ])
    }
    
    private func updateBackupStatus() {
        let mgr    = OEFolderBackupManager.shared
        let green  = NSColor(red: 0.2,  green: 0.78, blue: 0.35, alpha: 1)
        let red    = NSColor(red: 0.87, green: 0.20, blue: 0.18, alpha: 1)
        let yellow = NSColor(red: 0.95, green: 0.73, blue: 0.00, alpha: 1)
        let gray   = NSColor.secondaryLabelColor

        let hasFolderURL = mgr.backupFolderURL != nil

        switch mgr.status {
        case .noFolderSelected:
            bkStatusDot.textColor     = gray
            bkStatusLabel.stringValue = "No folder selected"
            bkStatusLabel.textColor   = gray
        case .idle:
            bkStatusDot.textColor     = green
            bkStatusLabel.stringValue = "Active"
            bkStatusLabel.textColor   = green
        case .syncing:
            bkStatusDot.textColor     = yellow
            bkStatusLabel.stringValue = "Syncing…"
            bkStatusLabel.textColor   = yellow
        case .failed:
            bkStatusDot.textColor     = red
            bkStatusLabel.stringValue = "Last backup failed"
            bkStatusLabel.textColor   = red
        @unknown default:
            break
        }

        bkFolderPathLabel.stringValue  = mgr.backupFolderURL?.path ?? ""
        bkOpenFinderButton.isHidden    = !hasFolderURL
        bkRemoveButton.isHidden        = !hasFolderURL

        if let date = mgr.lastBackupDate {
            bkLastSyncedLabel.stringValue = "Last backed up: \(dateFormatter.string(from: date))"
        } else if hasFolderURL {
            bkLastSyncedLabel.stringValue = "No backup yet"
        } else {
            bkLastSyncedLabel.stringValue = ""
        }
    }

    @objc private func chooseBackupFolder() {
        guard let window = view.window else { return }
        OEFolderBackupManager.shared.chooseFolder(relativeTo: window) { [weak self] _ in
            self?.updateBackupStatus()
        }
    }

    @objc private func artworkScopeChanged() {
        OEArtworkBackup.configuredScope = OEArtworkBackup.Scope(rawValue: awScopePopup.selectedTag()) ?? .pinnedAndHistory
    }

    @objc private func restoreArtwork() {
        awRestoreButton.isEnabled = false
        awStatusLabel.stringValue = "Restoring…"
        OEFolderBackupManager.shared.restoreArtwork { [weak self] result in
            guard let self = self else { return }
            self.awRestoreButton.isEnabled = true
            switch result {
            case .success(let report):
                self.awStatusLabel.stringValue = "Restored \(report.copied) picture(s). \(report.keptBoth) differed from one you have and were kept beside it. Nothing was replaced."
                Task { @MainActor in OEBigPictureArt.shared.reset() }
            case .failure(.nothingToRestore):
                self.awStatusLabel.stringValue = "There is no artwork in the backup folder yet."
            case .failure(.overlapping):
                self.awStatusLabel.stringValue = "The artwork folder and the backup folder overlap, so there is nothing to copy."
            case .failure:
                self.awStatusLabel.stringValue = "The restore stopped partway. Nothing was replaced; run it again to carry on."
            }
        }
    }

    @objc private func openBackupInFinder() {
        guard let url = OEFolderBackupManager.shared.backupFolderURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func removeBackupFolder() {
        OEFolderBackupManager.shared.removeFolder()
        updateBackupStatus()
    }
}

// MARK: - PreferencePane

extension PrefCloudSyncController: PreferencePane {
    
    var icon: NSImage? {
        // Use the built-in iCloud/cloud SF Symbol (available macOS 11+), fallback to nil.
        if #available(macOS 11.0, *) {
            return NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: "Cloud Sync")
        }
        return NSImage(named: NSImage.networkName)
    }
    
    var panelTitle: String { "Cloud Sync" }
    
    var viewSize: NSSize { NSSize(width: 468, height: 440) }
}
