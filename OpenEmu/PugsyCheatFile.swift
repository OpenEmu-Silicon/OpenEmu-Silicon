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

import Cocoa
import XADMaster

extension Notification.Name {
    /// Posted whenever the user's Pugsy MAME cheat archive was successfully imported.
    static let didImportPugsyCheatFile = Notification.Name("OEDidImportPugsyCheatFile")

    /// Posted on the main queue while decompressing the imported archive, so the Game Scanner banner
    /// can show real progress. userInfo: `current` (Int), `total` (Int), `finished` (Bool).
    static let pugsyCheatImportProgress = Notification.Name("OEPugsyCheatImportProgress")
}

/// Detects and imports Pugsy's MAME cheat archive (mamecheat.co.uk `cheat.7z`).
///
/// The archive is never bundled or auto-downloaded — the user downloads it themselves and drops it
/// onto the library window, exactly like a BIOS file. Pugsy publishes it as `cheatNNNN.zip` (a
/// versioned zip containing `cheat.7z`), so a dropped file is recognized either as `cheat.7z`
/// directly or as one of those zips, whose inner `cheat.7z` is extracted first. On import the
/// archive is decompressed once into a fixed host-owned location (a sibling of the Libretro cache),
/// so per-game lookups read a small `<romset>.xml` instead of re-scanning a ~4 MB 7z each time:
///
///     <library>/CheatDatabase/pugsy/cheat.7z   ← the imported archive, kept as-is
///     <library>/CheatDatabase/pugsy/cheats/     ← decompressed contents, replaced on every import
enum PugsyCheatFile {

    /// The exact filename Pugsy publishes. Recognition is a case-insensitive match on this.
    static let expectedFileName = "cheat.7z"

    /// `<library>/CheatDatabase/pugsy/`. `nil` when no library is loaded (same contract as the
    /// Libretro cache).
    static var folderURL: URL? {
        guard let base = OELibraryDatabase.default?.databaseFolderURL else { return nil }
        return base
            .appendingPathComponent("CheatDatabase", isDirectory: true)
            .appendingPathComponent("pugsy", isDirectory: true)
    }

    /// The imported archive itself, kept alongside its decompressed form.
    static var importedArchiveURL: URL? {
        folderURL?.appendingPathComponent(expectedFileName, isDirectory: false)
    }

    /// The decompressed `<romset>.xml` files. Wiped and rebuilt on every import; the single source
    /// of truth `PugsyCheatProvider` reads from.
    static var decompressedFolderURL: URL? {
        folderURL?.appendingPathComponent("cheats", isDirectory: true)
    }

    /// True once an archive has been imported and decompressed.
    static var isArchiveImported: Bool {
        guard let url = decompressedFolderURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// How a recognized drop yields the inner `cheat.7z`.
    private enum RecognizedSource {
        /// The dropped file already is the `cheat.7z`.
        case direct
        /// The dropped file is a Pugsy `cheatNNNN.zip` whose entry at this index is the `cheat.7z`.
        case insideZip(entryIndex: Int32)
    }

    /// Recognizes the dropped file as a Pugsy cheat package, or returns `nil` for anything else.
    private static func recognize(at url: URL) -> RecognizedSource? {
        let name = url.lastPathComponent.lowercased()
        if name == expectedFileName { return .direct }
        // Pugsy's download is `cheatNNNN.zip` with `cheat.7z` inside. Filter by name first to avoid
        // opening every dropped ROM zip, then confirm it really contains `cheat.7z` before claiming it.
        guard name.hasPrefix("cheat"), name.hasSuffix(".zip"),
              let index = innerCheatEntryIndex(inArchiveAt: url) else { return nil }
        return .insideZip(entryIndex: index)
    }

    /// Index of the `cheat.7z` entry inside an archive, or `nil` if absent. Only reads the archive
    /// directory (entry names), not the compressed data.
    private static func innerCheatEntryIndex(inArchiveAt url: URL) -> Int32? {
        guard let archive = XADArchive.oe_archiveForFile(at: url) else { return nil }
        for i in 0 ..< archive.numberOfEntries() where !archive.entryIsDirectory(i) {
            let entryLast = (archive.name(ofEntry: i) as NSString).lastPathComponent
            if entryLast.caseInsensitiveCompare(expectedFileName) == .orderedSame { return i }
        }
        return nil
    }

    /// Extracts a single archive entry into a fresh temp directory. The caller owns the returned
    /// file's parent directory and must delete it when done.
    private static func extractEntry(_ index: Int32, from archiveURL: URL) -> URL? {
        guard let archive = XADArchive.oe_archiveForFile(at: archiveURL) else { return nil }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = tempDir.appendingPathComponent(expectedFileName, isDirectory: false)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        if archive.oe_extractEntry(index, as: destination.path, deferDirectories: true, dataFork: true, resourceFork: false) {
            return destination
        }
        try? FileManager.default.removeItem(at: tempDir)
        return nil
    }

    /// Recognize a dropped file as Pugsy's cheat archive (either `cheat.7z` or a `cheatNNNN.zip`
    /// containing it) and, if so, import it: copy the archive in and decompress it into `cheats/`,
    /// replacing any previous import entirely.
    ///
    /// When an archive already exists the user is asked whether to replace it; declining keeps the
    /// existing import. Either way the return value is `true` — a recognized cheat archive is never a
    /// ROM/BIOS, so the importer must stop treating it as one regardless of the overwrite choice.
    /// - Returns: `true` if the file was recognized as the Pugsy cheat archive (and thus consumed by
    ///   the import pipeline), `false` if it is some other file the importer should keep handling.
    @discardableResult
    static func checkIfPugsyCheatFileAndImport(at url: URL) -> Bool {
        guard let source = recognize(at: url) else { return false }

        guard let folder = folderURL,
              let archiveDest = importedArchiveURL,
              let decompressedDest = decompressedFolderURL else {
            // Recognized, but no library is loaded so there's nowhere to put it. Still not a ROM.
            DLog("Recognized Pugsy cheat archive but no library is loaded; skipping import")
            return true
        }

        let fileManager = FileManager.default

        // Switch the scanner banner into cheat-import mode immediately, before the replace prompt
        // and the (slow) copy + decompression, so the user never sees a stale "Game Scanner" title.
        postProgress(current: 0, total: 0, finished: false)

        let alreadyImported = fileManager.fileExists(atPath: archiveDest.path)
            || fileManager.fileExists(atPath: decompressedDest.path)
        if alreadyImported {
            guard promptToReplaceExistingArchive() else {
                DLog("User chose to keep the existing Pugsy cheat archive")
                postProgress(current: 0, total: 0, finished: true)
                return true
            }
        }

        // Resolve the dropped file to a `cheat.7z` on disk, unwrapping Pugsy's `cheatNNNN.zip` if needed.
        var tempDirToClean: URL?
        let sevenZipURL: URL
        switch source {
        case .direct:
            sevenZipURL = url
        case .insideZip(let entryIndex):
            guard let extracted = extractEntry(entryIndex, from: url) else {
                postProgress(current: 0, total: 0, finished: true)
                DLog("Could not extract \(expectedFileName) from \(url)")
                return true
            }
            sevenZipURL = extracted
            tempDirToClean = extracted.deletingLastPathComponent()
        }
        defer { if let tempDirToClean { try? fileManager.removeItem(at: tempDirToClean) } }

        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

            // Replace the archive.
            if fileManager.fileExists(atPath: archiveDest.path) {
                try fileManager.removeItem(at: archiveDest)
            }
            try fileManager.copyItem(at: sevenZipURL, to: archiveDest)

            // Replace the decompressed contents entirely.
            if fileManager.fileExists(atPath: decompressedDest.path) {
                try fileManager.removeItem(at: decompressedDest)
            }
            try fileManager.createDirectory(at: decompressedDest, withIntermediateDirectories: true)

            let extracted = decompress(archiveAt: archiveDest, into: decompressedDest) { current, total in
                postProgress(current: current, total: total, finished: false)
            }
            postProgress(current: extracted, total: extracted, finished: true)
            if extracted == 0 {
                DLog("Pugsy cheat archive imported but decompression produced no files")
            }
            NotificationCenter.default.post(name: .didImportPugsyCheatFile, object: nil)
            DLog("Imported Pugsy cheat archive to \(archiveDest); decompressed \(extracted) file(s) into \(decompressedDest)")
        } catch {
            postProgress(current: 0, total: 0, finished: true)
            DLog("Could not import Pugsy cheat file \(url): \(error)")
        }

        return true
    }

    /// Extracts every non-directory entry of the archive into `directory`, preserving each entry's
    /// path. Uses the exception-safe `oe_extractEntry` wrapper (XADMaster raises ObjC exceptions on
    /// error, which are unsafe to let cross into Swift). `progress` is called (throttled to whole
    /// percentage steps) on every entry, extracted or skipped, so the denominator advances smoothly.
    /// - Returns: the number of files extracted.
    private static func decompress(archiveAt archiveURL: URL, into directory: URL,
                                   progress: ((_ current: Int, _ total: Int) -> Void)?) -> Int {
        guard let archive = XADArchive.oe_archiveForFile(at: archiveURL) else { return 0 }

        let total = Int(archive.numberOfEntries())
        let fileManager = FileManager.default
        var extractedCount = 0
        var lastReportedPercent = -1
        for i in 0 ..< archive.numberOfEntries() {
            let current = Int(i) + 1
            if !(archive.entryIsDirectory(i) || archive.entryIsEncrypted(i) || archive.entryIsArchive(i)) {
                let destination = directory.appendingPathComponent(archive.name(ofEntry: i))
                try? fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if archive.oe_extractEntry(i, as: destination.path, deferDirectories: true, dataFork: true, resourceFork: false) {
                    extractedCount += 1
                }
            }
            if let progress, total > 0 {
                let percent = current * 100 / total
                if percent != lastReportedPercent || current == total {
                    lastReportedPercent = percent
                    progress(current, total)
                }
            }
        }
        return extractedCount
    }

    /// Posts a decompression-progress notification on the main queue (the decompression itself runs
    /// on the import background queue).
    private static func postProgress(current: Int, total: Int, finished: Bool) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .pugsyCheatImportProgress, object: nil,
                                            userInfo: ["current": current, "total": total, "finished": finished])
        }
    }

    /// Asks the user whether to replace an already-imported archive. Runs on the main thread because
    /// the import pipeline calls this from a background operation.
    private static func promptToReplaceExistingArchive() -> Bool {
        var replace = false
        let showAlert = {
            let alert = OEAlert()
            alert.messageText = NSLocalizedString("Replace existing MAME cheat file?",
                                                  comment: "Pugsy cheat import: title asking whether to overwrite the already-imported cheat.7z")
            alert.informativeText = NSLocalizedString("A MAME cheat file has already been imported. Do you want to replace it with this one?",
                                                      comment: "Pugsy cheat import: body asking whether to overwrite the already-imported cheat.7z")
            alert.defaultButtonTitle = NSLocalizedString("Replace", comment: "")
            alert.alternateButtonTitle = NSLocalizedString("Keep Existing", comment: "")
            replace = alert.runModal() == .alertFirstButtonReturn
        }
        if Thread.isMainThread {
            showAlert()
        } else {
            DispatchQueue.main.sync(execute: showAlert)
        }
        return replace
    }
}
