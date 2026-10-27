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

class CoverArtSyncTests: XCTestCase {

    /// Asking for cover art from many threads at once must never lock the app up. With the old
    /// lock-on-the-thread code this deadlocked within a second.
    func testRepeatedCoverArtRequestsFromManyThreadsDoNotDeadlock() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenEmu-CoverArtSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Loading a library remembers its path; put the real one back so the app doesn't ask for a library later.
        let savedPath = UserDefaults.standard.object(forKey: OELibraryDatabase.databasePathKey)
        defer { UserDefaults.standard.set(savedPath, forKey: OELibraryDatabase.databasePathKey) }

        try OELibraryDatabase.load(from: folder)
        let database = try XCTUnwrap(OELibraryDatabase.default)

        // The bug only shows once a lookup thread has finished and is being replaced, so ask in
        // rounds with a pause in between to let each one finish.
        let finished = expectation(description: "all cover art requests returned")
        DispatchQueue.global().async {
            for _ in 0..<150 {
                let group = DispatchGroup()
                for _ in 0..<8 {
                    DispatchQueue.global().async(group: group) {
                        for _ in 0..<50 { database.startOpenVGDBSync() }
                    }
                }
                group.wait()
                Thread.sleep(forTimeInterval: 0.03)
            }
            finished.fulfill()
        }

        wait(for: [finished], timeout: 30)
    }
}
