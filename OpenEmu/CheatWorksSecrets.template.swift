// CheatWorksSecrets.template.swift
// ─────────────────────────────────────────────────────────────────────────────
// SETUP INSTRUCTIONS
// ─────────────────────────────────────────────────────────────────────────────
// 1. Copy this file and rename it:
//      CheatWorksSecrets.template.swift  →  CheatWorksSecrets.swift
//
// 2. Fill in the client access token issued by the CheatWorks team for the
//    OpenEmu-Silicon registered client.
//
// 3. CheatWorksSecrets.swift is gitignored — never commit it.
// ─────────────────────────────────────────────────────────────────────────────

import Foundation

extension CheatWorksConfig {
    /// Client access token issued to the OpenEmu-Silicon app by CheatWorks.
    /// Used only to enroll installations (exchanged for a per-installation reporter token).
    static let clientAccessToken = placeholderClientAccessToken
}
