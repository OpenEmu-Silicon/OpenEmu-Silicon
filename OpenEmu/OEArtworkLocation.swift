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

/// Where the artwork folder lives, and how to move it without risking a single picture.
///
/// A move copies every file to the new place and checks each copy byte for byte. The store is then held still for
/// the few files that changed meanwhile, the indexes are merged, and the app switches. The old folder is left as it
/// was, and nothing in the new folder is overwritten: a file that clashes is kept next to the incoming one.
enum OEArtworkLocation {

    static let defaultsKey = "OEArtworkFolderPath"

    /// The folder in use: the one chosen in Preferences, or the default.
    static var chosenRoot: URL {
        if let path = UserDefaults.standard.string(forKey: defaultsKey) {
            let expanded = (path as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded, isDirectory: true) }
        }
        return OEArtworkStore.defaultRoot
    }

    enum Problem: Error, Equatable {
        case sameFolder
        /// The new folder is inside the current one, or the other way round, and copying would loop.
        case nested
        case notWritable
        /// Files that are already in the new folder with different contents. Nothing was copied.
        case conflict([String])
        case copyFailed(String)
        /// A copy that does not match its original. Nothing was switched.
        case verifyFailed(String)
    }

    enum Warning: Equatable {
        case network
        case iCloud
    }

    /// What to do when the new folder already holds a different file with the same name.
    enum OnClash {
        /// Stop before anything is copied.
        case refuse
        /// Copy the incoming file beside it under another name.
        case keepBoth
    }

    struct Copied: Equatable {
        var count = 0
        /// Incoming files that were kept beside a clashing one, by relative path.
        var renamed = [String: String]()
    }

    // MARK: Warnings

    /// Reasons to think twice about a folder: a network share can disappear mid-game, and iCloud may keep files
    /// out of reach until they are downloaded. Looks at the disk, so call it off the main thread.
    static func warnings(for folder: URL) -> [Warning] {
        var found = [Warning]()
        if isInCloudFolder(canonicalPath(folder)) || isInCloudFolder(folder.standardizedFileURL.path) { found.append(.iCloud) }
        var probe = folder.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        if let local = try? probe.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal, !local { found.append(.network) }
        return found
    }

    static func isInCloudFolder(_ path: String) -> Bool {
        path.contains("/Library/Mobile Documents/") || path.contains("/Library/CloudStorage/")
    }

    // MARK: Paths

    /// A path with symlinks resolved as far as the folder exists, for telling whether two folders overlap. Lowercased,
    /// because the usual Mac disk ignores case; the cost on a case-sensitive disk is only a needless refusal.
    static func canonicalPath(_ url: URL) -> String {
        let fm = FileManager.default
        var existing = url.standardizedFileURL
        var tail = [String]()
        while !fm.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            tail.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        tail.forEach { resolved.appendPathComponent($0) }
        return resolved.path.lowercased()
    }

    /// Every file under `root` as a relative path with the real file behind it. Links to files and folders are
    /// followed, so what the app can read is what is copied.
    static func listFiles(in root: URL) -> (files: [(rel: String, real: URL)], unreadable: [String]) {
        let fm = FileManager.default
        var files = [(rel: String, real: URL)](), unreadable = [String]()
        var visited = Set<String>()

        func walk(_ folder: URL, _ prefix: String) {
            let real = folder.resolvingSymlinksInPath().path
            guard visited.insert(real).inserted else { return }   // a link back to a folder already walked
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { unreadable.append(prefix.isEmpty ? "." : prefix); return }
            for name in names.sorted() {
                let url = folder.appendingPathComponent(name)
                let rel = prefix.isEmpty ? name : prefix + "/" + name
                let resolved = url.resolvingSymlinksInPath()
                var isFolder: ObjCBool = false
                guard fm.fileExists(atPath: resolved.path, isDirectory: &isFolder) else { unreadable.append(rel); continue }   // a broken link
                if isFolder.boolValue { walk(url, rel) } else { files.append((rel, resolved)) }
            }
        }
        // A folder that does not exist yet is an empty library, not a failure.
        if fm.fileExists(atPath: root.path) { walk(root, "") }
        return (files, unreadable)
    }

    // MARK: Copying

    /// Copies every file under `source` into `destination` and checks each copy. Returns how many files were copied.
    /// Files already there with the same contents are skipped. With `.refuse`, files there with different contents
    /// stop the whole thing before anything is copied. `source` is never changed.
    static func copyAndVerify(from source: URL, to destination: URL, onClash: OnClash = .refuse) -> Result<Int, Problem> {
        copy(from: source, to: destination, onClash: onClash, skipIndex: false).map { $0.count }
    }

    static func copy(from source: URL, to destination: URL, onClash: OnClash, skipIndex: Bool, renamed known: [String: String] = [:]) -> Result<Copied, Problem> {
        let fm = FileManager.default
        let from = source.standardizedFileURL
        let to = destination.standardizedFileURL
        let fromKey = canonicalPath(from), toKey = canonicalPath(to)
        if fromKey == toKey { return .failure(.sameFolder) }
        if toKey.hasPrefix(fromKey + "/") || fromKey.hasPrefix(toKey + "/") { return .failure(.nested) }

        do { try fm.createDirectory(at: to, withIntermediateDirectories: true) } catch { return .failure(.notWritable) }
        guard fm.isWritableFile(atPath: to.path) else { return .failure(.notWritable) }

        let listing = listFiles(in: from)
        if let first = listing.unreadable.first { return .failure(.copyFailed(first)) }
        let files = listing.files.filter { !(skipIndex && $0.rel == OEArtworkStore.indexName) }

        // Where each file goes: its own name, or beside a different file already there.
        var result = Copied()
        var target = [String: String]()
        var clashes = [String]()
        for (rel, real) in files {
            if let earlier = known[rel], fm.fileExists(atPath: to.appendingPathComponent(earlier).path),
               fm.contentsEqual(atPath: real.path, andPath: to.appendingPathComponent(earlier).path) {
                target[rel] = earlier; result.renamed[rel] = earlier; continue
            }
            let existing = to.appendingPathComponent(rel)
            if fm.fileExists(atPath: existing.path), !fm.contentsEqual(atPath: real.path, andPath: existing.path) {
                clashes.append(rel)
                if onClash == .keepBoth { let other = keepBothName(rel, in: to); target[rel] = other; result.renamed[rel] = other }
            } else {
                target[rel] = rel
            }
        }
        if onClash == .refuse, !clashes.isEmpty { return .failure(.conflict(clashes)) }

        for (rel, real) in files {
            guard let name = target[rel] else { continue }
            let copy = to.appendingPathComponent(name)
            if fm.fileExists(atPath: copy.path) { continue }
            guard fm.fileExists(atPath: real.path) else { continue }   // moved away while copying; the last pass picks it up
            do {
                try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: real, to: copy)
            } catch { return .failure(.copyFailed(rel)) }
            result.count += 1
        }
        for (rel, real) in files {
            guard let name = target[rel], fm.fileExists(atPath: real.path) else { continue }
            if !fm.contentsEqual(atPath: real.path, andPath: to.appendingPathComponent(name).path) { return .failure(.verifyFailed(rel)) }
        }
        return .success(result)
    }

    /// `nes/cover/Metroid.png` -> `nes/cover/Metroid (moved).png`, or `(moved 2)` and so on.
    private static func keepBothName(_ rel: String, in folder: URL) -> String {
        let fm = FileManager.default
        let ns = rel as NSString
        let dir = ns.deletingLastPathComponent, ext = ns.pathExtension, stem = (ns.lastPathComponent as NSString).deletingPathExtension
        var n = 1
        while true {
            let label = n == 1 ? "moved" : "moved \(n)"
            let name = stem + " (\(label))" + (ext.isEmpty ? "" : "." + ext)
            let candidate = dir.isEmpty ? name : dir + "/" + name
            if !fm.fileExists(atPath: folder.appendingPathComponent(candidate).path) { return candidate }
            n += 1
        }
    }

    // MARK: Moving

    /// Moves the artwork folder: copy and check while the app keeps working, then a short pause for the files that
    /// changed meanwhile and the index, then switch. The old folder stays where it is.
    static func move(to destination: URL) -> Result<Int, Problem> {
        let old = OEArtworkStore.shared
        old.flush()
        let first = copy(from: old.root, to: destination, onClash: .keepBoth, skipIndex: true)
        guard case .success(let bulk) = first else { return first.map { $0.count } }

        let next = OEArtworkStore(root: destination.standardizedFileURL)
        var finishing: Result<Copied, Problem> = .success(bulk)
        let handedOver = old.handOver(to: next) {
            finishing = copy(from: old.root, to: destination, onClash: .keepBoth, skipIndex: true, renamed: bulk.renamed)
            if case .success(let last) = finishing { return last.renamed }
            return nil
        }
        guard handedOver, case .success(let last) = finishing else {
            if case .failure(let problem) = finishing { return .failure(problem) }
            return .failure(.copyFailed(OEArtworkStore.indexName))
        }
        UserDefaults.standard.set(destination.standardizedFileURL.path, forKey: defaultsKey)
        OEArtworkStore.install(next)
        return .success(bulk.count + last.count)
    }
}
