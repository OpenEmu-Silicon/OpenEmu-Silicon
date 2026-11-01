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

import XCTest
@testable import OpenEmu
import OpenEmuKit

/// The games shown in the library grid and list: fetch, search, sort and lookup.
class GamesDataSourceTests: XCTestCase {
    
    /// Loads a throwaway library, adds games with these names to a system and returns the data source set up for it.
    private func makeDataSource(gameNames: [String]) throws -> (GamesDataSource, OEDBSystem) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenEmu-GamesDataSourceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        
        // Loading a library remembers its path; put the real one back so the app doesn't ask for a library later.
        let savedPath = UserDefaults.standard.object(forKey: OELibraryDatabase.databasePathKey)
        addTeardownBlock { UserDefaults.standard.set(savedPath, forKey: OELibraryDatabase.databasePathKey) }
        
        try OELibraryDatabase.load(from: folder)
        let context = try XCTUnwrap(OELibraryDatabase.default?.mainThreadContext)
        
        // a fresh library has no systems until one is made for its plugin
        let plugin = try XCTUnwrap(OESystemPlugin.allPlugins.first { $0.systemIdentifier == "openemu.system.nes" })
        let system = OEDBSystem.system(for: plugin, in: context)
        for name in gameNames {
            _ = OEDBGame.createGame(withName: name, andSystem: system, in: context)
        }
        try context.save()
        
        let dataSource = GamesDataSource()
        dataSource.collection = system
        dataSource.fetchItems()
        return (dataSource, system)
    }
    
    private func names(_ dataSource: GamesDataSource) -> [String] {
        dataSource.games.map { $0.displayName }
    }
    
    func testDefaultOrderIgnoresLeadingArticlesAndCase() throws {
        let (dataSource, _) = try makeDataSource(gameNames: ["The Legend of Zelda", "metroid", "Contra", "A Boy and His Blob"])
        XCTAssertEqual(names(dataSource), ["A Boy and His Blob", "Contra", "The Legend of Zelda", "metroid"])
    }
    
    func testSearchFiltersGamesButNotTheEmptyState() throws {
        let (dataSource, _) = try makeDataSource(gameNames: ["Super Mario Bros.", "Super Mario Bros. 3", "Metroid"])
        
        dataSource.searchPredicate = NSPredicate(format: "%K contains[cd] %@", "name", "mario")
        dataSource.applySearch()
        XCTAssertEqual(dataSource.games.count, 2)
        XCTAssertFalse(dataSource.isEmpty)
        
        dataSource.searchPredicate = NSPredicate(format: "%K contains[cd] %@", "name", "nothing matches this")
        dataSource.applySearch()
        XCTAssertTrue(dataSource.games.isEmpty)
        XCTAssertFalse(dataSource.isEmpty, "a search with no results is not an empty collection")
    }
    
    func testEmptyCollectionIsEmpty() throws {
        let (dataSource, _) = try makeDataSource(gameNames: [])
        XCTAssertTrue(dataSource.isEmpty)
        XCTAssertEqual(dataSource.numberOfItems(in: 0), 0)
    }
    
    func testListOrderUsesTitleAsSecondaryKey() throws {
        let (dataSource, _) = try makeDataSource(gameNames: ["Charlie", "Alpha", "Bravo"])
        // none of the games has been played, so ordering by play count leaves the title to decide
        dataSource.sortDescriptors = [
            NSSortDescriptor(key: "listViewPlayCount", ascending: true),
            NSSortDescriptor(key: "listViewTitle", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
        ]
        XCTAssertEqual(names(dataSource), ["Alpha", "Bravo", "Charlie"])
        
        dataSource.sortDescriptors = [
            NSSortDescriptor(key: "listViewTitle", ascending: false, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
        ]
        XCTAssertEqual(names(dataSource), ["Charlie", "Bravo", "Alpha"])
    }
    
    func testIndexLookupMatchesTheSortedOrder() throws {
        let (dataSource, _) = try makeDataSource(gameNames: ["Zelda", "Mario", "Kirby"])
        for (index, game) in dataSource.games.enumerated() {
            XCTAssertEqual(dataSource.indexPath(forID: game.objectID), IndexPath(item: index, section: 0))
            XCTAssertEqual(dataSource.index(of: game), index)
            XCTAssertTrue(dataSource.game(at: index) === game)
        }
        XCTAssertNil(dataSource.game(at: 3))
        XCTAssertEqual(dataSource.items(at: [IndexPath(item: 2, section: 0), IndexPath(item: 0, section: 0)]).map { $0.displayName },
                       ["Kirby", "Zelda"], "items come back in list order")
    }
    
    func testRefetchPicksUpRenamedAndNewGames() throws {
        let (dataSource, system) = try makeDataSource(gameNames: ["Beta"])
        let context = try XCTUnwrap(OELibraryDatabase.default?.mainThreadContext)
        
        dataSource.games.first?.name = "Omega"
        _ = OEDBGame.createGame(withName: "Alpha", andSystem: system, in: context)
        try context.save()
        dataSource.fetchItems()
        
        XCTAssertEqual(names(dataSource), ["Alpha", "Omega"])
    }
}
