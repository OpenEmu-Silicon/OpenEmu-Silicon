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
import os.log

private let log = Logger(subsystem: "org.cheatworks.sdk", category: "Auth")

public enum CheatWorksAuthError: Error {
    /// The configured client access token is empty.
    case missingClientToken
    /// This installation was revoked by the backend; revocation is terminal (no re-enrollment).
    case installationRevoked
    /// The response was not an HTTP response.
    case invalidResponse
    /// Enrollment did not return 201 — the carried status code says why (401 = bad client token).
    case enrollmentFailed(statusCode: Int)
}

/// Manages a CheatWorks per-installation "reporter" token.
///
/// Each installation exchanges the consuming app's client access token for its own reporter
/// token via `POST /v1/installation`, stores it through an injected ``CheatWorksStorage``, and
/// reuses it to authenticate feedback submissions. The reporter token does not expire on its own;
/// the backend only invalidates it by revoking it (or the owning client credential).
///
/// Revocation is terminal. When an authenticated request returns `401`, the caller invokes
/// ``markRevoked()``; the stored token is discarded and the installation is flagged revoked, after
/// which ``installationToken()`` throws ``CheatWorksAuthError/installationRevoked`` and the app
/// stops reporting. A revoked installation is never silently re-enrolled — enrollment happens only
/// on first use.
///
/// The client is self-contained: by default it computes a pseudonymized device id
/// (``CheatWorksHardwareDeviceIdentity``) and stores its state on device
/// (``CheatWorksFileStorage``). Hosts may inject alternatives for testing or custom policy.
///
/// Concurrency: an actor serialises access so simultaneous callers share a single in-flight
/// enrollment rather than each hitting the network.
public actor CheatWorksAuthClient {

    private let configuration: CheatWorksConfiguration
    private let storage: any CheatWorksStorage
    private let deviceIdentity: any CheatWorksDeviceIdentity
    private let urlSession: URLSession

    /// Set while an enrollment request is in flight, so concurrent callers await the same
    /// network round-trip instead of each enrolling.
    private var enrollTask: Task<String, Error>?

    public init(configuration: CheatWorksConfiguration,
                storage: (any CheatWorksStorage)? = nil,
                deviceIdentity: (any CheatWorksDeviceIdentity)? = nil,
                urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.storage = storage ?? CheatWorksFileStorage()
        self.deviceIdentity = deviceIdentity ?? CheatWorksHardwareDeviceIdentity(prefix: configuration.externalIDPrefix)
        self.urlSession = urlSession
    }

    /// Returns a usable reporter token, enrolling this installation on first use. Subsequent calls
    /// return the stored token without a network request. Throws
    /// ``CheatWorksAuthError/installationRevoked`` once the installation has been revoked.
    public func installationToken() async throws -> String {
        if isRevoked { throw CheatWorksAuthError.installationRevoked }
        if let token = storage.string(forKey: Self.tokenKey) { return token }
        return try await sharedEnrollment()
    }

    /// Whether this installation has been revoked. Once `true`, it never returns to `false`.
    public var isInstallationRevoked: Bool { isRevoked }

    /// Marks this installation revoked after an authenticated request returned `401`. Terminal: the
    /// stored token is discarded and no re-enrollment is attempted, so the app stops reporting. This
    /// does not apply to a `401` from enrollment itself, which means the client token is bad — an
    /// app-wide problem, not a per-install one.
    public func markRevoked() {
        storage.setString(nil, forKey: Self.tokenKey)
        storage.setString("1", forKey: Self.revokedKey)
    }

    // MARK: - Enrollment

    private func sharedEnrollment() async throws -> String {
        if let inFlight = enrollTask {
            return try await inFlight.value
        }
        let task = Task { try await self.enroll() }
        enrollTask = task
        defer { enrollTask = nil }
        return try await task.value
    }

    private func enroll() async throws -> String {
        let clientToken = configuration.clientAccessToken
        guard !clientToken.isEmpty else {
            throw CheatWorksAuthError.missingClientToken
        }

        var request = URLRequest(url: configuration.installationURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(clientToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(InstallationRequest(externalID: deviceIdentity.externalID()))

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CheatWorksAuthError.invalidResponse
        }
        guard http.statusCode == 201 else {
            log.error("CheatWorks installation enrollment failed: HTTP \(http.statusCode, privacy: .public)")
            throw CheatWorksAuthError.enrollmentFailed(statusCode: http.statusCode)
        }

        let enrolled = try JSONDecoder().decode(InstallationResponse.self, from: data)
        storage.setString(enrolled.installationToken, forKey: Self.tokenKey)
        return enrolled.installationToken
    }

    private var isRevoked: Bool {
        storage.string(forKey: Self.revokedKey) != nil
    }

    private static let tokenKey = "installation_token"
    private static let revokedKey = "revoked"
}

// MARK: - Wire models

private struct InstallationRequest: Encodable {
    let externalID: String?

    enum CodingKeys: String, CodingKey {
        case externalID = "external_id"
    }
}

private struct InstallationResponse: Decodable {
    let installationToken: String

    enum CodingKeys: String, CodingKey {
        case installationToken = "installation_token"
    }
}
