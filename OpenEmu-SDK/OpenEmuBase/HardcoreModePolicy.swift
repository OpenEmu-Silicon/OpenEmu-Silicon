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

/// User-facing affordances that may need to be blocked when RetroAchievements
/// hardcore mode is on. Driven by RA's hardcore-compliance spec:
/// https://docs.retroachievements.org/general/hardcore-compliance-requirements.html
public enum HardcoreModeAction {
    case loadState
    case rewind
    case fastForward
    case slowMotion
    case frameStep
    case cheats
    case saveState
    /// An outside tool, such as an Archipelago client, reading and writing game memory.
    case liveMemoryAccess
}

/// Single source of truth for "what is allowed in hardcore mode."
///
/// Existing gates are scattered across `OEGameCore`, `OpenEmuHelperApp`, and
/// `OEGameDocument`. Routing those gates through this type means the rules
/// can be unit-tested in isolation, and a refactor at any one layer can't
/// silently change the contract with RA.
public enum HardcoreModePolicy {

    /// Whether the given action is permitted given the current hardcore state.
    public static func allows(_ action: HardcoreModeAction, hardcoreEnabled: Bool) -> Bool {
        guard hardcoreEnabled else { return true }

        switch action {
        case .loadState, .rewind, .slowMotion, .frameStep, .cheats:
            return false
        case .liveMemoryAccess:
            // Writing game memory from outside is cheating by RA's rules, and reads are
            // only ever paired with writes, so block the connection entirely.
            return false
        case .fastForward:
            // Fast-forward is permitted in hardcore. RA's hardcore-compliance
            // spec restricts only slowdown and frame advance, not speed-up.
            return true
        case .saveState:
            // Saving is permitted; RA only restricts restoring prior state.
            return true
        }
    }

    /// Whether toggling **into** hardcore mode mid-session must restart the run.
    /// Per RA spec: switching softcore→hardcore mid-game requires a hard reset
    /// so the player can't carry over advantages earned without hardcore rules.
    public static let requiresResetWhenEnabling: Bool = true

    /// Whether toggling **out of** hardcore mode mid-session requires a reset.
    /// It does not — softcore is the more permissive mode, no reset needed.
    public static let requiresResetWhenDisabling: Bool = false
}
