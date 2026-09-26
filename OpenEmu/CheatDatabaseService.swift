// Copyright (c) 2026, OpenEmu Team
// Author: Leonardo Kasperavičius
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
import OpenEmuBase
import os.log

// private let log = Logger(subsystem: "org.openemu.OpenEmu", category: "CheatDatabaseService")

/// A cheat entry returned by a provider, before import into the user's cheat list.
struct DatabaseCheat: Sendable {
    let name: String
    let code: String
    let providerName: String
    /// Unmodified text as published by the provider, before normalization. Not shown to the user;
    /// carried through for future cheat feedback correlation. Mandatory: every provider reads from
    /// some source text, even when that text equals `code` (e.g. `OpenEmuCheatProvider`, which
    /// applies no normalization).
    let rawCode: String

    init(name: String, code: String, providerName: String, rawCode: String) {
        self.name = name
        self.code = code
        self.providerName = providerName
        self.rawCode = rawCode
    }
}

/// A source of cheat codes for a given system and ROM.
protocol CheatDatabaseProvider {
    var name: String { get }
    func supportsSystem(_ systemIdentifier: String) -> Bool
    func cheats(forMD5 md5: String, serial: String?, gameName: String?, romURL: URL?, systemIdentifier: String) async throws -> [DatabaseCheat]
}

/// Facade that aggregates cheat database providers and presents a unified interface to the UI.
final class CheatDatabaseService {

    static let shared = CheatDatabaseService(providers: [OpenEmuCheatProvider(), LibretroCheatProvider()])

    private let providers: [CheatDatabaseProvider]

    init(providers: [CheatDatabaseProvider]) {
        self.providers = providers
    }

    /// Returns true if any registered provider supports the given system.
    func supportsSystem(_ systemIdentifier: String) -> Bool {
        providers.contains { $0.supportsSystem(systemIdentifier) }
    }

    /// Fetches cheats from all providers that support the system, merges, deduplicates, and filters invalid formats.
    /// Provider ordering determines precedence — earlier providers win on duplicate codes.
    func cheats(forMD5 md5: String, serial: String?, gameName: String? = nil, romURL: URL? = nil, systemIdentifier: String, coreIdentifier: String) async throws -> [DatabaseCheat] {
        var results: [DatabaseCheat] = []
        var seenCodes: Set<String> = []
        for provider in providers where provider.supportsSystem(systemIdentifier) {
            let providerCheats = try await provider.cheats(forMD5: md5, serial: serial, gameName: gameName, romURL: romURL, systemIdentifier: systemIdentifier)
            for cheat in providerCheats {
                guard CheatCodeValidator.isValid(code: cheat.code, systemIdentifier: systemIdentifier, coreIdentifier: coreIdentifier) else {
                    // log.info("Skipping invalid cheat code: \(cheat.code) (\(cheat.name)) from \(provider.name)")
                    continue
                }
                let normalized = cheat.code.replacingOccurrences(of: " ", with: "").lowercased()
                guard !seenCodes.contains(normalized) else { continue }
                seenCodes.insert(normalized)
                results.append(cheat)
            }
        }
        return results
    }
}
