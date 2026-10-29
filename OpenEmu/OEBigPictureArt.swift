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
    struct Details {
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

    /// Bumped whenever something new arrives so views redraw.
    @Published private(set) var tick = 0

    private var heroes = [String: NSImage]()
    private var grids = [String: NSImage]()
    private var icons = [String: NSImage]()
    private var logos = [String: NSImage]()
    private var details = [String: Details]()
    private var requested = Set<String>()
    /// Games whose poster came from a provider that makes proper portrait posters (SteamGridDB).
    private var standardPosters = Set<String>()
    /// When each game's lookup started, until its providers have answered. Views show a skeleton for a moment.
    private var pending = [String: Date]()
    private var skeletonExpiryScheduled = false
    /// How long a skeleton is shown at most. A slow provider (ScreenScraper queues a game for minutes) must not leave a
    /// card empty: after this, the library cover or placeholder shows and the art replaces it when it arrives.
    private static let skeletonSeconds: TimeInterval = 2.5
    private var known = [String: GameKey]()

    func hero(for key: GameKey) -> NSImage? { heroes[key.md5] }
    func grid(for key: GameKey) -> NSImage? { grids[key.md5] }
    func icon(for key: GameKey) -> NSImage? { icons[key.md5] }
    func logo(for key: GameKey) -> NSImage? { logos[key.md5] }
    func details(for key: GameKey) -> Details? { details[key.md5] }

    /// True when a poster should be built from the game's backdrop and logo: its box art comes in whatever shape the
    /// box was, so it is no use for a fixed portrait card. SteamGridDB's posters are already that shape.
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

    func hasStandardPoster(for key: GameKey) -> Bool { standardPosters.contains(key.md5) && grids[key.md5] != nil }

    func usesBuiltPoster(for key: GameKey) -> Bool { !standardPosters.contains(key.md5) && heroes[key.md5] != nil }

    /// Starts the lookups for a game once. Safe to call every time a game is shown.
    func load(_ key: GameKey) {
        guard !key.md5.isEmpty else { return }
        known[key.md5] = key
        guard requested.insert(key.md5).inserted else { return }

        if let found = Self.lookupDetails(md5: key.md5, name: key.name) {
            details[key.md5] = found
            tick += 1
        }

        let chain = OEBigPictureArtSource.providers()
        guard !chain.isEmpty else { return }
        pending[key.md5] = Date()
        if !skeletonExpiryScheduled {
            skeletonExpiryScheduled = true
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.skeletonSeconds * 1_000_000_000) + 100_000_000)
                self?.skeletonExpiryScheduled = false
                self?.tick += 1
            }
        }
        Task { [weak self] in
            defer { Task { @MainActor in self?.pending[key.md5] = nil; self?.tick += 1 } }
            // Each provider is asked only for what the ones before it did not have, and what arrives is shown at once.
            var merged = OEBigPictureArtSet()
            for provider in chain where !merged.isComplete {
                let found = await provider.art(for: key)
                if merged.grid == nil, found.grid != nil, provider.providesStandardPosters { self?.standardPosters.insert(key.md5) }
                merged.fillGaps(from: found)
                self?.store(merged, for: key.md5)
            }
        }
    }

    /// True when the provider in use is slow or rate limited (ScreenScraper), so the caller should not ask for the
    /// whole library at once.
    var providerIsThrottled: Bool { OEBigPictureArtSource.providers().contains { $0.isThrottled } }

    /// Forget what was asked, so a key just entered in Preferences takes effect.
    func reset() {
        requested.removeAll()
        heroes.removeAll(); grids.removeAll(); icons.removeAll(); logos.removeAll(); standardPosters.removeAll(); pending.removeAll()
        known.values.forEach { load($0) }
        tick += 1
    }

    // MARK: -

    private func store(_ art: OEBigPictureArtSet, for md5: String) {
        if let hero = art.hero { heroes[md5] = hero }
        if let grid = art.grid { grids[md5] = grid }
        if let icon = art.icon { icons[md5] = icon }
        if let logo = art.logo { logos[md5] = logo }
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

    var isComplete: Bool { hero != nil && grid != nil && icon != nil && logo != nil }

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
        return await OEBigPictureArtSet(hero: hero, grid: grid, icon: icon, logo: logo)
    }
}

/// ScreenScraper: one lookup per game (by hash, file name and size) returns every picture's address, so a game costs
/// one request. Its box art comes in every shape (N64 boxes are landscape, most others portrait), so each slot takes the
/// picture made for it: box art for posters, the fixed-size square "mix" image for tiles, fan art for backdrops. Requests go out one at a time, at least `interval` apart, and stop for a while when ScreenScraper
/// says the quota is used up. Every game is looked up once: what it had, or the fact that it had nothing, is kept on
/// disk (`~/Library/Application Support/OpenEmu/BigPictureArt/ScreenScraper`).
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

    private let directory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("OpenEmu/BigPictureArt/ScreenScraper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func file(_ md5: String, _ kind: String) -> URL { directory.appendingPathComponent("\(md5)-\(kind).png") }
    /// Bump when a lookup starts keeping something new, so games looked up before are asked about again.
    private static let lookupVersion = 7
    private func marker(_ md5: String) -> URL { directory.appendingPathComponent("\(md5).looked-up-\(Self.lookupVersion)") }

    func art(for key: OEBigPictureArt.GameKey) async -> OEBigPictureArtSet {
        guard !key.md5.isEmpty else { return OEBigPictureArtSet() }
        if let running = inFlight[key.md5] { return await running.value }
        let task = Task { await self.load(key) }
        inFlight[key.md5] = task
        let result = await task.value
        inFlight[key.md5] = nil
        return result
    }

    private func cached(_ md5: String) -> OEBigPictureArtSet {
        func image(_ kind: String) -> NSImage? { NSImage(contentsOf: file(md5, kind)) }
        return OEBigPictureArtSet(hero: image("hero"), grid: image("grid"), icon: image("icon"), logo: image("logo"))
    }

    private func load(_ key: OEBigPictureArt.GameKey) async -> OEBigPictureArtSet {
        let known = cached(key.md5)
        if FileManager.default.fileExists(atPath: marker(key.md5).path) { return known }
        guard let systemIdentifier = key.systemIdentifier else { return known }

        await waitForSlot()
        let outcome = await Task.detached {
            ScreenScraperClient.shared.fetchGameInfo(md5: key.md5, romName: key.romFileName, fileSize: key.fileSize,
                                                     systemIdentifier: systemIdentifier)
        }.value

        switch outcome {
        case .failure(.rateLimited):
            pausedUntil = Date().addingTimeInterval(pause)
            return known
        case .failure:
            return known   // offline or a bad login: try again next time, do not remember it
        case .success(let found):
            var art = known
            if let found = found {
                art.grid = await download(found.boxImageURL, to: file(key.md5, "grid")) ?? art.grid
                art.hero = await download(found.heroImageURL, to: file(key.md5, "hero")) ?? art.hero
                art.logo = await download(found.logoImageURL, to: file(key.md5, "logo")) ?? art.logo
                // A cutout with no background (cartridge, disc, 3D box) is what the tiles want. Failing that, a square.
                art.icon = nil   // a fresh lookup starts the choice over; an older pick may be a worse one
                for url in found.iconImageURLs {
                    if let image = await download(url, to: file(key.md5, "icon"), accept: { $0.hasTransparentCorners || $0.isNearlySquare }) {
                        art.icon = image
                        break
                    }
                }
            }
            try? Data().write(to: marker(key.md5))
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

    private func download(_ url: URL?, to path: URL, accept: (NSImage) -> Bool = { _ in true }) async -> NSImage? {
        guard let url = url, let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data),
              accept(image),
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        try? png.write(to: path)
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

    private let directory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("OpenEmu/BigPictureArt/Libretro", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func art(for key: OEBigPictureArt.GameKey) async -> OEBigPictureArtSet {
        guard !key.md5.isEmpty, key.systemIdentifier != nil else { return OEBigPictureArtSet() }
        if let running = inFlight[key.md5] { return await running.value }
        let task = Task { await self.load(key) }
        inFlight[key.md5] = task
        let result = await task.value
        inFlight[key.md5] = nil
        return result
    }

    private func load(_ key: OEBigPictureArt.GameKey) async -> OEBigPictureArtSet {
        let posterFile = directory.appendingPathComponent("\(key.md5)-grid.png")
        let marker = directory.appendingPathComponent("\(key.md5).looked-up")
        if let image = NSImage(contentsOf: posterFile) { return OEBigPictureArtSet(grid: image) }
        if FileManager.default.fileExists(atPath: marker.path) { return OEBigPictureArtSet() }
        guard let systemIdentifier = key.systemIdentifier else { return OEBigPictureArtSet() }

        // The library's title usually carries its region tag already; otherwise try the common ones.
        let tagged = key.fullName != key.name
        let candidates = tagged ? [key.fullName] : [key.name + " (USA)", key.name + " (Europe)", key.name + " (World)", key.name + " (Japan)"]
        for candidate in candidates {
            let address = await Task.detached {
                LibretroThumbnailsClient.shared.fetchBoxArtURL(gameName: candidate, systemIdentifier: systemIdentifier)
            }.value
            guard let address = address, let url = URL(string: address),
                  let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data),
                  let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: posterFile)
            return OEBigPictureArtSet(grid: image)
        }
        try? Data().write(to: marker)
        return OEBigPictureArtSet()
    }
}

extension NSImage {

    /// True for a cutout (a cartridge, a disc) whose corners are see-through, as opposed to a picture with its own
    /// background. Checked once per image.
    var hasTransparentCorners: Bool {
        if let known = NSImage.cornerCache.object(forKey: self) { return known.boolValue }
        var transparent = false
        if let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), rep.hasAlpha, rep.pixelsWide > 1, rep.pixelsHigh > 1 {
            let corners = [(0, 0), (rep.pixelsWide - 1, 0), (0, rep.pixelsHigh - 1), (rep.pixelsWide - 1, rep.pixelsHigh - 1)]
            transparent = corners.allSatisfy { (rep.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 1) < 0.1 }
        }
        NSImage.cornerCache.setObject(NSNumber(value: transparent), forKey: self)
        return transparent
    }

    var isNearlySquare: Bool { abs(size.width / max(size.height, 1) - 1) < 0.1 }

    private static let cornerCache = NSMapTable<NSImage, NSNumber>(keyOptions: .weakMemory, valueOptions: .strongMemory)
}
