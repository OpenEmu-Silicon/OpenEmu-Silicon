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

import XCTest
@testable import OpenEmu
@testable import OpenEmuSystem
import OpenEmuKit

/// Not a real test: builds a large library of made-up games for trying the library window at scale.
///
/// It does nothing unless `OE_SYNTHETIC_LIBRARY` names an empty folder, so it is skipped in normal test runs.
/// `Scripts/make-synthetic-library.sh` sets that up and prints how to open the library. The games have
/// generated covers, no ROM files and no saves, and nothing is written to the user's real library.
class SyntheticLibraryGenerator: XCTestCase {
    
    func testGenerateSyntheticLibrary() throws {
        guard let path = ProcessInfo.processInfo.environment["OE_SYNTHETIC_LIBRARY"], !path.isEmpty else {
            throw XCTSkip("OE_SYNTHETIC_LIBRARY is not set")
        }
        let count = Int(ProcessInfo.processInfo.environment["OE_SYNTHETIC_GAME_COUNT"] ?? "") ?? 5000
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        
        // Loading a library remembers its path; put the real one back.
        let savedPath = UserDefaults.standard.object(forKey: OELibraryDatabase.databasePathKey)
        defer { UserDefaults.standard.set(savedPath, forKey: OELibraryDatabase.databasePathKey) }
        
        try OELibraryDatabase.load(from: folder)
        let library = try XCTUnwrap(OELibraryDatabase.default)
        let context = library.mainThreadContext
        
        let identifiers = ["openemu.system.nes", "openemu.system.snes", "openemu.system.gb", "openemu.system.gba", "openemu.system.sg"]
        let systems: [OEDBSystem] = identifiers.compactMap { id in
            OESystemPlugin.allPlugins.first { $0.systemIdentifier == id }.map { OEDBSystem.system(for: $0, in: context) }
        }
        XCTAssertFalse(systems.isEmpty)
        systems.forEach { $0.isEnabled = true }
        
        // A few covers are written once and shared, so a large library does not need thousands of files.
        let covers: [[String: Any]] = (0..<24).map { index in
            let ratio: CGFloat = index % 3 == 0 ? 1.0 : 1.4
            let image = NSImage(size: NSSize(width: 280, height: 280 * ratio), flipped: false) { rect in
                NSColor(hue: CGFloat(index) / 24, saturation: 0.6, brightness: 0.85, alpha: 1).setFill()
                rect.fill()
                NSColor.white.withAlphaComponent(0.5).setFill()
                NSRect(x: 20, y: rect.height - 80, width: rect.width - 40, height: 40).fill()
                return true
            }
            return OEDBImage.prepareImage(with: image)
        }
        
        let words = ["Super", "Mega", "Turbo", "Ninja", "Dragon", "Star", "Space", "Road", "Quest", "Blade", "Pixel", "Knight",
                     "Racer", "Fighter", "Legend", "Hero", "Island", "Castle", "Galaxy", "Tales"]
        for index in 0..<count {
            let name = "\(words[index % words.count]) \(words[(index / words.count) % words.count]) \(index)"
            let game = OEDBGame.createGame(withName: name, andSystem: systems[index % systems.count], in: context)
            game.boxImage = OEDBImage.createImage(with: covers[index % covers.count], in: context)
            if index % 7 == 0 { game.rating = NSNumber(value: index % 6) }
            if index % 50 == 0 { game.status = .alert }
            if index % 400 == 0 { game.status = .processing }
            
            let rom = OEDBRom.createObject(in: context)
            rom.game = game
            rom.location = "file:///synthetic/\(index).rom"
            rom.md5 = String(format: "%032x", index)
            if index % 5 == 0 {
                rom.lastPlayed = Date(timeIntervalSinceNow: -Double(index) * 3600)
                rom.playCount = NSNumber(value: index % 40 + 1)
            }
            
            if index % 1000 == 999 { try context.save() }
        }
        try context.save()
        
        let total = try context.count(for: NSFetchRequest<OEDBGame>(entityName: OEDBGame.entityName))
        XCTAssertEqual(total, count)
    }
}
