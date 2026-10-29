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
/// Views never talk to a provider directly. One online provider supplies the art (see `OEBigPictureArtSource`:
/// SteamGridDB or ScreenScraper, chosen in Preferences → Artwork), and the library's own box art is always the fallback:
///
/// - poster: the provider's poster, then the library's own box art (drawn by the card)
/// - hero backdrop and title logo: the provider's, or plain black when it has none
/// - details (genre, developer, publisher, year): the local OpenVGDB database, found by the ROM's MD5
///
/// Images are cached on disk by ROM MD5 so a game is looked up once.
@MainActor
final class OEBigPictureArt: ObservableObject {

    static let shared = OEBigPictureArt()

    /// Facts about a game that the library itself does not store.
    struct Details: Codable {
        var genres = [String]()
        var developer: String?
        var publisher: String?
        var releaseDate: String?
        var summary: String?

        /// OpenVGDB genres are layered ("Action,Platformer,2D"), and "Action" alone describes half the library.
        /// Use the next level down for the broad buckets, so tiles read Platformer, Shooter, Beat-'Em-Up.
        var primaryGenre: String? {
            guard let top = genres.first else { return nil }
            if ["Action", "Miscellaneous"].contains(top), genres.count > 1, genres[1] != "General" { return genres[1] }
            return top
        }
    }

    /// Bumped, at most about fifteen times a second, when something new arrives so views redraw. One redraw per
    /// game would repaint every card on screen once for each of them.
    @Published private(set) var tick = 0
    private var tickScheduled = false

    private func bump() {
        guard !tickScheduled else { return }
        tickScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            self?.tickScheduled = false
            self?.tick += 1
        }
    }

    /// A game's decoded pictures, at the size the screens draw them (see `OEBigPictureArtStore`).
    private final class Entry {
        var backdrop: NSImage?
        var poster: NSImage?
        var icon: NSImage?
        var logo: NSImage?
        var standardPoster = false

        var cost: Int {
            [backdrop, poster, icon, logo].compactMap { $0 }.reduce(0) { $0 + Int($1.size.width * $1.size.height) * 4 }
        }
    }

    /// Decoded pictures stay in memory only up to a limit, least recently used first, so a library of thousands of
    /// games cannot fill it. A game that falls out is read back from disk when its card shows again.
    private let memory: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()
    /// The big backdrop of the featured game, which is much larger than a card's.
    private let fullHeroes: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 6
        return cache
    }()
    private var loadingFullHeroes = Set<String>()
    private var details = [String: Details]()
    private var detailsRequested = Set<String>()
    private var requested = Set<String>()
    private var rereading = Set<String>()
    /// When each game's lookup started, until its providers have answered. Views show a skeleton for a moment.
    private var pending = [String: Date]()
    private var skeletonExpiryScheduled = false
    /// How long a skeleton is shown at most. A slow provider (ScreenScraper queues a game for minutes) must not leave a
    /// card empty: after this, the library cover or placeholder shows and the art replaces it when it arrives.
    private static let skeletonSeconds: TimeInterval = 2.5
    private var known = [String: GameKey]()
    private var storeInUse: (signature: String, store: OEBigPictureArtStore)?

    private func entry(_ key: GameKey) -> Entry? { memory.object(forKey: key.md5 as NSString) }

    /// The game's backdrop at card size.
    func hero(for key: GameKey) -> NSImage? { entry(key)?.backdrop }
    func grid(for key: GameKey) -> NSImage? { entry(key)?.poster }
    func icon(for key: GameKey) -> NSImage? { entry(key)?.icon }
    func logo(for key: GameKey) -> NSImage? { entry(key)?.logo }
    func details(for key: GameKey) -> Details? { details[key.md5] }

    /// The backdrop for the featured game's full-width hero: the large version once it is read, the card-size one before.
    func fullHero(for key: GameKey) -> NSImage? { fullHeroes.object(forKey: key.md5 as NSString) ?? hero(for: key) }

    /// Reads the large backdrop for a game that is about to fill the hero. Safe to call every time it shows.
    func prepareFullHero(_ key: GameKey) {
        guard !key.md5.isEmpty, fullHeroes.object(forKey: key.md5 as NSString) == nil,
              loadingFullHeroes.insert(key.md5).inserted, let store = currentStore() else { return }
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { OEBigPictureArtSet(hero: store.readHero(md5: key.md5)) }.value
            guard let self = self else { return }
            self.loadingFullHeroes.remove(key.md5)
            if let image = found.hero { self.fullHeroes.setObject(image, forKey: key.md5 as NSString); self.bump() }
        }
    }

    /// True while a game's art is being looked for, for a short time after it is first asked for. Views draw a
    /// skeleton in place of art, so an empty card never looks like an error.
    func isLoading(_ key: GameKey) -> Bool {
        #if DEBUG
        // `-OEBigPictureAlwaysLoading 1` holds the skeleton on screen so its look can be checked.
        if UserDefaults.standard.bool(forKey: "OEBigPictureAlwaysLoading") { return true }
        #endif
        guard let since = pending[key.md5] else { return false }
        return Date().timeIntervalSince(since) < Self.skeletonSeconds
    }

    /// True when the tile's picture is a provider's own square icon, which is made to fill the tile.
    func tileFills(for game: OEDBGame) -> Bool { icon(for: GameKey(game)) != nil }

    func hasStandardPoster(for key: GameKey) -> Bool { entry(key).map { $0.standardPoster && $0.poster != nil } ?? false }

    /// True when a poster should be built from the game's backdrop and logo: its box art comes in whatever shape the
    /// box was, so it is no use for a fixed portrait card. SteamGridDB's posters are already that shape.
    func usesBuiltPoster(for key: GameKey) -> Bool { entry(key).map { !$0.standardPoster && $0.backdrop != nil } ?? false }

    private func currentStore() -> OEBigPictureArtStore? {
        let chain = OEBigPictureArtSource.providers()
        guard !chain.isEmpty else { return nil }
        let signature = chain.map { $0.id }.joined(separator: "+")
        if let inUse = storeInUse, inUse.signature == signature { return inUse.store }
        let store = OEBigPictureArtStore(signature: signature)
        storeInUse = (signature, store)
        return store
    }

    private func apply(_ stored: OEBigPictureArtStore.Stored, md5: String) {
        let entry = memory.object(forKey: md5 as NSString) ?? Entry()
        entry.backdrop = stored.backdrop ?? entry.backdrop
        entry.poster = stored.poster ?? entry.poster
        entry.icon = stored.icon ?? entry.icon
        entry.logo = stored.logo ?? entry.logo
        entry.standardPoster = stored.standardPoster || entry.standardPoster
        memory.setObject(entry, forKey: md5 as NSString, cost: entry.cost)
        bump()
    }

    /// Starts the lookups for a game once. Safe to call every time a game is shown, and never waits: the saved copies
    /// are read and decoded in the background, and the providers are asked only for what is not saved yet.
    func load(_ key: GameKey) {
        guard !key.md5.isEmpty else { return }
        known[key.md5] = key
        loadDetails(key)
        guard let store = currentStore() else { return }

        guard requested.insert(key.md5).inserted else {
            // Asked before: if the memory limit dropped its pictures, read the small saved copies back.
            if memory.object(forKey: key.md5 as NSString) == nil, rereading.insert(key.md5).inserted {
                Task { [weak self] in
                    let stored = await Task.detached(priority: .userInitiated) { store.read(md5: key.md5, providerIDs: []).stored }.value
                    self?.rereading.remove(key.md5)
                    self?.apply(stored, md5: key.md5)
                }
            }
            return
        }

        pending[key.md5] = Date()
        if !skeletonExpiryScheduled {
            skeletonExpiryScheduled = true
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.skeletonSeconds * 1_000_000_000) + 100_000_000)
                self?.skeletonExpiryScheduled = false
                self?.tick += 1
            }
        }

        let chain = OEBigPictureArtSource.providers()
        Task { [weak self] in
            // 1. What is already saved, which is nearly always everything: small files, decoded off the main thread.
            let snapshot = await Task.detached(priority: .userInitiated) { store.read(md5: key.md5, providerIDs: chain.map { $0.id }) }.value
            guard let self = self else { return }
            self.apply(snapshot.stored, md5: key.md5)
            self.pending[key.md5] = nil

            // 2. Only a provider that has not answered for this game yet is asked, and only while something is missing.
            var gathered = OEBigPictureArtSet()
            var standard = snapshot.stored.standardPoster
            func hasEverything() -> Bool {
                (snapshot.stored.backdrop != nil || gathered.hero != nil) && (snapshot.stored.poster != nil || gathered.grid != nil)
                    && (snapshot.stored.icon != nil || gathered.icon != nil) && (snapshot.stored.logo != nil || gathered.logo != nil)
            }
            for provider in chain where !snapshot.answered.contains(provider.id) && !hasEverything() {
                let found = await provider.art(for: key)
                if found.isDefinitive {
                    await Task.detached(priority: .utility) { store.recordAnswer(md5: key.md5, providerID: provider.id, found: found.hasAny) }.value
                }
                if gathered.grid == nil, snapshot.stored.poster == nil, found.grid != nil, provider.providesStandardPosters { standard = true }
                gathered.fillGaps(from: found)
            }
            guard gathered.hasAny else { return }
            let isStandard = standard
            let result = await Task.detached(priority: .userInitiated) { () -> OEBigPictureArtStore.Stored in
                store.write(gathered, md5: key.md5, standardPoster: isStandard)
                return store.read(md5: key.md5, providerIDs: []).stored
            }.value
            self.apply(result, md5: key.md5)
        }
    }

    /// Reads a game's facts (genre, developer, year) on a background queue and keeps them on disk, so the main
    /// thread never searches the OpenVGDB database.
    private func loadDetails(_ key: GameKey) {
        guard detailsRequested.insert(key.md5).inserted else { return }
        Task { [weak self] in
            let found = await OEBigPictureDetailsLookup.details(md5: key.md5, name: key.name)
            guard let self = self, let found = found else { return }
            self.details[key.md5] = found
            self.bump()
        }
    }

    /// True when the provider in use is slow or rate limited (ScreenScraper), so the caller should not ask for the
    /// whole library at once.
    var providerIsThrottled: Bool { OEBigPictureArtSource.providers().contains { $0.isThrottled } }

    /// Forget what was asked, so a key just entered in Preferences takes effect.
    func reset() {
        requested.removeAll()
        memory.removeAllObjects()
        fullHeroes.removeAllObjects()
        pending.removeAll()
        rereading.removeAll()
        known.values.forEach { load($0) }
        tick += 1
    }

    // MARK: -

    nonisolated fileprivate static func lookupDetails(md5: String, name: String) -> Details? {
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
        /// ScreenScraper matches on the ROM's file name and size as well as its hash.
        let romFileName: String?
        let fileSize: Int
        /// The title with its region tag ("Super Mario Bros. (USA)"), the way libretro-thumbnails names its files.
        let fullName: String

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
            fullName = game.cleanDisplayName
            romFileName = game.defaultROM?.url?.lastPathComponent
            fileSize = game.defaultROM?.fileSize?.intValue ?? 0
        }
    }
}

// MARK: - Art providers

/// What a provider found for one game. Any slot may be empty.
struct OEBigPictureArtSet: @unchecked Sendable {
    var hero: NSImage?
    var grid: NSImage?
    var icon: NSImage?
    var logo: NSImage?
    /// True when the provider really answered (it found art, or it is sure it has none), as opposed to failing to
    /// reach its server. Only a real answer is remembered, so a game is not asked about again.
    var isDefinitive = false

    var isComplete: Bool { hero != nil && grid != nil && icon != nil && logo != nil }
    var hasAny: Bool { hero != nil || grid != nil || icon != nil || logo != nil }

    /// Keeps what is already here and takes the rest from `other`.
    mutating func fillGaps(from other: OEBigPictureArtSet) {
        hero = hero ?? other.hero
        grid = grid ?? other.grid
        icon = icon ?? other.icon
        logo = logo ?? other.logo
    }
}

/// One online source of big-picture art. Each provider keeps its own cache and its own pacing, so the views and
/// `OEBigPictureArt` do not care which one is in use.
protocol OEBigPictureArtProvider: Sendable {
    var id: String { get }
    var title: String { get }
    /// True for providers that must be asked slowly (a rate limit shared by the whole library).
    var isThrottled: Bool { get }
    /// True when the poster it supplies is always a portrait poster of the same shape.
    var providesStandardPosters: Bool { get }
    func art(for key: OEBigPictureArt.GameKey) async -> OEBigPictureArtSet
}

/// Which provider supplies big-picture art. Only these two: others need a developer key that large libraries would
/// exhaust. Set in Preferences → Artwork, or for one run with `-OEBigPictureArtSource screenscraper`.
enum OEBigPictureArtSource: String, CaseIterable {
    /// SteamGridDB when it has a key, otherwise ScreenScraper when signed in, otherwise library covers only.
    case automatic
    case steamGridDB
    case screenScraper
    case libraryOnly

    static let defaultsKey = "OEBigPictureArtSource"

    static var chosen: OEBigPictureArtSource {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(OEBigPictureArtSource.init(rawValue:)) ?? .automatic
    }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .steamGridDB: return "SteamGridDB"
        case .screenScraper: return "ScreenScraper"
        case .libraryOnly: return "Library covers only"
        }
    }

    /// Debug builds can pretend there is no SteamGridDB key with `-OEBigPictureDisableSteamGridDB 1`.
    static var steamGridDBAvailable: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "OEBigPictureDisableSteamGridDB") { return false }
        #endif
        return SteamGridDBClient.isConfigured
    }

    /// Signed in on Preferences → ScreenScraper.
    static var screenScraperAvailable: Bool {
        !(UserDefaults.standard.string(forKey: "ScreenScraperUsername") ?? "").isEmpty
            && OECredentialStore.shared.has(.screenScraperPassword)
    }

    /// The providers in use, in the order they are asked. Empty means library covers only.
    ///
    /// Automatic is a chain: SteamGridDB when it has a key, then ScreenScraper when signed in, then libretro-thumbnails
    /// (posters only, no key or login). A game gets each picture from the first one that has it, and the library's own
    /// cover is always the last fallback. Choosing a single source uses only that source.
    static func providers() -> [OEBigPictureArtProvider] {
        #if DEBUG
        // `-OEBigPictureOnlyLibretro 1` runs the keyless provider alone, to see what a build with no keys gets.
        if UserDefaults.standard.bool(forKey: "OEBigPictureOnlyLibretro") { return [LibretroThumbnailsArtProvider.shared] }
        #endif
        switch chosen {
        case .libraryOnly: return []
        case .steamGridDB: return steamGridDBAvailable ? [SteamGridDBArtProvider()] : []
        case .screenScraper: return screenScraperAvailable ? [ScreenScraperArtProvider.shared] : []
        case .automatic:
            var chain = [OEBigPictureArtProvider]()
            if steamGridDBAvailable { chain.append(SteamGridDBArtProvider()) }
            if screenScraperAvailable { chain.append(ScreenScraperArtProvider.shared) }
            chain.append(LibretroThumbnailsArtProvider.shared)
            return chain
        }
    }

    /// The providers' names for Preferences and the Settings screen.
    static var inUseTitle: String {
        let names = providers().map { $0.title }
        return names.isEmpty ? "Library covers only" : names.joined(separator: ", then ") + ", then library covers"
    }
}

/// SteamGridDB: one search, then poster, backdrop, icon and logo as separate lookups. Its own caches live in
/// `OEHeroArtFetcher`.
struct SteamGridDBArtProvider: OEBigPictureArtProvider {

    let id = "steamgriddb"
    let title = "SteamGridDB"
    let isThrottled = false
    let providesStandardPosters = true

    func art(for key: OEBigPictureArt.GameKey) async -> OEBigPictureArtSet {
        async let hero = OEHeroArtFetcher.shared.heroArt(md5: key.md5, displayName: key.name)
        async let grid = OEHeroArtFetcher.shared.gridArt(md5: key.md5, displayName: key.name)
        async let icon = OEHeroArtFetcher.shared.iconArt(md5: key.md5, displayName: key.name)
        async let logo = OEHeroArtFetcher.shared.logoArt(md5: key.md5, displayName: key.name)
        return await OEBigPictureArtSet(hero: hero, grid: grid, icon: icon, logo: logo, isDefinitive: true)
    }
}

/// ScreenScraper: one lookup per game (by hash, file name and size) returns every picture's address, so a game costs
/// one request. Its box art comes in every shape (N64 boxes are landscape, most others portrait), so each slot takes the
/// picture made for it: box art for posters, the cartridge or disc for tiles, fan art for backdrops. Requests go out one
/// at a time, at least `interval` apart, and stop for a while when ScreenScraper says the quota is used up. What it found
/// is saved by `OEBigPictureArtStore`; this type keeps nothing on disk.
actor ScreenScraperArtProvider: OEBigPictureArtProvider {

    static let shared = ScreenScraperArtProvider()

    nonisolated let id = "screenscraper"
    nonisolated let title = "ScreenScraper"
    nonisolated let isThrottled = true
    nonisolated let providesStandardPosters = false

    private let interval: TimeInterval = 1.5
    private let pause: TimeInterval = 120
    private var nextSlot = Date.distantPast
    private var pausedUntil = Date.distantPast
    private var inFlight = [String: Task<OEBigPictureArtSet, Never>]()

    func art(for key: OEBigPictureArt.GameKey) async -> OEBigPictureArtSet {
        guard !key.md5.isEmpty else { return OEBigPictureArtSet() }
        if let running = inFlight[key.md5] { return await running.value }
        let task = Task { await self.load(key) }
        inFlight[key.md5] = task
        let result = await task.value
        inFlight[key.md5] = nil
        return result
    }

    private func load(_ key: OEBigPictureArt.GameKey) async -> OEBigPictureArtSet {
        guard let systemIdentifier = key.systemIdentifier else { return OEBigPictureArtSet(isDefinitive: true) }

        await waitForSlot()
        let outcome = await Task.detached {
            ScreenScraperClient.shared.fetchGameInfo(md5: key.md5, romName: key.romFileName, fileSize: key.fileSize,
                                                     systemIdentifier: systemIdentifier)
        }.value

        switch outcome {
        case .failure(.rateLimited):
            pausedUntil = Date().addingTimeInterval(pause)
            return OEBigPictureArtSet()   // not an answer: ask again later
        case .failure:
            return OEBigPictureArtSet()   // offline or a bad login: not an answer either
        case .success(let found):
            var art = OEBigPictureArtSet(isDefinitive: true)
            guard let found = found else { return art }
            art.grid = await download(found.boxImageURL)
            art.hero = await download(found.heroImageURL)
            art.logo = await download(found.logoImageURL)
            // A cutout with no background (cartridge, disc, 3D box) is what the tiles want. Failing that, a square.
            for url in found.iconImageURLs {
                if let image = await download(url, accept: { OEBigPictureArtStore.hasTransparentCorners($0) || $0.isNearlySquare }) {
                    art.icon = image
                    break
                }
            }
            return art
        }
    }

    /// Reserves the next free request time before waiting, so callers queue up in order.
    private func waitForSlot() async {
        let now = Date()
        let start = max(now, nextSlot, pausedUntil)
        nextSlot = start.addingTimeInterval(interval)
        let delay = start.timeIntervalSince(now)
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }

    private func download(_ url: URL?, accept: (NSImage) -> Bool = { _ in true }) async -> NSImage? {
        guard let url = url, let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data),
              accept(image) else { return nil }
        return image
    }
}

/// libretro-thumbnails: a free public set of box art named after No-Intro titles. No key and no login, so it is in
/// every build, but it only has posters, and only for a title spelled exactly as it spells it (region tag included).
actor LibretroThumbnailsArtProvider: OEBigPictureArtProvider {

    static let shared = LibretroThumbnailsArtProvider()

    nonisolated let id = "libretro"
    nonisolated let title = "libretro-thumbnails"
    nonisolated let isThrottled = false
    nonisolated let providesStandardPosters = false

    private var inFlight = [String: Task<OEBigPictureArtSet, Never>]()

    func art(for key: OEBigPictureArt.GameKey) async -> OEBigPictureArtSet {
        guard !key.md5.isEmpty, key.systemIdentifier != nil else { return OEBigPictureArtSet(isDefinitive: true) }
        if let running = inFlight[key.md5] { return await running.value }
        let task = Task { await self.load(key) }
        inFlight[key.md5] = task
        let result = await task.value
        inFlight[key.md5] = nil
        return result
    }

    private func load(_ key: OEBigPictureArt.GameKey) async -> OEBigPictureArtSet {
        guard let systemIdentifier = key.systemIdentifier else { return OEBigPictureArtSet(isDefinitive: true) }

        // The library's title usually carries its region tag already; otherwise try the common ones.
        let tagged = key.fullName != key.name
        let candidates = tagged ? [key.fullName] : [key.name + " (USA)", key.name + " (Europe)", key.name + " (World)", key.name + " (Japan)"]
        for candidate in candidates {
            let address = await Task.detached {
                LibretroThumbnailsClient.shared.fetchBoxArtURL(gameName: candidate, systemIdentifier: systemIdentifier)
            }.value
            guard let address = address, let url = URL(string: address),
                  let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { continue }
            return OEBigPictureArtSet(grid: image, isDefinitive: true)
        }
        return OEBigPictureArtSet(isDefinitive: true)
    }
}

// MARK: - Saved copies

/// Every game's pictures, saved at the size the screens draw them, in `~/Library/Caches/OpenEmu/BigPictureArt`.
///
/// The originals are 1 to 2 MB each (a backdrop is 1920 by 1080), which is slow to read and decode and adds up to
/// gigabytes for a big library. A card needs a few hundred pixels, so each picture is saved once, scaled down, in the
/// smallest form that keeps it sharp: JPEG for backdrops and opaque posters, PNG for cutouts (tiles, logos). A game is
/// about 400 KB, and its files decode in a millisecond or two. It lives in Caches because it can always be fetched again.
///
/// There is one folder per set of providers in use, so changing the source in Preferences starts fresh instead of
/// mixing art from different sources.
final class OEBigPictureArtStore: @unchecked Sendable {

    enum Slot: String, CaseIterable {
        case hero, backdrop, poster, icon, logo

        /// Big picture can be shown on a very large display, so nothing is scaled down: each slot keeps the picture's
        /// full resolution. Speed comes from reading it off the main thread and keeping it in memory, not from shrinking it.
        var longestSide: CGFloat { .greatestFiniteMagnitude }
    }

    /// What is saved for one game, decoded and ready to draw.
    struct Stored: @unchecked Sendable {
        var backdrop: NSImage?
        var poster: NSImage?
        var icon: NSImage?
        var logo: NSImage?
        var standardPoster = false
    }

    private let directory: URL
    /// A provider that found nothing is asked again after this long (it may have been offline).
    private static let retryAfterNothing: TimeInterval = 7 * 24 * 3600

    init(signature: String) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("OpenEmu/BigPictureArt/v2/\(signature)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func existing(_ md5: String, _ slot: Slot) -> URL? {
        for ext in ["jpg", "png"] {
            let url = directory.appendingPathComponent("\(md5)-\(slot.rawValue).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private func marker(_ md5: String, _ name: String) -> URL { directory.appendingPathComponent("\(md5).\(name)") }

    // MARK: Reading (call off the main thread)

    private static func decode(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// Everything saved for a game, decoded, and which of `providerIDs` have already answered for it.
    func read(md5: String, providerIDs: [String]) -> (stored: Stored, answered: Set<String>) {
        var stored = Stored()
        stored.backdrop = (existing(md5, .backdrop) ?? existing(md5, .hero)).flatMap(Self.decode)
        stored.poster = existing(md5, .poster).flatMap(Self.decode)
        stored.icon = existing(md5, .icon).flatMap(Self.decode)
        stored.logo = existing(md5, .logo).flatMap(Self.decode)
        stored.standardPoster = FileManager.default.fileExists(atPath: marker(md5, "standard").path)

        var answered = Set<String>()
        for id in providerIDs {
            let url = marker(md5, "answered-\(id)")
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
            let foundSomething = (try? String(contentsOf: url)) == "found"
            let age = Date().timeIntervalSince((attributes[.modificationDate] as? Date) ?? .distantPast)
            if foundSomething || age < Self.retryAfterNothing { answered.insert(id) }
        }
        return (stored, answered)
    }

    /// The large backdrop for the featured game's hero.
    func readHero(md5: String) -> NSImage? { existing(md5, .hero).flatMap(Self.decode) }

    // MARK: Writing (call off the main thread)

    func recordAnswer(md5: String, providerID: String, found: Bool) {
        try? (found ? "found" : "empty").write(to: marker(md5, "answered-\(providerID)"), atomically: true, encoding: .utf8)
    }

    /// Saves the pictures a provider found, each scaled to its slot. A picture already saved is kept.
    func write(_ art: OEBigPictureArtSet, md5: String, standardPoster: Bool) {
        if let hero = art.hero { save(hero, md5, .hero) }
        if let grid = art.grid { save(grid, md5, .poster) }
        if let icon = art.icon { save(icon, md5, .icon) }
        if let logo = art.logo { save(logo, md5, .logo) }
        if standardPoster, art.grid != nil { try? Data().write(to: marker(md5, "standard")) }
    }

    private func save(_ image: NSImage, _ md5: String, _ slot: Slot) {
        guard existing(md5, slot) == nil, let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let cutout = Self.hasTransparentCorners(source)
        let jpeg = slot == .hero || slot == .backdrop || (slot == .poster && !cutout)
        guard let scaled = Self.scaled(source, longestSide: slot.longestSide, opaque: jpeg) else { return }

        let url = directory.appendingPathComponent("\(md5)-\(slot.rawValue).\(jpeg ? "jpg" : "png")")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, (jpeg ? "public.jpeg" : "public.png") as CFString, 1, nil) else { return }
        let options: [CFString: Any] = jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.97] : [:]
        CGImageDestinationAddImage(destination, scaled, options as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    private static func scaled(_ image: CGImage, longestSide: CGFloat, opaque: Bool) -> CGImage? {
        let scale = min(1, longestSide / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded())), height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// True for a cutout (a cartridge, a disc) whose four corners are see-through, as opposed to a picture with its own
    /// background. Safe to call from any thread.
    static func hasTransparentCorners(_ image: CGImage) -> Bool {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast else { return false }
        let size = 16
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        context.clear(CGRect(x: 0, y: 0, width: size, height: size))
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        func alpha(_ x: Int, _ y: Int) -> UInt8 { data[(y * size + x) * 4 + 3] }
        return [alpha(0, 0), alpha(size - 1, 0), alpha(0, size - 1), alpha(size - 1, size - 1)].allSatisfy { $0 < 26 }
    }

    static func hasTransparentCorners(_ image: NSImage) -> Bool {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil).map(hasTransparentCorners) ?? false
    }
}

/// The OpenVGDB lookup for a game's genre, developer and year. The database has no index on the hash, so a lookup
/// takes tens of milliseconds: far too long for the main thread, which is where it used to run for every game in the
/// library when big picture opened. It now runs one at a time on its own queue, and the answers are kept on disk.
enum OEBigPictureDetailsLookup {

    private static let queue = DispatchQueue(label: "org.openemu.bigpicture.details", qos: .utility)

    static func details(md5: String, name: String) async -> OEBigPictureArt.Details? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: lookup(md5: md5, name: name)) }
        }
    }

    /// Answers are saved per version of the database, so a database update is picked up.
    private static var directory: URL {
        let version = UserDefaults.standard.string(forKey: OpenVGDB.versionKey) ?? "none"
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("OpenEmu/BigPictureArt/details-\(version)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func lookup(md5: String, name: String) -> OEBigPictureArt.Details? {
        let file = directory.appendingPathComponent("\(md5).json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(OEBigPictureArt.Details?.self, from: data) {
            return saved
        }
        guard OpenVGDB.shared.isAvailable else { return nil }
        let found = OEBigPictureArt.lookupDetails(md5: md5, name: name)
        if let data = try? JSONEncoder().encode(found) { try? data.write(to: file) }   // a "nothing found" answer is kept too
        return found
    }
}

extension NSImage {

    /// True for a cutout (a cartridge, a disc) whose corners are see-through, as opposed to a picture with its own
    /// background. Checked once per image, on the main thread.
    var hasTransparentCorners: Bool {
        if let known = NSImage.cornerCache.object(forKey: self) { return known.boolValue }
        let transparent = OEBigPictureArtStore.hasTransparentCorners(self)
        NSImage.cornerCache.setObject(NSNumber(value: transparent), forKey: self)
        return transparent
    }

    var isNearlySquare: Bool { abs(size.width / max(size.height, 1) - 1) < 0.1 }

    private static let cornerCache = NSMapTable<NSImage, NSNumber>(keyOptions: .weakMemory, valueOptions: .strongMemory)
}
