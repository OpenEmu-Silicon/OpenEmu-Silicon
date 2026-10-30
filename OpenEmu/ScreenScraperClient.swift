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

import Foundation
import os.log
import OpenEmuSystem

struct ScreenScraperResult {
    var gameTitle: String?
    var boxImageURL: URL?
    var gameDescription: String?
    /// Big-picture art from the same lookup: a wide backdrop (fan art, else a screenshot) and the title logo.
    var heroImageURL: URL?
    var logoImageURL: URL?
    /// For the small tiles, best first: the cartridge or disc, the 3D box, then a square screenshot-and-box mix.
    /// The first two are cutouts with no background; the mix is the last resort.
    var iconImageURLs = [URL]()
    var iconImageURL: URL? { iconImageURLs.first }
}

enum ScreenScraperFetchError: Error, Equatable {
    case networkUnavailable(String)
    case badCredentials
    case rateLimited
    case notFound
    case invalidResponse
}

extension ScreenScraperFetchError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .networkUnavailable(let detail):
            return "Could not reach ScreenScraper — check your connection. (\(detail))"
        case .badCredentials:
            return "ScreenScraper rejected your credentials. Check your username and password in Preferences → Cover Art."
        case .rateLimited:
            return "ScreenScraper rate limit reached. Try again later."
        case .notFound:
            return nil  // Not an error worth surfacing — ROM simply isn't in the database
        case .invalidResponse:
            return "ScreenScraper returned an unexpected response."
        }
    }
}

final class ScreenScraperClient {

    static let shared = ScreenScraperClient()

    /// The error from the most recent fetch, if any. Nil on success or .notFound.
    /// Updated on every call to fetchGameInfo. Thread-safe via main-queue dispatch.
    @MainActor private(set) var lastFetchError: ScreenScraperFetchError?

    /// True once verifyCredentials() has returned success this session.
    /// Lets the Cover Art pane distinguish "credentials saved but unverified"
    /// from "credentials confirmed by ScreenScraper."
    @MainActor private(set) var hasVerifiedCredentials: Bool = false

    @MainActor func clearLastFetchError() { lastFetchError = nil }

    /// Verify that a username/password pair is accepted by ScreenScraper.
    /// Calls ssuserInfos.php — lightweight, does not burn game-lookup quota.
    /// Returns true on 2xx, false on 403, throws on network error.
    func verifyCredentials(username: String, password: String) async throws -> Bool {
        var components = URLComponents(string: "https://www.screenscraper.fr/api2/ssuserInfos.php")!
        components.queryItems = [
            URLQueryItem(name: "devid",       value: ScreenScraperClient.devID),
            URLQueryItem(name: "devpassword", value: ScreenScraperClient.devPassword),
            URLQueryItem(name: "ssid",        value: username),
            URLQueryItem(name: "sspassword",  value: password),
            URLQueryItem(name: "output",      value: "json"),
            URLQueryItem(name: "softname",    value: "OpenEmu-Silicon"),
        ]
        guard let url = components.url else { return false }
        let (_, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { return false }
        let ok = (200..<300).contains(http.statusCode)
        if ok { await MainActor.run { hasVerifiedCredentials = true } }
        return ok
    }

    // ScreenScraper numeric system IDs keyed by OpenEmu system identifier.
    //
    // Verified against https://www.screenscraper.fr/api2/systemesListe.php (May 2026).
    // Each entry's SS ID was confirmed by name match; previously several were wrong
    // and silently sent lookups to the wrong databases (c64 → Amiga, sg1000 → Xbox,
    // wii → nonexistent ID 38, sv → nonexistent ID 24).
    //
    // Some OpenEmu identifiers cover multiple SS systems (e.g. "gb" handles both
    // Game Boy and GBC carts because they share the Gambatte core). For those, the
    // base ID below is the broader/older system; `resolveSystemID(for:romName:)`
    // upgrades to the variant ID based on file extension at lookup time.
    static let systemIDs: [String: Int] = [
        // Nintendo
        "openemu.system.nes":           3,
        "openemu.system.fds":         106,   // Famicom Disk System
        "openemu.system.snes":          4,
        "openemu.system.n64":          14,
        "openemu.system.gc":           13,   // GameCube
        "openemu.system.wii":          16,   // Wii (was 38 — nonexistent)
        "openemu.system.gb":            9,   // Game Boy — .gbc routes to 10 via resolveSystemID
        "openemu.system.gba":          12,
        "openemu.system.nds":          15,
        "openemu.system.vb":           11,   // Virtual Boy
        "openemu.system.pokemonmini": 211,

        // Sony
        "openemu.system.psx":          57,
        "openemu.system.ps2":          58,
        "openemu.system.psp":          61,

        // Sega
        "openemu.system.sg":            1,   // Mega Drive / Genesis
        "openemu.system.sg1000":      109,   // Sega SG-1000 (was 32 — that's Xbox)
        "openemu.system.sms":           2,
        "openemu.system.gg":           21,
        "openemu.system.scd":          20,
        "openemu.system.32x":          19,
        "openemu.system.saturn":       22,
        "openemu.system.dc":           23,

        // Atari
        "openemu.system.2600":         26,
        "openemu.system.5200":         40,
        "openemu.system.7800":         41,
        "openemu.system.jaguar":       27,
        "openemu.system.lynx":         28,
        "openemu.system.atari8bit":    43,

        // NEC
        "openemu.system.pce":          31,   // PC Engine / TurboGrafx-16
        "openemu.system.pcecd":       114,   // PC Engine CD-ROM
        "openemu.system.pcfx":         72,

        // SNK
        "openemu.system.ngp":          25,   // Neo Geo Pocket — .ngc routes to 82 (NGPC)

        // Bandai
        "openemu.system.ws":           45,   // WonderSwan — .wsc routes to 46 (WS Color)

        // Other home consoles
        "openemu.system.3do":          29,
        "openemu.system.colecovision": 48,
        "openemu.system.intellivision": 115,
        "openemu.system.odyssey2":    104,
        "openemu.system.vectrex":     102,
        "openemu.system.sv":          207,   // Watara Supervision (was 24 — nonexistent)

        // Computer / MSX
        "openemu.system.msx":         113,
        "openemu.system.c64":          66,   // Commodore 64 (was 64 — that's Amiga)

        // Arcade
        "openemu.system.arcade":       75,
    ]

    /// Returns the most specific ScreenScraper system ID for a given OpenEmu identifier,
    /// upgrading to a variant ID when the ROM's file extension indicates a sub-platform.
    ///
    /// OpenEmu treats Game Boy Color, WonderSwan Color, and Neo-Geo Pocket Color as the
    /// same logical system as their predecessors (single core handles both). ScreenScraper
    /// tracks them as separate systems with separate cover art catalogs. This routes
    /// `.gbc`/`.wsc`/`.ngc` ROMs to the correct color-variant database.
    static func resolveSystemID(for systemIdentifier: String, romName: String?) -> Int? {
        guard let baseID = systemIDs[systemIdentifier] else { return nil }
        guard let name = romName?.lowercased() else { return baseID }
        let ext = (name as NSString).pathExtension
        switch (systemIdentifier, ext) {
        case ("openemu.system.gb",  "gbc"): return 10   // Game Boy Color
        case ("openemu.system.ws",  "wsc"): return 46   // WonderSwan Color
        case ("openemu.system.ngp", "ngc"): return 82   // Neo Geo Pocket Color
        default: return baseID
        }
    }

    // Preferred region tags in priority order, per OELocalizationHelper region
    private func preferredRegions() -> [String] {
        switch OELocalizationHelper.shared.regionName {
        case "North America":
            return ["us", "wor", "eu", "uk"]
        case "Europe":
            // ScreenScraper has a version for each language of Europe; take the player's before the general one.
            let own: [String: String] = ["fr": "fr", "de": "de", "es": "sp", "it": "it"]
            let language = Locale.current.languageCode ?? ""
            return (own[language].map { [$0] } ?? []) + ["eu", "uk", "wor", "us"]
        case "Japan":
            return ["jp", "wor", "us", "eu", "uk"]
        default:
            return ["wor", "us", "eu", "uk"]
        }
    }

    /// Synchronous fetch suitable for calling from a background DispatchQueue.sync block.
    ///
    /// Returns `.success(nil)` when the ROM was not found (not an error).
    /// Returns `.failure` for network errors, bad credentials, rate limiting, etc.
    /// Also writes to `lastFetchError` (main actor) for UI display.
    ///
    /// Pass `debugMode: true` to attach the developer debug password (100 uses/day limit).
    /// - Parameters:
    ///   - md5: ROM MD5 hash (uppercased internally). Sent as `rommd5` when non-empty.
    ///   - romName: Full ROM filename including extension. Sent as `romnom`.
    ///   - fileSize: ROM file size in bytes. Sent as `romtaille` when > 0. Significantly
    ///     improves match accuracy for ROMs whose MD5 doesn't match SS's canonical hash
    ///     (headered/byte-swapped/trainer-modified dumps).
    ///   - systemIdentifier: OpenEmu system identifier, mapped to SS `systemeid`.
    ///   - debugMode: Developer cache-bypass mode (100/day limit, never use in production).
    func fetchGameInfo(md5: String?, romName: String?, fileSize: Int? = nil, systemIdentifier: String, debugMode: Bool = false) -> Result<ScreenScraperResult?, ScreenScraperFetchError> {

        guard let systemID = ScreenScraperClient.resolveSystemID(for: systemIdentifier, romName: romName) else {
            return .success(nil)
        }

        // First attempt: raw filename as provided.
        let firstResult = performFetch(md5: md5, romName: romName, fileSize: fileSize, systemID: systemID, debugMode: debugMode)

        // Retry on not-found (success(nil)) using a cleaned filename, if cleaning
        // actually produces a different name. This catches the very common case of
        // dump-tagged filenames — "Super Mario World (USA) [!].sfc" — where SS's
        // index entry uses the No-Intro canonical name without bracketed annotations.
        // Costs one extra request only on misses, never on hits.
        if case .success(nil) = firstResult,
           let raw = romName,
           !raw.isEmpty {
            let cleaned = ScreenScraperClient.cleanedROMFileName(raw)
            if cleaned != raw {
                let retry = performFetch(md5: md5, romName: cleaned, fileSize: fileSize, systemID: systemID, debugMode: debugMode)
                return retry
            }
        }
        return firstResult
    }

    /// Strips parenthesised and bracketed annotations — (USA), [!], (Rev A), (Disc 1) —
    /// from a ROM filename while preserving the file extension. Used to retry SS lookups
    /// when the raw filename misses but the canonical No-Intro name would match.
    static func cleanedROMFileName(_ filename: String) -> String {
        let ns = filename as NSString
        let ext  = ns.pathExtension
        let base = ns.deletingPathExtension
        var stripped = base
        stripped = stripped.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
        stripped = stripped.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        // Collapse runs of spaces and trim
        stripped = stripped.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        stripped = stripped.trimmingCharacters(in: .whitespaces)
        if stripped.isEmpty { return filename }
        return ext.isEmpty ? stripped : "\(stripped).\(ext)"
    }

    private func performFetch(md5: String?, romName: String?, fileSize: Int?, systemID: Int, debugMode: Bool) -> Result<ScreenScraperResult?, ScreenScraperFetchError> {

        var components = URLComponents(string: "https://www.screenscraper.fr/api2/jeuInfos.php")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "softname",  value: "OpenEmu-Silicon"),
            URLQueryItem(name: "output",    value: "json"),
            URLQueryItem(name: "systemeid", value: String(systemID)),
            // Developer app credentials — always present, identify the software to the API
            URLQueryItem(name: "devid",       value: ScreenScraperClient.devID),
            URLQueryItem(name: "devpassword", value: ScreenScraperClient.devPassword),
        ]

        // ScreenScraper requires romnom; rommd5 is additive for accuracy.
        // Sending both when available gives the best match rate.
        guard (md5 != nil && !(md5!.isEmpty)) || (romName != nil && !(romName!.isEmpty)) else {
            return .success(nil)
        }
        if let md5 = md5, !md5.isEmpty {
            queryItems.append(URLQueryItem(name: "rommd5", value: md5.uppercased()))
        }
        if let romName = romName, !romName.isEmpty {
            queryItems.append(URLQueryItem(name: "romnom", value: romName))
        }
        if let fileSize = fileSize, fileSize > 0 {
            queryItems.append(URLQueryItem(name: "romtaille", value: String(fileSize)))
        }

        // User credentials — optional, attached when the user has saved their own account.
        // Increases the user's personal rate limit beyond the anonymous shared quota.
        let ssUsername = UserDefaults.standard.string(forKey: "ScreenScraperUsername") ?? ""
        let ssPassword = OECredentialStore.shared.get(.screenScraperPassword) ?? ""
        if !ssUsername.isEmpty && !ssPassword.isEmpty {
            queryItems.append(URLQueryItem(name: "ssid",       value: ssUsername))
            queryItems.append(URLQueryItem(name: "sspassword", value: ssPassword))
        }

        // Developer debug mode — forces cache refresh and bypasses quota counters for testing.
        // Capped at 100 uses/day by ScreenScraper. Never enable in production flows.
        if debugMode {
            queryItems.append(URLQueryItem(name: "devdebugpassword", value: ScreenScraperClient.devDebugPassword))
            queryItems.append(URLQueryItem(name: "forceupdate",      value: "1"))
        }

        components.queryItems = queryItems

        guard let url = components.url else { return .success(nil) }

        var fetchResult: Result<ScreenScraperResult?, ScreenScraperFetchError> = .success(nil)
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            defer { semaphore.signal() }

            guard let self = self else { return }

            if let error = error {
                let detail = error.localizedDescription
                os_log(.error, log: .default, "ScreenScraper network error: %{public}@", detail)
                let ssError = ScreenScraperFetchError.networkUnavailable(detail)
                fetchResult = .failure(ssError)
                Task { @MainActor in self.lastFetchError = ssError }
                return
            }

            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200..<300:
                    break
                case 401, 403:
                    os_log(.error, log: .default, "ScreenScraper auth error: HTTP %d", http.statusCode)
                    fetchResult = .failure(.badCredentials)
                    Task { @MainActor in self.lastFetchError = .badCredentials }
                    return
                case 404:
                    fetchResult = .success(nil)
                    Task { @MainActor in self.lastFetchError = nil }
                    return
                case 430:
                    os_log(.error, log: .default, "ScreenScraper rate limited (HTTP 430)")
                    fetchResult = .failure(.rateLimited)
                    Task { @MainActor in self.lastFetchError = .rateLimited }
                    return
                default:
                    os_log(.error, log: .default, "ScreenScraper unexpected HTTP %d", http.statusCode)
                    fetchResult = .failure(.invalidResponse)
                    Task { @MainActor in self.lastFetchError = .invalidResponse }
                    return
                }
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = json["response"] as? [String: Any],
                  let jeu = response["jeu"] as? [String: Any] else {
                os_log(.error, log: .default, "ScreenScraper returned unparseable response")
                fetchResult = .failure(.invalidResponse)
                Task { @MainActor in self.lastFetchError = .invalidResponse }
                return
            }

            let parsed = self.parseGameInfo(jeu: jeu)
            fetchResult = .success(parsed)
            Task { @MainActor in
                self.lastFetchError = nil
                self.hasVerifiedCredentials = true
            }
        }

        task.resume()
        semaphore.wait()
        return fetchResult
    }

    // MARK: - JSON Parsing

    /// The best media for this player. With `regionFirst` false, `types` are tried in order and the player's region only
    /// picks among the same type: fan art always beats a screenshot, whatever the screenshot's region. With it true the
    /// region comes first across all the types: a Japanese HD logo is no use to a player in the US when the plain logo
    /// has a US version. Regions with their own script (Japan, China, Korea) are used only when nothing else exists.
    private func pickMedia(_ medias: [[String: Any]], types: [String], regionFirst: Bool = false) -> URL? {
        func region(_ media: [String: Any]) -> String { (media["region"] as? String) ?? "" }
        func type(_ media: [String: Any]) -> String { (media["type"] as? String) ?? "" }
        func address(_ media: [String: Any]) -> URL? { (media["url"] as? String).flatMap { URL(string: $0) } }
        let ownScript: Set<String> = ["jp", "cn", "asi", "kr", "tw"]

        func best(among tier: [String]) -> URL? {
            let wanted = medias.filter { tier.contains(type($0)) }
            for preferred in preferredRegions() {
                for wantedType in tier {
                    if let match = wanted.first(where: { type($0) == wantedType && region($0) == preferred }), let url = address(match) { return url }
                }
            }
            for includeOwnScript in [false, true] {
                for wantedType in tier {
                    if let match = wanted.first(where: { type($0) == wantedType && (includeOwnScript || !ownScript.contains(region($0))) }),
                       let url = address(match) { return url }
                }
            }
            return nil
        }

        let tiers = regionFirst ? [types] : types.map { [$0] }
        for tier in tiers { if let url = best(among: tier) { return url } }
        return nil
    }

    func parseGameInfo(jeu: [String: Any]) -> ScreenScraperResult? {
        var result = ScreenScraperResult()

        // Game title — prefer regional name
        if let noms = jeu["noms"] as? [[String: Any]] {
            let preferred = preferredRegions()
            var picked: String?
            for region in preferred {
                if let match = noms.first(where: { ($0["region"] as? String) == region }),
                   let text = match["text"] as? String {
                    picked = text
                    break
                }
            }
            if picked == nil {
                picked = noms.first?["text"] as? String
            }
            result.gameTitle = picked
        }

        // Description — prefer regional
        if let synopses = jeu["synopsis"] as? [[String: Any]] {
            let preferred = preferredRegions()
            var picked: String?
            for region in preferred {
                if let match = synopses.first(where: { ($0["region"] as? String) == region }),
                   let text = match["text"] as? String {
                    picked = text
                    break
                }
            }
            if picked == nil {
                picked = synopses.first?["text"] as? String
            }
            result.gameDescription = picked
        }

        if let medias = jeu["medias"] as? [[String: Any]] {
            result.boxImageURL = pickMedia(medias, types: ["box-2D"])
            result.heroImageURL = pickMedia(medias, types: ["fanart", "ss"])
            result.logoImageURL = pickMedia(medias, types: ["wheel-hd", "wheel"], regionFirst: true)
            result.iconImageURLs = ["support-2D", "box-3D", "mixrbv2", "mixrbv1"].compactMap { pickMedia(medias, types: [$0]) }
        }

        guard result.gameTitle != nil || result.boxImageURL != nil else { return nil }
        return result
    }
}
