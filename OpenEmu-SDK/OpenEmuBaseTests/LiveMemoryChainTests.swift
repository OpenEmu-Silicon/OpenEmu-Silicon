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

// Tests for LiveMemoryChain, the shared rules every Archipelago adapter relies on:
// steps run in order, and once a guard fails nothing after it touches memory.

import XCTest
@testable import OpenEmuBase

/// In-memory stand-in for a running core.
final class FakeLiveMemory: LiveMemory {
    var platform: String?
    var areas: [String: [UInt8]]

    init(platform: String? = "GB", areas: [String: [UInt8]]) {
        self.platform = platform
        self.areas = areas
    }

    var areaNames: [String] { areas.keys.sorted() }

    func size(of area: String) -> Int? {
        areas[area]?.count
    }

    func read(_ area: String, at address: UInt64, count: Int) -> [UInt8]? {
        guard let memory = areas[area] else { return nil }
        return (0..<count).map { i in
            let index = address + UInt64(i)
            return index < UInt64(memory.count) ? memory[Int(index)] : 0
        }
    }

    func write(_ area: String, at address: UInt64, bytes: [UInt8]) -> Bool {
        guard var memory = areas[area] else { return false }
        for (i, byte) in bytes.enumerated() {
            let index = address + UInt64(i)
            if index < UInt64(memory.count) {
                memory[Int(index)] = byte
            }
        }
        areas[area] = memory
        return true
    }
}

final class LiveMemoryChainTests: XCTestCase {

    private func makeMemory() -> FakeLiveMemory {
        FakeLiveMemory(areas: ["WRAM": Array(0..<16).map(UInt8.init)])
    }

    // The developer's example: if memory matches, write two places; otherwise do nothing.

    func testPassingGuardLetsWritesLand() {
        let memory = makeMemory()
        let outcome = LiveMemoryChain.run([
            .guard(area: "WRAM", address: 2, expected: [2, 3, 4]),
            .write(area: "WRAM", address: 8, bytes: [0xAA, 0xBB]),
            .write(area: "WRAM", address: 1, bytes: [0x01]),
        ], on: memory)

        XCTAssertEqual(outcome.results, [.guardChecked(passed: true, address: 2), .done, .done])
        XCTAssertEqual(memory.areas["WRAM"]?[8], 0xAA)
        XCTAssertEqual(memory.areas["WRAM"]?[9], 0xBB)
        XCTAssertEqual(memory.areas["WRAM"]?[1], 0x01)
    }

    func testFailingGuardSkipsEverythingAfterIt() {
        let memory = makeMemory()
        let before = memory.areas
        let outcome = LiveMemoryChain.run([
            .read(area: "WRAM", address: 0, count: 2),
            .guard(area: "WRAM", address: 2, expected: [9, 9]),
            .write(area: "WRAM", address: 8, bytes: [0xAA]),
            .guard(area: "WRAM", address: 0, expected: [0]),
            .lock,
            .message("should not show"),
        ], on: memory)

        XCTAssertEqual(outcome.results, [
            .bytes([0, 1]),
            .guardChecked(passed: false, address: 2),
            .skipped(guardAddress: 2),
            .skipped(guardAddress: 2),
            .skipped(guardAddress: 2),
            .skipped(guardAddress: 2),
        ])
        XCTAssertEqual(memory.areas, before, "No write may land after a failed guard.")
        XCTAssertNil(outcome.lockRequest)
        XCTAssertEqual(outcome.messages, [])
    }

    func testGuardOnUnknownAreaCountsAsFailed() {
        let memory = makeMemory()
        let outcome = LiveMemoryChain.run([
            .guard(area: "Nope", address: 4, expected: [0]),
            .write(area: "WRAM", address: 0, bytes: [0xFF]),
        ], on: memory)

        XCTAssertEqual(outcome.results, [.unknownArea("Nope"), .skipped(guardAddress: 4)])
        XCTAssertEqual(memory.areas["WRAM"]?[0], 0)
    }

    func testReadPastEndIsPaddedWithZeros() {
        let outcome = LiveMemoryChain.run([.read(area: "WRAM", address: 14, count: 4)], on: makeMemory())
        XCTAssertEqual(outcome.results, [.bytes([14, 15, 0, 0])])
    }

    func testWritePastEndIsIgnored() {
        let memory = makeMemory()
        let outcome = LiveMemoryChain.run([.write(area: "WRAM", address: 15, bytes: [0xEE, 0xEE])], on: memory)
        XCTAssertEqual(outcome.results, [.done])
        XCTAssertEqual(memory.areas["WRAM"]?.count, 16)
        XCTAssertEqual(memory.areas["WRAM"]?[15], 0xEE)
    }

    func testUnknownAreaIsReportedNotFatal() {
        let outcome = LiveMemoryChain.run([
            .read(area: "Nope", address: 0, count: 1),
            .areaSize("Nope"),
            .write(area: "Nope", address: 0, bytes: [1]),
            .areaSize("WRAM"),
        ], on: makeMemory())

        XCTAssertEqual(outcome.results, [.unknownArea("Nope"), .unknownArea("Nope"), .unknownArea("Nope"), .areaSize(16)])
    }

    func testOneResultPerOperation() {
        let operations: [LiveMemoryOperation] = [.noop, .platform, .areaSize("WRAM"), .read(area: "WRAM", address: 0, count: 1), .lock, .unlock]
        let outcome = LiveMemoryChain.run(operations, on: makeMemory())
        XCTAssertEqual(outcome.results.count, operations.count)
        XCTAssertEqual(outcome.results[1], .platform("GB"))
    }

    func testLockAndMessagesAreReportedToTheCaller() {
        let locked = LiveMemoryChain.run([.lock, .message("Got a Master Ball")], on: makeMemory())
        XCTAssertEqual(locked.lockRequest, true)
        XCTAssertEqual(locked.messages, ["Got a Master Ball"])

        let unlocked = LiveMemoryChain.run([.lock, .unlock], on: makeMemory())
        XCTAssertEqual(unlocked.lockRequest, false, "The last lock request in a list wins.")
    }

    func testHugeReadIsCapped() {
        let outcome = LiveMemoryChain.run([.read(area: "WRAM", address: 0, count: Int.max)], on: makeMemory())
        guard case .bytes(let bytes) = outcome.results.first else { return XCTFail("Expected bytes") }
        XCTAssertEqual(bytes.count, LiveMemoryChain.maximumReadCount)
    }
}
