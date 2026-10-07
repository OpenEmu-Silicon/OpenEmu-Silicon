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

/// OpenEmu's integration with the (portable) CheatWorks Integration SDK.
///
/// This is the host-specific layer: it names OpenEmu as the CheatWorks client, pulls the shipped
/// client access token from the gitignored `CheatWorksSecrets.swift`, and vends the shared
/// ``CheatWorksAuthClient`` the rest of the app talks to. Everything portable lives in the
/// `CheatWorks*` SDK-core files; nothing here should be needed once the SDK is a separate package.
enum CheatWorksConfig {

    /// Code identifying OpenEmu to CheatWorks when reporting feedback.
    static let clientCode = "openemu-silicon"

    /// Prefix for OpenEmu's pseudonymized installation id (`external_id`).
    static let externalIDPrefix = "oe-ins-"

    /// Placeholder shipped in the template; a real build overrides it in `CheatWorksSecrets.swift`.
    static let placeholderClientAccessToken = "YOUR_CHEATWORKS_CLIENT_ACCESS_TOKEN"

    // The client access token lives in CheatWorksSecrets.swift (gitignored).
    // Locally: copy CheatWorksSecrets.template.swift → CheatWorksSecrets.swift and fill it in.
    // In CI: the build workflow copies the template, then injects the real token.
    // The property is declared there as an extension on this type.
    // static let clientAccessToken: String — defined in CheatWorksSecrets.swift

    /// `true` once a real client token has been supplied (i.e. not the template placeholder).
    static var isClientTokenConfigured: Bool {
        !clientAccessToken.isEmpty && clientAccessToken != placeholderClientAccessToken
    }

    /// The shared auth client for the app. Uses the SDK's own on-device storage and
    /// hardware-derived device id — OpenEmu supplies only the configuration.
    static let authClient = CheatWorksAuthClient(
        configuration: CheatWorksConfiguration(
            clientCode: clientCode,
            clientAccessToken: clientAccessToken,
            externalIDPrefix: externalIDPrefix))
}
