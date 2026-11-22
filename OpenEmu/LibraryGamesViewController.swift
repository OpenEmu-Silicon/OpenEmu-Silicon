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
import ImageIO

extension NSNotification.Name {
    static let OELibrarySplitViewResetSidebar = NSNotification.Name("OELibrarySplitViewResetSidebar")
}

final class LibraryGamesViewController: NSSplitViewController {
    
    private static let skipDiscGuideMessageKey = "OESkipDiscGuideMessageKey"
    private lazy var discGuideMessageSystemIDs: [String?] = []
    
    private let sidebarMinWidth: CGFloat = 105
    private let sidebarDefaultWidth: CGFloat = 200
    private let sidebarMaxWidth: CGFloat = 450
    private let collectionViewMinWidth: CGFloat = 495
    
    private var sidebarController: SidebarController!
    private var collectionController: GameCollectionViewController!

    // Grid artwork has a fixed-width image well but its height depends on
    // the game's cover shape. Keep only the *average aspect ratio* of the
    // selected console; never read image files while the zoom slider moves.
    private var averageCoverHeightPerWidth: CGFloat = 1
    private var measuredCoverRatios = [URL: CGFloat]()
    private var currentGridCategory: AnyObject?

    // These values match GameCollectionViewItem.xib. They are fixed in points,
    // not scaled with the artwork: 13+13 horizontal image margins, 7 top,
    // and 17+16+4+11 points for title/rating beneath the image.
    private static let gridImageHorizontalMargins: CGFloat = 26
    // Standard horizontal section inset in ImageCollectionViewController.xib.
    // This is the visual left margin when art completely fills its image well.
    private static let gridDefaultHorizontalInset: CGFloat = 45
    private static let gridImageTopMargin: CGFloat = 7
    private static let gridFooterHeight: CGFloat = 48
    private static let gridImageNonArtworkHeight: CGFloat = gridImageTopMargin + gridFooterHeight
    private var toolbar: LibraryToolbar? {
        view.window?.toolbar as? LibraryToolbar
    }
    
    var database: OELibraryDatabase?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        sidebarController = SidebarController()
        collectionController = GameCollectionViewController()
        
        setUpSplitView()
        assignDatabase()
        
        NotificationCenter.default.addObserver(self, selector: #selector(updateCollectionContentsFromSidebar), name: .OESidebarSelectionDidChange, object: nil)
        // Cover replacements create/update OEDBImage objects. Invalidate the
        // cached ratios only for such saves, never for slider movement.
        NotificationCenter.default.addObserver(self,
            selector: #selector(libraryArtworkDidSave(_:)),
            name: .NSManagedObjectContextDidSave,
            object: OELibraryDatabase.default?.mainThreadContext)

    }

    // The full-height sidebar mode is intentionally constant. Flipping it
    // while an NSToolbar is visible makes AppKit retain separate titlebar
    // section heights when the toolbar is subsequently hidden.

    override func viewWillAppear() {
        super.viewWillAppear()
        
        setUpSplitViewAutosave()
        updateCollectionContentsFromSidebar()
        
        view.needsDisplay = true
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        
        collectionController.updateBlankSlate()
        applyCachedGridSpacing()
        
        if #available(macOS 11.0, *) {
            view.window?.titlebarSeparatorStyle = .automatic
        }
    }
    
    override func viewWillDisappear() {
        super.viewWillDisappear()
        
        if #available(macOS 11.0, *) {
            view.window?.titlebarSeparatorStyle = .line
        }
    }
    
    private func assignDatabase() {
        sidebarController.database = database
        collectionController.database = database
    }
    
    // MARK: - Split View
    
    private func setUpSplitView() {
        
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = NSColor.clear.cgColor
        
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = sidebarMinWidth
        sidebarItem.maximumThickness = sidebarMaxWidth
        sidebarItem.canCollapse = false
        if #available(macOS 11.0, *) {
            // Keep one titlebar geometry for the entire life of this view.
            // Switching full-height layout at runtime leaves stale sidebar
            // separator geometry after the toolbar is hidden. The normal
            // height layout does not create a separate full-height titlebar
            // section for the sidebar.
            sidebarItem.allowsFullHeightLayout = false
            sidebarItem.titlebarSeparatorStyle = .line
        }
        addSplitViewItem(sidebarItem)

        // The NSSplitViewItem sidebar wrapper spans the full left pane but the
        // SidebarController's view may not cover its bottom edge (xib gap between
        // the scroll view and the game-scanner panel). The system's
        // NSVisualEffectView behind the wrapper samples the desktop colour, which
        // renders dark on a dark wallpaper even in light mode.
        //
        // Fix: attach an NSBox directly to the wrapper so it covers every pixel
        // of the pane. Clear in dark mode so it never touches the vibrancy
        // compositor (an opaque fill in dark mode causes ghost-toolbar artifacts).
        if let sidebarWrapper = splitView.subviews.first {
            let gapFill = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? .clear
                    : NSColor(white: 0.88, alpha: 1)
            }
            let bg = NSBox()
            bg.boxType = .custom
            bg.borderWidth = 0
            bg.contentViewMargins = .zero
            bg.fillColor = gapFill
            bg.translatesAutoresizingMaskIntoConstraints = false
            sidebarWrapper.addSubview(bg, positioned: .below, relativeTo: nil)
            NSLayoutConstraint.activate([
                bg.topAnchor.constraint(equalTo: sidebarWrapper.topAnchor),
                bg.bottomAnchor.constraint(equalTo: sidebarWrapper.bottomAnchor),
                bg.leadingAnchor.constraint(equalTo: sidebarWrapper.leadingAnchor),
                bg.trailingAnchor.constraint(equalTo: sidebarWrapper.trailingAnchor),
            ])
        }

        let collectionItem = NSSplitViewItem(viewController: collectionController)
        collectionItem.minimumThickness = collectionViewMinWidth
        if #available(macOS 11.0, *) {
            collectionItem.titlebarSeparatorStyle = .line
        }
        addSplitViewItem(collectionItem)
    }
    
    private func setUpSplitViewAutosave() {
        
        if splitView.autosaveName != nil && !(splitView.autosaveName == "") {
            return
        }
        
        let autosaveName = "OELibraryGamesSplitView"
        
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(autosaveName)") == nil {
            splitView.setPosition(sidebarDefaultWidth, ofDividerAt: 0)
        }
        
        splitView.autosaveName = autosaveName
        
        NotificationCenter.default.addObserver(self, selector: #selector(resetSidebar), name: .OELibrarySplitViewResetSidebar, object: nil)
    }
    
    @objc func resetSidebar() {
        splitView.setPosition(sidebarDefaultWidth, ofDividerAt: 0)
    }
    
    // MARK: - Actions
    
    @IBAction func newCollection(_ sender: AnyObject?) {
        sidebarController.newCollection(sender)
    }
    
    @IBAction func selectSystems(_ sender: Any?) {
        sidebarController.selectSystems(sender)
    }
    
    @IBAction func switchToGridView(_ sender: Any?) {
        collectionController.showGridView()
    }
    
    @IBAction func switchToListView(_ sender: Any?) {
        collectionController.showListView()
    }
    
    @IBAction func search(_ sender: NSSearchField?) {
        guard let searchField = sender else { return }
        collectionController.performSearch(searchField.stringValue)
    }
    
    @IBAction func changeGridSize(_ sender: NSSlider?) {
        guard let slider = toolbar?.gridSizeSlider else { return }
        collectionController.zoomGridView(zoomValue: CGFloat(slider.doubleValue))
        applyCachedGridSpacing() // cached ratio only: O(1) on every slider event
    }
    
    @IBAction func decreaseGridSize(_ sender: AnyObject?) {
        guard let slider = toolbar?.gridSizeSlider else { return }
        slider.doubleValue -= sender?.tag == 199 ? 0.25 : 0.5
        collectionController.zoomGridView(zoomValue: CGFloat(slider.doubleValue))
        applyCachedGridSpacing()
    }
    
    @IBAction func increaseGridSize(_ sender: AnyObject?) {
        guard let slider = toolbar?.gridSizeSlider else { return }
        slider.doubleValue += sender?.tag == 199 ? 0.25 : 0.5
        collectionController.zoomGridView(zoomValue: CGFloat(slider.doubleValue))
        applyCachedGridSpacing()
    }
    
    @objc func updateCollectionContentsFromSidebar() {
        
        let selectedItem = sidebarController.selectedSidebarItem
        collectionController.representedObject = selectedItem as? GameCollectionViewItemProtocol
        if currentGridCategory !== (selectedItem as AnyObject?) {
            currentGridCategory = selectedItem as AnyObject?
            measureSelectedArtworkAspectRatio()
        } else {
            applyCachedGridSpacing()
        }
        
        // For empty collections of disc-based games, display an alert to compel the user to read the disc-importing guide.
        // Delay disc alert by 200 ms to allow navigating past disc-based systems with arrow keys in the sidebar without triggering the alert.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) {
            guard self.sidebarController.selectedSidebarItem === selectedItem else { return }
            
            if let system = selectedItem as? OEDBSystem,
               system.plugin?.supportsDiscsWithDescriptorFile ?? false,
               system.games.isEmpty,
               !self.discGuideMessageSystemIDs.contains(system.systemIdentifier),
               !UserDefaults.standard.bool(forKey: Self.skipDiscGuideMessageKey),
               let window = self.view.window {
                
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("Have you read the guide?", comment: "")
                alert.informativeText = NSLocalizedString("Disc-based games have special requirements. Please read the disc importing guide.", comment: "")
                alert.alertStyle = .informational
                alert.addButton(withTitle: NSLocalizedString("View Guide in Browser", comment: ""))
                alert.addButton(withTitle: NSLocalizedString("Dismiss", comment: ""))
                
                alert.beginSheetModal(for: window) { result in
                    if result == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(.userGuideCDBasedGames)
                    }
                }
                
                self.discGuideMessageSystemIDs.append(system.systemIdentifier)
            }
        }
    }
    
    // MARK: - Aspect-ratio-aware game grid

    /// Read image *metadata* only on console selection / artwork replacement.
    /// All files are ignored while the user resizes artwork; the resulting
    /// average is a single cached number, not a per-game calculation.
    private func measureSelectedArtworkAspectRatio() {
        let games: [OEDBGame]
        if let system = sidebarController.selectedSidebarItem as? OEDBSystem {
            // Use the complete console, not just current search results.
            games = Array(system.games)
        } else {
            games = collectionController.gamesDataSource.games
        }

        var total: CGFloat = 0
        var count = 0
        for game in games {
            let fallback = game.system?.coverAspectRatio ?? 1
            let ratio: CGFloat
            if let url = game.boxImage?.imageURL, url.isFileURL {
                if let cached = measuredCoverRatios[url] {
                    ratio = cached
                } else {
                    let measured = Self.coverHeightPerWidth(at: url) ?? fallback
                    ratio = measured
                    measuredCoverRatios[url] = measured
                }
            } else {
                ratio = fallback
            }
            guard ratio.isFinite, ratio > 0 else { continue }
            total += ratio
            count += 1
        }
        averageCoverHeightPerWidth = count > 0 ? total / CGFloat(count) : 1
        applyCachedGridSpacing()
    }

    /// CGImageSource reads width/height from the image header without
    /// allocating the decoded artwork bitmap.
    private static func coverHeightPerWidth(at url: URL) -> CGFloat? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let attributes = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
              let width = attributes[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = attributes[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0 else { return nil }
        return CGFloat(height.doubleValue / width.doubleValue)
    }

    /// With the image at the bottom of its well, shorter landscape art leaves
    /// dead space ABOVE it if every item has the same height. Shorten the
    /// *cell*, not the picture, so both the top margin and visible inter-row
    /// gap remain consistent. The title, stars and image width are unchanged.
    /// This is a handful of arithmetic operations during zoom (NO file I/O).
    private func applyCachedGridSpacing() {
        guard collectionController != nil,
              collectionController.isViewLoaded else { return }
        let layout = collectionController.flowLayout!
        let zoom = CGFloat(ImageCollectionViewController.lastGridSize)
        let baseSize = collectionController.itemSize
        let itemWidth = baseSize.width * zoom * collectionController.gridWidthMultiplier
        let originalHeight = baseSize.height * zoom * collectionController.gridZoomMultiplier
        let wellWidth = max(1, itemWidth - Self.gridImageHorizontalMargins)
        let maximumArtworkHeight = max(1, originalHeight - Self.gridImageNonArtworkHeight)
        let averageArtworkHeight = min(maximumArtworkHeight,
                                       wellWidth * averageCoverHeightPerWidth)
        let newHeight = min(originalHeight,
                            averageArtworkHeight + Self.gridImageNonArtworkHeight)

        // Portrait covers fill the well's height before its width, leaving
        // empty pixels on BOTH sides of a centered image. Remove that hidden
        // half-padding from the section's left/right margins; the FLOW layout
        // still distributes the space between columns evenly. A square or
        // landscape cover normally fills the well width, so it keeps 45 pt.
        // This uses the *cached average ratio*; no cover files are opened while
        // the user zooms, and no artwork/image-view sizes are modified.
        let displayedCoverWidth = min(wellWidth,
            maximumArtworkHeight / max(averageCoverHeightPerWidth, 0.01))
        let unusedPaddingPerSide = max(0, (wellWidth - displayedCoverWidth) / 2)
        let horizontalInset = max(0,
            Self.gridDefaultHorizontalInset - unusedPaddingPerSide)

        var insets = layout.sectionInset
        insets.left = horizontalInset
        insets.right = horizontalInset
        // Keep the already-approved FIRST ROW margin independent of dynamic
        // horizontal insets: 45 + 13 - 7 = 51, giving 58 pt above the covers.
        insets.top = max(0, Self.gridDefaultHorizontalInset
                            + Self.gridImageHorizontalMargins / 2
                            - Self.gridImageTopMargin)
        // NSEdgeInsets is a plain AppKit structure, not Swift Equatable.
        // Compare its fields explicitly to avoid needless layout invalidation.
        let currentInsets = layout.sectionInset
        if currentInsets.top != insets.top || currentInsets.left != insets.left ||
           currentInsets.bottom != insets.bottom || currentInsets.right != insets.right {
            layout.sectionInset = insets
        }

        let newSize = NSSize(width: itemWidth, height: max(Self.gridImageNonArtworkHeight + 1, newHeight))
        if layout.itemSize != newSize {
            layout.itemSize = newSize
            layout.invalidateLayout()
        }
    }

    @objc private func libraryArtworkDidSave(_ notification: Notification) {
        let keys = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey]
        let artworkChanged = keys.contains { key in
            guard let objects = notification.userInfo?[key] as? Set<NSManagedObject>
                else { return false }
            return objects.contains { $0 is OEDBImage }
        }
        guard artworkChanged else { return }
        // After the save has merged, fetch the updated relationships/URLs.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measuredCoverRatios.removeAll()
            self.measureSelectedArtworkAspectRatio()
        }
    }

    @objc func makeNewCollectionWithSelectedGames(_ sender: Any?) {
        assert(Thread.isMainThread, "Only call on main thread!")
        
        sidebarController.newCollection(games: selectedGames)
    }
}

extension LibraryGamesViewController: LibrarySubviewControllerGameSelection {
    
    var selectedGames: [OEDBGame] {
        collectionController.selectedGames
    }
}

// MARK: - Validation

extension LibraryGamesViewController: NSMenuItemValidation {
    
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let isGridView = collectionController.viewMode == .grid
        let isBlankSlate = collectionController.shouldShowBlankSlate
        
        switch menuItem.action {
        case #selector(switchToGridView):
            menuItem.state = isGridView ? .on : .off
            return !isBlankSlate
        case #selector(switchToListView):
            menuItem.state = !isGridView ? .on : .off
            return !isBlankSlate
        default:
            return true
        }
    }
}

