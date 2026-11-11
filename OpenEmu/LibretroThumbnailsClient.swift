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

/// Fetches box art from the public libretro-thumbnails server as a last-resort fallback.
///
/// URL pattern: https://thumbnails.libretro.com/<System_Name>/Named_Boxarts/<Game_Name>.png
///
/// Name matching is title-based (No-Intro/Redump conventions). This is best-effort —
/// the server is undocumented and could change, and name matching is imprecise.
/// No credentials or rate limits apply.
final class LibretroThumbnailsClient {

    static let shared = LibretroThumbnailsClient()

    private static let baseURL = "https://thumbnails.libretro.com"

    // Maps OpenEmu system identifiers to libretro playlist/folder names on the thumbnail server.
    // Verified against https://thumbnails.libretro.com/ directory listing (April 2026).
    static let systemNames: [String: String] = [
        "openemu.system.2600":         "Atari - 2600",
        "openemu.system.5200":         "Atari - 5200",
        "openemu.system.7800":         "Atari - 7800",
        "openemu.system.atari8bit":    "Atari - 8-bit",
        "openemu.system.lynx":         "Atari - Lynx",
        "openemu.system.jaguar":       "Atari - Jaguar",
        "openemu.system.ws":           "Bandai - WonderSwan",
        "openemu.system.colecovision": "Coleco - ColecoVision",
        "openemu.system.c64":          "Commodore - 64",
        "openemu.system.vectrex":      "GCE - Vectrex",
        "openemu.system.intellivision":"Mattel - Intellivision",
        "openemu.system.msx":          "Microsoft - MSX",
        "openemu.system.pcfx":         "NEC - PC-FX",
        "openemu.system.pce":          "NEC - PC Engine - TurboGrafx 16",
        "openemu.system.pcecd":        "NEC - PC Engine CD - TurboGrafx-CD",
        "openemu.system.fds":          "Nintendo - Family Computer Disk System",
        "openemu.system.gb":           "Nintendo - Game Boy",
        "openemu.system.gba":          "Nintendo - Game Boy Advance",
        "openemu.system.gc":           "Nintendo - GameCube",
        "openemu.system.n64":          "Nintendo - Nintendo 64",
        "openemu.system.3ds":          "Nintendo - Nintendo 3DS",
        "openemu.system.nds":          "Nintendo - Nintendo DS",
        "openemu.system.nes":          "Nintendo - Nintendo Entertainment System",
        "openemu.system.pokemonmini":  "Nintendo - Pokemon Mini",
        "openemu.system.snes":         "Nintendo - Super Nintendo Entertainment System",
        "openemu.system.vb":           "Nintendo - Virtual Boy",
        "openemu.system.wii":          "Nintendo - Wii",
        "openemu.system.odyssey2":     "Magnavox - Odyssey2",
        "openemu.system.ngp":          "SNK - Neo Geo Pocket",
        "openemu.system.32x":          "Sega - 32X",
        "openemu.system.dc":           "Sega - Dreamcast",
        "openemu.system.gg":           "Sega - Game Gear",
        "openemu.system.sms":          "Sega - Master System - Mark III",
        "openemu.system.scd":          "Sega - Mega-CD - Sega CD",
        "openemu.system.sg":           "Sega - Mega Drive - Genesis",
        "openemu.system.sg1000":       "Sega - SG-1000",
        "openemu.system.saturn":       "Sega - Saturn",
        "openemu.system.psx":          "Sony - PlayStation",
        "openemu.system.ps2":          "Sony - PlayStation 2",
        "openemu.system.psp":          "Sony - PlayStation Portable",
        "openemu.system.3do":          "The 3DO Company - 3DO",
        "openemu.system.sv":           "Watara - Supervision",
    ]

    /// Synchronous fetch suitable for calling from a background DispatchQueue.sync block.
    /// Returns a box art URL string, or nil if the system is unmapped or the image is not found.
    ///
    /// `gameName` should be the full game title as it appears in the library (e.g. from OpenVGDB
    /// or the ROM filename). The method normalizes it to match libretro's naming convention.
    func fetchBoxArtURL(gameName: String, systemIdentifier: String) -> String? {
        guard let systemFolder = LibretroThumbnailsClient.systemNames[systemIdentifier] else {
            return nil
        }

        let normalized = normalizeGameName(gameName)
        guard !normalized.isEmpty else { return nil }

        // Percent-encode each path component separately so spaces become %20 and
        // special chars are handled, but slashes between components are preserved.
        guard
            let encodedSystem = systemFolder.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let encodedName   = normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }

        let urlString = "\(LibretroThumbnailsClient.baseURL)/\(encodedSystem)/Named_Boxarts/\(encodedName).png"
        guard let url = URL(string: urlString) else { return nil }

        var found = false
        let semaphore = DispatchSemaphore(value: 0)

        // HEAD request — we only need to confirm the image exists, not download it.
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            defer { semaphore.signal() }
            if let error = error {
                os_log(.debug, log: .default, "LibretroThumbnails HEAD error: %{public}@", error.localizedDescription)
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                found = true
            }
        }
        task.resume()
        semaphore.wait()

        if found {
            os_log(.debug, log: .default, "LibretroThumbnails: found art for '%{public}@' (%{public}@)", gameName, systemIdentifier)
        }
        return found ? urlString : nil
    }

    // MARK: - Name normalization

    /// Converts a game title to the format libretro-thumbnails expects.
    ///
    /// Rules (from libretro docs and empirical testing):
    ///   - Characters  & * / : ` < > ? \ | "  are replaced with _
    ///   - No other transformations (case, spaces, punctuation are preserved)
    func normalizeGameName(_ name: String) -> String {
        // Characters that libretro replaces with underscores in filenames
        let forbidden = CharacterSet(charactersIn: "&*/:`<>?\\|\"")
        return name.unicodeScalars.map { scalar in
            forbidden.contains(scalar) ? "_" : String(scalar)
        }.joined()
    }
}
