// Copyright (c) 2019, OpenEmu Team
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
import OpenEmuKit

/// The library's games, as a grid of box art or a list.
///
/// It replaced the old games grid.
/// The grid is an `NSCollectionView` (see `ImageCollectionViewController`) and the list is an
/// `NSTableView` (`GameTableView`). Both show the same sorted array of games from `GamesDataSource`,
/// so a row and a grid item have the same index.
@objc
class GameCollectionViewController: ImageCollectionViewController {
    
    /// The two ways to show the games. The raw values are what `OELastCollectionViewKey` stores.
    @objc enum ViewMode: Int {
        case grid = 0
        case list = 2
    }
    
    private static let lastCollectionViewKey = "lastCollectionView"
    private static let sortDescriptorsKey = "OEGameTableSortDescriptors"
    private static let titleSortDescriptor = NSSortDescriptor(key: "listViewTitle", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
    
    let gamesDataSource = GamesDataSource()
    
    private(set) var listView: GameTableView!
    private var listScrollView: NSScrollView!
    
    @objc private(set) var viewMode: ViewMode = {
        ViewMode(rawValue: UserDefaults.standard.integer(forKey: GameCollectionViewController.lastCollectionViewKey)) ?? .grid
    }()
    
    /// Object IDs of the selected games. The grid and the list both show this selection.
    private var selectedGameIDs = Set<NSManagedObjectID>()
    private var isApplyingSelection = false
    
    /// When the list's selection last changed. The rating column only takes clicks some time after that (#294).
    private var listViewSelectionChangeDate: Date?
    
    private var imageAvailabilityReloadScheduled = false
    
    override var itemIdentifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("GameCollectionViewItem") }
    override var sectionHeaderHeight: CGFloat { 0 }
    // the old games grid drew its covers about this tall, in cells as wide as the nib's item
    override var gridZoomMultiplier: CGFloat { 1.4 }
    override var gridWidthMultiplier: CGFloat { 1.0 }
    override var selectionDefaultsKey: String { "OESelectedGamesKey" }
    
    override var representedObject: Any? {
        willSet {
            precondition(newValue == nil || newValue is GameCollectionViewItemProtocol, "unexpected object")
            gamesDataSource.collection = newValue as? GameCollectionViewItemProtocol
        }
        didSet {
            guard oldValue as AnyObject? !== representedObject as AnyObject? else { return }
            listView.shouldShowSystemColumn = (representedObject as? GameCollectionViewItemProtocol)?.shouldShowSystemColumnInListView ?? true
            reloadData()
            restoreSelectionFromDefaults()
            saveSelectionToDefaults()
            scrollToSelection()
        }
    }
    
    var selectedGames: [OEDBGame] {
        switch viewMode {
        case .grid:
            return gamesDataSource.items(at: collectionView.selectionIndexPaths)
        case .list:
            return listView.selectedRowIndexes.compactMap { gamesDataSource.game(at: $0) }
        }
    }
    
    // MARK: - View Lifecycle
    
    override func viewDidLoad() {
        searchKeys = ["name", "gameTitle"]
        dataSourceDelegate = gamesDataSource
        loadListView()
        
        super.viewDidLoad()
        
        // games can be dragged onto collections in the sidebar
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: true)
        
        // OEDBImage works out artwork availability in the background and posts this when a result is
        // ready, so the grid can pick up artwork that was not ready when the item was made.
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(imageDidBecomeAvailable(_:)),
                                               name: .oeDBImageDidBecomeAvailable,
                                               object: nil)
        UserDefaults.standard.addObserver(self, forKeyPath: OEDBGame.displayGameTitleKey, options: [], context: &Self.displayGameTitleContext)
    }
    
    private static var displayGameTitleContext = 0
    
    deinit {
        UserDefaults.standard.removeObserver(self, forKeyPath: OEDBGame.displayGameTitleKey, context: &Self.displayGameTitleContext)
        NotificationCenter.default.removeObserver(self)
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if context == &Self.displayGameTitleContext {
            // titles show the game's name or its title, depending on a preference
            scheduleUpdateViews()
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    private func loadListView() {
        var topLevelObjects: NSArray?
        Bundle(for: GameTableView.self).loadNibNamed("GameTableView", owner: self, topLevelObjects: &topLevelObjects)
        listScrollView = topLevelObjects?.compactMap { $0 as? NSScrollView }.first
        listView = listScrollView.documentView as? GameTableView
        
        listView.setDraggingSourceOperationMask(.copy, forLocal: false)
        listView.setDraggingSourceOperationMask(.copy, forLocal: true)
        listView.target = self
        listView.doubleAction = #selector(tableViewWasDoubleClicked(_:))
        listView.rowSizeStyle = .custom
        listView.rowHeight = 20
        listView.allowsMultipleSelection = true
        listView.registerForDraggedTypes([.fileURL])
        listView.dataSource = self
        
        // the saved order is applied before the delegate is set, so it is not saved again
        listView.sortDescriptors = Self.savedListSortDescriptors()
        listView.delegate = self
        
        if viewMode == .list {
            gamesDataSource.sortDescriptors = listView.sortDescriptors
        }
    }
    
    override func viewWillAppear() {
        super.viewWillAppear()
        scrollToSelection()
    }
    
    override func viewDidDisappear() {
        super.viewDidDisappear()
        
        // Keep the search while the view is only hidden because a game is running.
        let isPlayingGame = NSDocumentController.shared.currentDocument != nil
        if !isPlayingGame && !currentSearchTerm.isEmpty {
            currentSearchTerm = ""
            gamesDataSource.searchPredicate = NSPredicate(value: true)
            reloadData()
        }
    }
    
    // MARK: - Content
    
    override func contentView(for tag: ViewTag) -> NSView? {
        tag == .list ? listScrollView : super.contentView(for: tag)
    }
    
    override func updateBlankSlate() {
        if shouldShowBlankSlate {
            switchTo(tag: .blankSlate)
            blankSlateView.representedObject = representedObject
        } else {
            switchTo(tag: viewMode == .grid ? .collection : .list)
        }
        validateToolbarItems()
    }
    
    override func reloadData() {
        // Reloading clears the table's selection and reports it; the saved selection is put back afterwards.
        let ids = selectedGameIDs
        isApplyingSelection = true
        super.reloadData()
        listView.reloadData()
        isApplyingSelection = false
        applySelection(ids, notify: false)
    }
    
    /// Selects the games with these IDs in the grid and the list.
    private func applySelection(_ ids: Set<NSManagedObjectID>, notify: Bool) {
        isApplyingSelection = true
        defer { isApplyingSelection = false }
        
        var indexes = IndexSet()
        for id in ids {
            if let index = gamesDataSource.indexPath(forID: id)?.item {
                indexes.insert(index)
            }
        }
        
        selectedGameIDs = Set(indexes.compactMap { gamesDataSource.game(at: $0)?.objectID })
        collectionView.selectionIndexPaths = Set(indexes.map { IndexPath(item: $0, section: 0) })
        listView.selectRowIndexes(indexes, byExtendingSelection: false)
        
        if notify {
            selectionDidChange()
        }
    }
    
    override func restoreSelectionFromDefaults() {
        guard let coordinator = OELibraryDatabase.default?.mainThreadContext.persistentStoreCoordinator else { return }
        
        var ids = Set<NSManagedObjectID>()
        for data in UserDefaults.standard.object(forKey: selectionDefaultsKey) as? [Data] ?? [] {
            guard
                let representation = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: data),
                let objectID = coordinator.managedObjectID(forURIRepresentation: representation as URL)
            else { continue }
            ids.insert(objectID)
        }
        applySelection(ids, notify: false)
    }
    
    override func saveSelectionToDefaults() {
        let archivable = selectedGames.compactMap {
            try? NSKeyedArchiver.archivedData(withRootObject: $0.permanentIDURI as NSURL, requiringSecureCoding: true)
        }
        UserDefaults.standard.set(archivable, forKey: selectionDefaultsKey)
    }
    
    private func scrollToSelection() {
        guard let index = listView.selectedRowIndexes.first else { return }
        switch viewMode {
        case .grid:
            collectionView.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .centeredVertically)
        case .list:
            listView.scrollRowToVisible(index)
        }
    }
    
    /// Called when the selection in the grid changes.
    @objc override func selectionDidChange() {
        guard !isApplyingSelection else { return }
        
        selectedGameIDs = Set(selectedGames.map { $0.objectID })
        let indexes = IndexSet(selectedGames.compactMap { gamesDataSource.index(of: $0) })
        isApplyingSelection = true
        if viewMode == .grid {
            listView.selectRowIndexes(indexes, byExtendingSelection: false)
        } else {
            collectionView.selectionIndexPaths = Set(indexes.map { IndexPath(item: $0, section: 0) })
        }
        isApplyingSelection = false
        
        saveSelectionToDefaults()
        updateTouchBar()
    }
    
    @objc private func imageDidBecomeAvailable(_ notification: Notification) {
        // A freshly opened large library can finish dozens of artwork checks in quick succession,
        // so they are folded into one update.
        guard !imageAvailabilityReloadScheduled else { return }
        imageAvailabilityReloadScheduled = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.075) { [weak self] in
            guard let self else { return }
            self.imageAvailabilityReloadScheduled = false
            let visible = self.collectionView.indexPathsForVisibleItems()
            if !visible.isEmpty {
                self.collectionView.reloadItems(at: visible)
            }
        }
    }
    
    // MARK: - View Mode
    
    @objc func showGridView() {
        setViewMode(.grid)
    }
    
    @objc func showListView() {
        setViewMode(.list)
    }
    
    private func setViewMode(_ mode: ViewMode) {
        guard mode != viewMode else { return }
        viewMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.lastCollectionViewKey)
        
        gamesDataSource.sortDescriptors = mode == .grid ? GamesDataSource.defaultSortDescriptors : listView.sortDescriptors
        reloadData()
        scrollToSelection()
        updateTouchBar()
    }
    
    override func validateToolbarItems() {
        guard let toolbar = toolbar else { return }
        
        let isGridView = viewMode == .grid
        let isBlankSlate = shouldShowBlankSlate
        
        toolbar.viewModeSelector.isEnabled = !isBlankSlate
        toolbar.viewModeSelector.selectedSegment = isGridView ? 0 : 1
        
        toolbar.gridSizeSlider.isEnabled = isGridView && !isBlankSlate
        toolbar.decreaseGridSizeButton.isEnabled = isGridView && !isBlankSlate
        toolbar.increaseGridSizeButton.isEnabled = isGridView && !isBlankSlate
        
        toolbar.searchField.isEnabled = !isBlankSlate
        toolbar.searchField.searchMenuTemplate = nil
        toolbar.searchField.stringValue = currentSearchTerm
        
        toolbar.addButton.isEnabled = true
        
        if #available(macOS 11.0, *) {
            for item in toolbar.items {
                if item.itemIdentifier == .oeSearch {
                    item.isEnabled = !isBlankSlate
                }
            }
        }
    }
    
    // MARK: - Dragging
    
    /// A dragged game goes to the sidebar as a game and to Finder as its ROM file.
    override func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        gamesDataSource.game(at: indexPath.item)
    }
    
    /// An image dropped on a game becomes its box art. Files dropped anywhere else are imported.
    override func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo, proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        // a drag that started in this view does nothing
        if draggingInfo.draggingSource as? NSCollectionView === collectionView {
            return []
        }
        
        let pasteboard = draggingInfo.draggingPasteboard
        if proposedDropOperation.pointee == .on, NSImage.canInit(with: pasteboard) {
            return .copy
        }
        
        let types = pasteboard.types ?? []
        guard types.contains(.fileURL), !types.contains(.game) else { return [] }
        proposedDropOperation.pointee = .before
        return .copy
    }
    
    override func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        let pasteboard = draggingInfo.draggingPasteboard
        
        if dropOperation == .on,
           let image = NSImage(pasteboard: pasteboard),
           let game = gamesDataSource.game(at: indexPath.item) {
            game.setBoxImage(image: image)
            try? game.managedObjectContext?.save()
            reloadData()
            return true
        }
        
        guard let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty else {
            return false
        }
        importDroppedFiles(files)
        return true
    }
    
    // MARK: - Blank Slate and Dropped Files
    
    override func importDroppedFiles(_ files: [URL]) {
        let collection = representedObject as? OEDBCollection
        database.importer.importItems(at: files, intoCollectionWith: collection?.permanentID)
    }
}

extension GameCollectionViewController: CollectionViewExtendedDelegate, NSMenuItemValidation {
    
    var supportsQuickLook: Bool { false }
    
    // MARK: - Validation
    
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)),
             #selector(delete(_:)),
             #selector(showInFinder(_:)):
            return !selectedGames.isEmpty
        default:
            return true
        }
    }
    
    // MARK: - Context Menus
    
    func collectionView(_ collectionView: CollectionView, menuForItemsAt indexPaths: Set<IndexPath>, point: CGPoint) -> NSMenu? {
        menuForSelectedGames()
    }
    
    func menuForSelectedGames() -> NSMenu {
        let menu = NSMenu()
        var item: NSMenuItem
        let games = selectedGames
        let hasLocalFiles = games.first(where: { $0.defaultROM?.filesAvailable == true }) != nil
        
        if games.count == 1 {
            let game = games.first!
            
            menu.addItem(withTitle: NSLocalizedString("Play Game", comment: ""),
                         action: #selector(LibraryController.startSelectedGame(_:)),
                         keyEquivalent: "")
            
            if let coreSubmenu = coreMenu(for: game) {
                item = NSMenuItem()
                item.title = NSLocalizedString("Play With…", comment: "Submenu listing available cores for this system")
                item.submenu = coreSubmenu
                menu.addItem(item)
            }
            
            if isGenesisGame(game) && !isSonicKnucklesGame(game) {
                item = NSMenuItem(title: NSLocalizedString("Play locked on to Sonic & Knuckles", comment: "Launch a Genesis game using Sonic & Knuckles lock-on technology"),
                                  action: #selector(LibraryController.startSelectedGameLockedOnToSonicKnuckles(_:)),
                                  keyEquivalent: "")
                if let lockOnGame = sonicKnucklesGame(forLockOnGame: game) {
                    item.representedObject = lockOnGame
                } else {
                    item.isEnabled = false
                }
                menu.addItem(item)
            }
            
            item = NSMenuItem()
            item.title = NSLocalizedString("Play Save State", comment: "")
            item.submenu = saveStateMenu(for: game)
            menu.addItem(item)
            
            item = NSMenuItem()
            item.title = NSLocalizedString("Delete Save State", comment: "")
            item.isAlternate = true
            item.keyEquivalentModifierMask = .option
            item.submenu = saveStateMenu(for: game)
            menu.addItem(item)
            
            menu.addItem(.separator())
            
            item = NSMenuItem()
            item.title = NSLocalizedString("Rating", comment: "")
            item.submenu = ratingMenu(for: games)
            menu.addItem(item)
            
            if hasLocalFiles {
                menu.addItem(withTitle: NSLocalizedString("Show in Finder", comment: ""),
                             action: #selector(showInFinder(_:)),
                             keyEquivalent: "")
            }
            
            menu.addItem(.separator())
            
            if game.status == .ok {
                menu.addItem(withTitle: NSLocalizedString("Download Cover Art", comment: ""),
                             action: #selector(downloadCoverArt(_:)),
                             keyEquivalent: "")
            }
            if game.status == .processing {
                menu.addItem(withTitle: NSLocalizedString("Cancel Cover Art Download", comment: ""),
                             action: #selector(cancelCoverArtDownload(_:)),
                             keyEquivalent: "")
            }
            menu.addItem(withTitle: NSLocalizedString("Add Cover Art from File…", comment: ""),
                         action: #selector(addCoverArtFromFile(_:)),
                         keyEquivalent: "")
            menu.addItem(withTitle: NSLocalizedString("Choose Artwork…", comment: ""),
                         action: #selector(chooseArtwork(_:)),
                         keyEquivalent: "")
            menu.addItem(withTitle: NSLocalizedString("Import Artwork from Folder…", comment: ""),
                         action: #selector(importArtworkFromFolder(_:)),
                         keyEquivalent: "")
            if hasLocalFiles {
                menu.addItem(withTitle: NSLocalizedString("Consolidate Files…", comment: ""),
                             action: #selector(consolidateFiles(_:)),
                             keyEquivalent: "")
            }
            
            menu.addItem(.separator())
            
            item = NSMenuItem(title: NSLocalizedString("Add to Collection", comment: ""),
                              action: nil,
                              keyEquivalent: "")
            item.submenu = collectionsMenu(for: games)
            menu.addItem(item)
            
            menu.addItem(.separator())
            
            menu.addItem(withTitle: NSLocalizedString("Rename Game", comment: ""),
                         action: #selector(CollectionView.beginEditingWithSelectedItem(_:)),
                         keyEquivalent: "")
            var title: String
            if type(of: representedObject as AnyObject) === OEDBCollection.self {
                title = NSLocalizedString("Remove Game", comment: "")
            } else {
                title = NSLocalizedString("Delete Game", comment: "")
            }
            menu.addItem(withTitle: title,
                         action: #selector(deleteSelectedItems(_:)),
                         keyEquivalent: "")
        }
        else {
            // FIXME: starting multiple games only starts the first of the selected games
            /*if UserDefaults.standard.bool(forKey: OEForcePopoutGameWindowKey) {
                menu.addItem(withTitle: NSLocalizedString("Play Games (Caution)", comment: ""),
                             action: #selector(LibraryController.startSelectedGame(_:)),
                             keyEquivalent: "")
            }*/
            
            item = NSMenuItem()
            item.title = NSLocalizedString("Rating", comment: "")
            item.submenu = ratingMenu(for: games)
            menu.addItem(item)
            
            if hasLocalFiles {
                menu.addItem(withTitle: NSLocalizedString("Show in Finder", comment: ""),
                             action: #selector(showInFinder(_:)),
                             keyEquivalent: "")
            }
            
            menu.addItem(.separator())
            
            menu.addItem(withTitle: NSLocalizedString("Download Cover Art", comment: ""),
                         action: #selector(downloadCoverArt(_:)),
                         keyEquivalent: "")
            menu.addItem(withTitle: NSLocalizedString("Add Cover Art from File…", comment: ""),
                         action: #selector(addCoverArtFromFile(_:)),
                         keyEquivalent: "")
            menu.addItem(withTitle: NSLocalizedString("Import Artwork from Folder…", comment: ""),
                         action: #selector(importArtworkFromFolder(_:)),
                         keyEquivalent: "")
            menu.addItem(withTitle: NSLocalizedString("Consolidate Files…", comment: ""),
                         action: #selector(consolidateFiles(_:)),
                         keyEquivalent: "")
            
            menu.addItem(.separator())
            
            item = NSMenuItem(title: NSLocalizedString("Add to Collection", comment: ""),
                              action: nil,
                              keyEquivalent: "")
            item.submenu = collectionsMenu(for: games)
            menu.addItem(item)
            
            menu.addItem(.separator())
            
            var title: String
            if type(of: representedObject as AnyObject) === OEDBCollection.self {
                title = NSLocalizedString("Remove Games", comment: "")
            } else {
                title = NSLocalizedString("Delete Games", comment: "")
            }
            menu.addItem(withTitle: title,
                         action: #selector(deleteSelectedItems(_:)),
                         keyEquivalent: "")
        }
        
        return menu
    }
    
    private func coreMenu(for game: OEDBGame) -> NSMenu? {
        guard let systemID = game.system?.systemIdentifier else { return nil }
        var plugins = OECorePlugin.corePlugins(forSystemIdentifier: systemID)
        guard plugins.count > 1 else { return nil }
        plugins.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let menu = NSMenu()
        for plugin in plugins {
            let item = NSMenuItem(title: plugin.displayName,
                                  action: #selector(LibraryController.startSelectedGame(withCore:)),
                                  keyEquivalent: "")
            item.representedObject = plugin
            menu.addItem(item)
        }
        return menu
    }
    
    private func saveStateMenu(for game: OEDBGame) -> NSMenu {
        let menu = NSMenu()
        
        game.roms.forEach { rom in
            
            rom.removeMissingStates()
            
            let saveStates = rom.normalSaveStatesByTimestamp(ascending: false)
            saveStates.forEach { saveState in
                
                let title = saveState.name
                
                let item = NSMenuItem()
                item.title = title
                item.action = #selector(LibraryController.startSelectedGame(saveState:))
                item.representedObject = saveState
                menu.addItem(item)
                
                let alternateItem = NSMenuItem()
                alternateItem.title = title
                alternateItem.action = #selector(deleteSaveState(_:))
                alternateItem.isAlternate = true
                alternateItem.keyEquivalentModifierMask = .option
                alternateItem.representedObject = saveState
                menu.addItem(alternateItem)
            }
        }
        
        if menu.items.isEmpty {
            menu.addItem(withTitle: NSLocalizedString("No Save States available", comment: ""),
                         action: nil,
                         keyEquivalent: "")
        }
        
        return menu
    }
    
    private func ratingMenu(for games: [OEDBGame]) -> NSMenu {
        let menu = NSMenu()
        let ratingLabel = "★★★★★"
        
        for i in 0...5 {
            let item = NSMenuItem()
            item.title = i == 0 ? NSLocalizedString("None", comment: "")
                                      : "\(ratingLabel.prefix(i))"
            item.action = #selector(setRatingForSelectedGames(_:))
            item.representedObject = i
            menu.addItem(item)
        }
        
        var valuesDiffer = false
        for i in 0..<games.count {
            let gameRating = games[i].rating
            let itemIndex = gameRating?.intValue ?? 0
            let item = menu.item(at: itemIndex)
            
            if i == 0 {
                item?.state = .on
            } else if item?.state != .on {
                valuesDiffer = true
                item?.state = .mixed
            }
        }
        
        if valuesDiffer {
            let gameRating = games.first?.rating
            let item = menu.item(at: gameRating?.intValue ?? 0)
            item?.state = .mixed
        }
        
        return menu
    }
    
    private func collectionsMenu(for games: [OEDBGame]) -> NSMenu {
        let menu = NSMenu()
        let collections = database!.collections
        
        var item = NSMenuItem()
        item.title = NSLocalizedString("New Collection from Selection", comment: "")
        item.action = #selector(LibraryGamesViewController.makeNewCollectionWithSelectedGames(_:))
        menu.addItem(item)
        
        collections.forEach { collection in
            if type(of: collection) === OEDBCollection.self,
               !collection.isEqual(representedObject) {
                item = NSMenuItem()
                item.title = (collection as! OEDBCollection).name
                item.action = #selector(addSelectedGamesToCollection(_:))
                item.representedObject = collection
                menu.addItem(item)
            }
        }
        
        if menu.items.count != 1 {
            menu.insertItem(.separator(), at: 1)
        }
        
        return menu
    }
    
    // MARK: - Sonic & Knuckles Lock-On
    
    private func isGenesisGame(_ game: OEDBGame) -> Bool {
        game.system?.systemIdentifier == "openemu.system.sg"
    }
    
    private func isSonicKnucklesROM(_ rom: OEDBRom) -> Bool {
        guard rom.filesAvailable else { return false }
        
        if rom.header?.range(of: "SONIC & KNUCKLES", options: .caseInsensitive) != nil ||
            rom.serial?.range(of: "MK-1563", options: .caseInsensitive) != nil {
            return true
        }
        
        guard let url = rom.url, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        try? handle.seek(toOffset: 0x120)
        let data = (try? handle.read(upToCount: 16)) ?? Data()
        return String(data: data, encoding: .ascii)?.range(of: "SONIC & KNUCKLES", options: .caseInsensitive) != nil
    }
    
    private func isSonicKnucklesGame(_ game: OEDBGame) -> Bool {
        isGenesisGame(game) && game.roms.contains { isSonicKnucklesROM($0) }
    }
    
    private func sonicKnucklesGame(forLockOnGame game: OEDBGame) -> OEDBGame? {
        guard isGenesisGame(game), let context = game.managedObjectContext else { return nil }
        
        // Genesis has no stored header or serial, so identifying the ROM means reading its file. Only do that
        // for games whose name or file path mentions Knuckles, not for every Genesis game on each right-click.
        let request = NSFetchRequest<OEDBGame>(entityName: OEDBGame.entityName)
        request.predicate = NSPredicate(format: "system == %@ AND (name CONTAINS[c] %@ OR SUBQUERY(roms, $r, $r.location CONTAINS[c] %@ OR $r.header CONTAINS[c] %@ OR $r.serial CONTAINS[c] %@).@count > 0)",
                                        game.system!, "knuckles", "knuckles", "SONIC & KNUCKLES", "MK-1563")
        let candidates = (try? context.fetch(request)) ?? []
        return candidates.first { $0 != game && isSonicKnucklesGame($0) }
    }
    
    // MARK: - Actions
    
    @objc func showInFinder(_ sender: Any?) {
        let urls = selectedGames.compactMap { $0.defaultROM?.url?.absoluteURL }
        
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
    
    
    @objc override func deleteBackward(_ sender: Any?) {
        deleteSelectedItems(sender)
    }
    
    @objc override func deleteBackwardByDecomposingPreviousCharacter(_ sender: Any?) {
        deleteSelectedItems(sender)
    }
    
    @IBAction func copy(_ sender: Any?) {
        copySelectedItems(sender)
    }
    
    @objc func copySelectedItems(_ sender: Any?) {
        let fileURLs = selectedGames.compactMap { $0.defaultROM?.url?.absoluteURL as NSURL? }
        
        let pboard = NSPasteboard.general
        pboard.clearContents()
        pboard.declareTypes([.fileURL], owner: nil)
        pboard.writeObjects(fileURLs)
    }
    
    @IBAction override func delete(_ sender: Any?) {
        deleteSelectedItems(sender)
    }
    
    @objc func deleteSelectedItems(_ sender: Any?) {
        assert(Thread.isMainThread, "Only call on main thread!")
        let multipleGames = selectedGames.count > 1
        
        // deleting from 'All Games', smart collections and consoles removes games from the library
        if representedObject is OEDBSystem ||
           representedObject is OEDBSmartCollection ||
           representedObject is OEDBAllGamesCollection {
            // delete games from library if user allows it
            if OEAlert.removeGamesFromLibrary(multipleGames: multipleGames).runModal() == .alertFirstButtonReturn {
                selectedGames.forEach { $0.delete(moveToTrash: true, keepSaveStates: false) }
                
                let context = selectedGames.last?.managedObjectContext
                try? context?.save()
                
                reloadData()
            }
        }
        // deleting from regular collections removes games from that collection
        else if let collection = representedObject as? OEDBCollection {
            // remove games from collection if user allows it
            if OEAlert.removeGamesFromCollection(multipleGames: multipleGames).runModal() == .alertFirstButtonReturn {
                collection.games.subtract(selectedGames)
                collection.save()
            }
            reloadData()
        }
    }
    
    @objc func deleteSaveState(_ sender: NSMenuItem) {
        guard let state = sender.representedObject as? OEDBSaveState else { return }
        
        let stateName = state.name
        let alert = OEAlert.deleteSaveState(name: stateName)
        
        if alert.runModal() == .alertFirstButtonReturn {
            state.deleteAndRemoveFiles()
        }
    }
    
    @objc func addSelectedGamesToCollection(_ sender: NSMenuItem) {
        assert(Thread.isMainThread, "Only call on main thread!")
        guard let collection = sender.representedObject as? OEDBCollection else { return }
        
        collection.games.formUnion(selectedGames)
        collection.save()
        
        reloadData()
    }
    
    @objc func downloadCoverArt(_ sender: Any?) {
        selectedGames.forEach { $0.requestCoverDownload() }
        selectedGames.last?.save()
        
        reloadData()
    }
    
    @objc func cancelCoverArtDownload(_ sender: Any?) {
        selectedGames.forEach { $0.cancelCoverDownload() }
        selectedGames.last?.save()
        
        reloadData()
    }
    
    @objc func addCoverArtFromFile(_ sender: Any?) {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowedContentTypes = [.image]
        
        openPanel.begin { result in
            guard result == .OK, let url = openPanel.url else { return }
            
            self.selectedGames.forEach { $0.setBoxImage(url: url) }
            let context = self.selectedGames.last?.managedObjectContext
            try? context?.save()
            
            self.reloadData()
        }
    }
    
    @objc func chooseArtwork(_ sender: Any?) {
        guard selectedGames.count == 1, let game = selectedGames.first else { return }
        OEArtworkPickerController.show(for: game)
    }
    
    @objc func importArtworkFromFolder(_ sender: Any?) {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.prompt = NSLocalizedString("Choose", comment: "")
        openPanel.message = NSLocalizedString("Choose a folder of artwork images. Files are matched to games by name. Add -poster, -hero, -icon or -logo to a name to pick the kind. Your folder is never changed.", comment: "")
        
        openPanel.begin { [weak self] result in
            guard result == .OK, let url = openPanel.url, let self = self else { return }
            
            let games = self.selectedGames
            let matchResult = ArtworkFolderMatcher.match(folderURL: url, games: games)
            let review = ArtworkImportReviewViewController(matches: matchResult.matches,
                                                           unmatchedFileCount: matchResult.unmatchedFileURLs.count,
                                                           selectedGameCount: games.count)
            review.onApply = { [weak self] confirmed in
                guard !confirmed.isEmpty else { return }
                ArtworkFolderMatcher.apply(confirmed)
                self?.reloadData()
            }
            self.presentAsSheet(review)
        }
    }
    
    @objc func setRatingForSelectedGames(_ sender: NSMenuItem) {
        selectedGames.forEach { $0.rating = sender.representedObject as? NSNumber }
        
        reloadData()
    }
    
    // untested
    @objc func consolidateFiles(_ sender: Any?) {
        DispatchQueue.main.async {
            let games = self.selectedGames
            if games.isEmpty {
                return
            }
            
            var alert = OEAlert()
            alert.messageText = NSLocalizedString("Consolidating will copy all of the selected games into the OpenEmu Library folder.", comment: "")
            alert.informativeText = NSLocalizedString("This cannot be undone.", comment: "")
            alert.defaultButtonTitle = NSLocalizedString("Consolidate", comment: "")
            alert.alternateButtonTitle = NSLocalizedString("Cancel", comment: "")
            if alert.runModal() != .alertFirstButtonReturn {
                return
            }
            
            alert = OEAlert()
            alert.messageText = NSLocalizedString("Copying Game Files…", comment: "")
            alert.showsProgressbar = true
            alert.progress = 0
            
            var alertResult = -1
            let context = OELibraryDatabase.default!.makeWriterChildContext()
            let gameIDs = games.map { $0.permanentID }
            
            DispatchQueue.global(qos: .default).asyncAfter(deadline: DispatchTime.now() + .seconds(1)) {
                context.performAndWait {
                    var err: Error?
                    for i in 0..<gameIDs.count {
                        if alertResult != -1 {
                            break
                        }
                        
                        let gameID = gameIDs[i]
                        let game = OEDBGame.object(with: gameID, in: context)
                        for rom in game?.roms ?? [] {
                            if alertResult != -1 {
                                break
                            }
                            do {
                                try rom.consolidateFiles()
                                break
                            } catch {
                                err = error
                            }
                        }
                        
                        alert.performBlockInModalSession {
                            alert.progress = Double(i + 1) / Double(games.count)
                        }
                        
                        if err != nil {
                            break
                        }
                    }
                    
                    if let error = err {
                        let originalCompletionHandler = alert.callbackHandler
                        alert.callbackHandler = { alert, result in
                            let errorAlert = OEAlert()
                            errorAlert.messageText = NSLocalizedString("Consolidating files failed.", comment: "")
                            errorAlert.informativeText = error.localizedDescription
                            errorAlert.defaultButtonTitle = NSLocalizedString("OK", comment: "")
                            errorAlert.runModal()
                            
                            if let originalCompletionHandler = originalCompletionHandler {
                                originalCompletionHandler(alert, result)
                            }
                        }
                    }
                    
                    try? context.save()
                    let writerContext = context.parent
                    writerContext?.perform {
                        writerContext?.userInfo[OELibraryDatabase.managedObjectContextHasDirectChangesUserInfoKey] = true as NSNumber
                        try? writerContext?.save()
                    }
                    
                    alert.close(withResult: .alertFirstButtonReturn)
                }
            }
            
            alert.defaultButtonTitle = NSLocalizedString("Stop", comment: "")
            alertResult = alert.runModal().rawValue
        }
    }
    
    func collectionView(_ collectionView: CollectionView, doubleClickForItemAt indexPath: IndexPath) {
        guard selectedGames.count == 1 else { return }
        NSApp.sendAction(#selector(LibraryController.startSelectedGame(_:)), to: nil, from: self)
    }
    
    func collectionView(_ collectionView: CollectionView, setTitle title: String, forItemAt indexPath: IndexPath) {
        guard let game = gamesDataSource.game(at: indexPath.item), !title.isEmpty else { return }
        game.displayName = title
        game.save()
        
        if let itemView = collectionView.item(at: indexPath) as? ImageCollectionViewItem {
            gamesDataSource.loadItemView(itemView, at: indexPath)
        }
    }
    
    func collectionView(_ collectionView: CollectionView, indexPathForTypeSelect string: String, startingAt indexPath: IndexPath?) -> IndexPath? {
        let games = gamesDataSource.games
        guard !games.isEmpty else { return nil }
        let start = indexPath?.item ?? 0
        for offset in 0..<games.count {
            let index = (start + offset) % games.count
            if games[index].displayName.range(of: string, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil {
                return IndexPath(item: index, section: 0)
            }
        }
        return nil
    }
}

// MARK: - List View

extension GameCollectionViewController: NSTableViewDataSource, NSTableViewDelegate, GameTableViewMenuSource {
    
    /// The order the user chose for the list, or by name if nothing was saved.
    fileprivate static func savedListSortDescriptors() -> [NSSortDescriptor] {
        if let data = UserDefaults.standard.data(forKey: sortDescriptorsKey),
           let descriptors = try? NSKeyedUnarchiver.unarchivedArrayOfObjects(ofClass: NSSortDescriptor.self, from: data),
           !descriptors.isEmpty {
            descriptors.forEach { $0.allowEvaluation() }
            return descriptors
        }
        return [titleSortDescriptor]
    }
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        gamesDataSource.games.count
    }
    
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let game = gamesDataSource.game(at: row) else { return nil }
        guard let columnID = tableColumn?.identifier.rawValue else { return game }
        
        if columnID == "listViewStatus" {
            guard let imageName = game.listViewStatus(), let image = NSImage(named: imageName) else { return nil }
            let isSelected = listView.selectedRowIndexes.contains(row)
            let tintColor: NSColor = imageName == "list_indicator_missing" ? .systemOrange : .controlAccentColor
            return isSelected ? image : image.withTintColor(tintColor)
        }
        
        if game.responds(to: NSSelectorFromString(columnID)) {
            return game.value(forKey: columnID)
        }
        return nil
    }
    
    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard let game = gamesDataSource.game(at: row) else { return }
        
        switch tableColumn?.identifier.rawValue {
        case "listViewRating":
            game.setListViewRating(object as? NSNumber)
        case "listViewTitle":
            if let attributed = object as? NSAttributedString {
                game.setListViewTitle(attributed.string)
            } else if let title = object as? String {
                game.setListViewTitle(title)
            }
            try? game.managedObjectContext?.save()
            // search results may no longer be valid
            reloadData()
        default:
            return
        }
        
        try? game.managedObjectContext?.save()
    }
    
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard tableView === listView else { return }
        
        var descriptors = listView.sortDescriptors
        if descriptors.isEmpty {
            descriptors = Self.savedListSortDescriptors()
        }
        
        // Do not collect sort descriptors: the title is the secondary key unless it is the main one.
        if let main = descriptors.first {
            descriptors = main.key == Self.titleSortDescriptor.key ? [main] : [main, Self.titleSortDescriptor]
        }
        
        if descriptors != listView.sortDescriptors {
            listView.sortDescriptors = descriptors
            return // this method runs again for the new descriptors
        }
        
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: descriptors, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: Self.sortDescriptorsKey)
        }
        
        guard viewMode == .list else { return }
        gamesDataSource.sortDescriptors = descriptors
        reloadData()
    }
    
    // MARK: Drag and Drop
    
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        gamesDataSource.game(at: row)
    }
    
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let types = info.draggingPasteboard.types ?? []
        guard types.contains(.fileURL), !types.contains(.game) else { return [] }
        return .copy
    }
    
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let pasteboard = info.draggingPasteboard
        let types = pasteboard.types ?? []
        guard types.contains(.fileURL), !types.contains(.game) else { return false }
        
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        importDroppedFiles(files)
        return true
    }
    
    // MARK: Delegate
    
    func tableView(_ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, row: Int) {
        if let cell = cell as? NSCell, !(cell is RatingCell) {
            cell.isHighlighted = false
        }
    }
    
    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
        tableColumn?.identifier.rawValue == "listViewTitle"
    }
    
    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        if tableColumn?.identifier.rawValue == "listViewTitle" {
            return gamesDataSource.game(at: row)?.displayName
        }
        return ""
    }
    
    func tableViewSelectionIsChanging(_ notification: Notification) {
        // The rating cell only tracks the mouse some time after the selection changed, and this method
        // runs before the selection is final, so the date is pushed out until `tableViewSelectionDidChange`.
        listViewSelectionChangeDate = .distantFuture
    }
    
    func tableViewSelectionDidChange(_ notification: Notification) {
        listViewSelectionChangeDate = Date()
        selectionDidChange()
    }
    
    func tableView(_ tableView: NSTableView, shouldTrackCell cell: NSCell, for tableColumn: NSTableColumn?, row: Int) -> Bool {
        guard tableColumn?.identifier.rawValue == "listViewRating" else { return false }
        
        // Only in selected rows...
        guard listView.selectedRowIndexes.contains(row) else { return false }
        
        // ...and when the selection changed longer ago than a double click takes. The user has to click a
        // row to select it, wait the double click interval and then click the rating to change it (#294).
        guard let date = listViewSelectionChangeDate else { return false }
        return date.timeIntervalSinceNow < -NSEvent.doubleClickInterval
    }
    
    @objc func tableViewWasDoubleClicked(_ sender: Any?) {
        let row = listView.clickedRow
        guard row >= 0, let game = gamesDataSource.game(at: row) else { return }
        NSApp.sendAction(#selector(LibraryController.start(game:)), to: nil, from: game)
    }
    
    func tableView(_ tableView: GameTableView, menuForItemsAt indexes: IndexSet) -> NSMenu? {
        menuForSelectedGames()
    }
}
