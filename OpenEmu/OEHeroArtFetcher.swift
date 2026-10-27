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

    func heroArt(md5: String, displayName: String) async -> NSImage? {
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
                cacheToDisk(img, path: cachedPath)
                return ImageBox(img)
            }

            return ImageBox(nil)
        }

        inFlight[md5] = task
        return await task.value.image
    }

    func iconArt(md5: String, displayName: String) async -> NSImage? {
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
                cacheToDisk(img, path: cachedPath)
                return ImageBox(img)
            }
            return ImageBox(nil)
        }
        iconInFlight[md5] = task
        return await task.value.image
    }

    func gridArt(md5: String, displayName: String) async -> NSImage? {
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
            cacheToDisk(img, path: cachedPath)
            return ImageBox(img)
        }
        gridInFlight[md5] = task
        return await task.value.image
    }

    func setHeroArt(url: URL, forMD5 md5: String) async -> NSImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let img = NSImage(data: data) else { return nil }
        let cachedPath = cacheDir.appendingPathComponent("\(md5).png")
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
