// Copyright (c) 2026, CheatWorks Team
// Author: Leonardo Kasperavičius
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the CheatWorks Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY CheatWorks Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL CheatWorks Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

// Part of the portable CheatWorks Integration SDK core — no host dependencies.

import Foundation
import CryptoKit
import IOKit

/// Supplies the pseudonymized installation identifier sent to CheatWorks as `external_id`.
/// Hosts may inject a custom implementation; the SDK ships a hardware-derived default.
public protocol CheatWorksDeviceIdentity: Sendable {
    func externalID() -> String?
}

/// Default identity: a stable, anonymized per-machine id derived from the Mac's hardware UUID.
/// The raw hardware UUID never leaves the device — only a salted SHA-256 hash is exposed. The id
/// is deterministic per machine, so it survives app reinstalls and local-data resets, which lets
/// the backend treat a revoked installation as terminal. On the rare Mac whose hardware UUID can't
/// be read, a random id is used instead (unique, but not reset-stable — acceptable because
/// `external_id` is only sent once, at enrollment).
public struct CheatWorksHardwareDeviceIdentity: CheatWorksDeviceIdentity {

    private let prefix: String

    public init(prefix: String) { self.prefix = prefix }

    public func externalID() -> String? {
        let machine = CheatWorksHardware.platformUUID() ?? UUID().uuidString
        let digest = SHA256.hash(data: Data("cheatworks-installation:\(machine)".utf8))
        let hex = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return prefix + hex
    }
}

/// Reads the Mac's hardware platform UUID from IOKit. SDK-internal; shared by the default
/// identity and the default storage so there is a single IOKit implementation.
enum CheatWorksHardware {

    /// Example value: `"8A3F1C2D-4E5F-6789-ABCD-EF0123456789"`.
    static func platformUUID() -> String? {
        // kIOMainPortDefault was introduced in macOS 12; fall back to the deprecated name on 11.
        let port: mach_port_t
        if #available(macOS 12.0, *) {
            port = kIOMainPortDefault
        } else {
            port = kIOMasterPortDefault
        }
        let service = IOServiceGetMatchingService(port, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        guard service != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(
            service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String
    }
}
