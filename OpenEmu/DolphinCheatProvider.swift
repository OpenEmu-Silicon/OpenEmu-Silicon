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
import OpenEmuKit

/// Provides GameCube and Wii cheats from the Dolphin GameSettings database that ships *inside* the
/// Dolphin core plugin (`Contents/Resources/Sys/GameSettings/<GAMEID>.ini`). No network fetch is
/// needed — the ~1800 `.ini` files are bundled with the core.
///
/// Only the two sections that carry real gameplay cheats are read:
///   - `[ActionReplay]` — kept verbatim (Dolphin's AR engine applies every AR type we need).
///   - `[OnFrame]` — memory patches (`ADDR:type:VALUE`), converted to equivalent AR write codes.
/// `[Gecko]` (mostly widescreen/netplay hacks, often MEM2/ASM we can't apply) and the
/// `_RetroAchievements_Verified` name-only lists are skipped.
final class DolphinCheatProvider: CheatDatabaseProvider, @unchecked Sendable {

    static let providerName = "Dolphin"
    var name: String { Self.providerName }

    func supportsSystem(_ systemIdentifier: String) -> Bool {
        systemIdentifier == OESystemIdentifierGameCube || systemIdentifier == OESystemIdentifierWii
    }

    func cheats(forMD5 md5: String, serial: String?, gameName: String?, romURL: URL?, systemIdentifier: String, coreIdentifier: String) async throws -> [DatabaseCheat] {
        guard supportsSystem(systemIdentifier),
              let serial, let gameID = Self.baseGameID(from: serial),
              let directory = Self.gameSettingsDirectory(coreIdentifier: coreIdentifier)
        else { return [] }

        // Dolphin merges the full 6-char ini with a 3-char game-code fallback; read both, 6-char wins.
        var cheats: [DatabaseCheat] = []
        var seen: Set<String> = []
        for id in [gameID, String(gameID.prefix(3))] {
            let url = directory.appendingPathComponent("\(id).ini", isDirectory: false)
            // Codes are ASCII; fall back to Latin-1 (which maps every byte) if a file isn't valid UTF-8.
            guard let text = (try? String(contentsOf: url, encoding: .utf8))
                    ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            else { continue }
            for cheat in Self.parse(ini: text) {
                let key = cheat.code.replacingOccurrences(of: " ", with: "").lowercased()
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                cheats.append(cheat)
            }
        }
        return cheats
    }

    // MARK: - Game identification

    /// The disc ID without the `-DISC`/`-REV` suffix `serialLookup` appends. GameSettings filenames
    /// are the bare game ID: 6 characters for discs, 4 for WiiWare titles.
    private static func baseGameID(from serial: String) -> String? {
        let base = (serial.split(separator: "-").first.map(String.init) ?? serial).uppercased()
        guard (3...6).contains(base.count), base.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return base
    }

    private static func gameSettingsDirectory(coreIdentifier: String) -> URL? {
        guard let resources = OECorePlugin.corePlugin(bundleIdentifier: coreIdentifier)?.bundle.resourceURL
        else { return nil }
        return resources.appendingPathComponent("Sys/GameSettings", isDirectory: true)
    }

    // MARK: - INI parsing

    private static func parse(ini: String) -> [DatabaseCheat] {
        var result: [DatabaseCheat] = []
        var section = ""
        var name: String?
        var lines: [String] = []

        func flush() {
            defer { name = nil; lines = [] }
            guard let name, !lines.isEmpty else { return }
            switch section {
            case "ActionReplay":
                if let cheat = makeActionReplayCheat(name: name, lines: lines) { result.append(cheat) }
            case "OnFrame":
                if let cheat = makeMemPatchCheat(name: name, lines: lines) { result.append(cheat) }
            default:
                break
            }
        }

        for raw in ini.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") || line.hasPrefix("*") {
                continue
            }
            if line.hasPrefix("[") {
                flush()
                section = String(line.dropFirst().prefix(while: { $0 != "]" }))
            } else if line.hasPrefix("$") {
                flush()
                name = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if name != nil {
                lines.append(line)
            }
        }
        flush()
        return result
    }

    /// `[ActionReplay]` codes are kept verbatim (code == rawCode). Dolphin's AR engine handles every
    /// AR type — writes, conditionals, master codes, encrypted lines — and the validator accepts them.
    private static func makeActionReplayCheat(name: String, lines: [String]) -> DatabaseCheat? {
        let rawCode = lines.joined(separator: "\n")
        guard !rawCode.isEmpty else { return nil }
        return DatabaseCheat(name: name, code: rawCode, providerName: providerName, rawCode: rawCode)
    }

    /// `[OnFrame]` memory patches (`0xADDR:byte|word|dword:0xVALUE`) become equivalent Action Replay
    /// write codes, but the original patch text is preserved as `rawCode` for feedback correlation.
    /// A conditional patch (4 colon-separated fields) can't be expressed as a plain write, so a cheat
    /// containing any such line is dropped.
    private static func makeMemPatchCheat(name: String, lines: [String]) -> DatabaseCheat? {
        var arLines: [String] = []
        for line in lines {
            let fields = line.components(separatedBy: ":")
            guard fields.count == 3,
                  let ar = convertMemPatchLineToAR(address: fields[0], type: fields[1], value: fields[2])
            else { return nil }
            arLines.append(ar)
        }
        guard !arLines.isEmpty else { return nil }
        return DatabaseCheat(name: name,
                             code: arLines.joined(separator: "\n"),
                             providerName: providerName,
                             rawCode: lines.joined(separator: "\n"))
    }

    /// Converts one `ADDR:type:VALUE` patch into an Action Replay write word pair. The AR first word
    /// is `(size << 25) | (address & 0x01FFFFFF)` (base 0x80000000 implied); the value is written
    /// as-is — big-endian, matching how both the patch and an AR write store it.
    private static func convertMemPatchLineToAR(address: String, type: String, value: String) -> String? {
        func hex(_ s: String) -> UInt32? {
            UInt32(s.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16)
        }
        guard let address = hex(address), let value = hex(value) else { return nil }

        let size: UInt32
        switch type.trimmingCharacters(in: .whitespaces).lowercased() {
        case "byte":  size = 0
        case "word":  size = 1
        case "dword": size = 2
        default: return nil
        }
        let word = (size << 25) | (address & 0x01FF_FFFF)
        return String(format: "%08X %08X", word, value)
    }
}
