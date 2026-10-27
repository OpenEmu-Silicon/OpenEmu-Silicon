// Copyright (c) 2021, OpenEmu Team
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

extension XCTestCase {
    /// Returns the app's library, creating a throwaway one first if the test host did not load any.
    /// A host started by `xcodebuild test` on a fresh machine (CI) has no library, and force-unwrapping
    /// `OELibraryDatabase.default` there crashes the whole test run.
    /// The saved library path is restored so the debug app does not keep pointing at the temporary folder.
    @discardableResult
    func ensureTestLibrary() throws -> OELibraryDatabase {
        if let existing = OELibraryDatabase.default { return existing }
        let defaults = UserDefaults.standard
        let savedPath = defaults.object(forKey: OELibraryDatabase.databasePathKey)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenEmu-TestLibrary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            if let savedPath { defaults.set(savedPath, forKey: OELibraryDatabase.databasePathKey) }
            else { defaults.removeObject(forKey: OELibraryDatabase.databasePathKey) }
        }
        try OELibraryDatabase.load(from: folder)
        return try XCTUnwrap(OELibraryDatabase.default, "Could not create a test library")
    }
}

class ROMImporterTests: XCTestCase {

    func testDreamcastGDIContentHashUsesReferencedTracks() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenEmu-GDIHashTests-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let firstGDI = try makeDreamcastGDITestFolder(at: rootURL.appendingPathComponent("Crazy Taxi", isDirectory: true), trackPayload: "crazy taxi")
        let secondGDI = try makeDreamcastGDITestFolder(at: rootURL.appendingPathComponent("18 Wheeler", isDirectory: true), trackPayload: "18 wheeler")

        XCTAssertEqual(try FileManager.default.hashFile(at: firstGDI), try FileManager.default.hashFile(at: secondGDI))
        XCTAssertNotEqual(ImportOperation.dreamcastGDIContentHash(at: firstGDI), ImportOperation.dreamcastGDIContentHash(at: secondGDI))
    }

    func testDreamcastGDIContentHashMatchesIdenticalTrackContent() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenEmu-GDIHashTests-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let firstGDI = try makeDreamcastGDITestFolder(at: rootURL.appendingPathComponent("First", isDirectory: true), trackPayload: "same game")
        let secondGDI = try makeDreamcastGDITestFolder(at: rootURL.appendingPathComponent("Second", isDirectory: true), trackPayload: "same game")

        XCTAssertEqual(ImportOperation.dreamcastGDIContentHash(at: firstGDI), ImportOperation.dreamcastGDIContentHash(at: secondGDI))
    }

    private func makeDreamcastGDITestFolder(at folderURL: URL, trackPayload: String) throws -> URL {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let gdiURL = folderURL.appendingPathComponent("disc.gdi")
        let descriptor = """
        3
        1 0 4 2048 track01.bin 0
        2 450 0 2352 track02.raw 0
        3 45150 4 2048 track03.bin 0
        """
        try descriptor.write(to: gdiURL, atomically: true, encoding: .utf8)
        try "common metadata".data(using: .utf8)!.write(to: folderURL.appendingPathComponent("track01.bin"))
        try trackPayload.data(using: .utf8)!.write(to: folderURL.appendingPathComponent("track02.raw"))
        try "more common metadata".data(using: .utf8)!.write(to: folderURL.appendingPathComponent("track03.bin"))

        return gdiURL
    }

    func testArchiveUnarchiveOperationQueue() throws {
        let ri = ROMImporter(database: try ensureTestLibrary())

        let data: Data!
        let url1 = URL(string: "file://url/op1")!
        let url2 = URL(string: "file://url/op2")!

        do {
            var ops: [ImportOperation] = []
            var op: ImportOperation

            op = ImportOperation(url: url1, sourceURL: url1)
            ops.append(op)

            op = ImportOperation(url: url2, sourceURL: url2)
            ops.append(op)

            data = ri._data(forOperationQueue: ops)
            XCTAssertNotNil(data)
        }

        do {
            let ops: [ImportOperation]! = ri._operationQueue(from: data)
            XCTAssertNotNil(ops)
            XCTAssertEqual(ops.count, 2)
            var op: ImportOperation

            op = ops[0]
            XCTAssertEqual(op.url.absoluteString, url1.absoluteString)
            XCTAssertEqual(op.sourceURL.absoluteString, url1.absoluteString)

            op = ops[1]
            XCTAssertEqual(op.url.absoluteString, url2.absoluteString)
            XCTAssertEqual(op.sourceURL.absoluteString, url2.absoluteString)
        }
    }
}
