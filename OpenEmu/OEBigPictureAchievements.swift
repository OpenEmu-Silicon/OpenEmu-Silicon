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

import SwiftUI
import OpenEmuKit

/// One RetroAchievements achievement, as the game page shows it.
struct BigPictureAchievement: Identifiable {
    let id: Int
    let title: String
    let detail: String
    let points: Int
    let earned: Bool
    let badgeURL: String?
}

/// What the last RetroAchievements session knew about one game.
struct BigPictureAchievementSummary {
    let unlocked: Int
    let total: Int
    let unlockedPoints: Int
    let totalPoints: Int
    /// Earned ones first, then the locked ones, as in the in-app list.
    let achievements: [BigPictureAchievement]
}

/// Keeps the most recent RetroAchievements session of each game, so a game's page can show its achievements when
/// no game is running. The app announces a session whenever a game with achievements runs; nothing else stores it.
@MainActor
final class OEBigPictureAchievements {

    static let shared = OEBigPictureAchievements()

    private let sessionKey = "OEBigPictureAchievementSessions"
    private let md5Key = "OEBigPictureAchievementMD5ToHash"
    private var sessionByHash = [String: [String: Any]]()
    private var hashByMD5 = [String: String]()

    private init() {
        let defaults = UserDefaults.standard
        sessionByHash = (defaults.dictionary(forKey: sessionKey) as? [String: [String: Any]]) ?? [:]
        hashByMD5 = (defaults.dictionary(forKey: md5Key) as? [String: String]) ?? [:]

        NotificationCenter.default.addObserver(forName: .OERetroAchievementsSessionDidChange, object: nil, queue: .main) { [weak self] note in
            guard let info = note.userInfo as? [String: Any] else { return }
            let md5 = (note.object as? OEGameDocument)?.rom.md5
            MainActor.assumeIsolated { self?.record(info, md5: md5) }
        }
    }

    /// Starts listening. Called once at launch, so a session played before big picture was opened is not missed.
    func start() {}

    private func record(_ info: [String: Any], md5: String?) {
        let hash = (info[OERetroAchievementsGameHashKey] as? String ?? "").lowercased()
        guard !hash.isEmpty, (info[OERetroAchievementsAchievementsKey] as? [[String: Any]])?.isEmpty == false else { return }
        sessionByHash[hash] = info
        if let md5 = md5, !md5.isEmpty { hashByMD5[md5.lowercased()] = hash }
        let defaults = UserDefaults.standard
        defaults.set(sessionByHash as NSDictionary, forKey: sessionKey)
        defaults.set(hashByMD5 as NSDictionary, forKey: md5Key)
    }

    func summary(for game: OEDBGame) -> BigPictureAchievementSummary? {
        let md5 = game.defaultROM?.md5Hash?.lowercased() ?? ""
        guard let info = sessionByHash[hashByMD5[md5] ?? md5],
              let raw = info[OERetroAchievementsAchievementsKey] as? [[String: Any]], !raw.isEmpty else { return nil }

        let all = raw.enumerated().map { index, item -> BigPictureAchievement in
            let earned = (item[OERetroAchievementsStateKey] as? NSNumber)?.intValue == 2
            return BigPictureAchievement(
                id: (item[OEAchievementIDKey] as? NSNumber)?.intValue ?? index,
                title: item[OEAchievementTitleKey] as? String ?? "Achievement",
                detail: item[OEAchievementDescriptionKey] as? String ?? "",
                points: (item[OEAchievementPointsKey] as? NSNumber)?.intValue ?? 0,
                earned: earned,
                badgeURL: (earned ? item[OEAchievementBadgeURLKey] : item[OERetroAchievementsBadgeLockedURLKey]) as? String)
        }
        let unlocked = all.filter { $0.earned }
        let locked = all.filter { !$0.earned }
        return BigPictureAchievementSummary(
            unlocked: (info[OERetroAchievementsUnlockedCountKey] as? NSNumber)?.intValue ?? unlocked.count,
            total: (info[OERetroAchievementsAchievementCountKey] as? NSNumber)?.intValue ?? all.count,
            unlockedPoints: (info[OERetroAchievementsUnlockedPointsKey] as? NSNumber)?.intValue ?? unlocked.reduce(0) { $0 + $1.points },
            totalPoints: (info[OERetroAchievementsTotalPointsKey] as? NSNumber)?.intValue ?? all.reduce(0) { $0 + $1.points },
            achievements: Array((unlocked + locked).prefix(24)))
    }
}

/// A badge image fetched from a URL, kept in memory once loaded.
final class BigPictureRemoteImages: ObservableObject {

    static let shared = BigPictureRemoteImages()
    @Published private(set) var tick = 0
    private var images = [String: NSImage]()
    private var requested = Set<String>()

    func image(_ urlString: String?) -> NSImage? { urlString.flatMap { images[$0] } }

    func load(_ urlString: String?) {
        guard let urlString = urlString, let url = URL(string: urlString), requested.insert(urlString).inserted else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                self?.images[urlString] = image
                self?.tick += 1
            }
        }.resume()
    }
}
