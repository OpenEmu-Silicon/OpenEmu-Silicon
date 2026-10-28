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

struct SteamGridDBItem: Codable {
    let sgdbID: Int
    let type: SteamGridDBItemType
    let url: URL
    let thumbURL: URL
    let width: Int
    let height: Int
    let score: Int
    let authorName: String?
}

extension SteamGridDBItem: Identifiable {
    var id: String { "\(type.rawValue)-\(sgdbID)" }
}

enum SteamGridDBItemType: String, Codable {
    case hero, grid, icon
    var displayLabel: String {
        switch self {
        case .hero: return "HERO ART"
        case .grid: return "COVER ART"
        case .icon: return "ICON"
        }
    }
}

actor SteamGridDBClient {

    static let shared = SteamGridDBClient()

    /// Entered in Preferences → Artwork. Empty means the provider is off.
    static var apiKey: String { OECredentialStore.shared.get(.steamGridDBAPIKey) ?? "" }
    static var isConfigured: Bool { !apiKey.isEmpty }

    private let base = "https://www.steamgriddb.com/api/v2"

    // Avoid redundant search calls when hero and icon are fetched for the same game.
    private var nameToID: [String: Int] = [:]

    func gameID(for name: String) async -> Int? {
        guard SteamGridDBClient.isConfigured else { return nil }
        if let cached = nameToID[name] { return cached }

        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(base)/search/autocomplete/\(encoded)") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(SteamGridDBClient.apiKey)", forHTTPHeaderField: "Authorization")

        let fetched: (Data, URLResponse)
        do { fetched = try await URLSession.shared.data(for: request) } catch { return nil }
        let (data, response) = fetched
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]],
              let id = dataArray.first?["id"] as? Int else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            return nil
        }

        nameToID[name] = id
        return id
    }

    func heroURL(for gameID: Int) async -> URL? {
        guard let url = URL(string: "\(base)/heroes/game/\(gameID)") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(SteamGridDBClient.apiKey)", forHTTPHeaderField: "Authorization")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else { return nil }

        // Prefer images at least 1920px wide; fall back to first result.
        let entry = dataArray.first(where: { ($0["width"] as? Int ?? 0) >= 1920 }) ?? dataArray.first
        guard let urlStr = entry?["url"] as? String else { return nil }
        return URL(string: urlStr)
    }

    func iconURL(for gameID: Int) async -> URL? {
        guard let url = URL(string: "\(base)/icons/game/\(gameID)") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(SteamGridDBClient.apiKey)", forHTTPHeaderField: "Authorization")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]],
              let urlStr = dataArray.first?["url"] as? String else { return nil }
        return URL(string: urlStr)
    }

    /// The game's title logo (a transparent image of the title lettering), if SteamGridDB has one.
    func logoURL(for gameID: Int) async -> URL? {
        guard let url = URL(string: "\(base)/logos/game/\(gameID)") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(SteamGridDBClient.apiKey)", forHTTPHeaderField: "Authorization")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]],
              let urlStr = dataArray.first?["url"] as? String else { return nil }
        return URL(string: urlStr)
    }

    /// A portrait poster. Asks for the standard poster sizes first, then takes any portrait grid the game has.
    func gridURL(for gameID: Int) async -> URL? {
        let sized = await gridItems(gameID: gameID, dimensions: "600x900,342x482,660x930")
        if let url = sized.first?.url { return url }
        let any = await gridItems(gameID: gameID, dimensions: nil)
        let portrait = any.first { $0.height > $0.width }
        os_log(.default, log: .default, "SteamGridDB grids for game %d: %d sized, %d any, portrait found %d", gameID, sized.count, any.count, portrait == nil ? 0 : 1)
        return portrait?.url
    }

    private func gridItems(gameID: Int, dimensions: String?) async -> [(url: URL, width: Int, height: Int)] {
        guard var components = URLComponents(string: "\(base)/grids/game/\(gameID)") else { return [] }
        var items = [URLQueryItem(name: "types", value: "static"), URLQueryItem(name: "mimes", value: "image/png,image/jpeg")]
        if let dimensions = dimensions { items.append(URLQueryItem(name: "dimensions", value: dimensions)) }
        components.queryItems = items
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(SteamGridDBClient.apiKey)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return [] }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            return []
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let array = json["data"] as? [[String: Any]] else { return [] }
        return array.compactMap { entry in
            guard let urlString = entry["url"] as? String, let url = URL(string: urlString) else { return nil }
            return (url, entry["width"] as? Int ?? 0, entry["height"] as? Int ?? 0)
        }
    }

    func fetchArtMedia(gameID: Int) async -> [SteamGridDBItem] {
        async let heroes = fetchArtItems(type: .hero, gameID: gameID)
        async let grids  = fetchArtItems(type: .grid, gameID: gameID)
        async let icons  = fetchArtItems(type: .icon, gameID: gameID)
        return await heroes + grids + icons
    }

    private func fetchArtItems(type: SteamGridDBItemType, gameID: Int) async -> [SteamGridDBItem] {
        guard SteamGridDBClient.isConfigured else { return [] }
        let segment: String
        var queryItems: [URLQueryItem] = []
        switch type {
        case .hero: segment = "heroes"
        case .grid: segment = "grids"; queryItems.append(URLQueryItem(name: "dimensions", value: "600x900"))
        case .icon: segment = "icons"
        }
        var components = URLComponents(string: "\(base)/\(segment)/game/\(gameID)")!
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(SteamGridDBClient.apiKey)", forHTTPHeaderField: "Authorization")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else { return [] }

        return dataArray
            .filter { $0["animated"] as? Bool != true }
            .sorted { ($0["score"] as? Int ?? 0) > ($1["score"] as? Int ?? 0) }
            .prefix(6)
            .compactMap { item -> SteamGridDBItem? in
                guard let id       = item["id"] as? Int,
                      let urlStr   = item["url"] as? String,
                      let fullURL  = URL(string: urlStr) else { return nil }
                let thumbStr = item["thumb"] as? String ?? urlStr
                guard let thumbURL = URL(string: thumbStr) else { return nil }
                let score      = item["score"] as? Int ?? 0
                let width      = item["width"] as? Int ?? 0
                let height     = item["height"] as? Int ?? 0
                let authorName = (item["author"] as? [String: Any])?["name"] as? String
                return SteamGridDBItem(sgdbID: id, type: type, url: fullURL, thumbURL: thumbURL,
                                       width: width, height: height, score: score, authorName: authorName)
            }
    }
}

