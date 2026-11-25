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


import SwiftUI
import CoreData
import OpenEmuKit

/// SPIKE. Feeds the SwiftUI library window. It never holds more than one fetch result: a sorted, batched array of
/// games for the selected scope, so a library of thousands of games is not loaded into memory up front.
/// Nothing here writes to the library.
@MainActor
final class OESwiftLibraryStore: ObservableObject {

    struct SystemRow: Identifiable, Hashable {
        let id: String
        let name: String
        let count: Int
    }

    enum Sort: String, CaseIterable {
        case name = "Name"
        case recentlyAdded = "Recently Added"
    }

    @Published private(set) var systems = [SystemRow]()
    @Published private(set) var games = [OEDBGame]()
    @Published private(set) var totalCount = 0
    @Published var scope: String? = nil { didSet { if scope != oldValue { reloadGames() } } }
    @Published var sort: Sort = .name { didSet { if sort != oldValue { reloadGames() } } }
    @Published var search = "" { didSet { if search != oldValue { reloadGames() } } }

    var onPlay: ((OEDBGame) -> Void)?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .libraryDidLoad, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func reload() {
        guard let database = OELibraryDatabase.default else { return }
        let context = database.mainThreadContext
        // Counts come from the store, not from `system.games.count`, which would pull every game in.
        var rows = [SystemRow]()
        for system in OEDBSystem.allSystems(in: context) {
            let request = NSFetchRequest<OEDBGame>(entityName: OEDBGame.entityName)
            request.predicate = NSPredicate(format: "system == %@", system)
            let count = (try? context.count(for: request)) ?? 0
            if count > 0 { rows.append(SystemRow(id: system.systemIdentifier, name: system.name, count: count)) }
        }
        systems = rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        totalCount = rows.reduce(0) { $0 + $1.count }
        reloadGames()
    }

    func reloadGames() {
        guard let database = OELibraryDatabase.default else { return }
        let context = database.mainThreadContext
        let start = CFAbsoluteTimeGetCurrent()
        let request = NSFetchRequest<OEDBGame>(entityName: OEDBGame.entityName)
        var predicates = [NSPredicate]()
        if let scope, let system = OEDBSystem.system(for: scope, in: context) {
            predicates.append(NSPredicate(format: "system == %@", system))
        }
        if !search.isEmpty { predicates.append(NSPredicate(format: "name CONTAINS[cd] %@", search)) }
        request.predicate = predicates.isEmpty ? nil : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        switch sort {
        case .name:
            request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))]
        case .recentlyAdded:
            request.sortDescriptors = [NSSortDescriptor(key: "importDate", ascending: false)]
        }
        request.fetchBatchSize = 120
        games = (try? context.fetch(request)) ?? []
        OELibraryBench.note("fetch \(games.count) games: \(Int((CFAbsoluteTimeGetCurrent() - start) * 1000)) ms")
    }
}
