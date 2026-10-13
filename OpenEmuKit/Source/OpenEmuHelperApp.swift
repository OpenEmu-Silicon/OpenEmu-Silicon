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

import AudioToolbox
import Foundation
internal import os.log
import OpenEmuBase
import OpenEmuSystem
import OpenEmuKitPrivate
import OpenEmuShaders
internal import os.log

extension OSLog {
    static let display  = OSLog(subsystem: "org.openemu.OpenEmuKit", category: "display")
    static let renderer = OSLog(subsystem: "org.openemu.OpenEmuKit", category: "renderer")
}

@objc public class OpenEmuHelperApp: NSResponder, NSApplicationDelegate {
    @objc public var gameCoreOwner: OEGameCoreOwner!
    @objc public private(set) var gameCore: OEGameCore!
    @objc public private(set) var gameSystemResponderClientProtocol: Protocol!
    
    // MARK: - State
    // swiftlint:disable identifier_name
    var _previousScreenRect: OEIntRect = .init()
    var _previousAspectSize: OEIntSize = .init()
    
    // Video
    var _gameRenderer: GameRenderer!
    var _openGLGameRenderer: OpenGLGameRenderer?
    var _surface: CoreVideoTexture!
    var flipVertically: Bool = false
    
    // OE stuff
    var _gameController: OEGameCoreController!
    var _systemController: OESystemController!
    var _systemResponder: OESystemResponder!
    var _gameAudio: GameAudioProtocol!
    
    // initial shader and parameters
    var _shader: URL?
    var _shaderParameters: [String: Double]?
    
    var _currentShader: URL?
    
    var _gameVideoCAContext: CAContext!
    
    var _videoLayer: GameHelperMetalLayer!
    var _filterChain: FilterChain!
    var _screenshot: Screenshot!
    /// Only send 1 frame at once to the GPU.
    /// Since we aren't synced to the display, even one more
    /// is enough to block in nextDrawable for more than a frame
    /// and cause audio skipping.
    var _inflightSemaphore = DispatchSemaphore(value: 1)
    var _scope: MTLCaptureScope!
    var _device: MTLDevice!
    var _commandQueue: MTLCommandQueue!
    
    var _clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    var _skippedFrames: UInt = 0
    var _effectsMode: OEGameCoreEffectsMode = .reflectPaused
    
    var _unhandledEventsMonitor: Any?
    var _hasStartedAudio = false
    var _adaptiveSyncEnabled = false
    
    var _handleEvents: Bool = false
    var _handleKeyboardEvents: Bool = false
    
    var loadedRom = false

    // RetroAchievements token received from the main app via XPC.
    // Stored here so the core can pick it up at load time and on mid-session token delivery.
    var _retroAchievementsToken: String?
    var _retroAchievementsUsername: String?

    // RA hardcore mode flag received from the main app via XPC. Defaults to true
    // (RA's recommended default); cores read this at load time and on mid-session toggles.
    var _hardcoreEnabled: Bool = true

    // Observer for achievement unlock notifications posted by the active core plugin.
    var _achievementObserver: Any?
    var _raSessionObserver: Any?
    var _raEventObserver: Any?
    var _raUnrecognizedObserver: Any?
    var _raIdleTimer: DispatchSourceTimer?

    // frame rate debugging
    var previous    = CFTimeInterval()
    var frameRate   = CFTimeInterval()
    var lastLog     = CFTimeInterval()
    
    @objc public override init() {
        super.init()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: -
    
    @objc public func launchApplication() {
        
    }
    
    private func setupGameCoreAudioAndVideo() {
        guard let gameCore else { fatalError("Expected gameCore to be set") }
        
        // 1. Audio
        _gameAudio = GameAudio2(withCore: gameCore)
        _gameAudio.volume = 1.0
        
        // 2. Video
        _device         = MTLCreateSystemDefaultDevice()
        _scope          = MTLCaptureManager.shared().makeCaptureScope(device: _device)
        _commandQueue   = _device.makeCommandQueue()
        
        // TODO: Handle error
        // Original Obj-C didn't handle the error either
        _filterChain    = try? FilterChain(device: _device)
        _screenshot     = Screenshot(device: _device)
        
        updateScreenSize()
        setupGameRenderer()
        setupCVBuffer()
        setupRemoteLayer()
        if let _shader = _shader {
            try? setShaderURL(_shader, parameters: _shaderParameters)
            self._shader            = nil
            self._shaderParameters  = nil
        }
    }
    
    // MARK: - Core Video and Generic Video
    
    private func updateScreenSize() {
        _previousAspectSize = gameCore.aspectSize
        _previousScreenRect = gameCore.screenRect
    }
    
    private func setupGameRenderer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        
        _videoLayer = .init()
        _videoLayer.device = _device
        _videoLayer.isOpaque = true
        _videoLayer.framebufferOnly = true
        _videoLayer.displaySyncEnabled = true
        
        let rendering = gameCore.gameCoreRendering
        switch rendering {
        case .bitmap:
            _gameRenderer = setup2dVideo()
            
        case .openGL2, .openGL3:
            _openGLGameRenderer = setupOpenGLVideo()
            _gameRenderer       = _openGLGameRenderer
        case .metal2:
            _gameRenderer = setup3dVideo()
            
        default:
            fatalError("Rendering API \(rendering) not supported")
        }
    }
    
    private func setup2dVideo() -> GameRenderer {
        do {
            return try MTLGameRenderer(withDevice: _device, gameCore: gameCore)
        } catch {
            fatalError("Unable to create MTLGameRenderer")
        }
    }
    
    private func setup3dVideo() -> GameRenderer {
        do {
            return try MTL3DGameRenderer(withDevice: _device, gameCore: gameCore)
        } catch {
            fatalError("Unable to create MTL3DGameRenderer")
        }
    }
    
    private func setupOpenGLVideo() -> OpenGLGameRenderer {
        precondition(gameCore.gameCoreRendering == .openGL2 || gameCore.gameCoreRendering == .openGL3)
        _surface = CoreVideoTexture(device: _device, metalPixelFormat: .bgra8Unorm)
        
        if gameCore.gameCoreRendering == .openGL2 {
            return OpenGL2GameRenderer(withInteropTexture: _surface, gameCore: gameCore)
        } else {
            return OpenGL3GameRenderer(withInteropTexture: _surface, gameCore: gameCore)
        }
    }
    
    private func setupCVBuffer() {
        let surfaceSize = gameCore.bufferSize
        let size = CGSize(width: CGFloat(surfaceSize.width), height: CGFloat(surfaceSize.height))
        
        if gameCore.gameCoreRendering != .bitmap && gameCore.gameCoreRendering != .metal2 {
            _surface.size = size
            flipVertically = _surface.metalTextureIsFlippedVertically
        }
        
        _gameRenderer.update()
        let rect = gameCore.screenRect
        let sourceRect = CGRect(x: CGFloat(rect.origin.x), y: CGFloat(rect.origin.y),
                                width: CGFloat(rect.size.width), height: CGFloat(rect.size.height))
        let aspectSize = CGSize(width: CGFloat(gameCore.aspectSize.width),
                                height: CGFloat(gameCore.aspectSize.height))
        
        _filterChain.setSourceRect(sourceRect, aspect: aspectSize)
    }
    
    private func setupRemoteLayer() {
        CATransaction.begin()
        do {
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            
            // TODO: If there's a good default bounds, use that.
            _videoLayer.bounds = .init(x: 0, y: 0, width: Int(gameCore.bufferSize.width), height: Int(gameCore.bufferSize.height))
            _filterChain.drawableSize = _videoLayer.drawableSize
            
            let connectionID = CGSMainConnectionID()
            _gameVideoCAContext = CAContext(cgsConnection: connectionID, options: [kCAContextCIFilterBehavior: "ignore"])
            _gameVideoCAContext.layer = _videoLayer
        }
        
        updateRemoteContextID(_gameVideoCAContext.contextId)
    }
    
    // MARK: - Game Core methods
    
    @objc public func load(withStartupInfo info: OEGameStartupInfo) throws {
        guard !loadedRom
        else {
            // throw
            return // NO
        }
        
        let url = info.romURL.standardizedFileURL
        
        _shader = info.shaderURL
        _shaderParameters = info.shaderParameters
        _systemController = OESystemPlugin.systemPlugin(bundleAtURL: info.systemPluginURL)!.controller
        _systemResponder  = _systemController.newGameSystemResponder()
        
        _gameController = OECorePlugin.corePlugin(bundleAtURL: info.corePluginURL)!.controller
        gameCore = _gameController.newGameCore()
        
        let systemIdentifier = _systemController.systemIdentifier!
        
        gameCore.owner          = _gameController
        gameCore.delegate       = self
        gameCore.renderDelegate = self
        gameCore.audioDelegate  = self
        
        gameCore.systemIdentifier   = systemIdentifier
        gameCore.systemRegion       = info.systemRegion
        gameCore.displayModeInfo    = info.displayModeInfo ?? [:]
        gameCore.romMD5             = info.romMD5
        gameCore.romHeader          = info.romHeader
        gameCore.romSerial          = info.romSerial
        gameCore.lockOnRomURL       = info.lockOnRomURL
        gameCore.lockOnUpmemURL     = info.lockOnUpmemURL
        gameCore.hardcoreEnabled    = _hardcoreEnabled
        
        _systemResponder.client                 = gameCore
        _systemResponder.globalEventsHandler    = self
        
        _unhandledEventsMonitor = OEDeviceManager.shared.addUnhandledEventMonitorHandler { [weak self] _, event in
            guard
                let self = self,
                self._handleEvents,
                self._handleKeyboardEvents || event.type != .keyboard
            else { return }
            
            self._systemResponder.handle(event)
        }
        
        guard FileManager.default.isReadableFile(atPath: url.path)
        else {
            gameCore = nil
            
            throw OEGameCoreErrorCodes(.couldNotLoadROMError,
                                       userInfo: [
                                        NSLocalizedDescriptionKey: NSLocalizedString("The emulator does not have read permissions to the ROM.",
                                                                                     comment: "Error when loading a ROM."),
                                       ])
        }
        
        do {
            try gameCore.loadFile(at: url)
            gameCoreOwner.setDiscCount(gameCore.discCount)
            if let displayModes = gameCore.displayModes {
                gameCoreOwner.setDisplayModes(displayModes)
            }
            loadedRom = true
            replayRetroAchievementsTokenIfAvailable()
        } catch {
            gameCore = nil
            
			throw OEGameCoreErrorCodes(.couldNotLoadROMError,
                                       userInfo: [
                                        NSLocalizedDescriptionKey: NSLocalizedString("The emulator could not load ROM.",
                                                                                     comment: "Error when loading a ROM."),
                                        NSUnderlyingErrorKey: error
                                       ])
        }

        _achievementObserver = NotificationCenter.default.addObserver(
            forName: .OEAchievementUnlocked,
            object: nil,
            queue: nil
        ) { [weak self] note in
            NSLog("[RA-Helper] OEAchievementUnlocked notification received, gameCoreOwner=%@", self?.gameCoreOwner != nil ? "set" : "nil")
            guard let self = self,
                  let owner = self.gameCoreOwner,
                  let info = note.userInfo,
                  let idNum     = info[OEAchievementIDKey]          as? NSNumber,
                  let title     = info[OEAchievementTitleKey]        as? String,
                  let desc      = info[OEAchievementDescriptionKey]  as? String,
                  let badge     = info[OEAchievementBadgeURLKey]     as? String,
                  let ptsNum    = info[OEAchievementPointsKey]       as? NSNumber
            else {
                NSLog("[RA-Helper] guard failed — self=%@ owner=%@ info=%@",
                      self != nil ? "ok" : "nil",
                      self?.gameCoreOwner != nil ? "ok" : "nil",
                      note.userInfo != nil ? "ok" : "nil")
                return
            }
            NSLog("[RA-Helper] calling achievementUnlocked id=%u title=%@", idNum.uint32Value, title)
            owner.achievementUnlocked?(id: idNum.uint32Value,
                                        title: title,
                                        description: desc,
                                        badgeURL: badge,
                                        points: ptsNum.uint32Value)
        }

        _raSessionObserver = NotificationCenter.default.addObserver(
            forName: .OERetroAchievementsSessionUpdated,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self = self,
                  let owner = self.gameCoreOwner,
                  let info = note.userInfo as? [String: Any] else { return }
            owner.retroAchievementsSessionUpdated?(info)
        }

        _raEventObserver = NotificationCenter.default.addObserver(
            forName: .OERetroAchievementsEvent,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self = self,
                  let owner = self.gameCoreOwner,
                  let info = note.userInfo as? [String: Any] else { return }
            owner.retroAchievementsEvent?(info)
        }

        _raUnrecognizedObserver = NotificationCenter.default.addObserver(
            forName: .OERetroAchievementsEmulatorUnrecognized,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.gameCoreOwner?.retroAchievementsEmulatorUnrecognized?()
        }
    }
    
    // MARK: - OEGameCoreOwner subclass handles
    
    private func updateScreenSize(_ newScreenSize: OEIntSize, aspectSize newAspectSize: OEIntSize) {
        gameCoreOwner.setScreenSize(newScreenSize, aspectSize: newAspectSize)
    }
    
    private func updateRemoteContextID(_ newContextID: CAContextID) {
        gameCoreOwner.setRemoteContextID(newContextID)
    }
}

// MARK: - OEGameCoreHelper methods

@objc extension OpenEmuHelperApp: OEGameCoreHelper {
    
    public func setVolume(_ volume: Float) {
        gameCore.perform {
            self._gameAudio.volume = volume
        }
    }
    
    public func setPauseEmulation(_ paused: Bool) {
        gameCore.perform {
            self.gameCore.setPauseEmulation(paused)
        }
        if paused {
            startRetroAchievementsIdleTimer()
        } else {
            stopRetroAchievementsIdleTimer()
        }
    }

    public func canPauseRetroAchievementsHardcore(completionHandler block: @escaping (Bool, UInt32) -> Void) {
        gameCore.perform {
            var framesRemaining: UInt32 = 0
            let allowed = self.gameCore.canPauseRetroAchievementsHardcore(withFramesRemaining: &framesRemaining)
            block(allowed, framesRemaining)
        }
    }

    private func startRetroAchievementsIdleTimer() {
        stopRetroAchievementsIdleTimer()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, let gameCore = self.gameCore else { return }
            gameCore.perform {
                gameCore.retroAchievementsIdle()
            }
        }
        _raIdleTimer = timer
        timer.resume()
    }

    private func stopRetroAchievementsIdleTimer() {
        _raIdleTimer?.cancel()
        _raIdleTimer = nil
    }
    
    public func setEffectsMode(_ mode: OEGameCoreEffectsMode) {
        _effectsMode = mode
    }
    
    public func setAudioOutputDeviceID(_ deviceID: AudioDeviceID) {
        gameCore.perform {
            self._gameAudio.setOutputDeviceID(deviceID)
        }
    }
    
    public func setOutputBounds(_ rect: NSRect) {
        if let _videoLayer = _videoLayer, _videoLayer.bounds != rect {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            
            _videoLayer.bounds = rect
            _filterChain.drawableSize = _videoLayer.drawableSize
        }
        
        // Game will try to render at the window size on its next frame.
        guard _gameRenderer.canChangeBufferSize else { return }
        
        let newBufferSize = OEIntSize(width: Int32(rect.size.width.rounded(.up)), height: Int32(rect.size.height.rounded(.up)))
        gameCore.tryToResizeVideo(to: newBufferSize)
    }
    
    public func setBackingScaleFactor(_ newBackingScaleFactor: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        
        _videoLayer.contentsScale = newBackingScaleFactor
        _filterChain.drawableSize = _videoLayer.drawableSize
    }
    
    public func setAdaptiveSyncEnabled(_ enabled: Bool) {
        _adaptiveSyncEnabled = enabled
    }
    
    public func setShaderURL(_ url: URL, parameters: [String: NSNumber]?, completionHandler block: @escaping (Error?) -> Void) {
        gameCore.perform {
            do {
                try self.setShaderURL(url, parameters: parameters as? [String: Double])
                block(nil)
            } catch {
                block(error)
            }
        }
    }
    
    func setShaderURL(_ url: URL, parameters: [String: Double]?) throws {
        if _currentShader != url {
            try _filterChain.setShader(fromURL: url, options: .makeOptions())
            _currentShader = url
        }
        
        if let parameters = parameters, let filter = _filterChain {
            for (key, val) in parameters {
                filter.setValue(val, forParameterName: key)
            }
        }
    }
    
    public func setShaderParameterValue(_ value: CGFloat, forKey key: String) {
        _filterChain.setValue(value, forParameterName: key)
    }
    
    public func setGlobalShaderParameters(gamma: CGFloat, saturation: CGFloat) {
        _filterChain.setShaderParameters(gamma: Float(gamma), saturation: Float(saturation))
    }
    
    public func setupEmulation(completionHandler handler: @escaping (_ screenSize: OEIntSize, _ aspectSize: OEIntSize) -> Void) {
        gameCore.setupEmulation {
            self.setupGameCoreAudioAndVideo()
            
            handler(self._previousScreenRect.size, self._previousAspectSize)
        }
    }
    
    public func startEmulation(completionHandler handler: @escaping () -> Void) {
        gameCore.startEmulation(completionHandler: handler)
    }
    
    public func resetEmulation(completionHandler handler: @escaping () -> Void) {
        gameCore.resetEmulation(completionHandler: handler)
    }
    
    public func stopEmulation(completionHandler handler: @escaping () -> Void) {
        guard let gameCore = gameCore else { return }

        stopRetroAchievementsIdleTimer()

        if let observer = _achievementObserver {
            NotificationCenter.default.removeObserver(observer)
            _achievementObserver = nil
        }
        if let observer = _raSessionObserver {
            NotificationCenter.default.removeObserver(observer)
            _raSessionObserver = nil
        }
        if let observer = _raEventObserver {
            NotificationCenter.default.removeObserver(observer)
            _raEventObserver = nil
        }
        if let observer = _raUnrecognizedObserver {
            NotificationCenter.default.removeObserver(observer)
            _raUnrecognizedObserver = nil
        }

        gameCore.stopEmulation {
            self._gameAudio.stopAudio()
            gameCore.renderDelegate = nil
            gameCore.audioDelegate = nil
            self.gameCoreOwner = nil
            self._gameAudio = nil
            self.gameCore = nil
            
            handler()
        }
    }

    private func postRetroAchievementsTokenDidChange() {
        var userInfo: [String: Any]? = nil
        if let token = _retroAchievementsToken, let username = _retroAchievementsUsername {
            userInfo = [OERetroAchievementsTokenKey: token,
                        OERetroAchievementsUsernameKey: username]
        }
        NotificationCenter.default.post(
            name: .OERetroAchievementsTokenDidChange,
            object: nil,
            userInfo: userInfo
        )
    }

    private func replayRetroAchievementsTokenIfAvailable() {
        guard _retroAchievementsToken != nil, _retroAchievementsUsername != nil else { return }
        postRetroAchievementsTokenDidChange()
    }

    public func setRetroAchievementsToken(_ token: String?, username: String?) {
        _retroAchievementsToken = token
        _retroAchievementsUsername = username
        postRetroAchievementsTokenDidChange()
    }

    public func setHardcoreEnabled(_ enabled: Bool) {
        _hardcoreEnabled = enabled
        // Gate rewind / fast-forward / frame-step at the core level. The OESystemResponder
        // calls those directly on the OEGameCore client, bypassing our host-side gates.
        gameCore?.hardcoreEnabled = enabled
        NotificationCenter.default.post(
            name: .OEHardcoreModeDidChange,
            object: nil,
            userInfo: [OEHardcoreEnabledKey: enabled]
        )
    }

    public func saveStateToFile(at fileURL: URL, completionHandler block: @escaping (Bool, Error?) -> Void) {
        gameCore.perform {
            self.gameCore.saveStateToFile(at: fileURL) { success, error in
                if success, let blob = self.gameCore.retroAchievementsSerializedProgress() {
                    let sidecarURL = fileURL.appendingPathExtension("raprogress")
                    try? blob.write(to: sidecarURL)
                }
                block(success, error)
            }
        }
    }

    public func loadStateFromFile(at fileURL: URL, completionHandler block: @escaping (Bool, Error?) -> Void) {
        // Defense in depth: the document layer also blocks this with a user
        // alert, but the contract with RA is that the helper must never
        // restore prior state during a hardcore session, regardless of how
        // the call arrives. See HardcoreModePolicy.
        guard HardcoreModePolicy.allows(.loadState, hardcoreEnabled: _hardcoreEnabled) else {
            block(false, NSError(domain: OEGameCoreErrorDomain,
                                 code: 0,
                                 userInfo: [NSLocalizedDescriptionKey: "Loading save states is disabled in hardcore mode."]))
            return
        }
        gameCore.perform {
            self.gameCore.loadStateFromFile(at: fileURL) { success, error in
                if success {
                    let sidecarURL = fileURL.appendingPathExtension("raprogress")
                    let blob = try? Data(contentsOf: sidecarURL)
                    if blob == nil {
                        os_log(.debug, "[RA] no .raprogress sidecar at %{public}@ — rcheevos progress will reset for this load.", sidecarURL.lastPathComponent)
                    }
                    self.gameCore.retroAchievementsDeserializeProgress(blob)
                }
                block(success, error)
            }
        }
    }

    public func setCheat(_ cheatCode: String, withType type: String, enabled: Bool) {
        // Defense in depth: the document layer skips applying cheats when
        // hardcore is on, but enforce here too so a refactor of the document
        // can't silently let cheats through. See HardcoreModePolicy.
        guard HardcoreModePolicy.allows(.cheats, hardcoreEnabled: _hardcoreEnabled) else { return }
        gameCore.perform {
            self.gameCore.setCheat(cheatCode, setType: type, setEnabled: enabled)
        }
    }

    public func readableMemoryRegions(completionHandler block: @escaping ([[String: Any]]) -> Void) {
        gameCore.perform {
            let regions = self.gameCore.readableMemoryRegions()
            let dicts: [[String: Any]] = regions.map { region in
                [
                    "name": region.name,
                    "address": region.address,
                    "addressBytes": region.addressBytes,
                    "minDataBytes": region.minDataBytes,
                    "data": region.data,
                ]
            }
            block(dicts)
        }
    }

    public func setDisc(_ discNumber: UInt) {
        gameCore.perform {
            self.gameCore.setDisc(discNumber)
        }
    }
    
    public func changeDisplay(withMode displayMode: String) {
        gameCore.perform {
            self.gameCore.changeDisplay(withMode: displayMode)
            if let displayModes = self.gameCore.displayModes {
                self.gameCoreOwner.setDisplayModes(displayModes)
            }
        }
    }
    
    public func insertFile(at url: URL, completionHandler block: @escaping (Bool, Error?) -> Void) {
        gameCore.perform {
            self.gameCore.insertFile(at: url, completionHandler: block)
        }
    }
    
    public func handleMouseEvent(_ event: OEEvent) {
        DispatchQueue.main.async {
            self._systemResponder.handleMouseEvent(event)
        }
    }
    
    public func setHandleEvents(_ handleEvents: Bool) {
        _handleEvents = handleEvents
    }
    
    public func setHandleKeyboardEvents(_ handleKeyboardEvents: Bool) {
        _handleKeyboardEvents = handleKeyboardEvents
    }
    
    public func systemBindingsDidSetEvent(_ event: OEHIDEvent, forBinding bindingDescription: OEBindingDescription, playerNumber: UInt) {
        DispatchQueue.main.async {
            self._systemResponder.systemBindingsDidSetEvent(event, forBinding: bindingDescription, playerNumber: playerNumber)
        }
    }
    
    public func systemBindingsDidUnsetEvent(_ event: OEHIDEvent, forBinding bindingDescription: OEBindingDescription, playerNumber: UInt) {
        DispatchQueue.main.async {
            self._systemResponder.systemBindingsDidUnsetEvent(event, forBinding: bindingDescription, playerNumber: playerNumber)
        }
    }
    
    // MARK: - OEGameCoreOwner image capture
    
    public func captureOutputImage(completionHandler block: @escaping (NSBitmapImageRep) -> Void) {
        let gr      = _gameRenderer!
        let ss      = _screenshot!
        let chain   = _filterChain!
        let flipped = flipVertically
        gameCore.perform {
            let imgRef = ss.getCGImageFromOutput(gameRenderer: gr, filterChain: chain, flippedVertically: flipped)
            let img    = NSBitmapImageRep(cgImage: imgRef)
            block(img)
        }
    }
    
    public func captureSourceImage(completionHandler block: @escaping (NSBitmapImageRep) -> Void) {
        let gr      = _gameRenderer!
        let ss      = _screenshot!
        let flipped = flipVertically
        gameCore.perform {
            let imgRef = ss.getCGImageFromGameRenderer(gr, flippedVertically: flipped)
            let img    = NSBitmapImageRep(cgImage: imgRef)
            block(img)
        }
    }
}

@objc extension OpenEmuHelperApp: OERenderDelegate {
    public func presentDoubleBufferedFBO() {
        _openGLGameRenderer?.presentDoubleBufferedFBO()
    }
    
    public func willRenderFrameOnAlternateThread() {
        _openGLGameRenderer?.willRenderFrameOnAlternateThread()
    }
    
    public func didRenderFrameOnAlternateThread() {
        _openGLGameRenderer?.didRenderFrameOnAlternateThread()
    }
    
    public var presentationFramebuffer: Any? {
        _openGLGameRenderer?.presentationFramebuffer
    }
    
    public func willExecute() {
        _gameRenderer.willExecuteFrame()
    }
    
    public func didExecute() {
        let previousBufferSize = _gameRenderer.surfaceSize
        let previousAspectSize = _previousAspectSize
        let previousScreenRect = _previousScreenRect
        
        let bufferSize = gameCore.bufferSize
        let screenRect = gameCore.screenRect
        let aspectSize = gameCore.aspectSize
        var mustUpdate = false
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        if previousBufferSize != bufferSize {
            precondition(_gameRenderer.canChangeBufferSize, "Game tried changing IOSurface in a state we don't support")
            
            updateScreenSize()
            updateScreenSize(_previousScreenRect.size, aspectSize: _previousAspectSize)
            setupCVBuffer()
        } else {
            if screenRect != previousScreenRect {
                precondition(screenRect.origin.x + screenRect.size.width <= bufferSize.width, "screen rect must not be larger than buffer size")
                precondition(screenRect.origin.y + screenRect.size.height <= bufferSize.height, "screen rect must not be larger than buffer size")
                mustUpdate = true
            }

            if aspectSize != previousAspectSize {
                mustUpdate = true
            }
            
            if mustUpdate {
                updateScreenSize()
                updateScreenSize(_previousScreenRect.size, aspectSize: _previousAspectSize)
                setupCVBuffer()
            }
        }
        
        _gameRenderer.didExecuteFrame()
        
        CATransaction.commit()
        
        if !_hasStartedAudio {
            _gameAudio.startAudio()
            _hasStartedAudio = true
        }
    }
    
    public func suspendFPSLimiting() {
        _gameRenderer.suspendFPSLimiting()
    }
    
    public func resumeFPSLimiting() {
        _gameRenderer.resumeFPSLimiting()
    }
}

// MARK: - OEAudioDelegate

@objc extension OpenEmuHelperApp: OEAudioDelegate {
    public func audioSampleRateDidChange() {
        gameCore.perform {
            self._gameAudio.audioSampleRateDidChange()
        }
    }
    
    public func pauseAudio() {
        gameCore.perform {
            self._gameAudio.pauseAudio()
        }
    }
    
    public func resumeAudio() {
        gameCore.perform {
            self._gameAudio.resumeAudio()
        }
    }
}

@objc extension OpenEmuHelperApp: OEGameCoreDelegate {
    public func gameCoreDidFinishFrameRefreshThread(_ gameCore: OEGameCore) {
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
    
    public func gameCoreWillBeginFrame(_ isExecuting: Bool) {
        _scope.begin()
    }
    
    public func gameCoreWillEndFrame(_ isExecuting: Bool) {
        defer {
            _scope.end()
        }
        
        guard isExecuting || _effectsMode == .displayAlways
        else { return }
        
        guard _inflightSemaphore.wait(timeout: .now()) == .success
        else {
            _skippedFrames += 1
            return
        }
        
        autoreleasepool {
            // Ensure signal if we do not add it to finalCB
            var skipped: DispatchSemaphore? = _inflightSemaphore
            defer {
                if let skipped = skipped {
                    _skippedFrames += 1
                    skipped.signal()
                }
            }
            
            guard let offscreenCB = _commandQueue.makeCommandBuffer() else { return }
            offscreenCB.label = "offscreen"
            offscreenCB.enqueue()
            if let sourceTexture = _gameRenderer.prepareFrameForRender(commandBuffer: offscreenCB) {
                _filterChain.renderOffscreenPasses(sourceTexture: sourceTexture, commandBuffer: offscreenCB)
            }
            offscreenCB.commit()
            
            guard let drawable = _videoLayer.nextDrawable() else { return }
            
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].clearColor = _clearColor
            // TODO: Investigate whether we can avoid the MTLLoadActionClear
            // Frame buffer should be overwritten completely by final pass.
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].texture    = drawable.texture
            
            guard
                let finalCB = _commandQueue.makeCommandBuffer(),
                let rce     = finalCB.makeRenderCommandEncoder(descriptor: rpd)
            else { return }
            finalCB.label = "final"
            
            _filterChain.renderFinalPass(withCommandEncoder: rce, flipVertically: flipVertically)
            rce.endEncoding()
            
            skipped = nil
            let inflight = _inflightSemaphore
            finalCB.addCompletedHandler { _ in
                inflight.signal()
            }
            
            if _adaptiveSyncEnabled {
                if #available(macOS 10.15.4, *) {
                    // NOTE:
                    // When a variable refresh rate display is configured with minimum and maximum
                    // refresh rates, and the game window is full-screen, we inform the variable
                    // refresh rate display about the desired frame rate of the game core to
                    // produce smooth animation.
                    //
                    // This information came from the "Optimize for variable refresh rate displays" WWDC21 talk
                    finalCB.present(drawable, afterMinimumDuration: 1.0 / gameCore.frameInterval)
                } else {
                    finalCB.present(drawable)
                }
            } else {
                finalCB.present(drawable)
            }
            
            finalCB.commit()
        }
    }
}

@objc extension OpenEmuHelperApp: OEGlobalEventsHandler {
    public func saveState(_ sender: Any) {
        gameCoreOwner.saveState()
    }
    
    public func loadState(_ sender: Any) {
        gameCoreOwner.loadState()
    }
    
    public func quickSave(_ sender: Any) {
        gameCoreOwner.quickSave()
    }
    
    public func quickLoad(_ sender: Any) {
        gameCoreOwner.quickLoad()
    }
    
    public func toggleFullScreen(_ sender: Any) {
        gameCoreOwner.toggleFullScreen()
    }
    
    public func toggleAudioMute(_ sender: Any) {
        gameCoreOwner.toggleAudioMute()
    }
    
    public func volumeDown(_ sender: Any) {
        gameCoreOwner.volumeDown()
    }
    
    public func volumeUp(_ sender: Any) {
        gameCoreOwner.volumeUp()
    }
    
    public func stopEmulation(_ sender: Any) {
        gameCoreOwner.stopEmulation()
    }
    
    public func resetEmulation(_ sender: Any) {
        gameCoreOwner.resetEmulation()
    }
    
    public func toggleEmulationPaused(_ sender: Any) {
        gameCoreOwner.toggleEmulationPaused()
    }
    
    public func takeScreenshot(_ sender: Any) {
        gameCoreOwner.takeScreenshot()
    }
    
    public func fastForwardGameplay(_ enable: Bool) {
        if !HardcoreModePolicy.allows(.fastForward, hardcoreEnabled: _hardcoreEnabled) { return }
        // Required so that _videoLayer.nextDrawable() vends frames faster than the display refresh rate
        // Fixes: https://github.com/OpenEmu/OpenEmu/issues/4780
        _videoLayer.displaySyncEnabled = !enable
        gameCoreOwner.fastForwardGameplay(enable)
    }

    public func rewindGameplay(_ enable: Bool) {
        if _hardcoreEnabled { return }
        // TODO: technically a data race, but it is only updating a single NSInteger
        _filterChain.frameDirection = enable ? -1 : 1
        gameCoreOwner.rewindGameplay(enable)
    }

    public func stepGameplayFrameForward(_ sender: Any) {
        if _hardcoreEnabled { return }
        gameCoreOwner.stepGameplayFrameForward()
    }

    public func stepGameplayFrameBackward(_ sender: Any) {
        if _hardcoreEnabled { return }
        gameCoreOwner.stepGameplayFrameBackward()
    }
    
    public func nextDisplayMode(_ sender: Any) {
        gameCoreOwner.nextDisplayMode()
    }
    
    public func lastDisplayMode(_ sender: Any) {
        gameCoreOwner.lastDisplayMode()
    }
}
