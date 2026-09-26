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
import os.log

// private let log = Logger(subsystem: "org.openemu.OpenEmu", category: "PugsyCheatProvider")

/// Provides MAME/arcade cheats from Pugsy's cheat archive (mamecheat.co.uk).
///
/// The archive is NOT bundled or auto-downloaded — Pugsy's terms allow personal use only, not
/// redistribution/bundling. The user downloads `cheat.7z` themselves and imports it into OpenEmu
/// (BIOS-style drag/drop). The importer decompresses it into a fixed, host-owned location under the
/// library's `CheatDatabase/` folder — a sibling of the Libretro cache:
///
///     <library>/CheatDatabase/pugsy/cheats/<romset>.xml
///
/// Arcade games are identified by **romset name** (the ROM zip's filename without extension,
/// e.g. `sf2`), NOT by MD5 — MAME's whole identity model is romset-based. So matching keys off
/// `romURL` / `gameName`, not the `md5` argument.
final class PugsyCheatProvider: CheatDatabaseProvider, @unchecked Sendable {

    static let providerName = "Pugsy's"
    var name: String { Self.providerName }

    /// The one system this provider covers. No `OESystemIdentifierArcade` constant exists in the
    /// SDK, so the raw identifier string is used (matching the rest of the codebase).
    private static let arcadeSystemIdentifier = "openemu.system.arcade"

    /// Pugsy's cheats are MAME-address-based, so they only apply to the MAME core — not other arcade
    /// cores (e.g. a future FinalBurn), whose memory maps differ. This is the MAME core's bundle id.
    static let mameCoreIdentifier = "org.openemu.MAME"

    func supportsSystem(_ systemIdentifier: String) -> Bool {
        systemIdentifier == Self.arcadeSystemIdentifier
    }

    func cheats(forMD5 md5: String, serial: String?, gameName: String?, romURL: URL?, systemIdentifier: String, coreIdentifier: String) async throws -> [DatabaseCheat] {
        guard systemIdentifier == Self.arcadeSystemIdentifier, coreIdentifier == Self.mameCoreIdentifier else { return [] }

        // The arcade romset name is the ROM's filename without extension (e.g. ".../sf2.zip" → "sf2").
        // Fall back to gameName only if a romURL wasn't provided.
        guard let romset = romURL?.deletingPathExtension().lastPathComponent ?? gameName, !romset.isEmpty else {
            return []
        }

        guard let cheatFileURL = cheatFileURL(forRomset: romset),
              let data = try? Data(contentsOf: cheatFileURL) else {
            return []
        }

        return PugsyCheatParser.parse(data: data, providerName: Self.providerName)
    }

    /// Locates the decompressed Pugsy cheat file for a romset. Arcade cheats are stored flat as
    /// `cheats/<romset>.xml` (matching MAME's `machine().basename()` load path); the software-list
    /// subfolders in the archive are not consulted here.
    /// - Returns: the file URL if it exists, otherwise `nil`.
    func cheatFileURL(forRomset romset: String) -> URL? {
        guard let folder = PugsyCheatFile.decompressedFolderURL else { return nil }
        let fileURL = folder.appendingPathComponent("\(romset).xml", isDirectory: false)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }
}

// MARK: - MAME cheat XML parsing

/// Parses a MAME/Pugsy `<romset>.xml` into the subset of cheats OpenEmu's MAME core can apply:
/// constant pokes to `maincpu` program memory (`.pb`/`.pw`/`.pd`) from a `state="run"` script.
///
/// Everything else is dropped on purpose: ROM changes (`.rb`/`.rw`/`.rd`/`.rq`), 8-byte pokes
/// (`.pq`, unsupported by the core), non-`maincpu` regions (the core only pokes maincpu's program
/// space), conditional actions, parameterized cheats, and expression/bitwise values (`param`, `|`,
/// `BAND`, `~`, …). A cheat is emitted only when *every* one of its run-script actions is a plain
/// constant poke — a partially-applied cheat would be wrong.
private enum PugsyCheatParser {

    static func parse(data: Data, providerName: String) -> [DatabaseCheat] {
        let delegate = Delegate(providerName: providerName)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.cheats
    }

    /// `.pb`/`.pw`/`.pd` → the value's hex width. `.pq` is absent on purpose (8-byte pokes are not
    /// supported by the core).
    private static let accessWidths: [String: Int] = ["pb": 2, "pw": 4, "pd": 8]

    /// Converts one MAME action expression (e.g. `maincpu.pb@106E93=3C`) into OpenEmu's
    /// `ADDRESS:VALUE` code, or `nil` if it isn't a constant `maincpu` program poke the core can
    /// apply. The value is left-padded to the access width so the core infers the right poke size
    /// from the value's hex length (e.g. a `.pw` value `1` becomes `0001` → 2-byte write).
    static func convertAction(_ expression: String) -> String? {
        guard expression.hasPrefix("maincpu.") else { return nil }
        let afterRegion = expression.dropFirst("maincpu.".count)
        guard afterRegion.count > 3 else { return nil }
        let access = String(afterRegion.prefix(2))
        guard let width = accessWidths[access] else { return nil }
        var rest = afterRegion.dropFirst(2)
        guard rest.first == "@" else { return nil }
        rest = rest.dropFirst()
        guard let equals = rest.firstIndex(of: "=") else { return nil }
        let address = rest[rest.startIndex..<equals]
        let value = rest[rest.index(after: equals)...]
        guard !address.isEmpty, address.allSatisfy(\.isHexDigit),
              !value.isEmpty, value.allSatisfy(\.isHexDigit) else { return nil }
        let padded = String(repeating: "0", count: max(0, width - value.count)) + value.uppercased()
        return "\(address.uppercased()):\(padded)"
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let providerName: String
        var cheats: [DatabaseCheat] = []

        // Current <cheat> being assembled.
        private var desc: String?
        private var scriptState: String?
        private var sawRunScript = false
        private var cheatUnsupported = false
        private var runCodes: [String] = []
        private var runRaw: [String] = []

        // Current <action> being read.
        private var inAction = false
        private var actionHasCondition = false
        private var actionText = ""

        init(providerName: String) {
            self.providerName = providerName
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            switch elementName {
            case "cheat":
                desc = attributeDict["desc"]
                scriptState = nil
                sawRunScript = false
                cheatUnsupported = false
                runCodes = []
                runRaw = []
            case "parameter":
                // Parameterized cheats resolve their value at runtime (`param`); can't apply them.
                cheatUnsupported = true
            case "script":
                scriptState = attributeDict["state"]
                if scriptState == "run" { sawRunScript = true }
            case "action":
                inAction = true
                actionHasCondition = attributeDict["condition"] != nil
                actionText = ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inAction { actionText += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            switch elementName {
            case "action":
                // Only the persistent `run` script maps to the core's per-frame poke model.
                if scriptState == "run" {
                    let expr = actionText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if actionHasCondition {
                        cheatUnsupported = true
                    } else if let code = PugsyCheatParser.convertAction(expr) {
                        runCodes.append(code)
                        runRaw.append(expr)
                    } else {
                        cheatUnsupported = true
                    }
                }
                inAction = false
                actionHasCondition = false
                actionText = ""
            case "script":
                scriptState = nil
            case "cheat":
                let name = desc?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !name.isEmpty, sawRunScript, !cheatUnsupported, !runCodes.isEmpty {
                    cheats.append(DatabaseCheat(name: name,
                                                code: runCodes.joined(separator: "+"),
                                                providerName: providerName,
                                                rawCode: runRaw.joined(separator: "\n")))
                }
                desc = nil
            default:
                break
            }
        }
    }
}

