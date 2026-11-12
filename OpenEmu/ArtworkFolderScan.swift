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
import ImageIO

/// Reads a person's own artwork folder without touching it. Files are only read, never moved, renamed or written.
///
/// Understood layouts:
/// - `Game.png` — the cover.
/// - `Game-poster.png`, `Game-hero.png`, `Game-icon.png`, `Game-logo.png`, `Game-cover.png` — a named slot.
/// - A folder named for a slot (`poster/Game.png`) or an ES-DE media folder (`covers`, `fanart`, `marquees`,
///   `miximages`), at any depth up to three levels, as ES-DE's `downloaded_media/<system>/<kind>/Game.png`.
enum ArtworkFolderScan {

    struct Found: Equatable {
        let url: URL
        /// The title as written in the file name, with any slot suffix removed.
        let title: String
        let slot: OEArtworkStore.Slot
        /// Set when the picture's shape does not suit the slot. The file can still be used. Worked out on request:
        /// it reads the file's header, which is too slow to do for every picture in a big folder.
        var warning: String? { ArtworkFolderScan.shapeWarning(url, slot) }
    }

    /// ES-DE media folder names and the slot each one feeds. Other media kinds (screenshots, videos, manuals) have no
    /// slot here and are skipped.
    static let folderSlots: [String: OEArtworkStore.Slot] = [
        "cover": .cover, "covers": .cover, "box": .cover, "boxart": .cover,
        "poster": .poster, "posters": .poster, "miximages": .poster, "mixed": .poster,
        "hero": .hero, "heroes": .hero, "fanart": .hero, "banner": .hero, "banners": .hero,
        "icon": .icon, "icons": .icon,
        "logo": .logo, "logos": .logo, "marquee": .logo, "marquees": .logo, "wheel": .logo,
    ]

    private static let suffixes: [(suffix: String, slot: OEArtworkStore.Slot)] = OEArtworkStore.Slot.allCases.map { ("-" + $0.rawValue, $0) }
        + OEArtworkStore.Slot.allCases.map { ("_" + $0.rawValue, $0) }

    private static let maxDepth = 3
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "heic", "webp"]

    static func scan(_ folder: URL) -> [Found] {
        var found = [Found]()
        walk(folder, depth: 0, folderSlot: nil, into: &found)
        return found.sorted { $0.url.path < $1.url.path }
    }

    private static func walk(_ folder: URL, depth: Int, folderSlot: OEArtworkStore.Slot?, into found: inout [Found]) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }

        for child in children {
            let values = try? child.resourceValues(forKeys: Set(keys))
            // A link could lead out of the folder or loop back into it.
            if values?.isSymbolicLink == true { continue }

            if values?.isDirectory == true {
                guard depth < maxDepth else { continue }
                let name = child.lastPathComponent.lowercased()
                if name == "history" { continue }
                walk(child, depth: depth + 1, folderSlot: folderSlots[name] ?? folderSlot, into: &found)
            } else if values?.isRegularFile == true, imageExtensions.contains(child.pathExtension.lowercased()) {
                found.append(describe(child, folderSlot: folderSlot))
            }
        }
    }

    static func describe(_ url: URL, folderSlot: OEArtworkStore.Slot?) -> Found {
        var stem = url.deletingPathExtension().lastPathComponent
        var slot = folderSlot ?? .cover
        let lowered = stem.lowercased()
        if let hit = suffixes.first(where: { lowered.hasSuffix($0.suffix) && lowered.count > $0.suffix.count }) {
            stem = String(stem.dropLast(hit.suffix.count))
            slot = hit.slot
        }
        return Found(url: url, title: stem, slot: slot)
    }

    /// Pixel size from the file header, without decoding the picture.
    static func pixelSize(_ url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// The width-to-height range each slot suits.
    static func acceptedRatio(_ slot: OEArtworkStore.Slot) -> ClosedRange<Double> {
        switch slot {
        case .cover: return 0.5...1.2
        case .poster: return 0.5...0.9
        case .hero: return 1.4...4.0
        case .icon: return 0.85...1.18
        case .logo: return 1.0...6.0
        }
    }

    static func shapeWarning(_ url: URL, _ slot: OEArtworkStore.Slot) -> String? {
        guard let size = pixelSize(url) else { return "Could not read this picture." }
        let ratio = Double(size.width) / Double(size.height)
        guard !acceptedRatio(slot).contains(ratio) else { return nil }
        return "\(size.width)×\(size.height) is an unusual shape for \(slot.rawValue) art."
    }
}
