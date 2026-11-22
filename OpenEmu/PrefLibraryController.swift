// Copyright (c) 2020, OpenEmu Team
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

final class PrefLibraryController: NSViewController {

    private static let showStarRatingsKey = "OEShowStarRatings"
    private static let showCollectionsKey = "OEShowCollections"
    private static let showToolbarKey = "OEShowLibraryToolbar"
    private static let roundedCornersKey = "OERoundedGameCorners"

    @IBOutlet var availableLibrariesViewController: AvailableLibrariesViewController!
    @IBOutlet var librariesView: NSView!
    @IBOutlet var pathField: NSPathControl!
    @IBOutlet var resetLocationButton: NSButton!

    override func viewDidLoad() {
        super.viewDidLoad()

        pathField.url = OELibraryDatabase.default?.databaseFolderURL
        showResetLocationButtonIfNeeded()

        availableLibrariesViewController.isEnableObservers = true
        addChild(availableLibrariesViewController)

        let size = librariesView.frame.size
        let scrollView = availableLibrariesViewController.view as! NSScrollView
        let gridView = librariesView.superview as! NSGridView
        gridView.cell(for: librariesView)?.contentView = scrollView
        librariesView.removeFromSuperview()
        librariesView = scrollView

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .bezelBorder
        // Use a minimum height but allow the scroll view to grow taller.
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalToConstant: size.width),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: size.height)
        ])

        // Center the grid horizontally within the (potentially wider) window.
        // Deactivate XIB's fixed leading=30 and soft trailing>=30, then pin to center.
        for c in view.constraints where (c.firstItem as? NSView) === gridView
                                     && c.firstAttribute == .leading {
            c.isActive = false
        }
        for c in view.constraints where c.secondItem as? NSView === gridView
                                     && c.secondAttribute == .trailing {
            c.isActive = false
        }
        NSLayoutConstraint.activate([
            gridView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            gridView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 30),
            gridView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -30)
        ])

        addDisplayOptions(to: gridView)
        availableLibrariesViewController.loadData()
    }

    // MARK: - Library display preferences

    private func addDisplayOptions(to gridView: NSGridView) {
        // The original XIB has nine rows: organization ends at row 6,
        // a separator is row 7, and Available Libraries is row 8.
        // Insert the new preferences between that separator and the library list.
        guard let librariesLabel = gridView.cell(atColumnIndex: 0, rowIndex: 8).contentView else { return }
        let previousSeparator = gridView.cell(atColumnIndex: 0, rowIndex: 7).contentView

        // The old label-to-separator constraint would skip over our new rows.
        for constraint in gridView.constraints where
            (constraint.firstItem as? NSView) === librariesLabel &&
            (constraint.secondItem as? NSView) === previousSeparator &&
            constraint.firstAttribute == .top {
            constraint.isActive = false
        }

        let displayLabel = NSTextField(labelWithString: NSLocalizedString("Display Options:", comment: "Library preferences section title"))
        displayLabel.alignment = .right
        displayLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        let defaults = UserDefaults.standard

        // 1. Collections: enabled by default, and hiding never deletes data.
        let showCollections = NSButton(checkboxWithTitle: NSLocalizedString("Show Collections", comment: "Library display preference"),
                                       target: self, action: #selector(toggleCollections(_:)))
        showCollections.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        showCollections.state = (defaults.object(forKey: Self.showCollectionsKey) == nil || defaults.bool(forKey: Self.showCollectionsKey)) ? .on : .off
        gridView.insertRow(at: 8, with: [displayLabel, showCollections])

        // 2. Ratings: enabled by default; hide only the star control.
        let showStars = NSButton(checkboxWithTitle: NSLocalizedString("Show Star Ratings", comment: "Library display preference"),
                                 target: self, action: #selector(toggleStarRatings(_:)))
        showStars.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        showStars.state = (defaults.object(forKey: Self.showStarRatingsKey) == nil || defaults.bool(forKey: Self.showStarRatingsKey)) ? .on : .off
        gridView.insertRow(at: 9, with: [NSView(), showStars])

        // 3. Library window toolbar: enabled by default; the selection persists.
        let showToolbar = NSButton(checkboxWithTitle: NSLocalizedString("Show Toolbar", comment: "Library display preference"),
                                   target: self, action: #selector(toggleLibraryToolbar(_:)))
        showToolbar.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        showToolbar.state = (defaults.object(forKey: Self.showToolbarKey) == nil || defaults.bool(forKey: Self.showToolbarKey)) ? .on : .off
        gridView.insertRow(at: 10, with: [NSView(), showToolbar])

        // 4. Artwork corners: opt-in, retaining the existing saved preference.
        let roundedCorners = NSButton(checkboxWithTitle: NSLocalizedString("Round Corners on Game Artwork", comment: "Library display preference"),
                                      target: self, action: #selector(toggleRoundedCorners(_:)))
        roundedCorners.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        roundedCorners.state = defaults.bool(forKey: Self.roundedCornersKey) ? .on : .off
        gridView.insertRow(at: 11, with: [NSView(), roundedCorners])

        let separator = NSBox()
        separator.boxType = .separator
        let separatorRow = gridView.insertRow(at: 12, with: [separator, NSView()])
        separatorRow.topPadding = 6
        separatorRow.bottomPadding = 6
        gridView.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2),
                            verticalRange: NSRange(location: 12, length: 1))

        // Re-anchor the Available Libraries label to the new separator, leaving
        // its original top padding and the existing libraries list intact.
        NSLayoutConstraint.activate([
            librariesLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 23)
        ])
    }

    @objc private func toggleStarRatings(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Self.showStarRatingsKey)
        NotificationCenter.default.post(name: .oeStarRatingsVisibilityDidChange, object: nil)
    }

    @objc private func toggleCollections(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Self.showCollectionsKey)
        NotificationCenter.default.post(name: .oeCollectionsVisibilityDidChange, object: nil)
    }

    @objc private func toggleLibraryToolbar(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Self.showToolbarKey)
        NotificationCenter.default.post(name: .oeLibraryToolbarVisibilityDidChange, object: nil)
    }

    @objc private func toggleRoundedCorners(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Self.roundedCornersKey)
        NotificationCenter.default.post(name: .oeRoundedGameCornersDidChange, object: nil)
    }

    deinit {
        availableLibrariesViewController.isEnableObservers = false
    }

    // MARK: - Actions

    @IBAction func resetLibraryFolder(_ sender: Any?) {
        OELibraryDatabase.default?.moveGameLibraryToDefaultLocation()

        pathField.url = OELibraryDatabase.default?.databaseFolderURL
        showResetLocationButtonIfNeeded()
    }

    @IBAction func changeLibraryFolder(_ sender: Any?) {
        let alert = OEAlert()
        alert.messageUsesHTML = true
        alert.messageText = NSLocalizedString(
            "Moving the Game Library is not recommended",
            comment: "Message headline (attempted to change location of library)")
        alert.informativeText = NSLocalizedString("ALERT_MOVE_LIBRARY_HTML",
            comment: "Message text (attempted to change location of library, HTML)")
        alert.defaultButtonTitle = NSLocalizedString("Cancel", comment: "")
        alert.alternateButtonTitle = NSLocalizedString("I understand the risks",
            comment: "OK button (attempted to change location of library)")
        alert.beginSheetModal(for: view.window!) { result in
            if result == .alertSecondButtonReturn {
                self.moveGameLibrary()
            }
        }
    }

    private func moveGameLibrary() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true
        openPanel.beginSheetModal(for: view.window!) { result in
            if result == .OK, let url = openPanel.url {
                openPanel.orderOut(nil)
                OELibraryDatabase.default?.moveGameLibrary(to: url)
                self.pathField.url = OELibraryDatabase.default?.databaseFolderURL
                self.showResetLocationButtonIfNeeded()
            }
        }
    }

    private func showResetLocationButtonIfNeeded() {
        let defaultDatabasePath = (UserDefaults.standard.string(forKey: OELibraryDatabase.defaultDatabasePathKey)! as NSString).expandingTildeInPath
        let defaultLocation = URL(fileURLWithPath: defaultDatabasePath, isDirectory: true)

        let currentLocation = OELibraryDatabase.default?.databaseFolderURL

        resetLocationButton.isHidden = currentLocation == defaultLocation
    }

    @IBAction func resetWarningDialogs(_ sender: Any?) {
        let keysToRemove: [String] = [
            OEAlert.OEDeleteGameAlertSuppressionKey,
            OEAlert.OEDeleteSaveStateAlertSuppressionKey,
            OEAlert.OEDeleteScreenshotAlertSuppressionKey,
            OEAlert.OERemoveCollectionAlertSuppressionKey,
            OEAlert.OERemoveGameFromCollectionAlertSuppressionKey,
            OEAlert.OERemoveGameFromLibraryAlertSuppressionKey,
            OEAlert.OERenameSpecialSaveStateAlertSuppressionKey,
            OEAlert.OELoadAutoSaveAlertSuppressionKey,
            OEAlert.OEDownloadRomWarningSuppressionKey,
            OEAlert.OESaveGameAlertSuppressionKey,
            OEAlert.OEResetSystemAlertSuppressionKey,
            OEAlert.OEStopEmulationAlertSuppressionKey,
            OEAlert.OEChangeCoreAlertSuppressionKey,
            OEAlert.OEAutoSwitchCoreAlertSuppressionKey,
            OEAlert.OEGameCoreGlitchesSuppressionKey,
            OEAlert.OEDeleteShaderPresetAlertSuppressionKey,
            OEAlert.OEInputMonitoringAlertSuppressionKey,
        ]

        keysToRemove.forEach { key in
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

// MARK: - PreferencePane

extension PrefLibraryController: PreferencePane {

    var icon: NSImage? { NSImage(named: "library_tab_icon") }

    var panelTitle: String { "Library" }

    var viewSize: NSSize { view.fittingSize }
}
