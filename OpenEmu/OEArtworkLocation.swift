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
/// Moving copies every file to the new place, checks each copy byte for byte, and only then switches. The old
/// folder is left exactly as it was, and nothing in the new folder is overwritten.
enum OEArtworkLocation {

    static let defaultsKey = "OEArtworkFolderPath"

    /// The folder in use: the one chosen in Preferences, or the default.
    static var chosenRoot: URL {
        if let path = UserDefaults.standard.string(forKey: defaultsKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
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

    /// Reasons to think twice about a folder: a network share can disappear mid-game, and iCloud may keep files
    /// out of reach until they are downloaded.
    static func warnings(for folder: URL) -> [Warning] {
        var found = [Warning]()
        if isInCloudFolder(folder.standardizedFileURL.path) { found.append(.iCloud) }
        var probe = folder.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        if let local = try? probe.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal, !local { found.append(.network) }
        return found
    }

    static func isInCloudFolder(_ path: String) -> Bool {
        path.contains("/Library/Mobile Documents/") || path.contains("/Library/CloudStorage/")
    }

    /// Copies every file under `source` into `destination` and checks each copy. Returns how many files were copied.
    /// Files already there with the same contents are skipped. Files there with different contents stop the whole
    /// thing before anything is copied. `source` is never changed.
    static func copyAndVerify(from source: URL, to destination: URL) -> Result<Int, Problem> {
        let fm = FileManager.default
        let from = source.standardizedFileURL
        let to = destination.standardizedFileURL
        let fromPath = from.path, toPath = to.path
        if fromPath == toPath { return .failure(.sameFolder) }
        if toPath.hasPrefix(fromPath + "/") || fromPath.hasPrefix(toPath + "/") { return .failure(.nested) }

        do { try fm.createDirectory(at: to, withIntermediateDirectories: true) } catch { return .failure(.notWritable) }
        guard fm.isWritableFile(atPath: toPath) else { return .failure(.notWritable) }

        var files = [String]()
        if let walker = fm.enumerator(at: from, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(String(url.standardizedFileURL.path.dropFirst(fromPath.count + 1)))
            }
        }
        files.sort()

        // Look for clashes first, so a refusal leaves the new folder exactly as it was.
        let clashes = files.filter { name in
            let existing = to.appendingPathComponent(name).path
            return fm.fileExists(atPath: existing) && !fm.contentsEqual(atPath: from.appendingPathComponent(name).path, andPath: existing)
        }
        if !clashes.isEmpty { return .failure(.conflict(clashes)) }

        var copied = 0
        for name in files {
            let original = from.appendingPathComponent(name)
            let copy = to.appendingPathComponent(name)
            if fm.fileExists(atPath: copy.path) { continue }
            do {
                try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: original, to: copy)
            } catch { return .failure(.copyFailed(name)) }
            copied += 1
        }
        for name in files where !fm.contentsEqual(atPath: from.appendingPathComponent(name).path, andPath: to.appendingPathComponent(name).path) {
            return .failure(.verifyFailed(name))
        }
        return .success(copied)
    }

    /// Moves the artwork folder: copy, check, then switch. The old folder stays where it is.
    static func move(to destination: URL) -> Result<Int, Problem> {
        let current = OEArtworkStore.shared
        current.flush()
        let result = copyAndVerify(from: current.root, to: destination)
        if case .success = result {
            UserDefaults.standard.set(destination.standardizedFileURL.path, forKey: defaultsKey)
            OEArtworkStore.useRoot(destination.standardizedFileURL)
        }
        return result
    }
}
