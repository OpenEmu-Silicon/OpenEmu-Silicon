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

extension NSNotification.Name {
    static let OELibrarySplitViewResetSidebar = NSNotification.Name("OELibrarySplitViewResetSidebar")
}

/// What `LibraryGamesViewController` needs from the view that shows the games. Both the old
/// `OEGameCollectionViewController` and the new `GameCollectionViewController` provide it, so the
/// new one can be switched on from the debug preferences while it is tested.
protocol GamesCollectionControlling: NSViewController {
    func use(database: OELibraryDatabase?)
    var selectedGames: [OEDBGame] { get }
    var isGridView: Bool { get }
    var isBlankSlate: Bool { get }
    
    func updateBlankSlate()
    func showGridView()
    func showListView()
    func performSearch(_ text: String)
    func zoomGrid(to value: CGFloat)
}

extension OEGameCollectionViewController: GamesCollectionControlling {
    var isGridView: Bool { selectedViewTag == .gridViewTag }
    var isBlankSlate: Bool { shouldShowBlankSlate() }
    func use(database: OELibraryDatabase?) { self.database = database }
    func zoomGrid(to value: CGFloat) { zoomGridView(withValue: value) }
}

extension GameCollectionViewController: GamesCollectionControlling {
    var isGridView: Bool { viewMode == .grid }
    var isBlankSlate: Bool { shouldShowBlankSlate }
    func use(database: OELibraryDatabase?) { self.database = database }
    func zoomGrid(to value: CGFloat) { zoomGridView(zoomValue: value) }
}

extension Key {
    static let useNewGamesViewController: Key = "useNewGamesViewController"
}

extension LibraryGamesViewController {
    @UserDefault(.useNewGamesViewController, defaultValue: false)
    static var useNewGamesViewController: Bool
}

final class LibraryGamesViewController: NSSplitViewController {
    
    private static let skipDiscGuideMessageKey = "OESkipDiscGuideMessageKey"
    private lazy var discGuideMessageSystemIDs: [String?] = []
    
    private let sidebarMinWidth: CGFloat = 105
    private let sidebarDefaultWidth: CGFloat = 200
    private let sidebarMaxWidth: CGFloat = 450
    private let collectionViewMinWidth: CGFloat = 495
    
    private var sidebarController: SidebarController!
    private var collectionController: GamesCollectionControlling!
    private var toolbar: LibraryToolbar? {
        view.window?.toolbar as? LibraryToolbar
    }
    
    var database: OELibraryDatabase?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        sidebarController = SidebarController()
        collectionController = Self.useNewGamesViewController ? GameCollectionViewController() : OEGameCollectionViewController()
        
        setUpSplitView()
        assignDatabase()
        
        NotificationCenter.default.addObserver(self, selector: #selector(updateCollectionContentsFromSidebar), name: .OESidebarSelectionDidChange, object: nil)
    }


    
    override func viewWillAppear() {
        super.viewWillAppear()
        
        setUpSplitViewAutosave()
        updateCollectionContentsFromSidebar()
        
        view.needsDisplay = true
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        
        collectionController.updateBlankSlate()
        
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
        collectionController.use(database: database)
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
            sidebarItem.titlebarSeparatorStyle = .automatic
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
        collectionController.zoomGrid(to: CGFloat(slider.doubleValue))
    }
    
    @IBAction func decreaseGridSize(_ sender: AnyObject?) {
        guard let slider = toolbar?.gridSizeSlider else { return }
        slider.doubleValue -= sender?.tag == 199 ? 0.25 : 0.5
        collectionController.zoomGrid(to: CGFloat(slider.doubleValue))
    }
    
    @IBAction func increaseGridSize(_ sender: AnyObject?) {
        guard let slider = toolbar?.gridSizeSlider else { return }
        slider.doubleValue += sender?.tag == 199 ? 0.25 : 0.5
        collectionController.zoomGrid(to: CGFloat(slider.doubleValue))
    }
    
    @objc func updateCollectionContentsFromSidebar() {
        
        let selectedItem = sidebarController.selectedSidebarItem
        collectionController.representedObject = selectedItem as? GameCollectionViewItemProtocol
        
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
        let isGridView = collectionController.isGridView
        let isBlankSlate = collectionController.isBlankSlate
        
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

