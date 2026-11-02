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


#if DEBUG
import Cocoa

/// Debug builds only. `-OEMeasureScreenScraper <report path>` downloads ScreenScraper's pictures for every library
/// game (one lookup per game, paced like the app does) and writes one line per picture to the report: game, slot,
/// format, pixels and bytes. Nothing is stored in the artwork folder or the library; it is how the "Phase 0"
/// size table gets its ScreenScraper rows. `-OEMeasureLimit <n>` stops after n games.
enum OEArtworkMeasure {

    @MainActor
    static func runIfRequested(_ database: OELibraryDatabase) {
        guard let report = UserDefaults.standard.string(forKey: "OEMeasureScreenScraper"), !report.isEmpty,
              OEBigPictureArtSource.screenScraperAvailable else { return }
        let limit = UserDefaults.standard.integer(forKey: "OEMeasureLimit")
        let request = OEDBGame.fetchRequest()
        var games = ((try? database.mainThreadContext.fetch(request)) as? [OEDBGame]) ?? []
        if limit > 0 { games = Array(games.prefix(limit)) }
        let keys = games.map { OEBigPictureArt.GameKey($0) }.filter { !$0.md5.isEmpty }
        NSLog("Artwork measure: %d games, report %@", keys.count, report)

        Task { @MainActor in
            var lines = ["game\tslot\tformat\twidth\theight\tbytes"]
            for key in keys {
                for slot in [OEArtworkStore.Slot.cover, .hero, .logo, .icon] {
                    let pictures = await ScreenScraperArtProvider.shared.pictures(for: key, slot: slot)
                    if pictures.isEmpty { lines.append("\(key.fullName)\t\(slot.rawValue)\tnone\t0\t0\t0"); continue }
                    for picture in pictures {
                        let size = picture.image?.representations.first.map { ($0.pixelsWide, $0.pixelsHigh) } ?? (0, 0)
                        lines.append("\(key.fullName)\t\(slot.rawValue)\t\(OEArtworkOriginals.fileExtension(for: picture.data))\t\(size.0)\t\(size.1)\t\(picture.data.count)")
                    }
                }
                try? lines.joined(separator: "\n").appending("\n").write(toFile: report, atomically: true, encoding: .utf8)
            }
            lines.append("done")
            try? lines.joined(separator: "\n").appending("\n").write(toFile: report, atomically: true, encoding: .utf8)
            NSLog("Artwork measure: finished")
        }
    }
}
#endif
