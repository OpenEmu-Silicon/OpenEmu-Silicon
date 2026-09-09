// Copyright (c) 2026, OpenEmu Team
// Author: Leonardo Kasperavičius
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
import OpenEmuBase
import CryptoKit
import os.log

// private let log = Logger(subsystem: "org.openemu.OpenEmu", category: "LibretroCheatProvider")

/// Cached cheat file stored on disk per game.
private struct LibretroCachedCheatFile: Codable {
    let sources: [LibretroCachedSource]
    let cheats: [LibretroCachedCheat]
}

private struct LibretroCachedSource: Codable {
    let chtFileName: String
    let etag: String?
}

private struct LibretroCachedCheat: Codable {
    let name: String
    let code: String
}

final class LibretroCheatProvider: CheatDatabaseProvider, @unchecked Sendable {

    let name = "Libretro"

    private static let datBaseURLNoIntro = "https://raw.githubusercontent.com/libretro/libretro-database/master/metadat/no-intro/"
    private static let datBaseURLRedump = "https://raw.githubusercontent.com/libretro/libretro-database/master/metadat/redump/"
    private static let chtBaseURL = "https://raw.githubusercontent.com/libretro/libretro-database/master/cht/"

    // Disc-based systems use redump DATs instead of no-intro
    private static let redumpSystems: Set<String> = [OESystemIdentifierPSX, OESystemIdentifierSegaCD]

    // OpenEmu system ID → Libretro directory/DAT name
    private let systemMap: [String: String] = [
        OESystemIdentifierAtari2600: "Atari - 2600",
        OESystemIdentifierSMS:       "Sega - Master System - Mark III",
        OESystemIdentifierNES:       "Nintendo - Nintendo Entertainment System",
        OESystemIdentifierFDS:       "Nintendo - Family Computer Disk System",
        OESystemIdentifierN64:       "Nintendo - Nintendo 64",
        OESystemIdentifierGenesis:   "Sega - Mega Drive - Genesis",
        OESystemIdentifierSegaCD:    "Sega - Mega-CD - Sega CD",
        OESystemIdentifierGBA:       "Nintendo - Game Boy Advance",
        OESystemIdentifierSNES:      "Nintendo - Super Nintendo Entertainment System",
        OESystemIdentifierNDS:       "Nintendo - Nintendo DS",
        OESystemIdentifierGameGear:  "Sega - Game Gear",
        OESystemIdentifierSG1000:    "Sega - SG-1000",
        OESystemIdentifierGB:        "Nintendo - Game Boy",
        OESystemIdentifierColecoVision: "Coleco - ColecoVision",
        OESystemIdentifierPSX:       "Sony - PlayStation",
        OESystemIdentifierLynx:      "Atari - Lynx",
        OESystemIdentifierNGP:       "SNK - Neo Geo Pocket",
    ]

    // Systems where a single system ID maps to multiple Libretro DAT/CHT directories
    private let systemFallbacks: [String: [String]] = [
        OESystemIdentifierGB: ["Nintendo - Game Boy", "Nintendo - Game Boy Color"],
        OESystemIdentifierNGP: ["SNK - Neo Geo Pocket", "SNK - Neo Geo Pocket Color"],
    ]

    // In-memory cache: systemIdentifier → [key → (gameName, libretroSystem)]
    // Keys are uppercased MD5 hashes and serial numbers
    private var datCache: [String: [String: (name: String, libretroSystem: String)]] = [:]
    // Guards datCache; cheats(forMD5:) runs off the caller's actor, so multiple windows can hit it at once.
    private let datCacheLock = NSLock()

    func supportsSystem(_ systemIdentifier: String) -> Bool {
        systemMap[systemIdentifier] != nil
    }

    func cheats(forMD5 md5: String, serial: String?, gameName: String?, romURL: URL?, systemIdentifier: String) async throws -> [DatabaseCheat] {
        guard let libretroSystem = systemMap[systemIdentifier] else { return [] }

        // 1. Check local cache
        if let cached = loadCachedCheats(md5: md5, systemIdentifier: systemIdentifier) {
            // log.info("Local cache hit for \(md5) (\(cached.sources.map(\.chtFileName).joined(separator: ", ")))")
            // Try to update each cached source
            var anyUpdated = false
            var allCheats: [LibretroCachedCheat] = []
            var updatedSources: [LibretroCachedSource] = []
            for source in cached.sources {
                if let updated = try await downloadCHT(chtFileName: source.chtFileName, libretroSystem: libretroSystem, systemIdentifier: systemIdentifier, existingETag: source.etag) {
                    allCheats.append(contentsOf: updated.cheats)
                    updatedSources.append(LibretroCachedSource(chtFileName: source.chtFileName, etag: updated.etag))
                    anyUpdated = true
                } else if !anyUpdated {
                    // Nothing updated yet — return the full cached set as-is
                    return cached.cheats.map { DatabaseCheat(name: Self.decodingHTMLEntities($0.name), code: $0.code, providerName: name) }
                } else {
                    // Some sources updated, this one didn't — keep cached cheats and this source's existing ETag
                    allCheats.append(contentsOf: cached.cheats)
                    updatedSources.append(source)
                }
            }
            let cheats = anyUpdated ? dedup(allCheats) : cached.cheats
            if anyUpdated {
                saveCachedCheats(LibretroCachedCheatFile(sources: updatedSources, cheats: cheats), md5: md5, systemIdentifier: systemIdentifier)
            }
            return cheats.map { DatabaseCheat(name: Self.decodingHTMLEntities($0.name), code: $0.code, providerName: name) }
        }

        // 2. No local cache — resolve game name via DAT (try MD5 first, then serial)
        // For disc systems, OpenEmu's stored MD5 hashes the .cue playlist file, not the disc data,
        // so it never matches Libretro's per-track MD5s. Recompute the data track's MD5 when possible.
        var lookupMD5 = md5
        if Self.redumpSystems.contains(systemIdentifier), let romURL,
           let recomputed = dataTrackMD5(forCueURL: romURL) {
            lookupMD5 = recomputed
        }
        // Lynx .lnx dumps prepend a 64-byte header; the no-intro DAT indexes the headerless image.
        if systemIdentifier == OESystemIdentifierLynx, let romURL,
           let recomputed = headerlessLynxMD5(forROMURL: romURL) {
            lookupMD5 = recomputed
        }

        let lookup = try await lookupGameName(md5: lookupMD5, serial: serial, systemIdentifier: systemIdentifier)

        if lookup == nil && gameName == nil {
            // log.info("No game found for MD5 \(md5) / serial \(serial ?? "nil") in system \(systemIdentifier)")
            return []
        }

        let resolvedSystem = lookup?.libretroSystem ?? libretroSystem
        // log.info("MD5 \(md5) → \(lookup?.name ?? "nil") (in \(resolvedSystem))")

        // 3. Download plain + device-suffixed + region-variant candidates, merge
        var allCheats: [LibretroCachedCheat] = []
        var sources: [LibretroCachedSource] = []

        let useRegionFallback = systemIdentifier == OESystemIdentifierPSX
        var gameNames: [String] = []
        if let name = lookup?.name {
            gameNames.append(name)
            gameNames += compoundRegionVariants(for: name)
            if useRegionFallback { gameNames += regionVariants(for: name) }
        }

        // Fallback: try the library game name if the DAT lookup didn't work or wasn't found.
        // Not restricted to redump systems — cartridge dumps (NDS trim variance, N64 byte-order
        // variance) can miss the MD5/serial DAT match too.
        if let gameName, !gameNames.contains(gameName) {
            gameNames.append(gameName)
            gameNames += compoundRegionVariants(for: gameName)
            if useRegionFallback { gameNames += regionVariants(for: gameName) }
        }

        for gameName in gameNames {
            let candidates = ["\(gameName).cht"] + Self.chtSuffixes.map { "\(gameName) (\($0)).cht" }
            for candidate in candidates {
                if let result = try await downloadCHT(chtFileName: candidate, libretroSystem: resolvedSystem, systemIdentifier: systemIdentifier, existingETag: nil) {
                    allCheats.append(contentsOf: result.cheats)
                    sources.append(LibretroCachedSource(chtFileName: candidate, etag: result.etag))
                }
            }
            if !allCheats.isEmpty { break }
        }

        guard !allCheats.isEmpty else {
            // log.info("No CHT files found for \(gameNames.joined(separator: ", "))")
            return []
        }

        let cheats = dedup(allCheats)
        saveCachedCheats(LibretroCachedCheatFile(sources: sources, cheats: cheats), md5: md5, systemIdentifier: systemIdentifier)
        return cheats.map { DatabaseCheat(name: Self.decodingHTMLEntities($0.name), code: $0.code, providerName: name) }
    }

    // MARK: - Local Cache

    private func cacheFileURL(md5: String, systemIdentifier: String) -> URL? {
        guard let base = OELibraryDatabase.default?.databaseFolderURL else { return nil }
        let dir = base
            .appendingPathComponent("CheatDatabase", isDirectory: true)
            .appendingPathComponent("libretro", isDirectory: true)
            .appendingPathComponent(systemIdentifier, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(md5.uppercased()).json")
    }

    /// Returns alternate game names with different region combinations for CHT fallback.
    private static let regionFallbacks: [String: [String]] = [
        "USA":    ["USA, Europe", "USA, Japan", "World"],
        "Europe": ["USA, Europe", "Europe, Japan", "World"],
        "Japan":  ["USA, Japan", "Europe, Japan", "World"],
    ]

    private func regionVariants(for gameName: String) -> [String] {
        for (region, alternates) in Self.regionFallbacks {
            let tag = "(\(region))"
            if gameName.hasSuffix(tag) {
                let base = String(gameName.dropLast(tag.count)).trimmingCharacters(in: .whitespaces)
                return alternates.map { "\(base) (\($0))" }
            }
        }
        return []
    }

    /// For names with a compound region tag like "(USA, Australia)", generates single-region
    /// variants ("(USA)", "(Australia)"). Libretro's .cht filenames are often pinned to an
    /// older no-intro naming convention with a single region, while the DAT (and OpenVGDB) can
    /// carry a newer compound multi-region name for the same ROM.
    private func compoundRegionVariants(for gameName: String) -> [String] {
        guard gameName.hasSuffix(")"), let openParen = gameName.lastIndex(of: "(") else { return [] }
        let inside = gameName[gameName.index(after: openParen)..<gameName.index(before: gameName.endIndex)]
        guard inside.contains(",") else { return [] }
        let base = String(gameName[..<openParen]).trimmingCharacters(in: .whitespaces)
        return inside.split(separator: ",").map { "\(base) (\($0.trimmingCharacters(in: .whitespaces)))" }
    }

    private func loadCachedCheats(md5: String, systemIdentifier: String) -> LibretroCachedCheatFile? {
        guard let url = cacheFileURL(md5: md5, systemIdentifier: systemIdentifier),
              let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(LibretroCachedCheatFile.self, from: data)
        else { return nil }
        return cached
    }

    private func saveCachedCheats(_ file: LibretroCachedCheatFile, md5: String, systemIdentifier: String) {
        guard let url = cacheFileURL(md5: md5, systemIdentifier: systemIdentifier),
              let data = try? JSONEncoder().encode(file)
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - CHT Fetch

    // Known cheat device suffixes appended to CHT filenames in the Libretro database
    private static let chtSuffixes = ["Action Replay", "Code Breaker", "Game Buster", "Game Genie", "Game Shark", "GameShark"]

    private struct CHTDownloadResult {
        let cheats: [LibretroCachedCheat]
        let etag: String?
    }

    /// Single HTTP fetch for a CHT file. Returns parsed cheats + etag on 200, nil on 304/404/error.
    private func downloadCHT(
        chtFileName: String,
        libretroSystem: String,
        systemIdentifier: String,
        existingETag: String?
    ) async throws -> CHTDownloadResult? {
        let encoded = "\(libretroSystem)/\(chtFileName)"
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? chtFileName
        guard let url = URL(string: "\(Self.chtBaseURL)\(encoded)") else { return nil }

        var request = URLRequest(url: url)
        if let etag = existingETag {
            request.setValue("\"\(etag)\"", forHTTPHeaderField: "If-None-Match")
            // log.debug("Checking for CHT update: \(chtFileName)")
        } else {
            // log.info("Downloading CHT: \(chtFileName)")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return nil }

        switch httpResponse.statusCode {
        case 304:
            // log.debug("CHT not modified: \(chtFileName)")
            return nil
        case 404:
            // log.debug("CHT not found: \(chtFileName)")
            return nil
        case 200:
            break
        default:
            // log.warning("Unexpected HTTP \(httpResponse.statusCode) for \(chtFileName)")
            return nil
        }

        let newETag = httpResponse.value(forHTTPHeaderField: "ETag")?.replacingOccurrences(of: "\"", with: "")
        let cheats = parseCHTFile(data, systemIdentifier: systemIdentifier)
        // log.info("CHT parsed: \(chtFileName) → \(cheats.count) cheats")
        return CHTDownloadResult(cheats: cheats, etag: newETag)
    }

    private func dedup(_ cheats: [LibretroCachedCheat]) -> [LibretroCachedCheat] {
        var seen: Set<String> = []
        return cheats.filter {
            let key = $0.code.lowercased()
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    // MARK: - CHT Parser

    private func parseCHTFile(_ data: Data, systemIdentifier: String) -> [LibretroCachedCheat] {
        guard let content = String(data: data, encoding: .utf8) else { return [] }

        // Group fields by cheat index: "cheat0" → ["desc": "...", "code": "...", "address": "...", ...]
        var groups: [String: [String: String]] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let eqRange = trimmed.range(of: " = ") else { continue }

            let key = String(trimmed[..<eqRange.lowerBound])
            let raw = String(trimmed[eqRange.upperBound...])
            let value = raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2
                ? String(raw.dropFirst().dropLast())
                : raw

            // Split "cheat0_desc" → prefix "cheat0", field "desc"
            guard let underIdx = key.firstIndex(of: "_") else { continue }
            let prefix = String(key[..<underIdx])
            let field = String(key[key.index(after: underIdx)...])
            groups[prefix, default: [:]][field] = value
        }

        var cheats: [LibretroCachedCheat] = []
        var seenCodes: Set<String> = []

        for index in 0..<groups.count {
            let prefix = "cheat\(index)"
            guard let fields = groups[prefix] else { continue }
            guard let desc = fields["desc"], !desc.isEmpty else { continue }

            var code = fields["code"] ?? ""

            // If code is empty, try to synthesize from address + value (Format B)
            // TODO: handle big_endian and memory_search_size for multi-byte systems
            // TODO: filter by cheat_type — only type 1 (set to value) is usable; types 2-7 need RetroArch's RAM engine
            if code.isEmpty, let addrStr = fields["address"], let valStr = fields["value"],
               let addr = UInt32(addrStr), let val = UInt32(valStr) {
                // Pad the address to the width the per-system raw ADDRESS:VALUE validator expects.
                let addressHexChars = Self.formatBAddressHexChars(for: systemIdentifier)
                code = String(format: "%0\(addressHexChars)X:%02X", addr, val)
            }

            guard !code.isEmpty else { continue }
            // Normalize separators: some CHT files use ';' instead of '+'
            var cleaned = code.replacingOccurrences(of: " ", with: "")
                              .replacingOccurrences(of: ";", with: "+")
            cleaned = normalizeCode(cleaned, systemIdentifier: systemIdentifier)
            guard !seenCodes.contains(cleaned) else { continue }
            seenCodes.insert(cleaned)
            cheats.append(LibretroCachedCheat(name: Self.decodingHTMLEntities(desc), code: cleaned))
        }

        return cheats
    }

    /// Address hex-digit width the raw ADDRESS:VALUE validator expects per system (see CheatCodeValidator).
    private static func formatBAddressHexChars(for systemIdentifier: String) -> Int {
        switch systemIdentifier {
        case OESystemIdentifierSNES, OESystemIdentifierGenesis, OESystemIdentifierSegaCD:
            return 6
        case OESystemIdentifierGBA:
            return 8
        default:
            return 4
        }
    }

    // Some CHT descriptions embed HTML entities (e.g. `&quot;`) instead of literal characters.
    private static func decodingHTMLEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }

        var result = string
        let namedEntities: [(String, String)] = [
            ("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", "\u{00A0}"),
        ]
        for (entity, replacement) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        if let regex = try? NSRegularExpression(pattern: "&#x?([0-9A-Fa-f]+);") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: result),
                      let digitsRange = Range(match.range(at: 1), in: result) else { continue }
                let digits = String(result[digitsRange])
                let isHex = result[fullRange].hasPrefix("&#x") || result[fullRange].hasPrefix("&#X")
                guard let scalarValue = UInt32(digits, radix: isHex ? 16 : 10),
                      let scalar = Unicode.Scalar(scalarValue) else { continue }
                result.replaceSubrange(fullRange, with: String(scalar))
            }
        }

        // Decode last so a literal "&amp;quot;" doesn't get double-unescaped into a quote.
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Normalizes non-standard code formats into forms the core can parse.
    private func normalizeCode(_ code: String, systemIdentifier: String) -> String {
        switch systemIdentifier {
        case OESystemIdentifierGenesis:
            return normalizeGenesisCode(code)
        case OESystemIdentifierGBA:
            return normalizeGBACode(code)
        case OESystemIdentifierNDS:
            return normalizeNDSCode(code)
        case OESystemIdentifierGameGear:
            return normalizeGameGearCode(code)
        case OESystemIdentifierPSX:
            return normalizePSXCode(code)
        default:
            return code
        }
    }

    private func normalizeGameGearCode(_ code: String) -> String {
        // Some GG Game Genie codes use '+' instead of '-' as separator (e.g., 96D+355+A22 → 96D-355-A22)
        // Detect groups of 3-hex parts joined by '+' and convert to dash-separated Game Genie
        let parts = code.split(separator: "+")
        guard parts.count >= 3 && parts.count.isMultiple(of: 3)
            && parts.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isHexDigit) })
        else { return code }
        var ggCodes: [String] = []
        var i = 0
        while i < parts.count - 2 {
            ggCodes.append("\(parts[i])-\(parts[i+1])-\(parts[i+2])")
            i += 3
        }
        return ggCodes.joined(separator: "+")
    }

    private func normalizePSXCode(_ code: String) -> String {
        // Fix common typo: letter O/o used instead of zero
        var code = code.replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "o", with: "0")
        // PSX codes in Libretro use '+' as separator within codes, not between codes.
        // Two patterns: 8hex+4hex (GameShark) and 4hex+4hex+4hex (GameBuster)
        // Both need to be concatenated into 12-hex codes, then joined by '+' as multi-code separator.
        let parts = code.split(separator: "+").map { String($0) }
        guard parts.allSatisfy({ $0.allSatisfy(\.isHexDigit) }) else { return code }

        var codes: [String] = []
        var i = 0
        while i < parts.count {
            // Try 8+4 (GameShark: XXXXXXXX+XXXX → XXXXXXXXXXXX)
            if i + 1 < parts.count && parts[i].count == 8 && parts[i + 1].count == 4 {
                codes.append("\(parts[i])\(parts[i + 1])")
                i += 2
            }
            // Try 4+4+4 (GameBuster: XXXX+XXXX+XXXX → XXXXXXXXXXXX)
            else if i + 2 < parts.count && parts[i].count == 4 && parts[i + 1].count == 4 && parts[i + 2].count == 4 {
                codes.append("\(parts[i])\(parts[i + 1])\(parts[i + 2])")
                i += 3
            }
            // Already 12 hex (standalone GameShark)
            else if parts[i].count == 12 {
                codes.append(parts[i])
                i += 1
            }
            else {
                return code
            }
        }
        return codes.joined(separator: "+")
    }

    private func normalizeNDSCode(_ code: String) -> String {
        // NDS AR codes: pairs of 8-hex parts joined by '+' need to be concatenated into 16-hex lines
        // e.g., 620D5010+00000000+B20D5010+00000000 → 620D501000000000+B20D501000000000
        let parts = code.split(separator: "+")
        guard parts.count >= 2 && parts.count.isMultiple(of: 2)
            && parts.allSatisfy({ $0.count == 8 && $0.allSatisfy(\.isHexDigit) })
        else { return code }
        var lines: [String] = []
        var i = 0
        while i < parts.count - 1 {
            lines.append("\(parts[i])\(parts[i + 1])")
            i += 2
        }
        return lines.joined(separator: "+")
    }

    private func normalizeGBACode(_ code: String) -> String {
        // Handle '+' used as address/value separator (8hex+4hex = CodeBreaker format)
        // e.g., 8201ED74+0FFF → 8201ED740FFF, 00007358+000A+100092B8+0007 → 00007358000A+100092B80007
        let parts = code.split(separator: "+")
        if parts.count >= 2 && parts.count.isMultiple(of: 2) {
            var pairs: [String] = []
            var i = 0
            while i < parts.count - 1 {
                let addr = parts[i], val = parts[i + 1]
                if addr.count == 8 && val.count == 4
                    && addr.allSatisfy(\.isHexDigit) && val.allSatisfy(\.isHexDigit) {
                    pairs.append("\(addr)\(val)")
                    i += 2
                } else {
                    return code
                }
            }
            if !pairs.isEmpty { return pairs.joined(separator: "+") }
        }
        return code
    }

    private func normalizeGenesisCode(_ code: String) -> String {
        // 10 hex chars without separator → insert colon at position 6 (e.g., FF00220010 → FF0022:0010)
        if code.count == 10 && !code.contains(":") && !code.contains("-") && code.allSatisfy(\.isHexDigit) {
            let idx = code.index(code.startIndex, offsetBy: 6)
            return "\(code[..<idx]):\(code[idx...])"
        }
        // Handle '+' used as address/value separator instead of multi-code joiner.
        // Pattern: alternating 6-hex and 4-hex parts (e.g., FF002C+1800 or FF002C+1800+FF003C+2800)
        let parts = code.split(separator: "+")
        if parts.count >= 2 && parts.count.isMultiple(of: 2) {
            var pairs: [String] = []
            var i = 0
            while i < parts.count - 1 {
                let addr = parts[i], val = parts[i + 1]
                if addr.count == 6 && val.count == 4
                    && addr.allSatisfy(\.isHexDigit) && val.allSatisfy(\.isHexDigit) {
                    pairs.append("\(addr):\(val)")
                    i += 2
                } else {
                    return code
                }
            }
            if !pairs.isEmpty { return pairs.joined(separator: "+") }
        }
        return code
    }

    // MARK: - Data Track MD5 Recomputation

    /// Describes where the disc's data track lives and how many bytes of it to hash.
    /// `length == nil` means "hash the whole referenced file" (single-track disc, or the
    /// data track already lives in its own separate file per the CUE's FILE statements).
    private struct CUEDataTrackLayout {
        let fileURL: URL
        let length: Int?
    }

    /// Parses a CUE sheet to find the data track (always the first track) and, if a second
    /// track shares the same underlying file (as with a merged chdman `extractcd` dump),
    /// the byte offset where that second track begins.
    private func parseCUEDataTrackLayout(cueURL: URL) -> CUEDataTrackLayout? {
        guard let content = try? String(contentsOf: cueURL, encoding: .utf8) else { return nil }
        let folderURL = cueURL.deletingLastPathComponent()

        struct TrackEntry { var indices: [Int: (mm: Int, ss: Int, ff: Int)] = [:] }
        struct FileSection { let fileName: String; var tracks: [TrackEntry] = [] }

        var sections: [FileSection] = []

        let filePattern = try! NSRegularExpression(pattern: #"^FILE\s+"([^"]+)""#)
        let trackPattern = try! NSRegularExpression(pattern: #"^TRACK\s+\d+"#)
        let indexPattern = try! NSRegularExpression(pattern: #"^INDEX\s+(\d+)\s+(\d+):(\d+):(\d+)"#)

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let fullRange = NSRange(line.startIndex..., in: line)

            if let match = filePattern.firstMatch(in: line, range: fullRange),
               let nameRange = Range(match.range(at: 1), in: line) {
                sections.append(FileSection(fileName: String(line[nameRange])))
            } else if trackPattern.firstMatch(in: line, range: fullRange) != nil {
                guard !sections.isEmpty else { continue }
                sections[sections.count - 1].tracks.append(TrackEntry())
            } else if let match = indexPattern.firstMatch(in: line, range: fullRange),
                      let idxRange = Range(match.range(at: 1), in: line),
                      let mmRange = Range(match.range(at: 2), in: line),
                      let ssRange = Range(match.range(at: 3), in: line),
                      let ffRange = Range(match.range(at: 4), in: line),
                      let idx = Int(line[idxRange]), let mm = Int(line[mmRange]),
                      let ss = Int(line[ssRange]), let ff = Int(line[ffRange]) {
                guard !sections.isEmpty, !sections[sections.count - 1].tracks.isEmpty else { continue }
                sections[sections.count - 1].tracks[sections[sections.count - 1].tracks.count - 1].indices[idx] = (mm, ss, ff)
            }
        }

        guard let firstSection = sections.first, !firstSection.tracks.isEmpty else { return nil }
        let dataTrackURL = folderURL.appendingPathComponent(firstSection.fileName)

        // A second track in the SAME file section marks where the data track ends (merged dump)
        if firstSection.tracks.count > 1 {
            let secondTrack = firstSection.tracks[1]
            if let msf = secondTrack.indices[0] ?? secondTrack.indices[1] {
                let sectors = (msf.mm * 60 + msf.ss) * 75 + msf.ff
                return CUEDataTrackLayout(fileURL: dataTrackURL, length: sectors * 2352)
            }
        }

        // Single track, or the next track lives in its own separate file — hash the whole file
        return CUEDataTrackLayout(fileURL: dataTrackURL, length: nil)
    }

    /// Recomputes the MD5 of just the disc's data track, matching how Libretro/Redump hash CD images.
    /// OpenEmu's stored MD5 for CUE-based imports hashes the playlist text file, not disc content,
    /// so it can never match the DAT — this recomputes it directly from the referenced binary.
    private func dataTrackMD5(forCueURL cueURL: URL) -> String? {
        guard cueURL.pathExtension.lowercased() == "cue" else { return nil }
        guard let layout = parseCUEDataTrackLayout(cueURL: cueURL) else { return nil }

        guard let file = try? FileHandle(forReadingFrom: layout.fileURL) else { return nil }
        defer { try? file.close() }

        var md5 = Insecure.MD5()
        let bufferSize = 1024 * 1024
        var remaining = layout.length

        while true {
            let toRead = remaining.map { min($0, bufferSize) } ?? bufferSize
            guard toRead > 0, let data = try? file.read(upToCount: toRead), !data.isEmpty else { break }
            md5.update(data: data)
            if let r = remaining {
                remaining = r - data.count
                if remaining! <= 0 { break }
            }
        }

        return md5.finalize().map { String(format: "%02X", $0) }.joined()
    }

    /// Atari Lynx `.lnx` dumps prepend a 64-byte header ("LYNX" magic); the no-intro DAT
    /// indexes the headerless image, so recompute the MD5 over the data past the header.
    /// Returns nil when the file has no header (its MD5 already matches the DAT).
    private func headerlessLynxMD5(forROMURL romURL: URL) -> String? {
        guard let file = try? FileHandle(forReadingFrom: romURL) else { return nil }
        defer { try? file.close() }

        guard let magic = try? file.read(upToCount: 4), magic == Data("LYNX".utf8) else { return nil }
        do { try file.seek(toOffset: 64) } catch { return nil }

        var md5 = Insecure.MD5()
        let bufferSize = 1024 * 1024
        while let data = try? file.read(upToCount: bufferSize), !data.isEmpty {
            md5.update(data: data)
        }

        return md5.finalize().map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - DAT Lookup

    /// Generates progressively shorter serial variants for fuzzy matching against DAT entries.
    /// e.g. "MK-4407 -00" → ["MK-4407 -00", "MK-4407-00", "MK-4407", "4407"]
    private func serialLookupKeys(_ serial: String) -> [String] {
        let raw = serial.trimmingCharacters(in: .whitespaces).uppercased()
        var keys: [String] = [raw]

        let collapsed = raw.replacingOccurrences(of: " ", with: "")
        if collapsed != raw { keys.append(collapsed) }

        // Strip revision suffix: "-XX" at end where XX is digits
        for base in [raw, collapsed] {
            if let range = base.range(of: #"-\d+$"#, options: .regularExpression) {
                let stripped = String(base[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !stripped.isEmpty && !keys.contains(stripped) {
                    keys.append(stripped)
                }
            }
        }

        // Strip manufacturer prefix (e.g. "MK-") if remainder starts with a digit
        for key in Array(keys) {
            if let idx = key.firstIndex(of: "-") {
                let rest = String(key[key.index(after: idx)...])
                if let first = rest.first, first.isNumber, !keys.contains(rest) {
                    keys.append(rest)
                }
            }
        }

        return keys
    }

    private func lookupBySerial(_ serial: String, in cache: [String: (name: String, libretroSystem: String)]) -> (name: String, libretroSystem: String)? {
        for key in serialLookupKeys(serial) {
            if let result = cache[key] { return result }
        }
        return nil
    }

    private func lookupGameName(md5: String, serial: String?, systemIdentifier: String) async throws -> (name: String, libretroSystem: String)? {
        datCacheLock.lock()
        let cachedSnapshot = datCache[systemIdentifier]
        datCacheLock.unlock()
        if let cached = cachedSnapshot {
            // log.debug("DAT cache hit for \(systemIdentifier)")
            if let result = cached[md5.uppercased()] { return result }
            if let serial, let result = lookupBySerial(serial, in: cached) { return result }
            return nil
        }

        guard let libretroSystem = systemMap[systemIdentifier] else { return nil }

        let datSystems = systemFallbacks[systemIdentifier] ?? [libretroSystem]
        var merged: [String: (name: String, libretroSystem: String)] = [:]
        for datSystem in datSystems {
            // log.info("Downloading DAT for \(datSystem)…")
            let encoded = datSystem.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? datSystem
            let datBaseURL = Self.redumpSystems.contains(systemIdentifier) ? Self.datBaseURLRedump : Self.datBaseURLNoIntro
            guard let url = URL(string: "\(datBaseURL)\(encoded).dat") else { continue }
            let (data, _) = try await URLSession.shared.data(from: url)
            let parsed = parseDATFile(data)
            // log.info("DAT loaded for \(datSystem): \(parsed.count) entries indexed")
            for entry in parsed {
                let value = (name: entry.name, libretroSystem: datSystem)
                if let md5 = entry.md5, merged[md5] == nil {
                    merged[md5] = value
                }
                if let serial = entry.serial, merged[serial] == nil {
                    merged[serial] = value
                }
            }
        }
        datCacheLock.lock()
        datCache[systemIdentifier] = merged
        datCacheLock.unlock()
        if let result = merged[md5.uppercased()] { return result }
        if let serial, let result = lookupBySerial(serial, in: merged) { return result }
        return nil
    }

    // MARK: - DAT Parser (clrmamepro format)

    private struct DATEntry {
        let name: String
        let md5: String?
        let serial: String?
    }

    private func parseDATFile(_ data: Data) -> [DATEntry] {
        guard let content = String(data: data, encoding: .utf8) else { return [] }
        var results: [DATEntry] = []
        var currentName: String?
        var currentSerial: String?

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("name \"") {
                let start = trimmed.index(trimmed.startIndex, offsetBy: 6)
                if let end = trimmed.lastIndex(of: "\""), end > start {
                    currentName = String(trimmed[start..<end])
                    currentSerial = nil
                }
            } else if trimmed.hasPrefix("serial \""), let name = currentName {
                let start = trimmed.index(trimmed.startIndex, offsetBy: 8)
                if let end = trimmed.lastIndex(of: "\""), end > start {
                    currentSerial = String(trimmed[start..<end])
                }
            } else if trimmed.contains("md5 "), let name = currentName {
                if let md5Range = trimmed.range(of: "md5 ") {
                    let afterMD5 = trimmed[md5Range.upperBound...]
                    let md5Value = String(afterMD5.prefix(while: { !$0.isWhitespace }))
                    if md5Value.count == 32 {
                        results.append(DATEntry(name: name, md5: md5Value.uppercased(), serial: currentSerial?.uppercased()))
                    }
                }
            }
        }
        return results
    }
}
