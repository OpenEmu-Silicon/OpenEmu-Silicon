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
import OpenEmuSystem
import AudioToolbox

@objc public enum OEGameCoreEffectsMode: UInt, RawRepresentable {
    case reflectPaused
    case displayAlways
}

/// A protocol that defines the behaviour required to control an emulator core.
///
/// A host application obtains an instance of @c OEGameCoreHelper in order
/// to communicate with the core, which may be running in another thread or
/// a remote process.
@objc(OEGameCoreHelper) public protocol OEGameCoreHelper: NSObjectProtocol {

    /// Adjust the output volume of the core.
    ///
    /// - Parameter value: The new volume level, from @c [0,1.0]
    func setVolume(_ value: Float)
    
    /**
     * Manage the paused status of the core.
     *
     * @param pauseEmulation Specify @c true to pause the core.
     */
    func setPauseEmulation(_ pauseEmulation: Bool)

    /// Returns whether a RetroAchievements hardcore session may pause right now.
    func canPauseRetroAchievementsHardcore(completionHandler block: @escaping (Bool, UInt32) -> Void)
    
    /** Specifies how and when shader effects are rendered.
     *
     * Shader effects are normally paused when the core is paused. This
     * API allows further control over when the effects are rendered.
     *
     * @param mode Determines how and when shader effects are rendered.
     */
    func setEffectsMode(_ mode: OEGameCoreEffectsMode)
    func setAudioOutputDeviceID(_ deviceID: AudioDeviceID)
    func setOutputBounds(_ rect: NSRect)
    func setBackingScaleFactor(_ newBackingScaleFactor: CGFloat)
    
    /// Controls whether the renderer should use a variable refresh rate.
    func setAdaptiveSyncEnabled(_ enabled: Bool)
    func setGlobalShaderParameters(gamma: CGFloat, saturation: CGFloat)
    func setShaderURL(_ url: URL, parameters: [String: NSNumber]?, completionHandler block: @escaping (Error?) -> Void)
    func setShaderParameterValue(_ value: CGFloat, forKey key: String)
    func setupEmulation(completionHandler handler: @escaping (_ screenSize: OEIntSize, _ aspectSize: OEIntSize) -> Void)
    func startEmulation(completionHandler handler: @escaping () -> Void)
    func resetEmulation(completionHandler handler: @escaping () -> Void)
    func stopEmulation(completionHandler handler: @escaping () -> Void)
    func saveStateToFile(at fileURL: URL, completionHandler block: @escaping (Bool, Error?) -> Void)
    func loadStateFromFile(at fileURL: URL, completionHandler block: @escaping (Bool, Error?) -> Void)
    func setCheat(_ cheatCode: String, withType type: String, enabled: Bool)
    func readableMemoryRegions(completionHandler block: @escaping ([[String: Any]]) -> Void)
    func setDisc(_ discNumber: UInt)
    func changeDisplay(withMode displayMode: String)
    func insertFile(at url: URL, completionHandler block: @escaping (Bool, Error?) -> Void)
    
    func handleMouseEvent(_ event: OEEvent)
    func setHandleEvents(_ handleEvents: Bool)
    func setHandleKeyboardEvents(_ handleKeyboardEvents: Bool)

    /// Debug builds only (a no-op in release): press or release a keyboard key (a HID usage code) inside the helper
    /// process, where the game reads its input, as if it came from the keyboard. Used by the play-test driver.
    func injectKeyboardKey(usage: UInt, pressed: Bool)
    func systemBindingsDidSetEvent(_ event: OEHIDEvent, forBinding bindingDescription: OEBindingDescription, playerNumber: UInt)
    func systemBindingsDidUnsetEvent(_ event: OEHIDEvent, forBinding bindingDescription: OEBindingDescription, playerNumber: UInt)
    
    /// Capture an image of the core's video display buffer, which includes all shader effects.
    func captureOutputImage(completionHandler block: @escaping (NSBitmapImageRep) -> Void)
    
    /// Capture an image of the core's raw video display buffer with no effects.
    func captureSourceImage(completionHandler block: @escaping (NSBitmapImageRep) -> Void)

    /// Pass stored RetroAchievements credentials to the helper process.
    ///
    /// The helper posts a notification received by active cores, which call
    /// `rc_client_begin_login_with_token` to link to the player's RA account.
    /// Pass `nil` for both parameters to log out.
    ///
    /// - Parameters:
    ///   - token: The stored RA token, or `nil` to log out.
    ///   - username: The RA username associated with the token.
    func setRetroAchievementsToken(_ token: String?, username: String?)

    /// Toggle RetroAchievements hardcore mode in the helper process.
    ///
    /// The helper posts a notification received by active cores, which call
    /// `rc_client_set_hardcore_enabled` with the new value.
    ///
    /// - Parameter enabled: `true` to enable hardcore mode, `false` for softcore.
    func setHardcoreEnabled(_ enabled: Bool)
}
