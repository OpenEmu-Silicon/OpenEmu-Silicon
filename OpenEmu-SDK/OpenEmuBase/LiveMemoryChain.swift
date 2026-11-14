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

/// A running game's memory, as an outside tool sees it. The helper wraps `OEGameCore`
/// in one of these; the tests use a fake.
///
/// Every call must happen inside `-[OEGameCore performLiveMemoryTransaction:]`.
public protocol LiveMemory {
    /// The platform of the loaded game ("GB", "GBC", "GBA", ...), or nil if unsupported.
    var platform: String? { get }
    /// The names of the memory areas that can be read and written.
    var areaNames: [String] { get }
    /// The size of an area in bytes, or nil if the area is unknown.
    func size(of area: String) -> Int?
    /// Bytes from an area, with bytes past the end read as 0. Nil if the area is unknown.
    func read(_ area: String, at address: UInt64, count: Int) -> [UInt8]?
    /// Writes bytes into an area, ignoring bytes past the end. False if the area is unknown.
    func write(_ area: String, at address: UInt64, bytes: [UInt8]) -> Bool
}

/// One step in a list of memory requests. Every client protocol (BizHawk Client, PolyEmu, ...)
/// turns its messages into these, so the rules for running them live in one place.
public enum LiveMemoryOperation: Equatable {
    case noop
    case platform
    case areaSize(String)
    case read(area: String, address: UInt64, count: Int)
    case write(area: String, address: UInt64, bytes: [UInt8])
    /// If the memory does not match `expected`, nothing after this step runs.
    case `guard`(area: String, address: UInt64, expected: [UInt8])
    case message(String)
    case lock
    case unlock
}

public enum LiveMemoryResult: Equatable {
    /// The step ran and has nothing to report (no-op, write, message, lock, unlock).
    case done
    case platform(String?)
    case areaSize(Int)
    case bytes([UInt8])
    case guardChecked(passed: Bool, address: UInt64)
    /// The step did not run because the guard at `guardAddress` failed earlier in the list.
    case skipped(guardAddress: UInt64)
    case unknownArea(String)
}

public struct LiveMemoryChainOutcome: Equatable {
    /// One result per operation, in the same order.
    public var results: [LiveMemoryResult]
    /// True if the list asked to stop the game, false if it asked to start it again, nil if neither.
    /// When a list does both, the last one wins.
    public var lockRequest: Bool?
    /// Text the list asked to show the player.
    public var messages: [String]
}

public enum LiveMemoryChain {

    /// Largest single read. Far above anything a client asks for; it only stops a bad
    /// request from allocating gigabytes.
    public static let maximumReadCount = 1 << 24

    /// Runs the operations in order. After a guard fails, the rest are skipped.
    public static func run(_ operations: [LiveMemoryOperation], on memory: LiveMemory) -> LiveMemoryChainOutcome {
        var outcome = LiveMemoryChainOutcome(results: [], lockRequest: nil, messages: [])
        outcome.results.reserveCapacity(operations.count)
        var failedGuardAddress: UInt64?

        for operation in operations {
            if let address = failedGuardAddress {
                outcome.results.append(.skipped(guardAddress: address))
                continue
            }

            switch operation {
            case .noop:
                outcome.results.append(.done)

            case .platform:
                outcome.results.append(.platform(memory.platform))

            case .areaSize(let area):
                if let size = memory.size(of: area) {
                    outcome.results.append(.areaSize(size))
                } else {
                    outcome.results.append(.unknownArea(area))
                }

            case .read(let area, let address, let count):
                let count = min(max(count, 0), maximumReadCount)
                if let bytes = memory.read(area, at: address, count: count) {
                    outcome.results.append(.bytes(bytes))
                } else {
                    outcome.results.append(.unknownArea(area))
                }

            case .write(let area, let address, let bytes):
                if memory.write(area, at: address, bytes: bytes) {
                    outcome.results.append(.done)
                } else {
                    outcome.results.append(.unknownArea(area))
                }

            case .guard(let area, let address, let expected):
                guard let actual = memory.read(area, at: address, count: expected.count) else {
                    // An area that does not exist cannot match, so treat it as a failed guard.
                    outcome.results.append(.unknownArea(area))
                    failedGuardAddress = address
                    continue
                }
                let passed = actual == expected
                outcome.results.append(.guardChecked(passed: passed, address: address))
                if !passed {
                    failedGuardAddress = address
                }

            case .message(let text):
                outcome.messages.append(text)
                outcome.results.append(.done)

            case .lock:
                outcome.lockRequest = true
                outcome.results.append(.done)

            case .unlock:
                outcome.lockRequest = false
                outcome.results.append(.done)
            }
        }

        return outcome
    }
}
