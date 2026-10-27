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

/// The one place big-picture views ask for artwork and game details.
///
/// Views never talk to a provider directly. Each slot has an ordered list of sources, and a source that has no key
/// or finds nothing is skipped:
///
/// - poster: SteamGridDB grid art, then the library's own box art (drawn by the card)
/// - hero backdrop: SteamGridDB hero art, then a blurred cover
/// - details (genre, developer, publisher, year): the local OpenVGDB database, found by the ROM's MD5
///
/// Images are cached on disk by ROM MD5 so a game is looked up once.
@MainActor
final class OEBigPictureArt: ObservableObject {

    static let shared = OEBigPictureArt()

    /// Facts about a game that the library itself does not store.
    struct Details {
        var genres = [String]()
        var developer: String?
        var publisher: String?
        var releaseDate: String?
        var summary: String?
    }

    /// Bumped whenever something new arrives so views redraw.
    @Published private(set) var tick = 0

    private var heroes = [String: NSImage]()
    private var grids = [String: NSImage]()
    private var icons = [String: NSImage]()
    private var details = [String: Details]()
    private var requested = Set<String>()
    private var known = [String: GameKey]()

    func hero(for key: GameKey) -> NSImage? { heroes[key.md5] }
    func grid(for key: GameKey) -> NSImage? { grids[key.md5] }
    func icon(for key: GameKey) -> NSImage? { icons[key.md5] }
    func details(for key: GameKey) -> Details? { details[key.md5] }

    /// Starts the lookups for a game once. Safe to call every time a game is shown.
    func load(_ key: GameKey) {
        guard !key.md5.isEmpty else { return }
        known[key.md5] = key
        guard requested.insert(key.md5).inserted else { return }

        if let found = Self.lookupDetails(md5: key.md5, name: key.name) {
            details[key.md5] = found
            tick += 1
        }

        guard SteamGridDBClient.isConfigured else { return }
        Task { [weak self] in
            async let hero = OEHeroArtFetcher.shared.heroArt(md5: key.md5, displayName: key.name)
            async let grid = OEHeroArtFetcher.shared.gridArt(md5: key.md5, displayName: key.name)
            async let icon = OEHeroArtFetcher.shared.iconArt(md5: key.md5, displayName: key.name)
            let (heroImage, gridImage, iconImage) = await (hero, grid, icon)
            self?.store(hero: heroImage, grid: gridImage, icon: iconImage, for: key.md5)
        }
    }

    /// Forget what was asked, so a key just entered in Preferences takes effect.
    func reset() {
        requested.removeAll()
        known.values.forEach { load($0) }
        tick += 1
    }

    // MARK: -

    private func store(hero: NSImage?, grid: NSImage?, icon: NSImage?, for md5: String) {
        if let hero = hero { heroes[md5] = hero }
        if let grid = grid { grids[md5] = grid }
        if let icon = icon { icons[md5] = icon }
        tick += 1
    }

    private static func lookupDetails(md5: String, name: String) -> Details? {
        guard OpenVGDB.shared.isAvailable else { return nil }
        let columns = "releaseDeveloper, releasePublisher, releaseGenre, releaseDate, releaseDescription"

        func text(_ row: [String: Any], _ column: String) -> String? {
            guard let value = row[column] as? String, !value.isEmpty else { return nil }
            return value
        }
        func firstUseful(_ rows: [[String: Any]]) -> [String: Any]? {
            rows.first { text($0, "releaseDeveloper") != nil || text($0, "releaseGenre") != nil }
        }

        // Exact ROM first. A different dump of the same game is not in the database, so fall back to the title.
        var row: [String: Any]?
        let hash = md5.filter { $0.isHexDigit }.lowercased()
        if !hash.isEmpty {
            let sql = "SELECT \(columns) FROM ROMs rom LEFT JOIN RELEASES release USING (romID) WHERE lower(romHashMD5) = '\(hash)'"
            row = firstUseful((try? OpenVGDB.shared.executeQuery(sql)) ?? [])
        }
        if row == nil, !name.isEmpty {
            let safe = name.replacingOccurrences(of: "'", with: "''")
            let sql = "SELECT \(columns) FROM RELEASES WHERE releaseTitleName = '\(safe)' COLLATE NOCASE LIMIT 20"
            row = firstUseful((try? OpenVGDB.shared.executeQuery(sql)) ?? [])
        }
        guard let row = row else { return nil }

        var found = Details()
        found.developer = text(row, "releaseDeveloper")
        found.publisher = text(row, "releasePublisher")
        found.genres = (text(row, "releaseGenre") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        found.releaseDate = text(row, "releaseDate")
        found.summary = text(row, "releaseDescription")
        return found
    }

    /// What identifies a game to the providers and the caches.
    struct GameKey {
        let md5: String
        let name: String
        let systemIdentifier: String?

        /// Region and revision tags such as "(USA)" or "[!]" make provider searches miss.
        static func searchName(_ name: String) -> String {
            let stripped = name.replacingOccurrences(of: "\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", with: "", options: .regularExpression)
            let trimmed = stripped.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? name : trimmed
        }

        @MainActor
        init(_ game: OEDBGame) {
            md5 = game.defaultROM?.md5Hash ?? ""
            name = Self.searchName(game.cleanDisplayName)
            systemIdentifier = game.system?.systemIdentifier
        }
    }
}
