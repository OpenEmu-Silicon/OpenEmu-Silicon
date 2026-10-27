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
import AudioToolbox
import OpenEmuBase
import OpenEmuSystem

public typealias StartupCompletionHandler = (Error?) -> Void

@objc public class GameCoreManager: NSObject {
    @objc public private(set) var startupInfo: OEGameStartupInfo
    @objc public private(set) weak var gameCoreOwner: OEGameCoreOwner?
    
    @objc public init(startupInfo: OEGameStartupInfo, gameCoreOwner: OEGameCoreOwner) {
        self.startupInfo    = startupInfo
        self.gameCoreOwner  = gameCoreOwner
    }
    
    public override var description: String {
        String(format: "<%@ %p, ROM: %@, Core: %@, System: %@, Display Helper: %@>",
               "\(Self.self)",
               Unmanaged.passUnretained(self).toOpaque().debugDescription,
               startupInfo.romURL.path,
               startupInfo.corePluginURL.deletingPathExtension().lastPathComponent,
               startupInfo.systemPluginURL.deletingPathExtension().lastPathComponent,
               gameCoreOwner != nil ? Unmanaged.passUnretained(gameCoreOwner!).toOpaque().debugDescription : "no gameCoreOwner"
        )
    }
    
    // MARK: - Abstract methods that must be overridden in subclasses
    
    func stop() {
        fatalError("Not implemented")
    }
    
    @objc public func loadROM(completionHandler: @escaping () -> Void, errorHandler: @escaping (Error) -> Void) {
        fatalError("Not implemented")
    }
    
    public func loadROM(completionHandler: @escaping StartupCompletionHandler) {
        fatalError("Not implemented")
    }
    
    // MARK: - Internal APIs
    
    var gameCoreHelper: OEGameCoreHelper?
    
    /// Asynchronously sends the -gameCoreDidTerminate message to the
    /// gameCoreOwner
    func notifyGameCoreDidTerminate() {
        DispatchQueue.main.async { [weak self] in
            self?.gameCoreOwner?.gameCoreDidTerminate?()
        }
    }
}

extension GameCoreManager: OEGameCoreHelper {
    public func setVolume(_ value: Float) {
        gameCoreHelper?.setVolume(value)
    }
    
    public func setPauseEmulation(_ pauseEmulation: Bool) {
        gameCoreHelper?.setPauseEmulation(pauseEmulation)
    }

    public func canPauseRetroAchievementsHardcore(completionHandler block: @escaping (Bool, UInt32) -> Void) {
        guard let gameCoreHelper else {
            block(true, 0)
            return
        }
        gameCoreHelper.canPauseRetroAchievementsHardcore { allowed, framesRemaining in
            DispatchQueue.main.async {
                block(allowed, framesRemaining)
            }
        }
    }
    
    public func setEffectsMode(_ mode: OEGameCoreEffectsMode) {
        gameCoreHelper?.setEffectsMode(mode)
    }
    
    public func setAudioOutputDeviceID(_ deviceID: AudioDeviceID) {
        gameCoreHelper?.setAudioOutputDeviceID(deviceID)
    }
    
    public func setAdaptiveSyncEnabled(_ enabled: Bool) {
        gameCoreHelper?.setAdaptiveSyncEnabled(enabled)
    }
    
    public func setGlobalShaderParameters(gamma: CGFloat, saturation: CGFloat) {
        gameCoreHelper?.setGlobalShaderParameters(gamma: gamma, saturation: saturation)
    }
    
    public func setCheat(_ cheatCode: String, withType type: String, enabled: Bool) {
        gameCoreHelper?.setCheat(cheatCode, withType: type, enabled: enabled)
    }

    public func readableMemoryRegions(completionHandler block: @escaping ([[String: Any]]) -> Void) {
        gameCoreHelper!.readableMemoryRegions { dicts in
            DispatchQueue.main.async {
                block(dicts)
            }
        }
    }

    public func readableMemoryRegionDescriptors(completionHandler block: @escaping ([OEMemoryRegionDescriptor]) -> Void) {
        readableMemoryRegions { dicts in
            let regions: [OEMemoryRegionDescriptor] = dicts.compactMap { dict in
                guard let name = dict["name"] as? String,
                      let address = dict["address"] as? UInt32,
                      let addressBytes = dict["addressBytes"] as? UInt8,
                      let data = dict["data"] as? Data
                else { return nil }
                let minDataBytes = dict["minDataBytes"] as? UInt8 ?? 1
                let addressShift = dict["addressShift"] as? Int8 ?? 0
                return OEMemoryRegionDescriptor(name: name, address: address, addressBytes: addressBytes, minDataBytes: minDataBytes, addressShift: addressShift, data: data)
            }
            block(regions)
        }
    }

    public func setDisc(_ discNumber: UInt) {
        gameCoreHelper?.setDisc(discNumber)
    }

    public func insertFile(at url: URL, completionHandler block: @escaping (Bool, Error?) -> Void) {
        // we force unwrap, to ensure we panic, as the block will never be called
        gameCoreHelper!.insertFile(at: url) { success, error in
            DispatchQueue.main.async {
                block(success, error)
            }
        }
    }

    public func changeDisplay(withMode displayMode: String) {
        gameCoreHelper?.changeDisplay(withMode: displayMode)
    }

    public func setOutputBounds(_ rect: NSRect) {
        gameCoreHelper?.setOutputBounds(rect)
    }

    public func setBackingScaleFactor(_ newBackingScaleFactor: CGFloat) {
        gameCoreHelper?.setBackingScaleFactor(newBackingScaleFactor)
    }

    public func setShaderURL(_ url: URL, parameters: [String: NSNumber]?, completionHandler block: @escaping (Error?) -> Void) {
        // we force unwrap, to ensure we panic, as the block will never be called
        gameCoreHelper!.setShaderURL(url, parameters: parameters) { error in
            DispatchQueue.main.async {
                block(error)
            }
        }
    }
    
    public func setShaderParameterValue(_ value: CGFloat, forKey key: String) {
        gameCoreHelper?.setShaderParameterValue(value, forKey: key)
    }
    
    public func setupEmulation(completionHandler handler: @escaping (_ screenSize: OEIntSize, _ aspectSize: OEIntSize) -> Void) {
        // we force unwrap, to ensure we panic, as the block will never be called
        gameCoreHelper!.setupEmulation { screenSize, aspectSize in
            DispatchQueue.main.async {
                handler(screenSize, aspectSize)
            }
        }
    }
    
    public func startEmulation(completionHandler handler: @escaping () -> Void) {
        gameCoreHelper!.startEmulation {
            DispatchQueue.main.async(execute: handler)
        }
    }
    
    public func resetEmulation(completionHandler handler: @escaping () -> Void) {
        gameCoreHelper!.resetEmulation {
            DispatchQueue.main.async(execute: handler)
        }
    }
    
    public func stopEmulation(completionHandler handler: @escaping () -> Void) {
        gameCoreHelper!.stopEmulation {
            DispatchQueue.main.async {
                handler()
                self.stop()
            }
        }
    }
    
    public func saveStateToFile(at fileURL: URL, completionHandler block: @escaping (Bool, Error?) -> Void) {
        gameCoreHelper!.saveStateToFile(at: fileURL) { success, error in
            DispatchQueue.main.async {
                block(success, error)
            }
        }
    }
    
    public func loadStateFromFile(at fileURL: URL, completionHandler block: @escaping (Bool, Error?) -> Void) {
        gameCoreHelper!.loadStateFromFile(at: fileURL) { success, error in
            DispatchQueue.main.async {
                block(success, error)
            }
        }
    }
    
    public func captureOutputImage(completionHandler block: @escaping (NSBitmapImageRep) -> Void) {
        gameCoreHelper!.captureOutputImage { image in
            DispatchQueue.main.async {
                block(image)
            }
        }
    }
    
    public func captureSourceImage(completionHandler block: @escaping (NSBitmapImageRep) -> Void) {
        gameCoreHelper!.captureSourceImage { image in
            DispatchQueue.main.async {
                block(image)
            }
        }
    }

    public func handleMouseEvent(_ event: OEEvent) {
        gameCoreHelper?.handleMouseEvent(event)
    }
    
    public func setHandleEvents(_ handleEvents: Bool) {
        gameCoreHelper?.setHandleEvents(handleEvents)
    }
    
    public func setHandleKeyboardEvents(_ handleKeyboardEvents: Bool) {
        gameCoreHelper?.setHandleKeyboardEvents(handleKeyboardEvents)
    }

    public func injectKeyboardKey(usage: UInt, pressed: Bool) {
        gameCoreHelper?.injectKeyboardKey(usage: usage, pressed: pressed)
    }
    
    public func systemBindingsDidSetEvent(_ event: OEHIDEvent, forBinding bindingDescription: OEBindingDescription, playerNumber: UInt) {
        gameCoreHelper?.systemBindingsDidSetEvent(event, forBinding: bindingDescription, playerNumber: playerNumber)
    }
    
    public func systemBindingsDidUnsetEvent(_ event: OEHIDEvent, forBinding bindingDescription: OEBindingDescription, playerNumber: UInt) {
        gameCoreHelper?.systemBindingsDidUnsetEvent(event, forBinding: bindingDescription, playerNumber: playerNumber)
    }

    public func setRetroAchievementsToken(_ token: String?, username: String?) {
        gameCoreHelper?.setRetroAchievementsToken(token, username: username)
    }

    public func setHardcoreEnabled(_ enabled: Bool) {
        gameCoreHelper?.setHardcoreEnabled(enabled)
    }
}

// MARK: - Synchronous image capture APIs

extension GameCoreManager {
    public func captureOutputImage() -> NSBitmapImageRep {
        let sem = DispatchSemaphore(value: 0)
        var res: NSBitmapImageRep?
        gameCoreHelper!.captureOutputImage { image in
            res = image
            sem.signal()
        }
        
        sem.wait()
        return res!
    }
    
    public func captureSourceImage() -> NSBitmapImageRep {
        let sem = DispatchSemaphore(value: 0)
        var res: NSBitmapImageRep?
        gameCoreHelper!.captureSourceImage { image in
            res = image
            sem.signal()
        }
        
        sem.wait()
        return res!
    }
}
