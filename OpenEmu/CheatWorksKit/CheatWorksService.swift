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

// MARK: - Public models

/// A reporter's verdict for a cheat code.
public enum CheatWorksFeedbackStatus: String, Sendable {
    case works = "WORKS"
    case doesNotWork = "DOES_NOT_WORK"
    case notSure = "NOT_SURE"
}

/// The emulator/core a cheat code was tested on.
public struct CheatWorksEmulator: Sendable {
    /// Emulator/core code, e.g. `"genesisplus"`.
    public let code: String
    /// Emulator/core version string.
    public let version: String
    /// Optional display name, used when the emulator is first seen by the backend.
    public let name: String?

    public init(code: String, version: String, name: String? = nil) {
        self.code = code
        self.version = version
        self.name = name
    }

    public init(_ code: CheatWorksEmulatorCode, version: String, name: String? = nil) {
        self.init(code: code.rawValue, version: version, name: name)
    }
}

/// One cheat-code feedback submission. `cheatCode` is stored verbatim by the backend.
public struct CheatWorksFeedback: Sendable {
    /// The system/platform the cheat code targets.
    public let system: CheatWorksSystem
    /// 32-character hexadecimal game fingerprint.
    public let gameFingerprint: String
    /// Optional game name, used when the game is first seen by the backend.
    public let gameName: String?
    /// Cheat code exactly as tested; never normalized.
    public let cheatCode: String
    /// The reporter's verdict.
    public let status: CheatWorksFeedbackStatus
    /// The emulator the cheat code was tested on.
    public let emulator: CheatWorksEmulator
    /// Optional cheat-code provider name, e.g. `"pugsy"`.
    public let provider: String?

    public init(system: CheatWorksSystem,
                gameFingerprint: String,
                cheatCode: String,
                status: CheatWorksFeedbackStatus,
                emulator: CheatWorksEmulator,
                gameName: String? = nil,
                provider: String? = nil) {
        self.system = system
        self.gameFingerprint = gameFingerprint
        self.cheatCode = cheatCode
        self.status = status
        self.emulator = emulator
        self.gameName = gameName
        self.provider = provider.flatMap(Self.normalizedProvider)
    }

    /// The backend expects provider tags as lowercase alphanumerics, so punctuation and spacing are
    /// stripped (e.g. `"Pugsy's"` → `"pugsys"`). Returns `nil` if nothing printable remains.
    private static func normalizedProvider(_ provider: String) -> String? {
        let cleaned = provider.lowercased().filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        return cleaned.isEmpty ? nil : cleaned
    }
}

/// The backend's outcome for a feedback submission.
public struct CheatWorksFeedbackResult: Sendable {
    /// `"accepted"` for a new report, `"updated"` when it replaced the reporter's previous verdict.
    public let status: String
    /// Non-fatal warnings, e.g. `"unrecognised game"` / `"unrecognised emulator"`.
    public let warnings: [String]
}

public enum CheatWorksServiceError: Error, Sendable {
    /// The response was not an HTTP response.
    case invalidResponse
    /// The request was rate-limited (HTTP 429). `retryAfter` is the server's suggested wait in
    /// seconds (from the `Retry-After` header), or `nil` if none was given. The service does **not**
    /// wait — the caller should hold off on further requests for at least this long.
    case rateLimited(retryAfter: TimeInterval?)
    /// The backend rejected the request parameters (HTTP 422). Carries the server's message.
    case invalidRequest(message: String?)
    /// An unexpected HTTP status. Carries the code and the server's message, if any.
    case unexpectedStatus(statusCode: Int, message: String?)
}

// MARK: - Service

/// The public entry point to CheatWorks for a consuming app. Wraps the authentication layer
/// (``CheatWorksAuthClient``) so callers never deal with installation tokens directly — the
/// service enrolls on demand, in the background, as part of each authenticated request.
///
/// Today it submits cheat-code feedback; ratings queries and a health check will be added here.
public final class CheatWorksService: Sendable {

    private let configuration: CheatWorksConfiguration
    private let authClient: CheatWorksAuthClient
    private let urlSession: URLSession

    public init(configuration: CheatWorksConfiguration,
                authClient: CheatWorksAuthClient? = nil,
                urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.authClient = authClient ?? CheatWorksAuthClient(configuration: configuration)
        self.urlSession = urlSession
    }

    /// Submits cheat-code feedback, enrolling this installation on demand if it hasn't been yet.
    ///
    /// Set `localSyncMode` to `true` when draining a backlog of locally stored feedback: it tags the
    /// request for the backend's higher rate-limit ceiling. This is a temporary accommodation the
    /// server may withdraw later; use it only for backlog drains, not routine single submissions.
    ///
    /// Throws ``CheatWorksAuthError`` from the authentication step (e.g. `installationRevoked` if
    /// this installation was revoked, or `missingClientToken`), or ``CheatWorksServiceError`` for a
    /// bad request / unexpected response. A `401` here means the installation token was rejected:
    /// the installation is marked revoked (terminal) and ``CheatWorksAuthError/installationRevoked``
    /// is thrown — callers should stop reporting rather than retry.
    @discardableResult
    public func submitFeedback(_ feedback: CheatWorksFeedback,
                               localSyncMode: Bool = false) async throws -> CheatWorksFeedbackResult {
        let token = try await authClient.installationToken()

        var request = URLRequest(url: configuration.feedbackURL)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Installation-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if localSyncMode {
            request.setValue("true", forHTTPHeaderField: "X-CheatWorks-FeedbackBulk")
        }
        request.httpBody = try JSONEncoder().encode(
            FeedbackRequestBody(feedback: feedback, clientVersion: configuration.clientVersion))

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CheatWorksServiceError.invalidResponse
        }

        switch http.statusCode {
        case 202:
            let decoded = try JSONDecoder().decode(FeedbackResponseBody.self, from: data)
            return CheatWorksFeedbackResult(status: decoded.status, warnings: decoded.warnings ?? [])
        case 401:
            // Installation token rejected — revocation is terminal, so stop reporting.
            await authClient.markRevoked()
            throw CheatWorksAuthError.installationRevoked
        case 429:
            throw CheatWorksServiceError.rateLimited(retryAfter: Self.retryAfter(from: http))
        case 422:
            throw CheatWorksServiceError.invalidRequest(message: Self.errorMessage(from: data))
        default:
            throw CheatWorksServiceError.unexpectedStatus(
                statusCode: http.statusCode, message: Self.errorMessage(from: data))
        }
    }

    private static func errorMessage(from data: Data) -> String? {
        (try? JSONDecoder().decode(ErrorResponseBody.self, from: data))?.error
    }

    /// Parses the `Retry-After` header into a wait in seconds. Handles both forms allowed by
    /// RFC 9110: a delay in seconds, or an HTTP-date to wait until.
    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else { return nil }

        if let seconds = TimeInterval(raw) {
            return max(0, seconds)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }
}

// MARK: - Wire models

private struct FeedbackRequestBody: Encodable {
    let system: String
    let gameFingerprint: String
    let gameName: String?
    let cheatCode: String
    let status: String
    let clientVersion: String
    let emulator: EmulatorPayload
    let provider: String?

    enum CodingKeys: String, CodingKey {
        case system
        case gameFingerprint = "game_fingerprint"
        case gameName = "game_name"
        case cheatCode = "cheat_code"
        case status
        case clientVersion = "client_version"
        case emulator
        case provider
    }

    struct EmulatorPayload: Encodable {
        let code: String
        let version: String
        let name: String?
    }

    init(feedback: CheatWorksFeedback, clientVersion: String) {
        system = feedback.system.rawValue
        gameFingerprint = feedback.gameFingerprint
        gameName = feedback.gameName
        cheatCode = feedback.cheatCode
        status = feedback.status.rawValue
        self.clientVersion = clientVersion
        emulator = EmulatorPayload(
            code: feedback.emulator.code, version: feedback.emulator.version, name: feedback.emulator.name)
        provider = feedback.provider
    }
}

private struct FeedbackResponseBody: Decodable {
    let status: String
    let warnings: [String]?
}

private struct ErrorResponseBody: Decodable {
    let error: String
}
