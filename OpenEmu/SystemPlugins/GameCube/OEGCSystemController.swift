// Copyright (c) 2023, OpenEmu Team
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
import OpenEmuSystem

class OEGCSystemController: OESystemController {
    // Read header to detect GameCube ISO, GCM & CISO.
    override func canHandle(_ file: OEFile) -> OEFileSupport {
        // gcm/gcz are GameCube-only container formats.
        if ["gcm", "gcz"].contains(file.fileExtension) {
            return .yes
        }

        var dataRange = NSRange(location: 0x1C, length: 4)

        // Handle ciso file and set the offset for the Magicword in compressed iso.
        if file.fileExtension == "ciso" {
            dataRange.location = 0x801C
        }
        // RVZ/WIA keep the disc's first 0x80 bytes uncompressed in WIAHeader2 (file 0x58), so the
        // GameCube magic sits at disc offset 0x1C -> file 0x74. Reading it tells a GameCube .rvz
        // apart from a Wii .rvz, which the old blanket extension match could not.
        else if file.fileExtension == "rvz" {
            dataRange.location = 0x74
        }

        let dataBuffer = file.readData(in: dataRange)
        // GameCube Magicword 0xC2339F3D
        let bytes: [UInt8] = [0xC2, 0x33, 0x9F, 0x3D]
        let comparisonData = Data(bytes: bytes, count: 4)

        if dataBuffer == comparisonData {
            return .yes
        }

        return .no
    }

    override func serialLookup(for file: OEFile) -> String? {
        // The 6-character game ID sits at the start of the disc header; its file offset depends on
        // the container format. Plain ISO/GCM is 0x0; compressed formats keep the header elsewhere.
        let discStart: Int
        switch file.fileExtension.lowercased() {
        case "ciso":       discStart = 0x8000
        case "rvz", "wia": discStart = 0x58
        default:           discStart = 0x0
        }

        let gameID = file.readASCIIString(in: NSRange(location: discStart, length: 6))

        // Reject anything that isn't a real game ID (6 uppercase letters/digits) so a format whose
        // header offset we didn't decode never yields a bogus serial like "RVZ".
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard gameID.count == 6, gameID.unicodeScalars.allSatisfy(allowed.contains) else { return nil }

        // Read the disc number and version number bytes from the header.
        var result = gameID
        let headerDiscByte = [UInt8](file.readData(in: NSRange(location: discStart + 0x6, length: 1))).first ?? 0
        let headerVersionByte = [UInt8](file.readData(in: NSRange(location: discStart + 0x7, length: 1))).first ?? 0

        if headerDiscByte > 0 {
            result += "-DISC\(headerDiscByte + 1)"
        }

        if headerVersionByte > 0 {
            result += "-REV\(headerVersionByte)"
        }

        return result
    }
}
