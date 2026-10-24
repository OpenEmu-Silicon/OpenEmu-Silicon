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

extension Notification.Name {
    static let OEFolderBackupStatusDidChange = Notification.Name("OEFolderBackupStatusDidChange")
}

@objc enum OEFolderBackupStatus: Int {
    case noFolderSelected  // No folder configured.
    case idle              // Folder configured, monitoring active.
    case syncing           // Initial sync or restore in progress.
    case failed            // Last copy operation failed.
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
            guard let path = UserDefaults.standard.string(forKey: kBackupFolderPathKey) else { return nil }
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
            self?.backupFolderURL = url
            self?.start()
            completion(true)
        }
    }

    /// Clears the saved folder and stops monitoring.
    @objc func removeFolder() {
        stop()
        backupFolderURL = nil
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
            }
        }

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
        for url in urls {
            guard !url.lastPathComponent.hasPrefix(".") else { continue }
            guard let root = saveItemRoot(for: url) else { continue }
            guard fm.fileExists(atPath: root.path) else { continue }
            roots.insert(root)
        }
        for localURL in roots {
            guard let dest = backupURL(for: localURL, backupFolder: backupFolder) else { continue }
            copyQueue.async { [weak self] in
                self?.copyToBackupIfNewer(from: localURL, to: dest)
            }
        }
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
        if let contents = try? fm.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
            for dir in contents {
                var isDir: ObjCBool = false
                fm.fileExists(atPath: dir.path, isDirectory: &isDir)
                guard isDir.boolValue else { continue }
                let bs = dir.appendingPathComponent("Battery Saves")
                if fm.fileExists(atPath: bs.path) { sourceDirs.append(bs) }
            }
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
                    copyToBackupIfNewer(from: fileURL, to: dest)
                } else {
                    let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    guard !isDir else { continue }
                    guard let dest = backupURL(for: fileURL, backupFolder: backupFolder) else { continue }
                    copyToBackupIfNewer(from: fileURL, to: dest)
                }
            }
        }
        os_log(.info, log: log, "Initial sync complete.")
    }

    // MARK: - File copy helpers

    private func copyToBackupIfNewer(from localURL: URL, to destURL: URL) {
        let localDate = (try? localURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let destDate  = (try? destURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let l = localDate, let d = destDate, d >= l { return }
        copyFile(from: localURL, to: destURL, direction: "→")
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
        let temp = dest.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString)
        do {
            try fm.copyItem(at: src, to: temp)
            try fm.replaceItem(at: dest, withItemAt: temp, backupItemName: nil, options: [], resultingItemURL: nil)
            lastBackupDate = Date()
            os_log(.debug, log: log, "%@ %@", direction, src.lastPathComponent)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.status == .failed else { return }
                self.status = .idle
            }
        } catch {
            try? fm.removeItem(at: temp)
            os_log(.error, log: log, "Copy failed (%@ %@): %@", direction, src.lastPathComponent, error.localizedDescription)
            DispatchQueue.main.async { [weak self] in self?.status = .failed }
            return false
        }
        return true
    }

    // MARK: - Pre-launch check

    /// Checks whether the backup folder contains a newer save for the given game.
    /// Completion is always called on the main thread.
    @objc func checkForNewerBackup(
        systemIdentifier: String,
        gameName: String,
        completion: @escaping (_ shouldRestore: Bool, _ newestDate: Date?) -> Void
    ) {
        guard let backupFolder = backupFolderURL else {
            completion(false, nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { completion(false, nil); return }
            let backupDate = self.newestBackupDate(backupFolder: backupFolder, systemIdentifier: systemIdentifier, gameName: gameName)
            guard let backupDate else {
                DispatchQueue.main.async { completion(false, nil) }
                return
            }
            let localDate = self.newestLocalDate(systemIdentifier: systemIdentifier, gameName: gameName)
            let backupIsNewer = backupDate > (localDate ?? .distantPast)
            os_log(.debug, log: log, "Pre-launch '%@': backup=%@, local=%@, newer=%d",
                   gameName, backupDate.description, localDate?.description ?? "none", backupIsNewer)
            DispatchQueue.main.async { completion(backupIsNewer, backupDate) }
        }
    }

    /// Copies saves for the given game from the backup folder to local OpenEmu directories.
    @objc func restoreFromBackup(
        systemIdentifier: String,
        gameName: String,
        completion: @escaping (_ success: Bool) -> Void
    ) {
        guard let backupFolder = backupFolderURL else { completion(false); return }
        let systemShort = systemIdentifier.replacingOccurrences(of: "openemu.system.", with: "")
        let safeName    = sanitizedName(gameName)
        let fm = FileManager.default

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { completion(false); return }
            var allSucceeded = true

            // Save states
            let backupStateDir = backupFolder
                .appendingPathComponent("Save States")
                .appendingPathComponent(systemShort)
                .appendingPathComponent(safeName)
            if let states = try? fm.contentsOfDirectory(at: backupStateDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                for f in states where f.pathExtension.lowercased() == "oesavestate" {
                    if let local = self.localURL(for: f, backupFolder: backupFolder) {
                        if !self.copyFile(from: f, to: local, direction: "←") { allSucceeded = false }
                    }
                }
            }

            // Battery saves — search {backup}/{core}/Battery Saves/ for all cores
            if let coreDirs = try? fm.contentsOfDirectory(at: backupFolder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
                for coreDir in coreDirs {
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: coreDir.path, isDirectory: &isDir)
                    guard isDir.boolValue else { continue }
                    let bsDir = coreDir.appendingPathComponent("Battery Saves")
                    guard fm.fileExists(atPath: bsDir.path),
                          let files = try? fm.contentsOfDirectory(at: bsDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { continue }
                    for f in files where f.deletingPathExtension().lastPathComponent == safeName {
                        if let local = self.localURL(for: f, backupFolder: backupFolder) {
                            if !self.copyFile(from: f, to: local, direction: "←") { allSucceeded = false }
                        }
                    }
                }
            }

            DispatchQueue.main.async { completion(allSucceeded) }
        }
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
        var candidate = url
        while candidate.pathComponents.count > 1 {
            if candidate.pathExtension.lowercased() == "oesavestate" { return candidate }
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate { break }
            candidate = parent
        }
        return url.pathExtension.isEmpty ? nil : url
    }

    // MARK: - Date helpers

    private func newestBackupDate(backupFolder: URL, systemIdentifier: String, gameName: String) -> Date? {
        let systemShort = systemIdentifier.replacingOccurrences(of: "openemu.system.", with: "")
        let safeName    = sanitizedName(gameName)
        let fm = FileManager.default
        var dates: [Date] = []

        // Save states
        let stateDir = backupFolder
            .appendingPathComponent("Save States")
            .appendingPathComponent(systemShort)
            .appendingPathComponent(safeName)
        if let states = try? fm.contentsOfDirectory(at: stateDir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) {
            for f in states where f.pathExtension.lowercased() == "oesavestate" {
                if let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate { dates.append(d) }
            }
        }

        // Battery saves
        if let coreDirs = try? fm.contentsOfDirectory(at: backupFolder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
            for coreDir in coreDirs {
                var isDir: ObjCBool = false
                fm.fileExists(atPath: coreDir.path, isDirectory: &isDir)
                guard isDir.boolValue else { continue }
                let bsDir = coreDir.appendingPathComponent("Battery Saves")
                guard fm.fileExists(atPath: bsDir.path),
                      let files = try? fm.contentsOfDirectory(at: bsDir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else { continue }
                for f in files where f.deletingPathExtension().lastPathComponent == safeName {
                    if let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate { dates.append(d) }
                }
            }
        }
        return dates.max()
    }

    private func newestLocalDate(systemIdentifier: String, gameName: String) -> Date? {
        let systemShort = systemIdentifier.replacingOccurrences(of: "openemu.system.", with: "")
        let safeName    = sanitizedName(gameName)
        let supportDir  = URL.oeApplicationSupportDirectory
        let fm = FileManager.default
        var dates: [Date] = []

        // Save states
        let stateDir = supportDir
            .appendingPathComponent("Save States")
            .appendingPathComponent(systemShort)
            .appendingPathComponent(safeName)
        if let states = try? fm.contentsOfDirectory(at: stateDir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) {
            for f in states where f.pathExtension.lowercased() == "oesavestate" {
                if let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate { dates.append(d) }
            }
        }

        // Battery saves
        if let coreDirs = try? fm.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
            for coreDir in coreDirs {
                let bsDir = coreDir.appendingPathComponent("Battery Saves")
                guard fm.fileExists(atPath: bsDir.path),
                      let files = try? fm.contentsOfDirectory(at: bsDir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else { continue }
                for f in files where f.deletingPathExtension().lastPathComponent == safeName {
                    if let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate { dates.append(d) }
                }
            }
        }
        return dates.max()
    }
}
