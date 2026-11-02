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

import AppKit
import os.log
import OpenEmuKit

/// Fetches and disk-caches wide background hero images from SteamGridDB.
/// Falls back gracefully — if no hero art is found the hero shows a clean black background.
///
/// Cache location: ~/Library/Application Support/OpenEmu/HeroArt/{MD5}.png
actor OEHeroArtFetcher {

    static let shared = OEHeroArtFetcher()

    private let cacheDir: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("OpenEmu/HeroArt", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let iconCacheDir: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("OpenEmu/IconArt", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let logoCacheDir: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("OpenEmu/LogoArt", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let gridCacheDir: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("OpenEmu/GridArt", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private final class ImageBox: @unchecked Sendable {
        let image: NSImage?
        init(_ image: NSImage?) { self.image = image }
    }

    private var inFlight: [String: Task<ImageBox, Never>] = [:]
    private var iconInFlight: [String: Task<ImageBox, Never>] = [:]
    private var gridInFlight: [String: Task<ImageBox, Never>] = [:]
    private var logoInFlight: [String: Task<ImageBox, Never>] = [:]

    func heroArt(md5: String, displayName: String, game: OEArtworkStore.Game? = nil) async -> NSImage? {
        guard !md5.isEmpty else { return nil }

        let cachedPath = cacheDir.appendingPathComponent("\(md5).png")
        if FileManager.default.fileExists(atPath: cachedPath.path),
           let img = NSImage(contentsOf: cachedPath) {
            return img
        }

        if let existing = inFlight[md5] {
            return await existing.value.image
        }

        let task = Task<ImageBox, Never> {
            defer { inFlight.removeValue(forKey: md5) }

            guard !displayName.isEmpty else { return ImageBox(nil) }

            if let id = await SteamGridDBClient.shared.gameID(for: displayName),
               let artURL = await SteamGridDBClient.shared.heroURL(for: id),
               let (data, _) = try? await URLSession.shared.data(from: artURL),
               let img = NSImage(data: data) {
                OEArtworkOriginals.save(data, provider: "steamgriddb", md5: md5, slot: "hero", game: game)
                cacheToDisk(img, path: cachedPath)
                return ImageBox(img)
            }

            return ImageBox(nil)
        }

        inFlight[md5] = task
        return await task.value.image
    }

    func iconArt(md5: String, displayName: String, game: OEArtworkStore.Game? = nil) async -> NSImage? {
        guard !md5.isEmpty else { return nil }
        let cachedPath = iconCacheDir.appendingPathComponent("\(md5).png")
        if FileManager.default.fileExists(atPath: cachedPath.path),
           let img = NSImage(contentsOf: cachedPath) { return img }
        if let existing = iconInFlight[md5] { return await existing.value.image }
        let task = Task<ImageBox, Never> {
            defer { iconInFlight.removeValue(forKey: md5) }
            guard !displayName.isEmpty else { return ImageBox(nil) }
            if let id = await SteamGridDBClient.shared.gameID(for: displayName),
               let artURL = await SteamGridDBClient.shared.iconURL(for: id),
               let (data, _) = try? await URLSession.shared.data(from: artURL),
               let img = NSImage(data: data) {
                OEArtworkOriginals.save(data, provider: "steamgriddb", md5: md5, slot: "icon", game: game)
                cacheToDisk(img, path: cachedPath)
                return ImageBox(img)
            }
            return ImageBox(nil)
        }
        iconInFlight[md5] = task
        return await task.value.image
    }

    /// The game's title logo, cached on disk by ROM MD5.
    func logoArt(md5: String, displayName: String, game: OEArtworkStore.Game? = nil) async -> NSImage? {
        guard !md5.isEmpty else { return nil }
        let cachedPath = logoCacheDir.appendingPathComponent("\(md5).png")
        if FileManager.default.fileExists(atPath: cachedPath.path),
           let img = NSImage(contentsOf: cachedPath) { return img }
        if let existing = logoInFlight[md5] { return await existing.value.image }
        let task = Task<ImageBox, Never> {
            defer { logoInFlight.removeValue(forKey: md5) }
            guard !displayName.isEmpty else { return ImageBox(nil) }
            if let id = await SteamGridDBClient.shared.gameID(for: displayName),
               let artURL = await SteamGridDBClient.shared.logoURL(for: id),
               let (data, _) = try? await URLSession.shared.data(from: artURL),
               let img = NSImage(data: data) {
                OEArtworkOriginals.save(data, provider: "steamgriddb", md5: md5, slot: "logo", game: game)
                cacheToDisk(img, path: cachedPath)
                return ImageBox(img)
            }
            return ImageBox(nil)
        }
        logoInFlight[md5] = task
        return await task.value.image
    }

    func gridArt(md5: String, displayName: String, game: OEArtworkStore.Game? = nil) async -> NSImage? {
        guard !md5.isEmpty else { return nil }
        let cachedPath = gridCacheDir.appendingPathComponent("\(md5).png")
        if FileManager.default.fileExists(atPath: cachedPath.path),
           let img = NSImage(contentsOf: cachedPath) { return img }
        if let existing = gridInFlight[md5] { return await existing.value.image }
        let task = Task<ImageBox, Never> {
            defer { gridInFlight.removeValue(forKey: md5) }
            guard !displayName.isEmpty else { return ImageBox(nil) }
            guard let id = await SteamGridDBClient.shared.gameID(for: displayName) else {
                return ImageBox(nil)
            }
            guard let artURL = await SteamGridDBClient.shared.gridURL(for: id) else {
                return ImageBox(nil)
            }
            guard let (data, _) = try? await URLSession.shared.data(from: artURL), let img = NSImage(data: data) else {
                return ImageBox(nil)
            }
            OEArtworkOriginals.save(data, provider: "steamgriddb", md5: md5, slot: "poster", game: game)
            cacheToDisk(img, path: cachedPath)
            return ImageBox(img)
        }
        gridInFlight[md5] = task
        return await task.value.image
    }

    func setHeroArt(url: URL, forMD5 md5: String, game: OEArtworkStore.Game? = nil) async -> NSImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let img = NSImage(data: data) else { return nil }
        let cachedPath = cacheDir.appendingPathComponent("\(md5).png")
        OEArtworkOriginals.save(data, provider: "steamgriddb", md5: md5, slot: "hero", game: game)
        cacheToDisk(img, path: cachedPath)
        return img
    }

    // MARK: - Private

    private func cacheToDisk(_ image: NSImage, path: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: path)
    }
}

/// Keeps the exact bytes a provider sent, before anything decodes or re-saves them.
///
/// `~/Library/Application Support/OpenEmu/Artwork Originals/<provider>/<md5>-<slot>.<ext>`
///
/// Nothing here is ever replaced or deleted: a file that already exists is left alone, so a later fetch from the same
/// provider cannot change what was kept. The picture caches (`OEBigPictureArtStore` and the folders `OEHeroArtFetcher`
/// fills) are rebuilt from re-encoded copies; this is the only place the downloads are kept as they arrived.
enum OEArtworkOriginals {

    static let folderName = "Artwork Originals"

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenEmu", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// The file extension for what the bytes actually are, whatever the address said.
    static func fileExtension(for data: Data) -> String {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if head.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if head.starts(with: [0x00, 0x00, 0x01, 0x00]) { return "ico" }   // SteamGridDB icons
        if head.count >= 12, head.starts(with: [0x52, 0x49, 0x46, 0x46]), Array(head[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        return "img"
    }

    /// Writes `data` unless this provider already has a file for this game and slot. Returns the file that now holds it,
    /// or nil when nothing could be written. Safe to call from any thread.
    @discardableResult
    static func save(_ data: Data, provider: String, md5: String, slot: String, game: OEArtworkStore.Game? = nil, in root: URL = directory) -> URL? {
        // The artwork folder keeps the same bytes under the game's name, where a person can find them.
        if let game = game, let artSlot = OEArtworkStore.Slot(rawValue: slot) {
            OEArtworkStore.shared.supply(data, for: game, slot: artSlot, origin: .provider(provider), preferred: OEBigPictureArtSource.preferredID == provider)
        }
        let safe = { (text: String) in text.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }
        let provider = safe(provider), md5 = safe(md5), slot = safe(slot)
        guard !data.isEmpty, !provider.isEmpty, !md5.isEmpty, !slot.isEmpty else { return nil }

        let fm = FileManager.default
        let folder = root.appendingPathComponent(provider, isDirectory: true)
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return nil }

        let prefix = "\(md5)-\(slot)."
        if let names = try? fm.contentsOfDirectory(atPath: folder.path),
           let kept = names.first(where: { $0.hasPrefix(prefix) }) {
            return folder.appendingPathComponent(kept)
        }

        let url = folder.appendingPathComponent(prefix + fileExtension(for: data))
        do { try data.write(to: url, options: .withoutOverwriting) } catch { return nil }
        return url
    }
}
