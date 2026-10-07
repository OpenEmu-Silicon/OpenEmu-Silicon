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

// ─────────────────────────────────────────────────────────────────────────────
// CheatWorks Integration SDK — portable core.
// These files have no dependency on the host app and are intended to be lifted,
// unchanged, into a standalone CheatWorks Integration SDK for Mac. Keep them free
// of host (OpenEmu) types; everything app-specific arrives via CheatWorksConfiguration
// or an injected dependency.
// ─────────────────────────────────────────────────────────────────────────────

import Foundation

/// Immutable, host-supplied configuration for a CheatWorks client. Carries everything
/// app-specific so the rest of the SDK stays portable.
public struct CheatWorksConfiguration: Sendable {

    /// Code identifying the consuming app to CheatWorks, e.g. `"openemu-silicon"`.
    public let clientCode: String

    /// Client access token issued to the consuming app; exchanged for a per-installation token.
    public let clientAccessToken: String

    /// Base URL of the CheatWorks API. Defaults to production.
    public let baseURL: URL

    /// Prefix for the pseudonymized installation id sent as `external_id`, e.g. `"oe-ins-"`.
    public let externalIDPrefix: String

    public init(clientCode: String,
                clientAccessToken: String,
                baseURL: URL = URL(string: "https://api.cheatworks.org")!,
                externalIDPrefix: String = "cw-ins-") {
        self.clientCode = clientCode
        self.clientAccessToken = clientAccessToken
        self.baseURL = baseURL
        self.externalIDPrefix = externalIDPrefix
    }

    var installationURL: URL { baseURL.appendingPathComponent("v1/installation") }
}
