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

/// The games shown by `GameCollectionViewController`, for both the grid and the list.
///
/// The fetch uses the collection's predicate, limit and sort order. Search and the display sort order
/// are applied to the fetched games in memory, so a collection with a limit (such as Recently Played)
/// keeps the same games while the user searches or re-sorts.
final class GamesDataSource: ImageDataSourceDelegate {
    
    static let defaultSortDescriptors = [NSSortDescriptor(key: "cleanDisplayName", ascending: true, selector: #selector(NSString.caseInsensitiveCompare(_:)))]
    
    var collection: GameCollectionViewItemProtocol?
    
    var searchPredicate = NSPredicate(value: true)
    let entityName = OEDBGame.entityName
    
    /// Order of `games`. Changing it sorts again.
    var sortDescriptors = GamesDataSource.defaultSortDescriptors {
        didSet { sort() }
    }
    
    /// True if the collection has no games at all, before searching.
    private(set) var isEmpty = true
    private(set) var games = [OEDBGame]()
    private var unfilteredGames = [OEDBGame]()
    private var indexByObjectID = [NSManagedObjectID: Int]()
    
    var numberOfSections: Int { 1 }
    func numberOfItems(in section: Int) -> Int { games.count }
    
    // MARK: - Fetching
    
    func fetchItems() {
        guard let context = OELibraryDatabase.default?.mainThreadContext else { return }
        
        let request = NSFetchRequest<OEDBGame>(entityName: entityName)
        if let collection {
            request.predicate = collection.fetchPredicate
            request.fetchLimit = collection.fetchLimit
            let fetchSortDescriptors = collection.fetchSortDescriptors
            if !fetchSortDescriptors.isEmpty {
                request.sortDescriptors = fetchSortDescriptors
            }
        } else {
            request.predicate = NSPredicate(value: false)
        }
        request.fetchBatchSize = 100
        request.relationshipKeyPathsForPrefetching = ["system", "boxImage"]
        
        do {
            unfilteredGames = try context.fetch(request)
        } catch {
            NSLog("Error while fetching games: \(error.localizedDescription)")
            unfilteredGames = []
        }
        isEmpty = unfilteredGames.isEmpty
        
        applySearch()
    }
    
    /// Filters the fetched games with `searchPredicate`, then sorts them.
    func applySearch() {
        let filtered = (unfilteredGames as NSArray).filtered(using: searchPredicate) as? [OEDBGame] ?? unfilteredGames
        games = filtered
        sort()
    }
    
    private func sort() {
        games = (games as NSArray).sortedArray(using: sortDescriptors) as? [OEDBGame] ?? games
        indexByObjectID = Dictionary(uniqueKeysWithValues: games.enumerated().map { ($1.objectID, $0) })
    }
    
    // MARK: - Items
    
    func item(at indexPath: IndexPath) -> Any {
        game(at: indexPath.item) as Any
    }
    
    func game(at index: Int) -> OEDBGame? {
        games.indices.contains(index) ? games[index] : nil
    }
    
    func items(at indexPaths: Set<IndexPath>) -> [OEDBGame] {
        indexPaths.sorted().compactMap { game(at: $0.item) }
    }
    
    func indexPath(forID id: NSManagedObjectID) -> IndexPath? {
        indexByObjectID[id].map { IndexPath(item: $0, section: 0) }
    }
    
    func index(of game: OEDBGame) -> Int? {
        indexByObjectID[game.objectID]
    }
    
    func permanentIDURIs(forItemsAt indexPaths: Set<IndexPath>) -> [URL] {
        items(at: indexPaths).map { $0.permanentIDURI }
    }
    
    func imageURL(forItemAt indexPath: IndexPath) -> URL? {
        game(at: indexPath.item)?.boxImage?.imageURL
    }
    
    func imageURLs(forItemsAt indexPaths: Set<IndexPath>) -> [URL] {
        items(at: indexPaths).compactMap { $0.boxImage?.imageURL }
    }
    
    // MARK: - Item Views
    
    private var tasks = [IndexPath: Task<Void, Never>]()
    
    func loadItemView(_ view: ImageCollectionViewItem, at indexPath: IndexPath) {
        guard
            let itemView = view as? GameCollectionViewItem,
            let game = game(at: indexPath.item)
        else { return }
        
        itemView.representedObject = game
        itemView.textField?.stringValue = game.displayName
        itemView.rating = game.rating?.intValue ?? 0
        
        switch game.status {
        case .downloading, .processing:
            itemView.indication = .processing
        case .alert:
            itemView.indication = .fileMissing
        case .ok:
            itemView.indication = .none
        }
        
        if let image = game.boxImage, image.relativePath != nil, image.isLocalImageAvailable, let url = image.imageURL {
            itemView.imageURL = url
            itemView.isShowingMissingArtwork = false
            let task = Task(priority: .userInitiated) { [weak itemView] in
                let img = await ImageCacheService.shared.fetchImage(url)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let itemView, itemView.imageURL == url else { return }
                    itemView.imageView?.image = img
                    itemView.view.needsLayout = true
                }
            }
            tasks[indexPath] = task
        } else {
            itemView.imageURL = nil
            itemView.isShowingMissingArtwork = true
            itemView.imageView?.image = Self.missingArtwork(aspectRatio: game.system?.coverAspectRatio ?? 1)
            itemView.view.needsLayout = true
        }
    }
    
    func unloadItemView(at indexPath: IndexPath) {
        tasks.removeValue(forKey: indexPath)?.cancel()
    }
    
    func loadHeaderView(_ view: ImageCollectionHeaderView, at indexPath: IndexPath) {
        // games are not grouped
    }
    
    private static let missingArtworkCache = NSCache<NSString, NSImage>()
    
    /// The image for a game that has no artwork. It has the proportions of the system's covers.
    private static func missingArtwork(aspectRatio ratio: CGFloat) -> NSImage {
        let key = "\(ratio)" as NSString
        if let image = missingArtworkCache.object(forKey: key) {
            return image
        }
        let image = NSImage.missingArtworkImage(size: NSSize(width: 140, height: 140 * ratio)) ?? NSImage()
        missingArtworkCache.setObject(image, forKey: key)
        return image
    }
}
