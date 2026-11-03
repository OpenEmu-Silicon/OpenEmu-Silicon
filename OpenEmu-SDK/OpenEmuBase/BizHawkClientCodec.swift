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

/// Translates Archipelago's BizHawk Client messages into `LiveMemoryOperation`s and the results back.
///
/// The format is the one `data/lua/connector_bizhawk_generic.lua` in Archipelago implements:
/// each line from the client is either `VERSION` or a JSON array of requests, and each reply is
/// one line. This is the only file that knows that format; the cores and `LiveMemoryChain` do not.
public struct BizHawkClientCodec {

    /// The connector script version Archipelago's client expects (`EXPECTED_SCRIPT_VERSION`).
    public static let scriptVersion = 1

    /// The ports Archipelago's client tries, in order.
    public static let ports: ClosedRange<UInt16> = 43055...43059

    /// A line split into the steps to run, plus what each reply should look like.
    public struct Request {
        public let operations: [LiveMemoryOperation]
        fileprivate let replies: [Reply]
    }

    public enum Decoded {
        /// Send this line back as is (the VERSION handshake, or a message that could not be read).
        case reply(String)
        /// Run these steps between two frames, then pass the results to `encode`.
        case run(Request)
    }

    fileprivate enum Reply {
        case pong
        case system
        case hash
        case memorySize
        case guardCheck
        case read
        case write
        case displayMessage
        case setMessageInterval
        case preferredCores
        case locked
        case unlocked
        case error(String)
    }

    /// Stable text that identifies the loaded ROM. The client only checks that it does not change.
    public let romHash: String

    public init(romHash: String) {
        self.romHash = romHash
    }

    // MARK: - Decoding

    public func decode(_ line: String) -> Decoded {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)

        if line == "VERSION" {
            return .reply(String(Self.scriptVersion))
        }

        guard let data = line.data(using: .utf8),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else {
            return .reply(Self.encodeLine([Self.errorObject("Could not read request: expected a JSON array")]))
        }

        var operations: [LiveMemoryOperation] = []
        var replies: [Reply] = []
        operations.reserveCapacity(list.count)
        replies.reserveCapacity(list.count)

        for item in list {
            let (operation, reply) = Self.decodeRequest(item as? [String: Any] ?? [:])
            operations.append(operation)
            replies.append(reply)
        }

        return .run(Request(operations: operations, replies: replies))
    }

    private static func decodeRequest(_ request: [String: Any]) -> (LiveMemoryOperation, Reply) {
        guard let type = request["type"] as? String else {
            return (.noop, .error("Request has no type"))
        }

        switch type {
        case "PING":
            return (.noop, .pong)
        case "SYSTEM":
            return (.platform, .system)
        case "HASH":
            return (.noop, .hash)
        case "PREFERRED_CORES":
            return (.noop, .preferredCores)
        case "SET_MESSAGE_INTERVAL":
            return (.noop, .setMessageInterval)
        case "LOCK":
            return (.lock, .locked)
        case "UNLOCK":
            return (.unlock, .unlocked)

        case "DISPLAY_MESSAGE":
            return (.message(request["message"] as? String ?? ""), .displayMessage)

        case "MEMORY_SIZE":
            guard let area = area(in: request) else { return (.noop, .error("MEMORY_SIZE needs a domain")) }
            return (.areaSize(area), .memorySize)

        case "READ":
            guard let area = area(in: request),
                  let address = unsigned(request["address"]),
                  let size = unsigned(request["size"])
            else { return (.noop, .error("READ needs a domain, address and size")) }
            return (.read(area: area, address: address, count: Int(clamping: size)), .read)

        case "WRITE":
            guard let area = area(in: request),
                  let address = unsigned(request["address"]),
                  let bytes = base64(request["value"])
            else { return (.noop, .error("WRITE needs a domain, address and base64 value")) }
            return (.write(area: area, address: address, bytes: bytes), .write)

        case "GUARD":
            guard let area = area(in: request),
                  let address = unsigned(request["address"]),
                  let expected = base64(request["expected_data"])
            else { return (.noop, .error("GUARD needs a domain, address and base64 expected_data")) }
            return (.guard(area: area, address: address, expected: expected), .guardCheck)

        default:
            return (.noop, .error("Unknown command: \(type)"))
        }
    }

    // MARK: - Encoding

    /// Builds the reply line for a request after its steps have run.
    /// `results` must be the results of running `request.operations`.
    public func encode(_ request: Request, results: [LiveMemoryResult]) -> String {
        var objects: [[String: Any]] = []
        objects.reserveCapacity(request.replies.count)

        for (reply, result) in zip(request.replies, results) {
            objects.append(replyObject(reply, result: result))
        }

        return Self.encodeLine(objects)
    }

    private func replyObject(_ reply: Reply, result: LiveMemoryResult) -> [String: Any] {
        // The Lua connector answers every request after a failed guard with that guard's own reply.
        if case .skipped(let address) = result {
            return ["type": "GUARD_RESPONSE", "value": false, "address": address]
        }
        if case .unknownArea(let area) = result {
            return Self.errorObject("Unknown memory domain: \(area)")
        }

        switch (reply, result) {
        case (.pong, _):
            return ["type": "PONG"]
        case (.system, .platform(let platform)):
            return ["type": "SYSTEM_RESPONSE", "value": Self.systemID(forPlatform: platform)]
        case (.hash, _):
            return ["type": "HASH_RESPONSE", "value": romHash]
        case (.memorySize, .areaSize(let size)):
            return ["type": "MEMORY_SIZE_RESPONSE", "value": size]
        case (.guardCheck, .guardChecked(let passed, let address)):
            return ["type": "GUARD_RESPONSE", "value": passed, "address": address]
        case (.read, .bytes(let bytes)):
            return ["type": "READ_RESPONSE", "value": Data(bytes).base64EncodedString()]
        case (.write, _):
            return ["type": "WRITE_RESPONSE"]
        case (.displayMessage, _):
            return ["type": "DISPLAY_MESSAGE_RESPONSE"]
        case (.setMessageInterval, _):
            return ["type": "SET_MESSAGE_INTERVAL_RESPONSE"]
        case (.preferredCores, _):
            return ["type": "PREFERRED_CORES_RESPONSE", "value": [String: String]()]
        case (.locked, _):
            return ["type": "LOCKED"]
        case (.unlocked, _):
            return ["type": "UNLOCKED"]
        case (.error(let message), _):
            return Self.errorObject(message)
        default:
            return Self.errorObject("Internal error: unexpected result \(result)")
        }
    }

    // MARK: - Names

    /// BizHawk's system id for an OpenEmu live memory platform. BizHawk reports "NULL" with no game loaded.
    static func systemID(forPlatform platform: String?) -> String {
        guard let platform else { return "NULL" }
        return systemIDs[platform] ?? platform
    }

    private static let systemIDs: [String: String] = [
        "GB": "GB",
        "GBC": "GBC",
        "GBA": "GBA",
    ]

    /// BizHawk's memory domain names mapped to OpenEmu's area names, where they differ.
    /// Names that are not listed are passed through unchanged.
    private static let areaNames: [String: String] = [:]

    private static func area(in request: [String: Any]) -> String? {
        guard let domain = request["domain"] as? String else { return nil }
        return areaNames[domain] ?? domain
    }

    // MARK: - Helpers

    private static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double >= 0, double <= Double(UInt64.max), double == double.rounded() else { return nil }
        return number.uint64Value
    }

    private static func base64(_ value: Any?) -> [UInt8]? {
        guard let text = value as? String, let data = Data(base64Encoded: text) else { return nil }
        return [UInt8](data)
    }

    private static func errorObject(_ message: String) -> [String: Any] {
        ["type": "ERROR", "err": message]
    }

    private static func encodeLine(_ objects: [[String: Any]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: objects),
              let text = String(data: data, encoding: .utf8)
        else {
            return #"[{"type":"ERROR","err":"Could not encode reply"}]"#
        }
        return text
    }
}
