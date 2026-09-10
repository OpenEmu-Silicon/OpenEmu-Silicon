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
import os.log

// private let log = Logger(subsystem: "org.openemu.OpenEmu", category: "OpenEmuCheatProvider")

/// Provides cheats from the bundled cheats-database.xml file.
final class OpenEmuCheatProvider: CheatDatabaseProvider, @unchecked Sendable {

    let name = "OpenEmu"

    func supportsSystem(_ systemIdentifier: String) -> Bool {
        loadIfNeeded()
        return database.keys.contains(systemIdentifier)
    }

    func cheats(forMD5 md5: String, serial: String?, gameName: String?, romURL: URL?, systemIdentifier: String) async throws -> [DatabaseCheat] {
        loadIfNeeded()
        return database[systemIdentifier]?[md5.lowercased()] ?? []
    }

    /// Synchronous lookup for feedback-file migration — the bundled database needs no network fetch.
    func migrationLookup(forMD5 md5: String, systemIdentifier: String) -> (gameName: String?, cheats: [DatabaseCheat])? {
        loadIfNeeded()
        guard let cheats = database[systemIdentifier]?[md5.lowercased()], !cheats.isEmpty else { return nil }
        return (gameNames[systemIdentifier]?[md5.lowercased()], cheats)
    }

    // MARK: - XML Parsing

    // systemIdentifier → [lowercased MD5 → [DatabaseCheat]]
    private var database: [String: [String: [DatabaseCheat]]] = [:]
    // systemIdentifier → [lowercased MD5 → game title], for feedback-file migration only.
    private var gameNames: [String: [String: String]] = [:]
    private var loaded = false
    // supportsSystem (main thread) and cheats (off-actor) both trigger the lazy load; serialize it.
    private let loadLock = NSLock()

    private func loadIfNeeded() {
        loadLock.lock()
        defer { loadLock.unlock() }
        guard !loaded else { return }
        loaded = true

        guard let url = Bundle.main.url(forResource: "cheats-database", withExtension: "xml"),
              let data = try? Data(contentsOf: url)
        else {
            // log.warning("cheats-database.xml not found in app bundle")
            return
        }

        let parser = XMLParser(data: data)
        let delegate = CheatXMLParserDelegate(providerName: name)
        parser.delegate = delegate
        parser.parse()
        database = delegate.result
        gameNames = delegate.gameNames
        // let totalCheats = database.values.flatMap(\.values).flatMap({ $0 }).count
        // log.info("Loaded bundled cheat database: \(totalCheats) cheats")
    }
}

private class CheatXMLParserDelegate: NSObject, XMLParserDelegate {
    let providerName: String
    // systemIdentifier → [lowercased MD5 → [DatabaseCheat]]
    var result: [String: [String: [DatabaseCheat]]] = [:]
    // systemIdentifier → [lowercased MD5 → game title]
    var gameNames: [String: [String: String]] = [:]

    private var currentSystem: String?
    private var currentMD5s: [String] = []
    private var currentCheats: [DatabaseCheat] = []
    private var currentGameName: String?

    init(providerName: String) {
        self.providerName = providerName
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "system":
            currentSystem = attributeDict["id"]
        case "game":
            currentMD5s = []
            currentCheats = []
            currentGameName = attributeDict["title"]
        case "hash":
            if let md5 = attributeDict["md5"] {
                currentMD5s.append(md5.lowercased())
            }
        case "cheat":
            if let code = attributeDict["code"], let desc = attributeDict["description"], !code.isEmpty {
                // This provider does no normalization, so the stored code is already the raw source text.
                currentCheats.append(DatabaseCheat(name: desc, code: code, providerName: providerName, rawCode: code))
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "game", let system = currentSystem, !currentCheats.isEmpty else { return }
        for md5 in currentMD5s {
            result[system, default: [:]][md5] = currentCheats
            if let currentGameName {
                gameNames[system, default: [:]][md5] = currentGameName
            }
        }
    }
}
