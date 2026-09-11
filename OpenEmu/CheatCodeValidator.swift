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

/// Validates cheat codes against the formats a given core can handle.
/// TODO: move to a protocol on each core once cores declare supported formats via Info.plist
enum CheatCodeValidator {

    /// Returns true if the code (possibly multi-part with '+') is valid for the given core and system.
    static func isValid(code: String, systemIdentifier: String, coreIdentifier: String) -> Bool {
        let normalized = code.replacingOccurrences(of: " ", with: "")
        // NDS: each '+'-separated part must be a 16-hex AR line (already normalized by provider)
        if systemIdentifier == OESystemIdentifierNDS {
            return normalized.components(separatedBy: "+")
                .allSatisfy { isNDSActionReplayCode($0) }
        }
        return normalized.components(separatedBy: "+")
            .allSatisfy { isValidSingle($0, systemIdentifier: systemIdentifier, coreIdentifier: coreIdentifier) }
    }

    private static func isValidSingle(_ code: String, systemIdentifier: String, coreIdentifier: String) -> Bool {
        switch systemIdentifier {
        case OESystemIdentifierAtari2600, OESystemIdentifierColecoVision:
            // Stella: scanHexInt is flexible on length, cast to uInt16/uInt8
            return isRawAddressValue(code, maxAddressHexChars: 4, maxValueHexChars: 2)

        case OESystemIdentifierNES, OESystemIdentifierFDS:
            // FCEU: raw XXXX:XX, XXXX?XX:XX, NES Game Genie — no Pro Action Rocky
            if coreIdentifier == "org.openemu.FCEU" {
                return isRawAddressValue(code, addressHexChars: 4, valueHexChars: 2)
                    || isRawAddressValueWithCompare(code)
                    || isNESGameGenieCode(code)
            }
            // Nestopia (default): also supports Pro Action Rocky
            return isRawAddressValue(code, addressHexChars: 4, valueHexChars: 2)
                || isRawAddressValueWithCompare(code)
                || isNESGameGenieCode(code)
                || isNESProActionRockyCode(code)

        case OESystemIdentifierN64:
            // Mupen64Plus: 12 hex char GameShark only (8 address + 4 value)
            return isN64GameSharkCode(code)

        case OESystemIdentifierPSX:
            // Mednafen: 12 hex (PSX GameShark) or raw address:value
            return isPSXGameSharkCode(code) || isRawAddressValue(code)

        case OESystemIdentifierSaturn:
            // Mednafen (ss module): 12 hex, type nibble 1 (word) or 3 (byte) only
            return isSaturnActionReplayCode(code)

        case OESystemIdentifierGBA:
            // mGBA: 12 hex (CodeBreaker), 16 hex (GameShark/PAR v3), or VBA (address:value)
            return isGBACode(code)

        case OESystemIdentifierGB:
            // Gambatte: GB GameShark (8 hex, e.g. 01FF4AD8) or GB Game Genie (XXX-XXX-XXX)
            return isGBGameSharkCode(code) || isSMSGameGenieCode(code)

        case OESystemIdentifierSNES:
            // SNES9x/BSNES: Game Genie (XXXX-XXXX), PAR (8 hex), or raw (6hex:2hex)
            return isSNESGameGenieCode(code) || isSNESPARCode(code) || isRawAddressValue(code, addressHexChars: 6, valueHexChars: 2)

        case OESystemIdentifierGenesis, OESystemIdentifierSegaCD:
            // GenesisPlus MD mode: Game Genie (XXXX-XXXX) or Patch/PAR (XXXXXX:XXXX)
            return isGenesisGameGenieCode(code) || isGenesisPARCode(code)

        case OESystemIdentifierSMS:
            if coreIdentifier == "org.openemu.CrabEmu" {
                return isSMSActionReplayCode(code) || isRawAddressValue(code)
            }
            // Genesis Plus (default): also supports SMS Game Genie (XX-XXX or XXX-XXX-XXX)
            return isSMSGameGenieCode(code) || isSMSActionReplayCode(code) || isRawAddressValue(code)

        case OESystemIdentifierGameGear, OESystemIdentifierSG1000:
            return isSMSGameGenieCode(code) || isSMSActionReplayCode(code) || isRawAddressValue(code)

        case OESystemIdentifierPCE:
            // Mednafen (pce module): paged (F8-FB) or linear (1F0000-1F7FFF) physical address, 1-byte value
            return isPCECode(code)

        case OESystemIdentifierVB:
            // Mednafen (vb module): no named format, only raw WRAM address:value (8 hex address + 2 hex value)
            return isRawAddressValue(code, addressHexChars: 8, valueHexChars: 2)

        default:
            return true
        }
    }

    // MARK: - Format Checks

    /// Raw address:value hex format. Accepts optional exact or max size constraints.
    static func isRawAddressValue(
        _ code: String,
        addressHexChars: Int? = nil,
        valueHexChars: Int? = nil,
        maxAddressHexChars: Int? = nil,
        maxValueHexChars: Int? = nil
    ) -> Bool {
        guard code.contains(":"), !code.contains("?") else { return false }
        let parts = code.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isHexDigit) }) else { return false }
        if let exact = addressHexChars, parts[0].count != exact { return false }
        if let exact = valueHexChars, parts[1].count != exact { return false }
        if let max = maxAddressHexChars, parts[0].count > max { return false }
        if let max = maxValueHexChars, parts[1].count > max { return false }
        return true
    }

    /// Raw address with compare: XXXX?XX:XX (exactly 10 chars)
    static func isRawAddressValueWithCompare(_ code: String) -> Bool {
        guard code.count == 10,
              code[code.index(code.startIndex, offsetBy: 4)] == "?",
              code[code.index(code.startIndex, offsetBy: 7)] == ":"
        else { return false }
        let addr = code.prefix(4)
        let comp = code[code.index(code.startIndex, offsetBy: 5)..<code.index(code.startIndex, offsetBy: 7)]
        let val = code.suffix(2)
        return addr.allSatisfy(\.isHexDigit) && comp.allSatisfy(\.isHexDigit) && val.allSatisfy(\.isHexDigit)
    }

    /// NES Pro Action Rocky: exactly 8 hex characters, scrambled encoding (Nestopia only)
    static func isNESProActionRockyCode(_ code: String) -> Bool {
        return code.count == 8 && code.allSatisfy(\.isHexDigit)
    }

    /// SMS/GG Game Genie: XX-XXX (short) or XXX-XXX-XXX (long), hex chars with dashes
    static func isSMSGameGenieCode(_ code: String) -> Bool {
        guard code.contains("-") else { return false }
        let parts = code.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isHexDigit) }
    }

    /// GB GameShark: exactly 8 hex characters (e.g., 01FF4AD8)
    static func isGBGameSharkCode(_ code: String) -> Bool {
        return code.count == 8 && code.allSatisfy(\.isHexDigit)
    }

    private static let nesGameGenieChars = Set("AEPOZXLUGKISTVYN")

    /// NES Game Genie: 6 or 8 letters from AEPOZXLUGKISTVYN
    static func isNESGameGenieCode(_ code: String) -> Bool {
        let upper = code.uppercased()
        return (upper.count == 6 || upper.count == 8)
            && upper.allSatisfy { nesGameGenieChars.contains($0) }
    }

    /// N64 GameShark: exactly 12 hex characters (8 address + 4 value, e.g. "8033B21D0064")
    static func isN64GameSharkCode(_ code: String) -> Bool {
        return code.count == 12 && code.allSatisfy(\.isHexDigit)
    }

    /// PSX GameShark: exactly 12 hex characters (type byte + 24-bit address + 16-bit value)
    static func isPSXGameSharkCode(_ code: String) -> Bool {
        return code.count == 12 && code.allSatisfy(\.isHexDigit)
    }

    /// Saturn GameShark/Action Replay: 12 hex characters, type nibble 1 (word write) or 3 (byte
    /// write) only — the only two operations Mednafen's `ss` cheat branch actually applies.
    static func isSaturnActionReplayCode(_ code: String) -> Bool {
        guard code.count == 12, code.allSatisfy(\.isHexDigit), let typeNibble = code.first else { return false }
        return typeNibble == "1" || typeNibble == "3"
    }

    /// GBA code: 12 hex (CodeBreaker), 16 hex (GameShark/PAR v3), or VBA (8hex:value)
    static func isGBACode(_ code: String) -> Bool {
        if code.contains(":") {
            // VBA format: 8-hex address : hex value
            let parts = code.split(separator: ":")
            return parts.count == 2 && parts[0].count == 8 && parts[0].allSatisfy(\.isHexDigit)
                && parts[1].allSatisfy(\.isHexDigit)
        }
        // CodeBreaker (12 hex) or GameShark/PAR v3 (16 hex)
        return (code.count == 12 || code.count == 16) && code.allSatisfy(\.isHexDigit)
    }

    /// SNES Game Genie: XXXX-XXXX (9 chars, dash at pos 4, hex digits)
    static func isSNESGameGenieCode(_ code: String) -> Bool {
        guard code.count == 9, code[code.index(code.startIndex, offsetBy: 4)] == "-" else { return false }
        let stripped = code.replacingOccurrences(of: "-", with: "")
        return stripped.count == 8 && stripped.allSatisfy(\.isHexDigit)
    }

    /// SNES Pro Action Replay: exactly 8 hex characters
    static func isSNESPARCode(_ code: String) -> Bool {
        return code.count == 8 && code.allSatisfy(\.isHexDigit)
    }

    /// NDS Action Replay: 16 hex chars per line (8 address + 8 value). DeSmuME strips non-hex internally.
    static func isNDSActionReplayCode(_ code: String) -> Bool {
        let hex = code.filter(\.isHexDigit)
        return !hex.isEmpty && hex.count.isMultiple(of: 16)
    }

    private static let genesisGameGenieChars = Set("ABCDEFGHJKLMNPRSTVWXYZ0123456789")

    /// Genesis Game Genie: XXXX-XXXX (9 chars with dash at pos 4, from alphabet without I/O/Q/U)
    static func isGenesisGameGenieCode(_ code: String) -> Bool {
        guard code.count == 9, code[code.index(code.startIndex, offsetBy: 4)] == "-" else { return false }
        let stripped = code.replacingOccurrences(of: "-", with: "").uppercased()
        return stripped.count == 8 && stripped.allSatisfy { genesisGameGenieChars.contains($0) }
    }

    /// Genesis Patch/PAR: XXXXXX:XXXX (6 hex address + colon + up to 4 hex value)
    static func isGenesisPARCode(_ code: String) -> Bool {
        guard code.contains(":") else { return false }
        let parts = code.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts[0].count == 6 && parts[0].allSatisfy(\.isHexDigit)
            && parts[1].count >= 1 && parts[1].count <= 4 && parts[1].allSatisfy(\.isHexDigit)
    }

    /// SMS/GG Action Replay: XXXX-XXXX (2 groups of 4 hex chars)
    static func isSMSActionReplayCode(_ code: String) -> Bool {
        guard code.contains("-") else { return false }
        let parts = code.split(separator: "-")
        return parts.count == 2 && parts.allSatisfy { $0.count == 4 && $0.allSatisfy(\.isHexDigit) }
    }

    /// PCE (Mednafen): 6-hex address + 2-hex value, address must land in a real RAM window —
    /// either the paged form (page F8-FB, slot offset 0x2000-0x3FFF, e.g. F82DBA:02) or the
    /// linear physical form `setCheat` converts paged addresses into (0x1F0000-0x1F7FFF, e.g. 1F0083:02).
    static func isPCECode(_ code: String) -> Bool {
        guard isRawAddressValue(code, addressHexChars: 6, valueHexChars: 2),
              let addr = UInt32(code.prefix(6), radix: 16)
        else { return false }
        let page = (addr >> 16) & 0xFF
        let offset = addr & 0xFFFF
        if (0xF8...0xFB).contains(page) && (0x2000...0x3FFF).contains(offset) {
            return true
        }
        return (0x1F0000...0x1F7FFF).contains(addr)
    }
}
