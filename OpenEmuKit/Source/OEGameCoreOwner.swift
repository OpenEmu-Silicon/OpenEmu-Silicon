// Copyright (c) 2022, OpenEmu Team
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

public typealias OEContextID = UInt32

@objc(OEGameCoreOwner) public protocol OEGameCoreOwner: NSObjectProtocol {
    // MARK: - Actions
    
    func saveState()
    func loadState()
    func quickSave()
    func quickLoad()
    func toggleFullScreen()
    func toggleAudioMute()
    func volumeDown()
    func volumeUp()
    func stopEmulation()
    func resetEmulation()
    func toggleEmulationPaused()
    func takeScreenshot()
    func fastForwardGameplay(_ enable: Bool)
    func rewindGameplay(_ enable: Bool)
    func stepGameplayFrameForward()
    func stepGameplayFrameBackward()
    func nextDisplayMode()
    func lastDisplayMode()
    
    /// Notify the host application that the screen and aspect sizes have changed for the core.
    ///
    /// The host application would use this information to adjust the size of the display window.
    ///
    /// - Parameters:
    ///   - newScreenSize: The updated screen size
    ///   - newAspectSize: The updated aspect size
    func setScreenSize(_ newScreenSize: OEIntSize, aspectSize newAspectSize: OEIntSize)
    
    /// Notify the host application that the disc count has changed
    /// - Parameter discCount: The new disc count
    func setDiscCount(_ discCount: UInt)
    func setDisplayModes(_ displayModes: [[String: Any]])
    func setRemoteContextID(_ contextID: OEContextID)
    
    /// Invoked when the game core execution has terminated.
    ///
    /// This may occur either because it was asked to stop, or because it
    /// terminated spontaneously (for example in case of a helper application crash).
    ///
    /// - Warning: This message may not be sent in certain situations (for example
    /// when the core manager is deallocated right after the game core is
    /// stopped).
    @objc optional func gameCoreDidTerminate()

    /// Invoked by the helper process when an achievement is earned.
    ///
    /// Called on whatever thread the XPC message arrives on; implementations
    /// should dispatch to the main thread before updating the UI.
    ///
    /// - Parameters:
    ///   - id: The RetroAchievements achievement ID
    ///   - title: Display name of the achievement
    ///   - description: Description text shown in the notification
    ///   - badgeURL: URL string for the achievement badge image
    ///   - points: Points value of the achievement
    @objc optional func achievementUnlocked(id: UInt32, title: String, description: String, badgeURL: String, points: UInt32)

    /// Called when the helper receives updated RetroAchievements metadata for the active game.
    /// The payload contains property-list-safe values using `OERetroAchievements*Key` constants.
    @objc optional func retroAchievementsSessionUpdated(_ info: [String: Any])

    /// Called when rcheevos emits a gameplay UI event such as challenge/progress
    /// indicator changes, leaderboard tracker updates, mastery, or server state.
    /// The payload contains property-list-safe values using `OERetroAchievementsEvent*Key` constants.
    @objc optional func retroAchievementsEvent(_ info: [String: Any])

    /// Called once when rcheevos fires the "warning achievement"
    /// (id >= 101000001), indicating RetroAchievements does not yet recognize
    /// OpenEmu-Silicon as a hardcore-compliant emulator. Hardcore unlocks for
    /// this session will land server-side as Softcore. Hosts should surface
    /// a single, dismissible notice; the bridge already suppresses the fake
    /// unlock banner.
    @objc optional func retroAchievementsEmulatorUnrecognized()

    /// Called when the running core asks a controller to rumble.
    ///
    /// Cores post an `OEGameCoreRumble` notification inside the helper process; the helper
    /// forwards it here. Called on whatever thread the XPC message arrives on.
    ///
    /// - Parameters:
    ///   - player: The player number, starting at 1
    ///   - strongMotor: Strength of the large (low frequency) motor, 0 to 1
    ///   - weakMotor: Strength of the small (high frequency) motor, 0 to 1
    @objc optional func setRumble(player: UInt, strongMotor: Float, weakMotor: Float)
}
