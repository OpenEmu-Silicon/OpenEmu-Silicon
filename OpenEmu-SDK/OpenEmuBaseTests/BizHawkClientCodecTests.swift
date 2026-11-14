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

// Tests for BizHawkClientCodec against the message shapes Archipelago's BizHawk Client
// sends (worlds/_bizhawk/__init__.py) and expects back (data/lua/connector_bizhawk_generic.lua).

import XCTest
@testable import OpenEmuBase

final class BizHawkClientCodecTests: XCTestCase {

    private let codec = BizHawkClientCodec(romHash: "ABC123")

    private func makeMemory() -> FakeLiveMemory {
        FakeLiveMemory(platform: "GBC", areas: [
            "ROM": Array(repeating: 0x11, count: 32),
            "WRAM": Array(0..<16).map(UInt8.init),
        ])
    }

    /// Sends one line through the codec the way the helper does, and returns the reply as JSON objects.
    private func send(_ line: String, to memory: FakeLiveMemory) throws -> [[String: Any]] {
        let reply: String
        switch codec.decode(line) {
        case .reply(let text):
            reply = text
        case .run(let request):
            let outcome = LiveMemoryChain.run(request.operations, on: memory)
            reply = codec.encode(request, results: outcome.results)
        }
        XCTAssertFalse(reply.contains("\n"), "Each reply must be a single line.")
        let objects = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [[String: Any]]
        return try XCTUnwrap(objects)
    }

    private func base64(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
    }

    func testVersionHandshake() {
        guard case .reply(let text) = codec.decode("VERSION") else { return XCTFail("VERSION must get a direct reply") }
        XCTAssertEqual(text, "1")
    }

    func testStartupRequests() throws {
        let replies = try send(#"[{"type":"PING"},{"type":"SYSTEM"},{"type":"HASH"},{"type":"PREFERRED_CORES"},{"type":"MEMORY_SIZE","domain":"ROM"}]"#, to: makeMemory())

        XCTAssertEqual(replies.count, 5)
        XCTAssertEqual(replies[0]["type"] as? String, "PONG")
        XCTAssertEqual(replies[1]["type"] as? String, "SYSTEM_RESPONSE")
        XCTAssertEqual(replies[1]["value"] as? String, "GBC")
        XCTAssertEqual(replies[2]["type"] as? String, "HASH_RESPONSE")
        XCTAssertEqual(replies[2]["value"] as? String, "ABC123")
        XCTAssertEqual(replies[3]["type"] as? String, "PREFERRED_CORES_RESPONSE")
        XCTAssertEqual((replies[3]["value"] as? [String: Any])?.count, 0)
        XCTAssertEqual(replies[4]["type"] as? String, "MEMORY_SIZE_RESPONSE")
        XCTAssertEqual(replies[4]["value"] as? Int, 32)
    }

    func testReadReturnsBase64() throws {
        let replies = try send(#"[{"type":"READ","domain":"WRAM","address":3,"size":4}]"#, to: makeMemory())
        XCTAssertEqual(replies[0]["type"] as? String, "READ_RESPONSE")
        XCTAssertEqual(replies[0]["value"] as? String, base64([3, 4, 5, 6]))
    }

    // What guarded_write sends: every guard first, then the writes.

    func testGuardedWriteWithMatchingGuard() throws {
        let memory = makeMemory()
        let line = #"[{"type":"GUARD","domain":"WRAM","address":2,"expected_data":"\#(base64([2, 3]))"},"#
            + #"{"type":"WRITE","domain":"WRAM","address":10,"value":"\#(base64([0xAB, 0xCD]))"}]"#
        let replies = try send(line, to: memory)

        XCTAssertEqual(replies[0]["type"] as? String, "GUARD_RESPONSE")
        XCTAssertEqual(replies[0]["value"] as? Bool, true)
        XCTAssertEqual(replies[0]["address"] as? Int, 2)
        XCTAssertEqual(replies[1]["type"] as? String, "WRITE_RESPONSE")
        XCTAssertEqual(Array(memory.areas["WRAM"]![10...11]), [0xAB, 0xCD])
    }

    func testFailedGuardRepeatsItsReplyAndWritesNothing() throws {
        let memory = makeMemory()
        let before = memory.areas
        let line = #"[{"type":"GUARD","domain":"WRAM","address":2,"expected_data":"\#(base64([9]))"},"#
            + #"{"type":"WRITE","domain":"WRAM","address":10,"value":"\#(base64([0xAB]))"},"#
            + #"{"type":"PING"}]"#
        let replies = try send(line, to: memory)

        XCTAssertEqual(replies.count, 3, "One reply per request, even when skipped.")
        for reply in replies {
            XCTAssertEqual(reply["type"] as? String, "GUARD_RESPONSE")
            XCTAssertEqual(reply["value"] as? Bool, false)
            XCTAssertEqual(reply["address"] as? Int, 2)
        }
        XCTAssertEqual(memory.areas, before)
    }

    func testLockUnlockMessageAndInterval() throws {
        let replies = try send(#"[{"type":"LOCK"},{"type":"UNLOCK"},{"type":"DISPLAY_MESSAGE","message":"Hi"},{"type":"SET_MESSAGE_INTERVAL","value":1.5}]"#, to: makeMemory())
        XCTAssertEqual(replies.map { $0["type"] as? String }, ["LOCKED", "UNLOCKED", "DISPLAY_MESSAGE_RESPONSE", "SET_MESSAGE_INTERVAL_RESPONSE"])
    }

    func testUnknownTypeAndUnknownDomainAreErrors() throws {
        let replies = try send(#"[{"type":"DANCE"},{"type":"READ","domain":"Nope","address":0,"size":1}]"#, to: makeMemory())
        XCTAssertEqual(replies[0]["type"] as? String, "ERROR")
        XCTAssertEqual(replies[0]["err"] as? String, "Unknown command: DANCE")
        XCTAssertEqual(replies[1]["type"] as? String, "ERROR")
    }

    func testReadPastEndOfRomIsDataNotAnError() throws {
        // Castlevania 64 reads beyond the end of small ROMs while checking the header.
        let replies = try send(#"[{"type":"READ","domain":"ROM","address":30,"size":4}]"#, to: makeMemory())
        XCTAssertEqual(replies[0]["type"] as? String, "READ_RESPONSE")
        XCTAssertEqual(replies[0]["value"] as? String, base64([0x11, 0x11, 0, 0]))
    }

    func testBadLineGetsAnErrorReply() throws {
        let replies = try send("not json", to: makeMemory())
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0]["type"] as? String, "ERROR")
    }

    func testNoGameReportsNullSystem() throws {
        let memory = FakeLiveMemory(platform: nil, areas: [:])
        let replies = try send(#"[{"type":"SYSTEM"}]"#, to: memory)
        XCTAssertEqual(replies[0]["value"] as? String, "NULL")
    }
}
