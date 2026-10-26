// Copyright (c) 2024, OpenEmu Team
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
import os.log

private let log = OSLog(subsystem: "org.openemu.OpenEmu", category: "FolderBackup")
private let kBackupFolderPathKey = "OEBackupFolderPath"
private let kLastBackupDateKey   = "OELastBackupDate"
private let kMachineIDKey        = "OEBackupMachineID"
private let kSyncRecordsKey      = "OEBackupSyncRecords"
private let kGameAliasesKey      = "OEBackupGameAliases"

extension Notification.Name {
    static let OEFolderBackupStatusDidChange = Notification.Name("OEFolderBackupStatusDidChange")
}

@objc enum OEFolderBackupStatus: Int {
    case noFolderSelected  // No folder configured.
    case idle              // Folder configured, monitoring active.
    case syncing           // Initial sync or restore in progress.
    case failed            // Last copy operation failed.
}

/// What the launch check found for one game.
enum OEBackupLaunchCheck: Equatable {
    case upToDate
    /// Another Mac saved newer progress and this Mac has not changed since the last sync.
    case newerBackup(backupDate: Date, machineName: String?)
    /// Both this Mac and another Mac changed the game since the last sync.
    case conflict(localDate: Date, backupDate: Date, machineName: String?)
    /// Files in the backup folder are still downloading.
    case stillSyncing
}

enum OEBackupDecision: Equatable {
    case upToDate
    case newerBackup
    case conflict
}

/// The newest save dates this Mac saw the last time it was fully in sync with the backup folder.
struct OEBackupSyncRecord: Equatable {
    var backupDate: Date
    var localDate: Date
}

/// Small file stored next to the backup, saying which Mac wrote a game's save and when.
struct OEBackupMetadata: Codable, Equatable {
    var machineID: String
    var machineName: String
    var writtenAt: Date
    var saveDate: Date
}

enum OEBackupPolicy {
    /// Network drives and iCloud round-trip file dates, so treat dates this close as equal.
    static let dateTolerance: TimeInterval = 1

    static func decide(
        backupDate: Date?,
        localDate: Date?,
        backupWrittenByThisMac: Bool,
        record: OEBackupSyncRecord?
    ) -> OEBackupDecision {
        guard let backupDate else { return .upToDate }
        let local = localDate ?? .distantPast
        guard let record else {
            return backupDate > local ? .newerBackup : .upToDate
        }
        let backupChanged = !backupWrittenByThisMac && backupDate > record.backupDate.addingTimeInterval(dateTolerance)
        let localChanged = local > record.localDate.addingTimeInterval(dateTolerance)
        if backupChanged && localChanged { return .conflict }
        if backupChanged && backupDate > local { return .newerBackup }
        return .upToDate
    }

    /// A game counts as synced only when the backup and this Mac hold the same newest save.
    /// A failed upload, a skipped upload, or a newer save from another Mac must not be recorded.
    static func isInSync(backupDate: Date?, localDate: Date?) -> Bool {
        guard let backupDate, let localDate else { return false }
        return abs(backupDate.timeIntervalSince(localDate)) <= dateTolerance
    }
}

/// Keeps the last few copies of a save that is about to be overwritten, in a `.versions`
/// folder next to it.
enum OESaveVersions {
    static let folderName = ".versions"
    static let keepCount = 5
    private static let stampLength = 19  // "yyyyMMdd-HHmmss-SSS"

    @discardableResult
    static func archive(_ url: URL, in versionsFolder: URL? = nil, keeping limit: Int = keepCount, now: Date = Date()) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let folder = versionsFolder ?? url.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        var copy = folder.appendingPathComponent("\(formatter.string(from: now))-\(url.lastPathComponent)")
        var attempt = 1
        while fm.fileExists(atPath: copy.path) {
            attempt += 1
            copy = folder.appendingPathComponent("\(formatter.string(from: now.addingTimeInterval(Double(attempt) / 1000)))-\(url.lastPathComponent)")
        }
        try fm.copyItem(at: url, to: copy)

        for old in versions(of: url, in: folder).dropFirst(max(limit, 1)) {
            try? fm.removeItem(at: old)
        }
        return copy
    }

    /// Kept copies of `url`, newest first.
    static func versions(of url: URL, in versionsFolder: URL? = nil) -> [URL] {
        let folder = versionsFolder ?? url.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
        let name = url.lastPathComponent
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: []) else { return [] }
        return entries
            .filter { $0.lastPathComponent.count == stampLength + 1 + name.count && $0.lastPathComponent.hasSuffix("-" + name) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

/// Decides whether a file in a core's `Battery Saves` folder belongs to a game.
/// `names` holds everything the game is known by: its library title, its ROM file name and its disc ID.
enum OEBatterySaveMatcher {
    static func matches(fileName: String, names: Set<String>) -> Bool {
        for name in names where !name.isEmpty {
            // "<name>.<ext>": cartridge saves from most cores.
            if fileName.hasPrefix(name + ".") {
                let rest = fileName.dropFirst(name.count + 1)
                if !rest.isEmpty && !rest.contains(".") { return true }
                // "<name>.<md5>.<ext>": Mednafen memory cards, e.g. "Game.0123…cdef.0.mcr".
                if let dot = rest.firstIndex(of: ".") {
                    let hash = rest[..<dot]
                    let ext = rest[rest.index(after: dot)...]
                    if hash.count == 32, hash.allSatisfy({ $0.isHexDigit }), !ext.isEmpty, ext.split(separator: ".").count <= 2 { return true }
                }
            }
            // "<disc id>_vmu_save_A1.bin": Dreamcast memory cards from Flycast.
            if fileName.hasPrefix(name + "_vmu_save_") {
                let port = fileName.dropFirst(name.count + "_vmu_save_".count)
                if port.count == 6, port.hasSuffix(".bin"), let letter = port.first, "ABCD".contains(letter) { return true }
            }
        }
        return false
    }
}

/// Save locations that are not in a core's `Battery Saves` folder: PSP save folders (PPSSPP),
/// Wii save folders and GameCube memory cards (Dolphin). All paths are relative to the OpenEmu support folder.
enum OEExtraSaveLocations {
    /// The folder or file that should be copied as one unit for a path inside one of these locations.
    static func unitComponents(for parts: [String]) -> [String]? {
        guard parts.count >= 3 else { return nil }
        if parts[1] == "PSP", parts[2] == "SAVEDATA", parts.count >= 4 { return Array(parts[0...3]) }
        if parts[1] == "Wii", parts[2] == "title", parts.count >= 6, parts[3] == "00010000", parts[5] == "data" { return Array(parts[0...5]) }
        if parts[1] == "GC", parts.count == 3, parts[2].hasPrefix("MemoryCard"), parts[2].hasSuffix(".raw") { return parts }
        return nil
    }

    /// The game a unit belongs to: a PSP disc ID or a Wii game ID. GameCube cards are shared, so they have none.
    static func gameKey(for parts: [String]) -> String? {
        guard let unit = unitComponents(for: parts) else { return nil }
        if unit[1] == "PSP" { return String(unit[3].prefix(9)) }
        if unit[1] == "Wii" { return asciiFromHex(unit[4]) }
        return nil
    }

    static func isPSPDiscID(_ s: String) -> Bool {
        s.count == 9 && s.prefix(4).allSatisfy { $0.isASCII && $0.isUppercase && $0.isLetter } && s.suffix(5).allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Wii game IDs are 4 letters or digits, stored in the NAND path as 8 hex digits.
    static func wiiTitleFolder(forGameID id: String) -> String? {
        let four = String(id.prefix(4))
        guard four.count == 4, four.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return nil }
        return four.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private static func asciiFromHex(_ hex: String) -> String? {
        guard hex.count == 8 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16), byte >= 0x20, byte < 0x7f else { return nil }
            bytes.append(byte)
            index = next
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - OEFolderBackupManager

/// Backs up battery saves, save states, and BIOS files to a user-chosen folder.
///
/// The backup mirrors the OpenEmu Application Support directory structure exactly:
///   local:  `~/Library/Application Support/OpenEmu/Save States/…`
///   backup: `{backupFolder}/Save States/…`
///
/// If the user points the backup folder at a location inside iCloud Drive
/// (`~/Library/Mobile Documents/`), macOS syncs it transparently — no entitlements needed.
@objc final class OEFolderBackupManager: NSObject {

    // MARK: - Singleton

    @objc static let shared = OEFolderBackupManager()

    // MARK: - Public state

    @objc private(set) var status: OEFolderBackupStatus = .noFolderSelected {
        didSet {
            guard status != oldValue else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .OEFolderBackupStatusDidChange, object: self)
            }
        }
    }

    @objc var backupFolderURL: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: kBackupFolderPathKey), !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        }
        set {
            UserDefaults.standard.set(newValue?.path, forKey: kBackupFolderPathKey)
        }
    }

    @objc var isEnabled: Bool { backupFolderURL != nil && (status == .idle || status == .failed) }

    @objc private(set) var lastBackupDate: Date? {
        get { UserDefaults.standard.object(forKey: kLastBackupDateKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: kLastBackupDateKey) }
    }

    // MARK: - Private

    private var eventStream: FSEventStreamRef?
    /// Dedicated serial queue for all backup copy operations.
    /// Serialising writes prevents I/O saturation on slow external/NAS destinations
    /// when several FSEvents fire simultaneously (e.g. auto-save + screenshot + Info.plist).
    private let copyQueue = DispatchQueue(label: "org.openemu.OpenEmu.FolderBackup.copy", qos: .utility)

    private let recordsLock = NSLock()

    private override init() { super.init() }

    deinit { stopFSEventStream() }

    // MARK: - Lifecycle

    /// Call once after the library database has loaded. No-op if no folder is configured.
    @objc func start() {
        guard backupFolderURL != nil else {
            status = .noFolderSelected
            return
        }
        status = .syncing
        copyQueue.async { [weak self] in
            self?.performInitialSync()
            DispatchQueue.main.async {
                self?.status = .idle
                self?.startFSEventStream()
            }
        }
    }

    @objc func stop() {
        stopFSEventStream()
        if backupFolderURL == nil { status = .noFolderSelected }
    }

    @objc func flush(completion: @escaping () -> Void) {
        guard backupFolderURL != nil else {
            completion()
            return
        }
        // The quit flow can call this from a main queue block and then wait in a nested
        // run loop that does not drain the main queue, so do not use DispatchQueue.main.
        let mainRunLoop = CFRunLoopGetMain()
        copyQueue.async { [weak self] in
            self?.performInitialSync()
            CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue, completion)
            CFRunLoopWakeUp(mainRunLoop)
        }
    }

    // MARK: - Folder selection

    /// Presents an NSOpenPanel. On selection: stops current monitoring, saves the new folder,
    /// runs initial sync, then starts FSEventStream. Calls completion(true) on success.
    @objc func chooseFolder(relativeTo window: NSWindow, completion: @escaping (_ selected: Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Select Backup Folder"
        panel.message = "Choose a folder to back up your save states, battery saves, and BIOS files. Pick a folder inside iCloud Drive to sync automatically across your Macs."

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else {
                completion(false)
                return
            }
            // Reject a folder that lives inside the OpenEmu support directory.
            // If the user picks a subfolder of Save States as the destination,
            // every copy would trigger another FSEvent → infinite copy loop.
            let supportPath = URL.oeApplicationSupportDirectory.standardized.path
            if url.standardized.path.hasPrefix(supportPath) {
                let alert = NSAlert()
                alert.messageText = "Invalid Backup Folder"
                alert.informativeText = "The backup folder cannot be inside the OpenEmu data folder. Please choose a different location, such as a folder on an external drive or inside iCloud Drive."
                alert.alertStyle = .warning
                alert.beginSheetModal(for: window) { _ in completion(false) }
                return
            }
            self?.stop()
            if self?.backupFolderURL?.standardized != url.standardized { self?.clearSyncRecords() }
            self?.backupFolderURL = url
            self?.start()
            completion(true)
        }
    }

    /// Clears the saved folder and stops monitoring.
    @objc func removeFolder() {
        stop()
        backupFolderURL = nil
        clearSyncRecords()
        status = .noFolderSelected
        os_log(.info, log: log, "Backup folder removed.")
    }

    // MARK: - FSEventStream (outbound: local → backup)

    private func startFSEventStream() {
        guard eventStream == nil, backupFolderURL != nil else { return }
        let supportDir = URL.oeApplicationSupportDirectory
        var watchURLs: [URL] = [
            supportDir.appendingPathComponent("Save States"),
            supportDir.appendingPathComponent("BIOS"),
        ]
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: supportDir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        ) {
            for dir in contents {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)
                guard isDir.boolValue else { continue }
                let bs = dir.appendingPathComponent("Battery Saves")
                if FileManager.default.fileExists(atPath: bs.path) { watchURLs.append(bs) }
                for sub in ["PSP/SAVEDATA", "Wii/title/00010000", "GC"] {
                    let extra = dir.appendingPathComponent(sub)
                    if FileManager.default.fileExists(atPath: extra.path) { watchURLs.append(extra) }
                }
            }
        }

        if let backupFolder = backupFolderURL { watchURLs.append(backupFolder) }

        let paths = watchURLs.map { $0.path } as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info else { return }
            let mgr = Unmanaged<OEFolderBackupManager>.fromOpaque(info).takeUnretainedValue()
            let rawPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
            let urls = rawPaths.prefix(numEvents).map { URL(fileURLWithPath: $0) }
            mgr.handleFSEvents(at: Array(urls))
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            os_log(.error, log: log, "Failed to create FSEventStream.")
            return
        }
        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue as CFString)
        FSEventStreamStart(stream)
        eventStream = stream
        os_log(.info, log: log, "FSEventStream watching %d director(ies).", watchURLs.count)
    }

    private func stopFSEventStream() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    private func handleFSEvents(at urls: [URL]) {
        guard let backupFolder = backupFolderURL else { return }
        let fm = FileManager.default
        var roots = Set<URL>()
        var remoteGames = Set<String>()
        for url in urls {
            if isInsideBackupFolder(url, backupFolder: backupFolder) {
                if let game = gameName(forBackup: url, backupFolder: backupFolder) { remoteGames.insert(game) }
                continue
            }
            guard !url.pathComponents.contains(where: { $0.hasPrefix(".") }) else { continue }
            guard let root = saveItemRoot(for: url) else { continue }
            guard fm.fileExists(atPath: root.path) else { continue }
            roots.insert(root)
        }

        var byGame: [String: [URL]] = [:]
        var otherRoots: [URL] = []
        for root in roots {
            if let game = gameName(forLocal: root) { byGame[game.name, default: []].append(root) } else { otherRoots.append(root) }
        }
        for (game, gameRoots) in byGame {
            copyQueue.async { [weak self] in
                guard let self else { return }
                var copied = false
                // Decide once, before the first copy moves the backup's dates.
                let conflicted = self.currentDecision(forGame: game) == .conflict
                for localURL in gameRoots {
                    guard let dest = self.backupURL(for: localURL, backupFolder: backupFolder) else { continue }
                    if self.copyToBackupIfNewer(from: localURL, to: dest, blockedByConflict: conflicted) { copied = true }
                }
                self.finishSync(ofGame: game, wroteBackup: copied, backupFolder: backupFolder)
            }
        }
        for localURL in otherRoots {
            guard let dest = backupURL(for: localURL, backupFolder: backupFolder) else { continue }
            copyQueue.async { [weak self] in
                _ = self?.copyToBackupIfNewer(from: localURL, to: dest, blockedByConflict: false)
            }
        }
        // Another Mac changed something: start downloading it now so it is here by the time a game launches.
        for game in remoteGames {
            copyQueue.async { [weak self] in
                _ = self?.requestDownloads(backupFolder: backupFolder, safeName: game, systemShort: nil)
            }
        }
    }

    private func isInsideBackupFolder(_ url: URL, backupFolder: URL) -> Bool {
        let path = url.standardized.path
        let candidates = [backupFolder.standardized.path, backupFolder.resolvingSymlinksInPath().path]
        return candidates.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    // MARK: - Initial sync

    private func performInitialSync() {
        guard let backupFolder = backupFolderURL else { return }
        let supportDir = URL.oeApplicationSupportDirectory
        let fm = FileManager.default
        os_log(.info, log: log, "Starting initial sync to %@", backupFolder.path)

        var sourceDirs: [URL] = [
            supportDir.appendingPathComponent("Save States"),
            supportDir.appendingPathComponent("BIOS"),
        ]
        var extraUnits: [URL] = []
        if let contents = try? fm.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
            for dir in contents {
                var isDir: ObjCBool = false
                fm.fileExists(atPath: dir.path, isDirectory: &isDir)
                guard isDir.boolValue else { continue }
                let bs = dir.appendingPathComponent("Battery Saves")
                if fm.fileExists(atPath: bs.path) { sourceDirs.append(bs) }
                extraUnits += extraSaveUnits(in: dir)
            }
        }

        var games: [String: Bool] = [:]  // game name → whether a copy was written
        var conflicts: [String: Bool] = [:]  // game name → conflict decided before its first copy
        func sync(_ fileURL: URL, to dest: URL) {
            var conflicted = false
            let game = gameName(forLocal: fileURL)
            if let game {
                if conflicts[game.name] == nil { conflicts[game.name] = currentDecision(forGame: game.name) == .conflict }
                conflicted = conflicts[game.name] ?? false
            }
            let copied = copyToBackupIfNewer(from: fileURL, to: dest, blockedByConflict: conflicted)
            if let game { games[game.name] = (games[game.name] ?? false) || copied }
        }

        for sourceDir in sourceDirs {
            guard let enumerator = fm.enumerator(
                at: sourceDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: .skipsHiddenFiles
            ) else { continue }

            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                if ext == "oesavestate" {
                    enumerator.skipDescendants()
                    guard let dest = backupURL(for: fileURL, backupFolder: backupFolder) else { continue }
                    sync(fileURL, to: dest)
                } else {
                    let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    guard !isDir else { continue }
                    guard let dest = backupURL(for: fileURL, backupFolder: backupFolder) else { continue }
                    sync(fileURL, to: dest)
                }
            }
        }
        for unit in extraUnits {
            guard let dest = backupURL(for: unit, backupFolder: backupFolder) else { continue }
            sync(unit, to: dest)
        }
        for (game, copied) in games { finishSync(ofGame: game, wroteBackup: copied, backupFolder: backupFolder) }
        os_log(.info, log: log, "Initial sync complete.")
    }

    // MARK: - File copy helpers

    /// Returns `true` if the backup copy was written.
    @discardableResult
    private func copyToBackupIfNewer(from localURL: URL, to destURL: URL, blockedByConflict: Bool) -> Bool {
        let localDate = Self.deepModificationDate(of: localURL)
        let destDate  = Self.deepModificationDate(of: destURL)
        if let l = localDate, let d = destDate, d >= l { return false }
        // Both Macs changed this game since they last synced: leave the backup alone and let the
        // launch prompt ask which save to keep.
        if blockedByConflict {
            os_log(.info, log: log, "Not backing up '%@': the backup folder has a conflicting save.", localURL.lastPathComponent)
            return false
        }
        return copyFile(from: localURL, to: destURL, direction: "→")
    }

    /// PPSSPP lists everything inside `SAVEDATA` as a save, so kept copies of its save folders
    /// go in `PSP/.versions` instead of next to them.
    static func versionsFolder(for url: URL) -> URL? {
        let parent = url.deletingLastPathComponent()
        guard parent.lastPathComponent == "SAVEDATA" else { return nil }
        return parent.deletingLastPathComponent().appendingPathComponent(OESaveVersions.folderName, isDirectory: true)
    }

    /// Newest modification date of an item. For a save state bundle this includes the files
    /// inside it, because editing a file in place does not change the bundle folder's own date.
    static func deepModificationDate(of url: URL) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        var newest = values.contentModificationDate
        if values.isDirectory == true,
           let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: .skipsHiddenFiles) {
            for case let child as URL in enumerator {
                if let d = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   d > (newest ?? .distantPast) {
                    newest = d
                }
            }
        }
        return newest
    }

    // MARK: - Name sanitisation

    /// Returns a filesystem-safe version of a game name.
    /// Replaces `/` (path separator) and `..` (parent-directory traversal) so a
    /// crafted game name cannot write outside the backup folder.
    private func sanitizedName(_ name: String) -> String {
        name
            .replacingOccurrences(of: "/",  with: "_")
            .replacingOccurrences(of: "..", with: "__")
    }

    @discardableResult
    private func copyFile(from src: URL, to dest: URL, direction: String) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        // PPSSPP lists everything inside SAVEDATA as a save, so stage PSP folders next to it instead.
        let stagingDir = Self.versionsFolder(for: dest)?.deletingLastPathComponent() ?? dest.deletingLastPathComponent()
        let temp = stagingDir.appendingPathComponent("." + UUID().uuidString)
        do {
            try fm.copyItem(at: src, to: temp)
            // Keep the save we are about to replace so a bad sync can be undone.
            try OESaveVersions.archive(dest, in: Self.versionsFolder(for: dest))
            try fm.replaceItem(at: dest, withItemAt: temp, backupItemName: nil, options: [], resultingItemURL: nil)
            lastBackupDate = Date()
            os_log(.debug, log: log, "%@ %@", direction, src.lastPathComponent)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.status == .failed else { return }
                self.status = .idle
            }
        } catch {
            try? fm.removeItem(at: temp)
            let nsError = error as NSError
            os_log(.error, log: log, "Copy failed (%{public}@ %{public}@): %{public}@ [%{public}@ %ld] to %{public}@",
                   direction, src.lastPathComponent, error.localizedDescription, nsError.domain, nsError.code, dest.path)
            DispatchQueue.main.async { [weak self] in self?.status = .failed }
            return false
        }
        return true
    }

    // MARK: - Pre-launch check

    /// Looks at the backup folder before a game starts. If other Macs saved newer progress,
    /// or both Macs changed the game, the result says so. If files are still downloading it
    /// waits a few seconds, then reports `.stillSyncing`. Completion is called on the main thread.
    func checkForNewerBackup(
        systemIdentifier: String,
        gameName: String,
        aliases: [String] = [],
        discID: String? = nil,
        downloadTimeout: TimeInterval = 8,
        completion: @escaping (OEBackupLaunchCheck) -> Void
    ) {
        guard let backupFolder = backupFolderURL else {
            completion(.upToDate)
            return
        }
        let safeName = sanitizedName(gameName)
        registerAliases(aliases, discID: discID, forGame: safeName)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { DispatchQueue.main.async { completion(.upToDate) }; return }

            let deadline = Date().addingTimeInterval(downloadTimeout)
            var pending = self.requestDownloads(backupFolder: backupFolder, safeName: safeName, systemShort: nil)
            while pending && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
                pending = self.requestDownloads(backupFolder: backupFolder, safeName: safeName, systemShort: nil)
            }
            if pending {
                DispatchQueue.main.async { completion(.stillSyncing) }
                return
            }

            let state = self.syncState(forGame: safeName, backupFolder: backupFolder)
            let decision = OEBackupPolicy.decide(
                backupDate: state.backupDate,
                localDate: state.localDate,
                backupWrittenByThisMac: state.metadata?.machineID == self.machineID,
                record: state.record
            )
            os_log(.debug, log: log, "Pre-launch '%@': backup=%@, local=%@, decision=%@",
                   gameName, state.backupDate?.description ?? "none", state.localDate?.description ?? "none", String(describing: decision))

            let result: OEBackupLaunchCheck
            switch decision {
            case .upToDate:
                result = .upToDate
            case .newerBackup:
                result = .newerBackup(backupDate: state.backupDate ?? Date(), machineName: state.metadata?.machineName)
            case .conflict:
                result = .conflict(localDate: state.localDate ?? Date(), backupDate: state.backupDate ?? Date(), machineName: state.metadata?.machineName)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Copies saves for the given game from the backup folder to local OpenEmu directories.
    /// Saves that get replaced are kept in a `.versions` folder next to them.
    @objc func restoreFromBackup(
        systemIdentifier: String,
        gameName: String,
        completion: @escaping (_ success: Bool) -> Void
    ) {
        guard let backupFolder = backupFolderURL else { completion(false); return }
        let safeName    = sanitizedName(gameName)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { completion(false); return }
            var allSucceeded = true
            let items = self.saveItems(under: backupFolder, safeName: safeName, systemShort: nil).items
            for f in items {
                if let local = self.localURL(for: f, backupFolder: backupFolder) {
                    if !self.copyFile(from: f, to: local, direction: "←") { allSucceeded = false }
                }
            }
            if allSucceeded { self.recordSynced(game: safeName, backupFolder: backupFolder) }
            DispatchQueue.main.async { completion(allSucceeded) }
        }
    }

    /// Replaces the backup folder's copy of a game with this Mac's saves. Used when the user
    /// settles a conflict in favour of this Mac. The replaced saves are kept in `.versions`.
    func keepLocalSave(
        systemIdentifier: String,
        gameName: String,
        completion: @escaping (_ success: Bool) -> Void
    ) {
        guard let backupFolder = backupFolderURL else { completion(false); return }
        let safeName    = sanitizedName(gameName)

        copyQueue.async { [weak self] in
            guard let self else { completion(false); return }
            var allSucceeded = true
            let stamp = Date()
            let supportDir = URL.oeApplicationSupportDirectory
            for f in self.saveItems(under: supportDir, safeName: safeName, systemShort: nil).items {
                if let dest = self.backupURL(for: f, backupFolder: backupFolder) {
                    if self.copyFile(from: f, to: dest, direction: "→") {
                        // Give both copies the same fresh date so the other Mac sees this choice as the newest
                        // save, even if the save the user kept was dated older.
                        for url in [f, dest] { try? FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path) }
                    } else {
                        allSucceeded = false
                    }
                }
            }
            if allSucceeded { self.finishSync(ofGame: safeName, wroteBackup: true, backupFolder: backupFolder) }
            DispatchQueue.main.async { completion(allSucceeded) }
        }
    }

    // MARK: - Sync state

    private var machineID: String {
        if let id = UserDefaults.standard.string(forKey: kMachineIDKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: kMachineIDKey)
        return id
    }

    private struct SyncState {
        var backupDate: Date?
        var localDate: Date?
        var metadata: OEBackupMetadata?
        var record: OEBackupSyncRecord?
    }

    private func syncState(forGame safeName: String, backupFolder: URL, systemShort: String? = nil) -> SyncState {
        let supportDir = URL.oeApplicationSupportDirectory
        let backupItems = saveItems(under: backupFolder, safeName: safeName, systemShort: systemShort).items
        let localItems = saveItems(under: supportDir, safeName: safeName, systemShort: systemShort).items
        return SyncState(
            backupDate: backupItems.compactMap { Self.deepModificationDate(of: $0) }.max(),
            localDate: localItems.compactMap { Self.deepModificationDate(of: $0) }.max(),
            metadata: readMetadata(forGame: safeName, backupFolder: backupFolder),
            record: syncRecord(forGame: safeName)
        )
    }

    private func currentDecision(forGame safeName: String) -> OEBackupDecision {
        guard let backupFolder = backupFolderURL else { return .upToDate }
        let state = syncState(forGame: safeName, backupFolder: backupFolder)
        return OEBackupPolicy.decide(
            backupDate: state.backupDate,
            localDate: state.localDate,
            backupWrittenByThisMac: state.metadata?.machineID == machineID,
            record: state.record
        )
    }

    /// Called after this Mac finished syncing a game's files. Writes the "who saved this" file
    /// when a backup was written, and remembers the dates so the next launch can tell what changed.
    private func finishSync(ofGame safeName: String, wroteBackup: Bool, backupFolder: URL) {
        guard backupFolderURL?.standardized == backupFolder.standardized else { return }
        if wroteBackup { writeMetadata(forGame: safeName, backupFolder: backupFolder) }
        recordSynced(game: safeName, backupFolder: backupFolder)
    }

    private func metadataURL(forGame safeName: String, backupFolder: URL) -> URL {
        backupFolder.appendingPathComponent("Sync Info", isDirectory: true).appendingPathComponent(safeName + ".json")
    }

    private func readMetadata(forGame safeName: String, backupFolder: URL) -> OEBackupMetadata? {
        guard let data = try? Data(contentsOf: metadataURL(forGame: safeName, backupFolder: backupFolder)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OEBackupMetadata.self, from: data)
    }

    private func writeMetadata(forGame safeName: String, backupFolder: URL) {
        let supportDir = URL.oeApplicationSupportDirectory
        let saveDate = saveItems(under: supportDir, safeName: safeName, systemShort: nil).items
            .compactMap { Self.deepModificationDate(of: $0) }.max() ?? Date()
        let metadata = OEBackupMetadata(
            machineID: machineID,
            machineName: Host.current().localizedName ?? "Another Mac",
            writtenAt: Date(),
            saveDate: saveDate
        )
        let url = metadataURL(forGame: safeName, backupFolder: backupFolder)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(metadata).write(to: url, options: .atomic)
        } catch {
            os_log(.error, log: log, "Could not write sync info for '%@': %@", safeName, error.localizedDescription)
        }
    }

    private func syncRecord(forGame safeName: String) -> OEBackupSyncRecord? {
        recordsLock.lock(); defer { recordsLock.unlock() }
        guard let all = UserDefaults.standard.dictionary(forKey: kSyncRecordsKey) as? [String: [String: Double]],
              let entry = all[safeName], let b = entry["backup"], let l = entry["local"] else { return nil }
        return OEBackupSyncRecord(backupDate: Date(timeIntervalSinceReferenceDate: b), localDate: Date(timeIntervalSinceReferenceDate: l))
    }

    /// Remembers the newest dates only when the backup and this Mac hold the same newest save.
    /// If another Mac's save is not pulled in, or an upload was skipped or failed, the next launch must still notice.
    private func recordSynced(game safeName: String, backupFolder: URL) {
        let state = syncState(forGame: safeName, backupFolder: backupFolder)
        guard OEBackupPolicy.isInSync(backupDate: state.backupDate, localDate: state.localDate),
              let b = state.backupDate, let l = state.localDate else { return }
        recordsLock.lock(); defer { recordsLock.unlock() }
        var all = (UserDefaults.standard.dictionary(forKey: kSyncRecordsKey) as? [String: [String: Double]]) ?? [:]
        all[safeName] = ["backup": b.timeIntervalSinceReferenceDate, "local": l.timeIntervalSinceReferenceDate]
        UserDefaults.standard.set(all, forKey: kSyncRecordsKey)
    }

    private func clearSyncRecords() {
        recordsLock.lock(); defer { recordsLock.unlock() }
        UserDefaults.standard.removeObject(forKey: kSyncRecordsKey)
    }

    // MARK: - Game name aliases

    /// Most cores name battery saves after the ROM file ("Super Mario 64 (U) [!].eep"), which can
    /// differ from the game's title in the library ("Super Mario 64 (USA)"). Some use the disc ID.
    /// The launch check records those names so they are all treated as the same game.
    private func registerAliases(_ names: [String], discID: String?, forGame safeName: String) {
        var aliases = names.filter { !$0.isEmpty && $0 != safeName }
        // Disc IDs show up in several forms: "ULUS-10272" in the database, "ULUS10272" in a PSP save folder,
        // "RSPE01" as a Wii game ID of which the first 4 letters name the save folder.
        if let discID, !discID.isEmpty {
            aliases.append(discID)
            let compact = discID.filter { $0.isLetter || $0.isNumber }
            aliases.append(compact)
            if compact.count == 6, compact.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) { aliases.append(String(compact.prefix(4))) }
        }
        aliases = Array(Set(aliases)).filter { !$0.isEmpty && $0 != safeName }
        recordsLock.lock(); defer { recordsLock.unlock() }
        var map = (UserDefaults.standard.dictionary(forKey: kGameAliasesKey) as? [String: String]) ?? [:]
        var changed = false
        // A name that already belongs to another game stays with that game. Two games that share
        // a ROM file name also share its save file, so it cannot be attributed to one of them.
        for alias in aliases + [safeName] where map[alias] == nil { map[alias] = safeName; changed = true }
        if changed { UserDefaults.standard.set(map, forKey: kGameAliasesKey) }
    }

    private func aliasMap() -> [String: String] {
        recordsLock.lock(); defer { recordsLock.unlock() }
        return (UserDefaults.standard.dictionary(forKey: kGameAliasesKey) as? [String: String]) ?? [:]
    }

    /// The library title for a battery save file name, if its ROM has been launched on this Mac.
    private func canonicalName(_ name: String) -> String { aliasMap()[name] ?? name }

    /// The game a battery save file belongs to, using every name the app knows. Memory card names
    /// like "Game.<md5>.0.mcr" and "<disc id>_vmu_save_A1.bin" cannot be reduced to a game name by
    /// dropping the extension, so each known name is tried against the matcher.
    private func gameName(forBatteryFile fileName: String) -> String {
        let map = aliasMap()
        for (alias, game) in map where OEBatterySaveMatcher.matches(fileName: fileName, names: [alias]) { return game }
        return (fileName as NSString).deletingPathExtension
    }

    /// Every file name stem that belongs to the game: its title plus any known ROM file names.
    private func names(forGame safeName: String) -> Set<String> {
        var result: Set<String> = [safeName]
        for (alias, canonical) in aliasMap() where canonical == safeName { result.insert(alias) }
        return result
    }

    // MARK: - Downloads

    /// Asks iCloud to download any of the game's files that are not on this Mac yet.
    /// Returns `true` while something is still missing or downloading.
    private func requestDownloads(backupFolder: URL, safeName: String, systemShort: String?) -> Bool {
        let fm = FileManager.default
        let found = saveItems(under: backupFolder, safeName: safeName, systemShort: systemShort)
        var pending = !found.placeholders.isEmpty
        for placeholder in found.placeholders { try? fm.startDownloadingUbiquitousItem(at: placeholder) }

        let info = listDirectory(metadataURL(forGame: safeName, backupFolder: backupFolder).deletingLastPathComponent())
        let metadataName = safeName + ".json"
        for placeholder in info.placeholders where placeholder.lastPathComponent == metadataName {
            try? fm.startDownloadingUbiquitousItem(at: placeholder)
            pending = true
        }

        var files: [URL] = []
        for item in found.items + info.items.filter({ $0.lastPathComponent == metadataName }) {
            files.append(item)
            if let children = fm.enumerator(at: item, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                for case let child as URL in children { files.append(child) }
            }
        }

        for url in files where isDownloadPending(url) {
            os_log(.info, log: log, "Still downloading: %@", url.path)
            try? fm.startDownloadingUbiquitousItem(at: url)
            pending = true
        }
        return pending
    }

    private func isDownloadPending(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .isDirectoryKey]),
              values.isUbiquitousItem == true else { return false }
        // A folder reports its own status, which stays "not current" while anything inside it
        // changes. Only the files inside decide whether the save is ready to read.
        if values.isDirectory == true { return false }
        return values.ubiquitousItemDownloadingStatus != .current
    }

    // MARK: - Path mapping

    /// Maps a URL inside the OpenEmu support directory to its counterpart in the backup folder.
    private func backupURL(for localURL: URL, backupFolder: URL) -> URL? {
        let supportPath = URL.oeApplicationSupportDirectory.standardized.path
        let localPath   = localURL.standardized.path
        guard localPath.hasPrefix(supportPath) else { return nil }
        var relative = String(localPath.dropFirst(supportPath.count))
        if !relative.hasPrefix("/") { relative = "/" + relative }
        return URL(fileURLWithPath: backupFolder.standardized.path + relative)
    }

    /// Maps a URL inside the backup folder to its counterpart in the OpenEmu support directory.
    private func localURL(for backupURL: URL, backupFolder: URL) -> URL? {
        let folderPath = backupFolder.standardized.path
        let backupPath = backupURL.standardized.path
        guard backupPath.hasPrefix(folderPath) else { return nil }
        var relative = String(backupPath.dropFirst(folderPath.count))
        if !relative.hasPrefix("/") { relative = "/" + relative }
        return URL(fileURLWithPath: URL.oeApplicationSupportDirectory.standardized.path + relative)
    }

    /// Walks up the path to find an `.oesavestate` bundle root; returns the URL itself for flat files.
    private func saveItemRoot(for url: URL) -> URL? {
        let supportPath = URL.oeApplicationSupportDirectory.standardized.path
        let path = url.standardized.path
        if path.hasPrefix(supportPath + "/") {
            let parts = path.dropFirst(supportPath.count + 1).split(separator: "/").map(String.init)
            if let unit = OEExtraSaveLocations.unitComponents(for: parts) {
                return URL(fileURLWithPath: supportPath + "/" + unit.joined(separator: "/"))
            }
        }
        var candidate = url
        while candidate.pathComponents.count > 1 {
            if candidate.pathExtension.lowercased() == "oesavestate" { return candidate }
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate { break }
            candidate = parent
        }
        return url.pathExtension.isEmpty ? nil : url
    }

    // MARK: - Save file lookup

    /// Lists a folder, separating iCloud placeholders (`.Name.icloud`) from real files.
    /// A placeholder is reported under the name of the file it stands for.
    private func listDirectory(_ dir: URL) -> (items: [URL], placeholders: [URL]) {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: []) else { return ([], []) }
        var items: [URL] = []
        var placeholders: [URL] = []
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") {
                if name.hasSuffix(".icloud"), name.count > ".icloud".count + 1 {
                    placeholders.append(dir.appendingPathComponent(String(name.dropFirst().dropLast(".icloud".count))))
                }
                continue
            }
            items.append(entry)
        }
        return (items, placeholders)
    }

    /// Every save belonging to one game under `root` (the local support folder or the backup
    /// folder): save state bundles and battery saves. `systemShort` limits save states to one system.
    private func saveItems(under root: URL, safeName: String, systemShort: String?) -> (items: [URL], placeholders: [URL]) {
        let fm = FileManager.default
        var items: [URL] = []
        var placeholders: [URL] = []

        let statesRoot = root.appendingPathComponent("Save States", isDirectory: true)
        var systemDirs: [URL] = []
        if let systemShort {
            systemDirs = [statesRoot.appendingPathComponent(systemShort, isDirectory: true)]
        } else {
            systemDirs = listDirectory(statesRoot).items
        }
        for systemDir in systemDirs {
            let listing = listDirectory(systemDir.appendingPathComponent(safeName, isDirectory: true))
            items += listing.items.filter { $0.pathExtension.lowercased() == "oesavestate" }
            placeholders += listing.placeholders.filter { $0.pathExtension.lowercased() == "oesavestate" }
        }

        let batteryNames = names(forGame: safeName)
        for coreDir in listDirectory(root).items {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: coreDir.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }
            let listing = listDirectory(coreDir.appendingPathComponent("Battery Saves", isDirectory: true))
            items += listing.items.filter { OEBatterySaveMatcher.matches(fileName: $0.lastPathComponent, names: batteryNames) }
            placeholders += listing.placeholders.filter { OEBatterySaveMatcher.matches(fileName: $0.lastPathComponent, names: batteryNames) }
            items += extraSaveFolders(in: coreDir, names: batteryNames)
        }
        return (items, placeholders)
    }

    /// PSP and Wii save folders for a game, found by its disc ID or game ID.
    private func extraSaveFolders(in coreDir: URL, names: Set<String>) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        let pspIDs = names.filter { OEExtraSaveLocations.isPSPDiscID($0) }
        if !pspIDs.isEmpty {
            let saveData = coreDir.appendingPathComponent("PSP/SAVEDATA", isDirectory: true)
            result += listDirectory(saveData).items.filter { entry in pspIDs.contains { entry.lastPathComponent.hasPrefix($0) } }
        }
        for name in names {
            guard let folder = OEExtraSaveLocations.wiiTitleFolder(forGameID: name), name.count == 4 || name.count == 6 else { continue }
            let data = coreDir.appendingPathComponent("Wii/title/00010000/\(folder)/data", isDirectory: true)
            if fm.fileExists(atPath: data.path) { result.append(data) }
        }
        return result
    }

    /// Every PSP save folder, Wii save folder and GameCube memory card under a core's folder.
    private func extraSaveUnits(in coreDir: URL) -> [URL] {
        let fm = FileManager.default
        var units: [URL] = []
        units += listDirectory(coreDir.appendingPathComponent("PSP/SAVEDATA", isDirectory: true)).items
        let titles = coreDir.appendingPathComponent("Wii/title/00010000", isDirectory: true)
        for game in listDirectory(titles).items {
            let data = game.appendingPathComponent("data", isDirectory: true)
            if fm.fileExists(atPath: data.path) { units.append(data) }
        }
        units += listDirectory(coreDir.appendingPathComponent("GC", isDirectory: true)).items.filter {
            $0.lastPathComponent.hasPrefix("MemoryCard") && $0.pathExtension.lowercased() == "raw"
        }
        return units
    }

    /// Game name for a file under the local support folder, if it is a save state or battery save.
    private func gameName(forLocal url: URL) -> (name: String, system: String?)? {
        let supportPath = URL.oeApplicationSupportDirectory.standardized.path
        let path = url.standardized.path
        guard path.hasPrefix(supportPath + "/") else { return nil }
        return gameName(fromRelativePath: String(path.dropFirst(supportPath.count + 1)))
    }

    /// Game name for a file under the backup folder, if it is a save state or battery save.
    private func gameName(forBackup url: URL, backupFolder: URL) -> String? {
        for base in [backupFolder.standardized.path, backupFolder.resolvingSymlinksInPath().path] {
            let path = url.standardized.path
            if path.hasPrefix(base + "/") {
                let relative = String(path.dropFirst(base.count + 1))
                if relative.hasPrefix("Sync Info/") {
                    let file = (relative as NSString).lastPathComponent
                    guard file.hasSuffix(".json") else { return nil }
                    return String(file.dropLast(".json".count))
                }
                return gameName(fromRelativePath: relative)?.name
            }
        }
        return nil
    }

    private func gameName(fromRelativePath relative: String) -> (name: String, system: String?)? {
        let parts = relative.split(separator: "/").map(String.init)
        guard !parts.contains(where: { $0.hasPrefix(".") && !$0.hasSuffix(".icloud") }) else { return nil }
        if let key = OEExtraSaveLocations.gameKey(for: parts) { return (canonicalName(key), nil) }
        if parts.count >= 4, parts[0] == "Save States" {
            return (parts[2], parts[1])
        }
        if parts.count >= 3, parts[1] == "Battery Saves" {
            return (gameName(forBatteryFile: parts[2]), nil)
        }
        return nil
    }
}
