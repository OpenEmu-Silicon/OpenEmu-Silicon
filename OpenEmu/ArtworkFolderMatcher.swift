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

import Cocoa

/// Matches the pictures in a person's own folder to games by normalized name, and puts the chosen ones in the
/// artwork folder as pinned, user-origin art. The person's folder is only read.
@objc(OEArtworkFolderMatcher)
final class ArtworkFolderMatcher: NSObject {

    @objc(OEArtworkFolderMatcherMatch) final class Match: NSObject {
        @objc let game: OEDBGame
        @objc let fileURL: URL
        let slot: OEArtworkStore.Slot
        @objc let warning: String?

        @objc var slotName: String { slot.rawValue }

        init(game: OEDBGame, fileURL: URL, slot: OEArtworkStore.Slot = .cover, warning: String? = nil) {
            self.game = game
            self.fileURL = fileURL
            self.slot = slot
            self.warning = warning
        }
    }

    @objc(OEArtworkFolderMatcherResult) final class Result: NSObject {
        @objc let matches: [Match]
        @objc let unmatchedFileURLs: [URL]

        init(matches: [Match], unmatchedFileURLs: [URL]) {
            self.matches = matches
            self.unmatchedFileURLs = unmatchedFileURLs
        }
    }

    static func normalize(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pairs found files with game names. A file matches only when exactly one game has that name; two games with the
    /// same name are left alone rather than guessed at. If several files fit the same game and slot, the first (by
    /// path) is kept and the rest are reported as unmatched.
    static func assign(_ found: [ArtworkFolderScan.Found], gameNames: [String]) -> (matched: [(found: ArtworkFolderScan.Found, game: Int)], unmatched: [ArtworkFolderScan.Found]) {
        var owner = [String: Int]()
        var ambiguous = Set<String>()
        for (index, name) in gameNames.enumerated() {
            let key = normalize(name)
            if owner[key] != nil { ambiguous.insert(key) } else { owner[key] = index }
        }

        var matched = [(found: ArtworkFolderScan.Found, game: Int)]()
        var unmatched = [ArtworkFolderScan.Found]()
        var taken = Set<String>()
        for file in found {
            let key = normalize(file.title)
            let slotKey = key + "\u{0}" + file.slot.rawValue
            if let game = owner[key], !ambiguous.contains(key), !taken.contains(slotKey) {
                matched.append((file, game))
                taken.insert(slotKey)
            } else {
                unmatched.append(file)
            }
        }
        return (matched, unmatched)
    }

    @objc(matchWithFolderURL:games:) static func match(folderURL: URL, games: [OEDBGame]) -> Result {
        let found = ArtworkFolderScan.scan(folderURL)
        let names = games.map { $0.displayName }
        let result = assign(found, gameNames: names)
        return Result(
            matches: result.matched.map { Match(game: games[$0.game], fileURL: $0.found.url, slot: $0.found.slot, warning: $0.found.warning) },
            unmatchedFileURLs: result.unmatched.map { $0.url })
    }

    /// Stores the confirmed matches as the person's own pinned art. Returns how many were stored.
    @objc(applyMatches:) @discardableResult static func apply(_ matches: [Match]) -> Int {
        var stored = 0
        var contexts = Set<NSManagedObjectContext>()
        for match in matches {
            guard let data = try? Data(contentsOf: match.fileURL), !data.isEmpty else { continue }
            let outcome = OEArtworkChoice.choose(data, for: OEArtworkStore.Game(match.game), slot: match.slot, provider: nil)
            switch outcome {
            case .stored, .alreadyActive: stored += 1
            default: continue
            }
            // The library's own cover is the game's box art; the other slots are read from the artwork folder.
            if match.slot == .cover {
                match.game.setBoxImage(url: match.fileURL)
                if let context = match.game.managedObjectContext { contexts.insert(context) }
            }
        }
        for context in contexts { try? context.save() }
        Task { @MainActor in OEBigPictureArt.shared.reset() }
        return stored
    }
}
