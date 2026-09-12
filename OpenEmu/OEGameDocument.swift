// Copyright (c) 2021, OpenEmu Team
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

import Cocoa
import IOKit.pwr_mgt
import OpenEmuBase
import OpenEmuSystem
import OpenEmuKit
import UserNotifications

let OEGameVolumeKey = "volume"
let OEGameCoreDisplayModeKeyFormat = "displayMode.%@"
let OEBackgroundPauseKey = "backgroundPause"
let OEBackgroundControllerPlayKey = "backgroundControllerPlay"
let OETakeNativeScreenshots = "takeNativeScreenshots"
let OEGameSaturationKey = "OEImageSaturation"
let OEGameGammaKey = "OEImageGamma"


let OEScreenshotFileFormatKey = "screenshotFormat"
let OEScreenshotPropertiesKey = "screenshotProperties"
let OEScreenshotAspectRatioCorrectionDisabled = "disableScreenshotAspectRatioCorrection"

let OEGameCoreManagerModePreferenceKey = "OEGameCoreManagerModePreference"

/// User preference key controlling whether RetroAchievements hardcore mode is on.
/// Default `true` per RA's recommendation. Disables save state loading, rewind,
/// frame advance, and cheats while enabled.
let RAHardcoreEnabledKey = "RAHardcoreEnabled"

/// Posted by `PrefRetroAchievementsController` when the user toggles hardcore mode.
/// `userInfo[OEHardcoreEnabledKey]` carries the new `Bool`.
extension Notification.Name {
    static let OERAHardcoreDidChange = Notification.Name("OERAHardcoreDidChange")
}

@objc
final class OEGameDocument: NSDocument {
    
    private enum EmulationStatus: UInt {
        /// The current `OEGameCoreManager` has not been instantiated yet,
        /// or it has been deallocated because emulation has terminated
        case notSetup
        /// The `OEGameCoreManager` is ready, but the emulation was not started for
        /// the first time yet
        case setup
        /// The emulation has been requested to start
        case starting
        ///
        case playing
        ///
        case paused
        /// After emulation stops, but before `OEGameCoreManager` is deallocated
        case terminating
    }
    
    enum Errors: LocalizedError, CustomNSError {
        case fileDoesNotExist
        case noCore
        case noCoreForSystem
        case noCoreForSaveState
        case importRequired
        case couldNotLoadROM
        case gameCoreCrashed(OECorePlugin, String, NSError)
        case invalidSaveState
        case libraryDatabaseUnavailable
        case noSystemPlugin
        
        var errorDescription: String? {
            if case .fileDoesNotExist = self {
                return NSLocalizedString("The file you selected doesn't exist", comment: "Inexistent file error reason.")
            } else if case .noCore = self {
                return NSLocalizedString("OpenEmu could not find a Core to launch the game", comment: "No Core error reason.")
            } else if case .noSystemPlugin = self {
                return NSLocalizedString("OpenEmu could not find a system plugin to launch the game", comment: "No system plugin error reason.")
            } else {
                return nil
            }
        }
        
        var recoverySuggestion: String? {
            if case .fileDoesNotExist = self {
                return NSLocalizedString("Choose a valid file.", comment: "Inexistent file error recovery suggestion.")
            } else if case .noCore = self {
                return NSLocalizedString("Make sure your internet connection is active and download a suitable core.", comment: "No Core error recovery suggestion.")
            } else if case .noSystemPlugin = self {
                return NSLocalizedString(""/*TODO*/, comment: "No system plugin error recovery suggestion.")
            } else {
                return nil
            }
        }
        
        static var errorDomain: String { "org.openemu.OpenEmu.OEGameDocument" }
        
        var errorCode: Int {
            switch self {
            case .fileDoesNotExist:
                return 1
            case .noCore:
                return 2
            case .noCoreForSystem:
                return 7
            case .noCoreForSaveState:
                return 8
            case .importRequired:
                return 9
            case .couldNotLoadROM:
                return 10
            case .gameCoreCrashed:
                return 11
            case .invalidSaveState:
                return 12
            case .libraryDatabaseUnavailable:
                return 13
            case .noSystemPlugin:
                return 14
            }
        }
    }
    
    private static let initializeDefaults: Void = {
        UserDefaults.standard.register(defaults: [
            OEScreenshotFileFormatKey : NSBitmapImageRep.FileType.png.rawValue,
            OEScreenshotPropertiesKey : [NSBitmapImageRep.PropertyKey : Any](),
            RAHardcoreEnabledKey      : true,
        ])
    }()
    
    private(set) var rom: OEDBRom!
    private(set) var romFileURL: URL!
    private(set) var corePlugin: OECorePlugin!
    private(set) var systemPlugin: OESystemPlugin!
    private(set) var lockOnROMURL: URL?
    private(set) var lockOnUPMEMURL: URL?

    private(set) var gameViewController: GameViewController!
    
    private(set) var cheats: [Cheat] = []
    private(set) var discCount: UInt = 0
    private(set) var displayModes: [[String: Any]] = []
    
    private var gameCoreManager: GameCoreManager?
    private var cheatSearchWindowController: CheatSearchWindowController?
    private var browseOnlineCheatsWindowController: BrowseOnlineCheatsWindowController?
    private var retroAchievementsWindowController: NSWindowController?
    @objc dynamic private(set) var retroAchievementsSessionInfo: [String: Any]?
    private var retroAchievementsSuppressedUnlockIDs = Set<UInt32>()
    private var retroAchievementsActiveChallengeIDs = Set<UInt32>()
    private var retroAchievementsActiveProgressByAchievementID: [UInt32: String] = [:]
    private var didShowRetroAchievementsBootPlacard = false
    private var raCredentialObserver: Any?
    private var raHardcoreObserver: Any?

    /// The user's hardcore-mode preference, regardless of whether an RA session
    /// is active. Read from `UserDefaults` — writes go through
    /// `PrefRetroAchievementsController`. Use this only for displaying or
    /// recording the user's choice; gate decisions go through
    /// `isHardcoreEnforcementActive` so users without an RA session don't
    /// lose save states, rewind, etc. by default.
    @objc var isHardcoreModePreferenceEnabled: Bool {
        UserDefaults.standard.bool(forKey: RAHardcoreEnabledKey)
    }

    /// Whether hardcore restrictions should actually be enforced right now.
    /// True only when the user has the preference on, a token is stored, and
    /// the selected core advertises RetroAchievements support for this system.
    /// Without all three, no hardcore achievements are being tracked, so blocking
    /// save states, cheats, rewind, etc. would just take existing OpenEmu
    /// functionality away from non-RA or unsupported games.
    @objc var isHardcoreModeEnabled: Bool {
        guard isHardcoreModePreferenceEnabled else { return false }
        guard OECredentialStore.shared.get(.retroAchievementsToken) != nil else { return false }
        return isRetroAchievementsSessionSupported
    }

    private var isRetroAchievementsSessionSupported: Bool {
        guard let corePlugin, let systemPlugin else { return false }
        return corePlugin.supportsRetroAchievements(forSystemIdentifier: systemPlugin.systemIdentifier)
    }

    private var displaySleepAssertionID: IOPMAssertionID = 0
    
    private var emulationStatus: EmulationStatus = .notSetup
    private var saveStateForGameStart: OEDBSaveState?
    private var lastPlayStartDate: Date?
    private var lastSelectedDisplayModeOption: String?
    private var isMuted = false
    private var pausedByGoingToBackground = false
    private var coreDidTerminateSuddenly = false
    /// Indicates whether the document is currently moving from the main window into a separate popout window.
    private var isUndocking = false
    
    /// Non-nil if ROM was decompressed.
    private var decompressedROMFileURL: URL?
    
    @objc dynamic var imageSaturation: Float = 1.0
    @objc dynamic var imageGamma: Float = 1.0
    
    static func clampedSaturation(_ value: Float) -> Float {
        return max(0.5, min(3.0, value))
    }
    
    static func clampedGamma(_ value: Float) -> Float {
        return max(0.5, min(2.0, value))
    }
    
    var coreIdentifier: String {
        return corePlugin.bundleIdentifier
    }
    
    var systemIdentifier: String {
        return systemPlugin.systemIdentifier
    }
    
    var gameCoreHelper: OEGameCoreHelper? {
        return gameCoreManager
    }
    
    private var _gameWindowController: NSWindowController?
    var gameWindowController: NSWindowController? {
        get {
            return _gameWindowController
        }
        set {
            if _gameWindowController == newValue {
                return
            }
            
            if let gameWindowController = _gameWindowController {
                removeObservers(for: gameWindowController)
                removeWindowController(gameWindowController)
            }
            
            _gameWindowController = newValue
            
            if let gameWindowController = _gameWindowController {
                addWindowController(gameWindowController)
                addObservers(for: gameWindowController)
            }
        }
    }
    
    private var _handleEvents = false
    var handleEvents: Bool {
        get {
            return _handleEvents
        }
        set {
            if _handleEvents == newValue {
                return
            }
            
            _handleEvents = newValue
            gameCoreManager?.setHandleEvents(newValue)
        }
    }
    
    private var _handleKeyboardEvents = false
    var handleKeyboardEvents: Bool {
        get {
            return _handleKeyboardEvents
        }
        set {
            if _handleKeyboardEvents == newValue {
                return
            }
            
            _handleKeyboardEvents = newValue
            gameCoreManager?.setHandleKeyboardEvents(newValue)
        }
    }
    
    // make sure we inherit init() from the superclass,
    // it is called by NSDocument.init(contentsOf:ofType:)
    override init() {
        super.init()
    }
    
    init(rom: OEDBRom, core: OECorePlugin?) throws {
        super.init()
        do {
            try setUpDocument(with: rom, using: core)
        } catch {
            throw error
        }
    }
    
    init(game: OEDBGame, core: OECorePlugin?) throws {
        super.init()
        do {
            try setUpDocument(with: game.defaultROM!, using: core)
        } catch {
            throw error
        }
    }

    init(game: OEDBGame, core: OECorePlugin?, lockOnROM: OEDBRom) throws {
        super.init()
        do {
            lockOnROMURL = lockOnROM.url
            let upmemNames = ["sk_upmem.bin", "Sonic & Knuckles (World) (Lock-on).bin"]
            lockOnUPMEMURL = upmemNames
                .map { BIOSFile.biosFolderURL.appendingPathComponent($0) }
                .first { FileManager.default.isReadableFile(atPath: $0.path) }
            try setUpDocument(with: game.defaultROM!, using: core)
        } catch {
            throw error
        }
    }
    
    init(saveState state: OEDBSaveState) throws {
        super.init()
        do {
            try setUpDocument(with: state)
        } catch {
            throw error
        }
    }
    
    private func setUpDocument(with saveState: OEDBSaveState) throws {
        do {
            try setUpDocument(with: saveState.rom!, using: OECorePlugin.corePlugin(bundleIdentifier: saveState.coreIdentifier))
            saveStateForGameStart = saveState
        } catch {
            throw error
        }
    }
    
    private func setUpDocument(with rom: OEDBRom, using core: OECorePlugin?) throws {
        Self.initializeDefaults
        
        var fileURL = rom.url
        
        // Check if local file is available
        let isReachable = try? fileURL?.checkResourceIsReachable()
        if isReachable != true {
            fileURL = nil
            let sourceURL = rom.sourceURL
            
            // try to fallback on external source
            if let sourceURL = sourceURL {
                let name = (rom.fileName != nil) ? rom.fileName! : (sourceURL.lastPathComponent as NSString).deletingPathExtension
                
                if OEAlert.romDownloadRequired(name: name).runModal() == .alertFirstButtonReturn {
                    
                    var destination: URL?
                    var error: NSError?
                    
                    let alert = OEAlert()
                    alert.messageText = String(format: NSLocalizedString("Downloading %@…", comment: "Downloading rom message text"), name)
                    alert.defaultButtonTitle = NSLocalizedString("Cancel", comment: "")
                    alert.showsProgressbar = true
                    alert.progress = -1
                    
                    alert.performBlockInModalSession {
                        let download = Download(url: sourceURL)
                        download.progressHandler = { progress in
                            alert.progress = Double(progress)
                            return true
                        }
                        
                        download.completionHandler = { dst, err in
                            destination = dst
                            if let err = err {
                                error = err as NSError
                            }
                            alert.close(withResult: .alertSecondButtonReturn)
                        }
                        
                        download.start()
                    }
                    
                    if alert.runModal() == .alertFirstButtonReturn || error?.code == NSUserCancelledError {
                        // User canceld
                        let error = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
                        throw error
                    }
                    else {
                        if error != nil || destination == nil {
                            throw error!
                        }
                        
                        fileURL = destination
                        // make sure that rom's fileName is set
                        if rom.fileName == nil {
                            rom.fileName = destination?.lastPathComponent
                            rom.save()
                        }
                    }
                }
                else {
                    // User canceld
                    let error = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
                    throw error
                }
            }
            
            // check if we have recovered
            let isReachable = try? fileURL?.checkResourceIsReachable()
            if fileURL == nil || isReachable != true {
                throw Errors.fileDoesNotExist
            }
        }
        
        self.rom = rom
        romFileURL = fileURL
        corePlugin = core
        systemPlugin = rom.game?.system?.plugin
        
        if systemPlugin == nil {
            throw Errors.noSystemPlugin
        }
        
        if corePlugin == nil {
            corePlugin = try? self.core(forSystem: systemPlugin)
        }
        
        if corePlugin == nil {
            
            var nsError: Error?
            CoreUpdater.shared.installCore(for: rom.game!) { plugin, error in
                if error == nil,
                   let plugin = plugin {
                    self.corePlugin = plugin
                }
                else if let error = error as NSError?,
                        error.domain == NSCocoaErrorDomain,
                        error.code == NSUserCancelledError {
                    nsError = error
                }
                else if let error = error as? CoreUpdater.Errors {
                    nsError = error
                }
            }
            
            if let error = nsError {
                throw error
            }
        }
        
        loadCheats()

        SentryService.setGameContext(
            gameName: rom.game?.displayName ?? "Unknown",
            systemIdentifier: systemPlugin.systemIdentifier,
            coreIdentifier: corePlugin?.bundleIdentifier ?? "Unknown"
        )

        gameCoreManager = newGameCoreManager(with: corePlugin)
        gameViewController = GameViewController(document: self)
    }
    
    deinit {
        // rom is a Core Data object — its context may already be torn down during quit.
        // Guard against a faulted/invalidated object before accessing the URL.
        if let url = romFileURL,
           rom.managedObjectContext != nil,
           !rom.isDeleted,
           url != rom.url {
            try? FileManager.default.removeItem(at: url)
        }
    }
    
    // MARK: - NSDocument
    
    override var description: String {
        return "<\(Self.self) \(Unmanaged.passUnretained(self).toOpaque()), ROM: '\(rom?.game?.displayName ?? "nil")', System: '\(systemPlugin?.systemIdentifier ?? "nil")', Core: '\(corePlugin?.bundleIdentifier ?? "nil")'>"
    }
    
    override var displayName: String! {
        get {
            // If we do not have a title yet, return an empty string instead of super.displayName.
            // The latter uses Cocoa document architecture and relies on documents having URLs,
            // including untitled (new) documents.
            var displayName = rom.game?.displayName ?? ""
            if let coreName = corePlugin?.displayName, !coreName.isEmpty {
                displayName += " (\(coreName))"
            }
            #if DEBUG
            displayName += " (DEBUG BUILD)"
            #endif
            return displayName
        }
        set {
            super.displayName = newValue
        }
    }
    
    /// Returns `true` if emulation is running or paused to prevent OpenEmu from quitting without warning/saving if the user attempts to quit the app during gameplay;
    /// returns `false` while undocking to prevent an ‘unsaved’ indicator from appearing inside the new popout window’s close button.
    override var isDocumentEdited: Bool {
        if isUndocking {
            return false
        }
        return emulationStatus == .playing || emulationStatus == .paused
    }
    
    override func data(ofType typeName: String) throws -> Data {
        throw NSError(domain: NSOSStatusErrorDomain, code: unimpErr)
    }
    
    override func read(from url: URL, ofType typeName: String) throws {
        guard let libraryDB = OELibraryDatabase.default else {
            throw Errors.libraryDatabaseUnavailable
        }
        
        let context = libraryDB.mainThreadContext
        if typeName == "org.openemu.savestate" {
            guard let state = OEDBSaveState.updateOrCreateState(with: url, in: context) else {
                // TODO: Specify failure reason and add recovery suggestion
                throw Errors.invalidSaveState
            }
            
            do {
                try setUpDocument(with: state)
            } catch {
                throw error
            }
            
            return
        }
        
        if !FileManager.default.fileExists(atPath: url.path) {
            throw Errors.fileDoesNotExist
        }

        if !url.isFileURL {
            // TODO: Handle URLs, by downloading to temp folder
            return
        }
        
        let game: OEDBGame?
        do {
            game = try OEDBGame.game(withURL: url, in: context)
        } catch {
            throw error
        }
        
        if game == nil {
            // Could not find game in database. Try to import the file
            let importer = libraryDB.importer
            let completion: ImportItemCompletionBlock = { romID in
                guard let romID = romID else {
                    // import probably failed
                    return
                }
                
                let fileName = (url.lastPathComponent as NSString).deletingPathExtension
                let informativeText = String(format: NSLocalizedString("The game '%@' was imported.", comment: ""), fileName)
                
                let alert = OEAlert()
                alert.messageText = NSLocalizedString("Your game finished importing, do you want to play it now?", comment: "")
                alert.informativeText = informativeText
                alert.defaultButtonTitle = NSLocalizedString("Play Game", comment: "")
                alert.alternateButtonTitle = NSLocalizedString("Cancel", comment: "")
                
                // Ugly hack to start imported games in main window
                let mainWindowController = (NSApp.delegate as! AppDelegate).mainWindowController
                alert.beginSheetModal(for: mainWindowController.window!) { response in
                    guard response == .alertFirstButtonReturn else { return }
                    let rom = OEDBRom.object(with: romID, in: context)!
                    if !mainWindowController.mainWindowRunsGame {
                        mainWindowController.startGame(rom.game)
                    } else {
                        if let url = rom.url {
                            NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { _, _, _ in }
                        }
                    }
                }
            }
            
            if importer.importItem(at: url, withCompletionHandler: completion) {
                throw Errors.importRequired
            }
        }
        
        if let state = game?.autosaveForLastPlayedRom,
           OEAlert.loadAutoSaveGame().runModal() == .alertFirstButtonReturn {
            do {
                try setUpDocument(with: state)
            } catch {
                throw error
            }
        } else if let rom = game?.defaultROM {
            do {
                // TODO: Load rom that was just imported instead of the default one
                try setUpDocument(with: rom, using: nil)
            } catch {
                throw error
            }
        }
    }
    
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        if emulationStatus == .notSetup || emulationStatus == .terminating {
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
            return
        }
        
        if !shouldTerminateEmulation {
            let shouldClose = {
                guard let shouldCloseSelector = shouldCloseSelector else { return }
                let Class: AnyClass = type(of: delegate as AnyObject)
                let method = class_getMethodImplementation(Class, shouldCloseSelector)
                
                typealias Signature = @convention(c) (Any, Selector, AnyObject, Bool, UnsafeMutableRawPointer?) -> Void
                let function = unsafeBitCast(method, to: Signature.self)
                
                function(delegate, shouldCloseSelector, self, false, contextInfo)
            }
            shouldClose()
            return
        }
        
        saveState(name: OEDBSaveState.autosaveName) {
            self.emulationStatus = .terminating
            // TODO: #567 and #568 need to be fixed first
            //removeDeviceNotificationObservers()
            
            self.gameCoreManager?.stopEmulation() {
                SentryService.addBreadcrumb(message: "Emulation stopped", category: "emulation")
                SentryService.clearGameContext()
                OEBindingsController.default.systemBindings(for: self.systemPlugin.controller).remove(self)

                if let observer = self.raCredentialObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.raCredentialObserver = nil
                }
                if let observer = self.raHardcoreObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.raHardcoreObserver = nil
                }

                self.emulationStatus = .notSetup
                self.retroAchievementsSessionInfo = nil
                self.retroAchievementsSuppressedUnlockIDs.removeAll()
                self.retroAchievementsActiveChallengeIDs.removeAll()
                self.retroAchievementsActiveProgressByAchievementID.removeAll()
                self.gameViewController?.clearRetroAchievementsIndicators()
                self.didShowRetroAchievementsBootPlacard = false
                
                self.gameCoreManager = nil
                self.pausedByGoingToBackground = false

                self.cheatSearchWindowController?.close()
                self.cheatSearchWindowController = nil
                self.browseOnlineCheatsWindowController?.close()
                self.browseOnlineCheatsWindowController = nil

                if let lastPlayStartDate = self.lastPlayStartDate {
                    self.rom.addTimeIntervalToPlayTime(abs(lastPlayStartDate.timeIntervalSinceNow))
                }
                self.lastPlayStartDate = nil
                
                super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
            }
        }
    }
    
    // MARK: - Setup
    
    func setUpGame(completionHandler handler: @escaping (_ success: Bool, _ error: Error?) -> Void) {
        guard
            emulationStatus == .notSetup,
            checkRequiredFiles(),
            !checkDeprecatedCore()
        else {
            handler(false, nil)
            return
        }
        
        checkGlitches()
        
        // MARK: Save Sync — Pre-launch cloud check
        // Before loading the ROM, check whether a newer cloud save exists.
        // This runs asynchronously; emulation proceeds after the check completes.
        performPreLaunchSyncCheckIfNeeded {
            self.gameCoreManager?.loadROM(completionHandler: {
            self.gameCoreManager?.setupEmulation() { screenSize, aspectSize in
                self.gameViewController.setScreenSize(screenSize, aspectSize: aspectSize)
                
                self.emulationStatus = .setup
                
                // TODO: #567 and #568 need to be fixed first
                //self.addDeviceNotificationObservers()
                
                self.disableOSSleep()
                self.rom.incrementPlayCount()
                self.rom.markAsPlayedNow()
                self.lastPlayStartDate = Date()

                // set initial volume
                self.setVolume(self.volume, asDefault: false)

                // set initial image adjustments
                self.imageSaturation = Self.clampedSaturation((UserDefaults.standard.object(forKey: OEGameSaturationKey) as? Float) ?? 1.0)
                self.imageGamma = Self.clampedGamma((UserDefaults.standard.object(forKey: OEGameGammaKey) as? Float) ?? 1.0)

                self.gameCoreHelper?.setGlobalShaderParameters(gamma: CGFloat(self.imageGamma), saturation: CGFloat(self.imageSaturation))

                OEBindingsController.default.systemBindings(for: self.systemPlugin.controller).add(self)

                self.gameCoreManager?.setHandleEvents(self.handleEvents)
                self.gameCoreManager?.setHandleKeyboardEvents(self.handleKeyboardEvents)

                // Push the effective hardcore state to the helper before any startup save-state
                // decision. The helper defaults to hardcore=true; without this early push a
                // softcore/non-RA/unsupported startup restore would be blocked by the stale default (#438).
                self.gameCoreManager?.setHardcoreEnabled(self.isHardcoreModeEnabled)

                if let saveStateForGameStart = self.saveStateForGameStart {
                    self.saveStateForGameStart = nil
                    DispatchQueue.main.async {
                        self.loadState(state: saveStateForGameStart)
                    }
                }

                // Pass stored RA credentials so the core can log in at launch
                let raUsername = UserDefaults.standard.string(forKey: "RAUsername")
                let raToken    = OECredentialStore.shared.get(.retroAchievementsToken)
                if let username = raUsername, let token = raToken {
                    self.gameCoreManager?.setRetroAchievementsToken(token, username: username)
                }

                // Forward mid-session credential changes (e.g. user signs in while a game is running).
                // Whenever the RA session state flips, re-push the hardcore enforcement value too —
                // signing out should drop hardcore enforcement (see #445), signing in should pick
                // up the user's preference.
                self.raCredentialObserver = NotificationCenter.default.addObserver(
                    forName: .OERACredentialsDidChange,
                    object: nil,
                    queue: .main
                ) { [weak self] note in
                    guard let self = self else { return }
                    let token    = note.userInfo?[RACredentialsTokenKey]    as? String
                    let username = note.userInfo?[RACredentialsUsernameKey] as? String
                    self.gameCoreManager?.setRetroAchievementsToken(token, username: username)
                    // Route through handleHardcoreToggle so that signing in while a game
                    // is running triggers the required reset — not a direct enforcement
                    // flip that would let RA track an already-mutated session (#447).
                    self.handleHardcoreToggle(enabled: self.isHardcoreModePreferenceEnabled)
                }

                // Forward mid-session hardcore toggles. soft→hard requires a reset
                // (RA spec: switching into hardcore must restart the run).
                self.raHardcoreObserver = NotificationCenter.default.addObserver(
                    forName: .OERAHardcoreDidChange,
                    object: nil,
                    queue: .main
                ) { [weak self] note in
                    guard let self = self else { return }
                    let enabled = (note.userInfo?[OEHardcoreEnabledKey] as? Bool) ?? self.isHardcoreModeEnabled
                    self.handleHardcoreToggle(enabled: enabled)
                }

                handler(true, nil)
            }
        }, errorHandler: { error in
            self.emulationStatus = .notSetup
            if let url = self.decompressedROMFileURL {
                try? FileManager.default.removeItem(at: url)
            }
            OEBindingsController.default.systemBindings(for: self.systemPlugin.controller).remove(self)
            self.gameCoreManager = nil
            self.stopEmulation(self)
            
            let rootError = error as NSError
            if rootError.domain == NSCocoaErrorDomain,
               rootError.code >= NSXPCConnectionErrorMinimum,
               rootError.code <= NSXPCConnectionErrorMaximum {
                let error = Errors.gameCoreCrashed(self.corePlugin, self.systemIdentifier, rootError)
                handler(false, error)
                return
            }
            
            // TODO: the setup completion handler shouldn't be the place where non-setup-related errors are handled!
            handler(false, error)
        })
        } // end performPreLaunchSyncCheckIfNeeded
    }
    
    private func setUpGameCoreManager(using core: OECorePlugin, completionHandler: @escaping () -> Void) {
        assert(core != corePlugin, "Do not attempt to run a new core using the same plug-in as the current one.")
        
        emulationStatus = .notSetup
        retroAchievementsSessionInfo = nil
        retroAchievementsSuppressedUnlockIDs.removeAll()
        retroAchievementsActiveChallengeIDs.removeAll()
        retroAchievementsActiveProgressByAchievementID.removeAll()
        gameViewController?.clearRetroAchievementsIndicators()
        didShowRetroAchievementsBootPlacard = false
        gameCoreManager?.stopEmulation() {
            OEBindingsController.default.systemBindings(for: self.systemPlugin.controller).remove(self)
            
            self.gameCoreManager = self.newGameCoreManager(with: core)
            self.setUpGame { success, error in
                if !success {
                    if let error = error {
                        self.presentError(error)
                    }
                    return
                }
                
                completionHandler()
            }
        }
    }
    
    private func newGameCoreManager(with corePlugin: OECorePlugin) -> GameCoreManager {
        self.corePlugin = corePlugin
        
        let lastDisplayModeInfo = UserDefaults.standard.object(forKey: String(format: OEGameCoreDisplayModeKeyFormat, corePlugin.bundleIdentifier)) as? [String : Any]
        
        let romURL: URL
        if systemPlugin.systemIdentifier != "openemu.system.arcade",
           let index = rom.archiveFileIndex as? Int
        {
            var didDecompress = ObjCBool(false)
            let decomprDst = ArchiveHelper.decompressFileInArchive(at: romFileURL, atIndex: index, withHash: rom.md5, didDecompress: &didDecompress)
            if didDecompress.boolValue {
                // if we decompressed it, we should clean it up
                decompressedROMFileURL = decomprDst
            }
            romURL = decomprDst ?? romFileURL
        } else {
            romURL = romFileURL
        }
        
        let preset = ShaderControl.currentPreset(forSystemPlugin: systemPlugin)
        let params = preset.parameters
        
        let info = OEGameStartupInfo(romURL: romURL,
                                     romMD5: rom.md5 ?? "",
                                     romHeader: rom.header ?? "",
                                     romSerial: rom.serial ?? "",
                                     systemRegion: OELocalizationHelper.shared.regionName,
                                     displayModeInfo: lastDisplayModeInfo,
                                     shaderURL: preset.shader.url,
                                     shaderParameters: params,
                                     corePluginURL: corePlugin.url,
                                     systemPluginURL: systemPlugin.url,
                                     lockOnRomURL: lockOnROMURL,
                                     lockOnUpmemURL: lockOnUPMEMURL)
        
        if let managerClassName = UserDefaults.standard.string(forKey: OEGameCoreManagerModePreferenceKey),
           let managerClass = NSClassFromString(managerClassName),
           managerClass == OEThreadGameCoreManager.self {
            return OEThreadGameCoreManager(startupInfo: info, gameCoreOwner: self)
        } else {
            return OEXPCGameCoreManager(startupInfo: info, gameCoreOwner: self, serviceName: "org.openemu.broker", helperExecutableName: "OpenEmuHelperApp")
        }
    }
    
    private func core(forSystem system: OESystemPlugin) throws -> OECorePlugin {
        let systemIdentifier = system.systemIdentifier
        var validPlugins = OECorePlugin.corePlugins(forSystemIdentifier: systemIdentifier)

        if validPlugins.isEmpty {
            throw Errors.noCore
        }
        else if validPlugins.count == 1 {
            return validPlugins.first!
        }
        else {
            let defaults = UserDefaults.standard
            if let coreIdentifier = defaults.string(forKey: "defaultCore.\(systemIdentifier)"),
               let core = OECorePlugin.corePlugin(bundleIdentifier: coreIdentifier) {
                return core
            } else {
                validPlugins.sort {
                    $0.displayName.caseInsensitiveCompare($1.displayName) == .orderedAscending
                }
                return validPlugins.first!
            }
        }
    }
    
    private func checkRequiredFiles() -> Bool {
        // Check current system plugin for OERequiredFiles and core plugin for OEGameCoreRequiresFiles opt-in
        if !corePlugin.requiresFiles(forSystemIdentifier: systemPlugin.systemIdentifier) {
            return true
        }
        
        if let validRequiredFiles = corePlugin.requiredFiles(forSystemIdentifier: systemPlugin.systemIdentifier) {
            let available = BIOSFile.requiredFilesAvailable(forSystemIdentifier: validRequiredFiles)
            return available
        } else {
            return true
        }
    }
    
    @discardableResult
    private func checkGlitches() -> Bool {
        let OEGameCoreGlitchesKey = OEAlert.OEGameCoreGlitchesSuppressionKey
        let coreName = corePlugin.displayName
        let systemIdentifier = systemPlugin.systemIdentifier
        let systemKey = "\(coreName).\(systemIdentifier)"
        let defaults = UserDefaults.standard
        
        let glitchInfo = defaults.object(forKey: OEGameCoreGlitchesKey) as? [String : Bool] ?? [:]
        let showAlert = !(glitchInfo[systemKey] ?? false)
        
        if corePlugin.hasGlitches(forSystemIdentifier: systemPlugin.systemIdentifier) && showAlert {
            
            let message = String(format: NSLocalizedString("The %@ core has compatibility issues and some games may contain glitches or not play at all.\n\nPlease do not report problems as we are not responsible for the development of %@.", comment: ""), coreName, coreName)
            let alert = OEAlert()
            alert.messageText = NSLocalizedString("Warning", comment: "")
            alert.informativeText = message
            alert.defaultButtonTitle = NSLocalizedString("OK", comment: "")
            alert.showsSuppressionButton = true
            alert.suppressionLabelText = NSLocalizedString("Do not show me again", comment: "Alert suppression label")
            
            if alert.runModal() == .alertFirstButtonReturn && alert.suppressionButtonState {
                var systemKeyGlitchInfo: [String : Bool] = [:]
                for (key, value) in glitchInfo {
                    systemKeyGlitchInfo[key] = value
                }
                systemKeyGlitchInfo[systemKey] = true
                
                defaults.set(systemKeyGlitchInfo, forKey: OEGameCoreGlitchesKey)
            }
            
            return true
        }
        return false
    }
    
    private func checkDeprecatedCore() -> Bool {
        guard corePlugin.isDeprecated == true else {
            return false
        }
        
        let coreName = corePlugin.displayName
        let systemIdentifier = systemPlugin.systemIdentifier
        
        let removalDate = corePlugin.infoDictionary[OEGameCoreSupportDeadlineKey] as? Date
        var deadlineInMoreThanOneMonth = false
        let oneMonth: TimeInterval = 30 * 24 * 60 * 60
        if removalDate == nil || removalDate!.timeIntervalSinceNow > oneMonth {
            deadlineInMoreThanOneMonth = true
        }
        
        let replacements = corePlugin.infoDictionary[OEGameCoreSuggestedReplacement] as? [String : String]
        let replacement = replacements?[systemIdentifier]
        var replacementName: String?
        var download: CoreDownload?
        
        if let replacement = replacement {
            if let plugin = OECorePlugin.corePlugin(bundleIdentifier: replacement) {
                replacementName = plugin.displayName
            } else {
                let repl = CoreUpdater.shared.coreList.first(where: { $0.bundleIdentifier.caseInsensitiveCompare(replacement) == .orderedSame })
                if let repl = repl {
                    download = repl
                    replacementName = download?.name
                }
            }
        }
        
        let title: String
        if deadlineInMoreThanOneMonth {
            title = String(format: NSLocalizedString("The %@ core plugin is deprecated", comment: "Message title (removal far away)"), coreName)
        } else {
            title = String(format: NSLocalizedString("The %@ core plugin is deprecated, and will be removed soon", comment: "Message title (removal happening soon)"), coreName)
        }
        
        var infoMsg: String
        if deadlineInMoreThanOneMonth {
            infoMsg = NSLocalizedString("This core plugin will not be available in the future. Once it is removed, any save states created with it will stop working.", comment: "Message info, part 1 (removal far away)")
        } else {
            infoMsg = NSLocalizedString("In a few days, this core plugin is going to be automatically removed. Once it is removed, any save states created with it will stop working.", comment: "Message info, part 1 (removal happening soon)")
        }
        
        if let replacementName = replacementName {
            infoMsg += "\n\n"
            infoMsg += String(format: NSLocalizedString("We suggest you switch to the %@ core plugin as soon as possible.", comment: "Message info, part 2 (shown only if the replacement plugin is available)"), replacementName)
        }
        
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = infoMsg
        
        if let download = download, gameWindowController == nil {
            let defaults = UserDefaults.standard
            let prefKey = "defaultCore." + systemIdentifier
            let currentCore = defaults.string(forKey: prefKey)
            let deprecatedIsDefault = currentCore == corePlugin.bundleIdentifier
            
            if deprecatedIsDefault {
                alert.addButton(withTitle: String(format: NSLocalizedString("Install %@ and Set as Default", comment: ""), replacementName!))
            } else {
                alert.addButton(withTitle: String(format: NSLocalizedString("Install %@", comment: ""), replacementName!))
            }
            alert.addButton(withTitle: NSLocalizedString("Ignore", comment: ""))
            
            if alert.runModal() != .alertFirstButtonReturn {
                return false
            }
            
            CoreUpdater.shared.installCore(with: download) { plugin, error in
                if deprecatedIsDefault,
                   let plugin = plugin {
                    defaults.set(plugin.bundleIdentifier, forKey: prefKey)
                }
            }
            
            return true
        } else {
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.runModal()
        }
        
        return false
    }
    
    // MARK: - Game Window
    
    func showInSeparateWindow(inFullScreen fullScreen: Bool) {
        isUndocking = true
        let window = NSWindow(contentRect: .zero,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: true)
        let windowController = GameWindowController(window: window)
        windowController.shouldShowWindowInFullScreen = fullScreen
        gameWindowController = windowController
        showWindows()
        
        isEmulationPaused = false
        isUndocking = false
    }
    
    func toggleFullScreen(_ sender: Any?) {
        gameWindowController?.window?.toggleFullScreen(sender)
    }
    
    private func addObservers(for windowController: NSWindowController) {
        let window = windowController.window
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(windowDidBecomeMain(_:)), name: NSWindow.didBecomeMainNotification, object: window)
        nc.addObserver(self, selector: #selector(windowDidResignMain(_:)), name: NSWindow.didResignMainNotification, object: window)
    }
    
    private func removeObservers(for windowController: NSWindowController) {
        let window = windowController.window
        let nc = NotificationCenter.default
        nc.removeObserver(self, name: NSWindow.didBecomeMainNotification, object: window)
        nc.removeObserver(self, name: NSWindow.didResignMainNotification, object: window)
    }
    
    @objc private func windowDidResignMain(_ notification: Notification) {
        // Deferred one runloop turn to avoid a race where the pause fires
        // while AppKit is still mid-transition between main windows.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let backgroundPause = UserDefaults.standard.bool(forKey: OEBackgroundPauseKey)
            if backgroundPause && self.emulationStatus == .playing {
                self.requestEmulationPauseRespectingRetroAchievementsHardcore { [weak self] paused in
                    if paused {
                        self?.pausedByGoingToBackground = true
                    }
                }
            }
        }
    }
    
    @objc private func windowDidBecomeMain(_ notification: Notification) {
        if pausedByGoingToBackground {
            isEmulationPaused = false
            pausedByGoingToBackground = false
        }
    }
    
    // MARK: - Device Notifications
    
    private func addDeviceNotificationObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didReceiveLowBatteryWarning(_:)), name: .OEDeviceHandlerDidReceiveLowBatteryWarning, object: nil)
        nc.addObserver(self, selector: #selector(deviceDidDisconnect(_:)), name: .OEDeviceManagerDidRemoveDeviceHandler, object: nil)
    }
    
    private func removeDeviceNotificationObservers() {
        let nc = NotificationCenter.default
        nc.removeObserver(self, name: .OEDeviceHandlerDidReceiveLowBatteryWarning, object: nil)
        nc.removeObserver(self, name: .OEDeviceManagerDidRemoveDeviceHandler, object: nil)
    }
    
    @objc private func didReceiveLowBatteryWarning(_ notification: Notification) {
        let isRunning = !isEmulationPaused
        let showAlert = { [weak self] in
            guard let self else { return }
            let devHandler = notification.object as? OEDeviceHandler
            let message = String(format: NSLocalizedString("The battery in device number %lu, %@, is low. Please charge or replace the battery.", comment: "Low battery alert detail message."), devHandler?.deviceNumber ?? 0, devHandler?.deviceDescription?.name ?? "")
            let alert = OEAlert()
            alert.messageText = NSLocalizedString("Low Controller Battery", comment: "Device battery level is low.")
            alert.informativeText = message
            alert.defaultButtonTitle = NSLocalizedString("Resume", comment: "")
            alert.runModal()

            if isRunning && self.isEmulationPaused {
                self.isEmulationPaused = false
            }
        }

        if isRunning {
            requestEmulationPauseRespectingRetroAchievementsHardcore { _ in
                showAlert()
            }
        } else {
            showAlert()
        }
    }
    
    @objc private func deviceDidDisconnect(_ notification: Notification) {
        let isRunning = !isEmulationPaused
        let showAlert = { [weak self] in
            guard let self else { return }
            let devHandler = notification.userInfo?[OEDeviceManagerDeviceHandlerUserInfoKey] as? OEDeviceHandler
            let message = String(format: NSLocalizedString("Device number %lu, %@, has disconnected.", comment: "Device disconnection detail message."), devHandler?.deviceNumber ?? 0, devHandler?.deviceDescription?.name ?? "")
            let alert = OEAlert()
            alert.messageText = NSLocalizedString("Device Disconnected", comment: "A controller device has disconnected.")
            alert.informativeText = message
            alert.defaultButtonTitle = NSLocalizedString("Resume", comment: "Resume game after battery warning button label")
            alert.runModal()

            if isRunning && self.isEmulationPaused {
                self.isEmulationPaused = false
            }
        }

        if isRunning {
            requestEmulationPauseRespectingRetroAchievementsHardcore { _ in
                showAlert()
            }
        } else {
            showAlert()
        }
    }
    
    // MARK: - Display Sleep Handling
    
    private func enableOSSleep() {
        if displaySleepAssertionID == kIOPMNullAssertionID { return }
        IOPMAssertionRelease(displaySleepAssertionID)
        displaySleepAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
    }
    
    private func disableOSSleep() {
        if displaySleepAssertionID != kIOPMNullAssertionID { return }
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "OpenEmu playing game" as CFString, &displaySleepAssertionID)
    }
    
    // MARK: - Controlling Emulation
    
    private func startEmulation() {
        if emulationStatus != .setup {
            return
        }

        SentryService.addBreadcrumb(message: "Emulation started", category: "emulation")
        emulationStatus = .starting
        gameCoreManager?.startEmulation() {
            self.emulationStatus = .playing
            // Cheats are disabled in hardcore mode (RA spec).
            if HardcoreModePolicy.allows(.cheats, hardcoreEnabled: self.isHardcoreModeEnabled) {
                self.cheats.filter(\.isEnabled).forEach { self.setCheat($0) }
            }
            (self.gameWindowController as? GameWindowController)?.gameDidStartPlaying()
        }

        gameViewController.reflectEmulationPaused(false)
        gameViewController.announceHardcoreModeChange(isHardcoreModeEnabled)
    }
    
    private var retroAchievementsHardcorePausePreflightSatisfied = false

    var isEmulationPaused: Bool {
        get {
            return emulationStatus != .playing
        }
        set(pauseEmulation) {
            if emulationStatus == .setup {
                if !pauseEmulation {
                    startEmulation()
                }
                return
            }
            // A resume arriving during or after teardown (a window regaining focus as the
            // game window closes) would otherwise flip the status back to .playing, leaving
            // the document "edited" with no core behind it.
            if !pauseEmulation && (emulationStatus == .terminating || emulationStatus == .notSetup) {
                return
            }
            if pauseEmulation {
                if emulationStatus == .playing && isHardcoreModeEnabled && !retroAchievementsHardcorePausePreflightSatisfied {
                    showRetroAchievementsPauseBlockedToast(framesRemaining: 0)
                    return
                }
                SentryService.addBreadcrumb(message: "Emulation paused", category: "emulation")
                enableOSSleep()
                emulationStatus = .paused
                if let lastPlayStartDate = lastPlayStartDate {
                    rom.addTimeIntervalToPlayTime(abs(lastPlayStartDate.timeIntervalSinceNow))
                    self.lastPlayStartDate = nil
                }
            } else {
                SentryService.addBreadcrumb(message: "Emulation resumed", category: "emulation")
                disableOSSleep()
                rom.markAsPlayedNow()
                lastPlayStartDate = Date()
                emulationStatus = .playing
            }
            
            gameCoreManager?.setPauseEmulation(pauseEmulation)
            gameViewController.reflectEmulationPaused(pauseEmulation)
        }
    }
    
    @IBAction func performClose(_ sender: Any?) {
        stopEmulation(sender)
    }
    
    @IBAction func stopEmulation(_ sender: Any?) {
        // we can't just close the document here because proper shutdown is implemented in
        // method canClose(withDelegate:shouldClose:contextInfo:)
        windowControllers.forEach { $0.window?.performClose(sender) }
    }
    
    @objc func toggleEmulationPaused(_ sender: Any?) {
        if isEmulationPaused {
            isEmulationPaused = false
            return
        }

        requestEmulationPauseRespectingRetroAchievementsHardcore()
    }

    func requestEmulationPauseRespectingRetroAchievementsHardcore(showBlockedToast: Bool = true, completion: ((Bool) -> Void)? = nil) {
        guard emulationStatus == .playing else {
            completion?(false)
            return
        }

        guard isHardcoreModeEnabled else {
            isEmulationPaused = true
            completion?(true)
            return
        }

        guard let gameCoreManager else {
            completion?(false)
            return
        }

        gameCoreManager.canPauseRetroAchievementsHardcore { [weak self] allowed, framesRemaining in
            guard let self else { return }
            guard self.emulationStatus == .playing else {
                completion?(false)
                return
            }

            if allowed {
                self.retroAchievementsHardcorePausePreflightSatisfied = true
                defer { self.retroAchievementsHardcorePausePreflightSatisfied = false }
                self.isEmulationPaused = true
                completion?(self.isEmulationPaused)
            } else {
                if showBlockedToast {
                    self.showRetroAchievementsPauseBlockedToast(framesRemaining: framesRemaining)
                }
                completion?(false)
            }
        }
    }

    private func showRetroAchievementsPauseBlockedToast(framesRemaining: UInt32) {
        let seconds = max(1, Int(ceil(Double(framesRemaining) / 60.0)))
        gameViewController?.showRetroAchievementsEventToast(
            title: NSLocalizedString("Pause Blocked in Hardcore", comment: "RetroAchievements pause blocked title"),
            subtitle: String(format: NSLocalizedString("Try again in about %d seconds.", comment: "RetroAchievements pause blocked subtitle"), seconds),
            symbolName: "pause.slash"
        )
    }
    
    @objc func resetEmulation(_ sender: Any?) {
        if OEAlert.resetSystem().runModal() == .alertFirstButtonReturn {
            gameCoreManager?.resetEmulation() {
                self.isEmulationPaused = false
            }
        }
    }

    /// Handle a mid-session hardcore toggle. Soft→hard requires confirming a reset
    /// (RA spec) — but only when an RA session can actually be active for the
    /// current core/system; without a signed-in RA-supported session, hardcore
    /// wouldn't be enforced anyway, so we skip the reset prompt and just record
    /// the preference. Hard→soft drops to softcore immediately with no prompt.
    private func handleHardcoreToggle(enabled: Bool) {
        let willEnforce = enabled
            && isRetroAchievementsSessionSupported
            && OECredentialStore.shared.get(.retroAchievementsToken) != nil

        if willEnforce && HardcoreModePolicy.requiresResetWhenEnabling {
            let revertHardcorePreference = {
                UserDefaults.standard.set(false, forKey: RAHardcoreEnabledKey)
                NotificationCenter.default.post(
                    name: .OERAHardcoreDidChange,
                    object: nil,
                    userInfo: [OEHardcoreEnabledKey: false]
                )
            }

            requestEmulationPauseRespectingRetroAchievementsHardcore { [weak self] paused in
                guard let self else { return }
                guard paused else {
                    revertHardcorePreference()
                    return
                }

                let alert = OEAlert()
                alert.messageText = NSLocalizedString("Switching to hardcore mode requires restarting the game.", comment: "")
                alert.informativeText = NSLocalizedString("Save states, rewind, frame advance, and cheats will be disabled.", comment: "")
                alert.defaultButtonTitle = NSLocalizedString("Restart Game", comment: "")
                alert.alternateButtonTitle = NSLocalizedString("Cancel", comment: "")

                let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                    guard let self else { return }
                    if response == .alertFirstButtonReturn {
                        // Flush active cheats from the core before engaging hardcore.
                        // setHardcoreEnabled(true) blocks the document's setCheat guard,
                        // but core cheat lists persist across a reset — they must be
                        // cleared first so the restarted session is clean (#447).
                        self.cheats.filter(\.isEnabled).forEach {
                            self.gameCoreManager?.setCheat($0.code, withType: $0.type, enabled: false)
                        }
                        self.gameCoreManager?.setHardcoreEnabled(true)
                        self.gameCoreManager?.resetEmulation { [weak self] in
                            self?.isEmulationPaused = false
                        }
                        self.gameViewController.announceHardcoreModeChange(true)
                    } else {
                        // User cancelled — revert the preference so UI and state agree.
                        // Post the change so the prefs checkbox can resync (#446); if we
                        // only write UserDefaults, the imperatively-set checkbox stays
                        // visually checked until the pane is rebuilt.
                        revertHardcorePreference()
                        self.isEmulationPaused = false
                    }
                }

                if let win = self.gameWindowController?.window {
                    alert.beginSheetModal(for: win, completionHandler: handleResponse)
                } else {
                    handleResponse(alert.runModal())
                }
            }
        } else if !enabled && HardcoreModePolicy.requiresResetWhenDisabling {
            // Reserved branch for future spec changes — currently unreachable.
            gameCoreManager?.setHardcoreEnabled(false)
            gameCoreManager?.resetEmulation { [weak self] in
                self?.isEmulationPaused = false
            }
            gameViewController.announceHardcoreModeChange(false)
        } else {
            // Either turning hardcore off, or turning it on without an RA session
            // (no enforcement, no reset, just record the preference).
            gameCoreManager?.setHardcoreEnabled(willEnforce)
            gameViewController.announceHardcoreModeChange(willEnforce)
        }
    }
    
    @objc func setAdaptiveSyncEnabled(_ enabled: Bool) {
        gameCoreHelper?.setAdaptiveSyncEnabled(enabled)
    }
    
    private var shouldTerminateEmulation: Bool {
        if coreDidTerminateSuddenly {
            return true
        }
        
        let didPauseEmulation = pauseEmulationIfNeeded()
        
        if OEAlert.stopEmulation().runModal() != .alertFirstButtonReturn {
            if didPauseEmulation {
                isEmulationPaused = false
            }
            return false
        }
        
        return true
    }
    
    @discardableResult
    private func pauseEmulationIfNeeded() -> Bool {
        let pauseNeeded = emulationStatus == .playing
        
        if pauseNeeded {
            isEmulationPaused = true
        }
        
        return pauseNeeded && isEmulationPaused
    }
    
    // MARK: - Actions
    
    @IBAction func editControls(_ sender: Any?) {
        let userInfo = [
            PreferencesWindowController.userInfoPanelNameKey: "Controls",
            PreferencesWindowController.userInfoSystemIdentifierKey: systemIdentifier,
        ]
        
        NotificationCenter.default.post(Notification(name: PreferencesWindowController.openPaneNotificationName, userInfo: userInfo))
    }

    @IBAction func showRetroAchievements(_ sender: Any?) {
        if retroAchievementsWindowController == nil {
            let viewController = RetroAchievementsGameViewController(document: self)
            let window = NSWindow(contentViewController: viewController)
            window.title = NSLocalizedString("Achievements", comment: "RetroAchievements game window title")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 680, height: 520))
            window.minSize = NSSize(width: 520, height: 360)
            retroAchievementsWindowController = NSWindowController(window: window)
        }

        retroAchievementsWindowController?.showWindow(sender)
        retroAchievementsWindowController?.window?.makeKeyAndOrderFront(sender)
    }
    
    /// expects `sender` or `sender.representedObject` to be an `OECorePlugin` object and prompts the user for confirmation
    @objc func switchCore(_ sender: AnyObject) {
        let plugin: OECorePlugin
        if let sender = sender as? OECorePlugin {
            plugin = sender
        } else if let obj = sender.representedObject as? OECorePlugin {
            plugin = obj
        } else {
            assertionFailure("Invalid argument passed: \(String(describing: sender))")
            return
        }
        
        if plugin.bundleIdentifier == corePlugin.bundleIdentifier {
            return
        }
        
        isEmulationPaused = true
        guard isEmulationPaused else { return }
        
        let alert = OEAlert()
        alert.messageText = NSLocalizedString("If you change the core you current progress will be lost and save states will not work anymore.", comment: "")
        alert.defaultButtonTitle = NSLocalizedString("Change Core", comment: "")
        alert.alternateButtonTitle = NSLocalizedString("Cancel", comment: "")
        alert.showSuppressionButton(forUDKey: OEAlert.OEAutoSwitchCoreAlertSuppressionKey)
        
        alert.callbackHandler = { alert, result in
            if result != .alertFirstButtonReturn {
                return
            }
            
            self.setUpGameCoreManager(using: plugin) {
                self.validateCheatCompatibility()
                self.browseOnlineCheatsWindowController?.resetForCoreChange()
                self.startEmulation()
            }
        }
        
        alert.runModal()
    }
    
    /// Returns a filtered screenshot of the currently running core.
    func screenshot() -> NSImage? {
        guard let rep = gameCoreManager?.captureOutputImage() else { return nil }
        let screenshot = NSImage(size: rep.size)
        screenshot.addRepresentation(rep)
        return screenshot
    }
    
    @objc func takeScreenshot(_ sender: Any?) {
        let defaults = UserDefaults.standard
        let type = NSBitmapImageRep.FileType(rawValue: UInt(defaults.integer(forKey: OEScreenshotFileFormatKey)))!
        let properties = defaults.dictionary(forKey: OEScreenshotPropertiesKey) as! [NSBitmapImageRep.PropertyKey : Any]
        let takeNativeScreenshots = defaults.bool(forKey: OETakeNativeScreenshots)
        let disableAspectRatioFix = defaults.bool(forKey: OEScreenshotAspectRatioCorrectionDisabled)
        
        if takeNativeScreenshots || ((sender as? NSMenuItem)?.tag == 1) {
            gameCoreManager?.captureSourceImage() { image in
                var image = image
                if !disableAspectRatioFix {
                    let newSize = self.gameViewController.defaultScreenSize
                    image = image.resized(newSize) ?? image
                }
                if let imageData = image.representation(using: type, properties: properties) {
                    self.writeScreenshotImageData(imageData)
                }
            }
        } else {
            gameCoreManager?.captureOutputImage() { image in
                if let imageData = image.representation(using: type, properties: properties) {
                    self.writeScreenshotImageData(imageData)
                }
            }
        }
    }
    
    private func writeScreenshotImageData(_ imageData: Data) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let timeStamp = dateFormatter.string(from: Date())
        
        // Replace forward slashes in the game title with underscores because forward slashes aren't allowed in filenames.
        var displayName = rom?.game?.displayName ?? ""
        displayName = displayName.replacingOccurrences(of: "/", with: "_")
        
        let fileName = "\(displayName) \(timeStamp).png"
        let temporaryURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)
        
        do {
            try imageData.write(to: temporaryURL, options: .atomic)
            if let context = rom.managedObjectContext {
                let screenshot = OEDBScreenshot.createObject(in: context, for: rom, with: temporaryURL)
                screenshot?.save()
                gameViewController.showScreenShotNotification()
            }
        } catch {
        }
    }
    
    // MARK: - Volume/Audio
    
    /// expects `sender` or `sender.representedObject` to be an `OEAudioDevice` object
    @IBAction func changeAudioOutputDevice(_ sender: AnyObject) {
        let device: OEAudioDevice
        if let sender = sender as? OEAudioDevice {
            device = sender
        } else if let obj = sender.representedObject as? OEAudioDevice {
            device = obj
        } else {
            assertionFailure("Invalid argument passed: \(String(describing: sender))")
            return
        }
        
        gameCoreManager?.setAudioOutputDeviceID(device.deviceID)
    }
    
    @IBAction func changeAudioOutputDeviceToSystemDefault(_ sender: Any?) {
        gameCoreManager?.setAudioOutputDeviceID(0)
    }
    
    var volume: Float {
        return UserDefaults.standard.float(forKey: OEGameVolumeKey)
    }
    
    func setVolume(_ volume: Float, asDefault defaultFlag: Bool) {
        gameCoreManager?.setVolume(volume)
        gameViewController.reflectVolume(volume)
        
        if defaultFlag {
            UserDefaults.standard.set(volume, forKey: OEGameVolumeKey)
        }
    }
    
    func setSaturation(_ value: Float, asDefault: Bool) {
        imageSaturation = Self.clampedSaturation(value)
        gameCoreHelper?.setGlobalShaderParameters(gamma: CGFloat(imageGamma), saturation: CGFloat(imageSaturation))
        if asDefault {
            UserDefaults.standard.set(imageSaturation, forKey: OEGameSaturationKey)
        }
    }
    
    func setGamma(_ value: Float, asDefault: Bool) {
        imageGamma = Self.clampedGamma(value)
        gameCoreHelper?.setGlobalShaderParameters(gamma: CGFloat(imageGamma), saturation: CGFloat(imageSaturation))
        if asDefault {
            UserDefaults.standard.set(imageGamma, forKey: OEGameGammaKey)
        }
    }
    
    @IBAction func changeVolume(_ sender: AnyObject) {
        if let sender = sender as? NSSlider {
            setVolume(sender.floatValue, asDefault: true)
        } else {
            assertionFailure("Invalid argument passed: \(String(describing: sender))")
        }
    }
    
    @IBAction func mute(_ sender: Any?) {
        isMuted = true
        setVolume(0, asDefault: false)
    }
    
    @IBAction func unmute(_ sender: Any?) {
        isMuted = false
        setVolume(volume, asDefault: false)
    }
    
    func volumeDown(_ sender: Any?) {
        var volume = volume
        volume -= 0.1
        if volume < 0 {
            volume = 0
        }
        setVolume(volume, asDefault: true)
    }
    
    func volumeUp(_ sender: Any?) {
        var volume = volume
        volume += 0.1
        if volume > 1 {
            volume = 1
        }
        setVolume(volume, asDefault: true)
    }
    
    // MARK: - Cheats
    
    var supportsCheats: Bool {
        return corePlugin.supportsCheatCode(forSystemIdentifier: systemPlugin.systemIdentifier)
    }

    var supportsCheatSearch: Bool {
        return corePlugin.supportsCheatSearch(forSystemIdentifier: systemPlugin.systemIdentifier)
    }

    var supportsOnlineCheats: Bool {
        return CheatDatabaseService.shared.supportsSystem(systemPlugin.systemIdentifier)
    }

    func fetchReadableMemoryRegions(completionHandler block: @escaping ([OEMemoryRegionDescriptor]) -> Void) {
        gameCoreManager?.readableMemoryRegionDescriptors(completionHandler: block)
    }

    @IBAction func openCheatSearch(_ sender: Any?) {
        if cheatSearchWindowController == nil {
            cheatSearchWindowController = CheatSearchWindowController(document: self)
        }
        cheatSearchWindowController?.showWindow(self)
    }

    @IBAction func browseOnlineCheats(_ sender: Any?) {
        if browseOnlineCheatsWindowController == nil {
            browseOnlineCheatsWindowController = BrowseOnlineCheatsWindowController(document: self)
        }
        browseOnlineCheatsWindowController?.showWindow(self)
    }

    func addCheatFromSearch(code: String, type: String, name: String, enabled: Bool) {
        let cheat = Cheat(code: code, type: type, name: name)
        if enabled {
            cheat.isEnabled = true
            setCheat(cheat)
        }
        cheats.append(cheat)
        saveUserCheats()
        validateCheatCompatibility()
    }

    /// `cheatSource` (the provider name) is what marks this as Browse Online Cheats-imported,
    /// distinguishing it from cheats added manually or via Cheat Search.
    func addImportedCheat(code: String, name: String, providerName: String, rawCode: String? = nil) {
        // BSNES is the only core that reads the cheat type — it strips ':' from raw
        // address:value codes only when tagged Raw/Action Replay. Everyone else ignores
        // the type or strips the colon itself, so the code shape is all we need.
        let type = code.contains(":") ? OECheatTypeRaw : OECheatTypeGameShark
        let cheat = Cheat(code: code, type: type, name: name, cheatSource: providerName, rawCode: rawCode)
        cheat.isEnabled = true
        setCheat(cheat)
        cheats.append(cheat)
        saveUserCheats()
        validateCheatCompatibility()
    }

    /// Only removes a cheat that was itself imported, so a matching manual/Cheat Search entry is never touched.
    func removeImportedCheat(code: String) {
        let key = CheatFeedbackService.key(for: code)
        guard let index = cheats.firstIndex(where: { $0.cheatSource != nil && CheatFeedbackService.key(for: $0.code) == key })
        else { return }

        let cheat = cheats[index]
        if cheat.isEnabled {
            gameCoreManager?.setCheat(cheat.code, withType: cheat.type, enabled: false)
        }
        cheats.remove(at: index)
        saveUserCheats()
        promptCheatRemovalFeedback(cheat)
    }
    
    /// In order to load cheats, we need the core plugin and the ROM to be set.
    private func loadCheats() {
        if supportsCheats {
            cheats = loadUserCheats()
            validateCheatCompatibility()
        }
    }

    /// Marks cheats as incompatible if the current core can't handle their code format.
    private func validateCheatCompatibility() {
        let systemID = systemPlugin.systemIdentifier
        let coreID = corePlugin.bundleIdentifier
        for cheat in cheats {
            cheat.isCompatibleWithCore = CheatCodeValidator.isValid(
                code: cheat.code, systemIdentifier: systemID, coreIdentifier: coreID
            )
        }
    }

    // MARK: - User Cheat Persistence

    private var userCheatsFileURL: URL? {
        guard let md5 = rom.md5Hash,
              let base = OELibraryDatabase.default?.databaseFolderURL
        else { return nil }
        let dir = base.appendingPathComponent("Cheats", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(md5).json")
    }

    private func loadUserCheats() -> [Cheat] {
        guard let url = userCheatsFileURL,
              let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([Cheat].self, from: data)
        else { return [] }
        return saved
    }

    private func saveUserCheats() {
        guard let url = userCheatsFileURL else { return }
        if let data = try? JSONEncoder().encode(cheats) {
            try? data.write(to: url, options: .atomic)
        }
    }
    
    @IBAction func addCheat(_ sender: Any?) {
        if isHardcoreModeEnabled { return }
        let format = Self.cheatFormat(for: systemPlugin.systemIdentifier)

        var presetCode = ""
        var presetName = ""
        var presetEnable = false

        while true {
            let alert = OEAlert()

            alert.otherInputLabelText = NSLocalizedString("Title:", comment: "")
            alert.showsOtherInputField = true
            alert.otherInputPlaceholderText = NSLocalizedString("Cheat Description", comment: "")
            alert.otherStringValue = presetName

            alert.inputLabelText = NSLocalizedString("Code:", comment: "")
            alert.showsInputField = true
            alert.inputPlaceholderText = format.placeholder
            alert.stringValue = presetCode

            alert.defaultButtonTitle = NSLocalizedString("Add Cheat", comment: "")
            alert.alternateButtonTitle = NSLocalizedString("Cancel", comment: "")

            alert.showsSuppressionButton = true
            alert.suppressionLabelText = NSLocalizedString("Enable now", comment: "Cheats button label")
            alert.suppressionButtonState = presetEnable

            alert.inputLimit = 1000

            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let code = alert.stringValue
            let name = alert.otherStringValue
            let shouldEnable = alert.suppressionButtonState

            if let validate = format.validator, !validate(code) {
                let warn = OEAlert()
                warn.messageText = NSLocalizedString("This code doesn't match a known cheat format for this system.", comment: "Add Cheat validation alert title")
                warn.informativeText = format.validationHint
                warn.defaultButtonTitle = NSLocalizedString("Edit", comment: "Add Cheat validation alert: return to the cheat dialog to fix the code")
                warn.alternateButtonTitle = NSLocalizedString("Save Anyway", comment: "Add Cheat validation alert: save the unrecognized code as-is")
                warn.otherButtonTitle = NSLocalizedString("Cancel", comment: "")

                switch warn.runModal() {
                case .alertFirstButtonReturn:
                    presetCode = code
                    presetName = name
                    presetEnable = shouldEnable
                    continue
                case .alertSecondButtonReturn:
                    break
                default:
                    return
                }
            }

            let cheat = Cheat(code: code, type: "GameShark", name: name)

            if shouldEnable {
                cheat.isEnabled = true
                setCheat(cheat)
            }

            cheats.append(cheat)
            saveUserCheats()
            validateCheatCompatibility()
            return
        }
    }

    private struct CheatFormat {
        let placeholder: String
        let validationHint: String
        let validator: ((String) -> Bool)?
    }

    private static let defaultCheatFormat = CheatFormat(
        placeholder: NSLocalizedString("Join multi-line cheats with '+' e.g. 000-000+111-111", comment: "Add Cheat dialog placeholder for systems without a specific format hint"),
        validationHint: "",
        validator: nil
    )

    private static func cheatFormat(for systemIdentifier: String) -> CheatFormat {
        switch systemIdentifier {
        case OESystemIdentifierN64:
            return CheatFormat(
                placeholder: NSLocalizedString("12 hex chars per code, e.g. 8033B21D0064. Join multi-line cheats with '+'.", comment: "Add Cheat dialog placeholder, N64"),
                validationHint: NSLocalizedString("N64 codes must be 12 hex characters (8-char address + 4-char value), e.g. 8033B21D0064. Longer 16-char GameShark Pro / Action Replay codes are not supported by the Mupen64Plus core.", comment: "Add Cheat validation hint, N64"),
                validator: { code in
                    let parts = code.replacingOccurrences(of: " ", with: "")
                                    .replacingOccurrences(of: "\n", with: "")
                                    .split(separator: "+")
                    guard !parts.isEmpty else { return false }
                    return parts.allSatisfy { p in
                        p.count == 12 && p.allSatisfy { $0.isHexDigit }
                    }
                }
            )
        case OESystemIdentifierNES, OESystemIdentifierFDS:
            return CheatFormat(
                placeholder: NSLocalizedString("Game Genie or raw hex (XXXX:YY). Join multi-line cheats with '+'.", comment: "Add Cheat dialog placeholder, NES"),
                validationHint: "",
                validator: nil
            )
        case OESystemIdentifierSNES:
            return CheatFormat(
                placeholder: NSLocalizedString("Game Genie or PAR codes. Join multi-line cheats with '+'.", comment: "Add Cheat dialog placeholder, SNES"),
                validationHint: "",
                validator: nil
            )
        case OESystemIdentifierGB, OESystemIdentifierGBA:
            return CheatFormat(
                placeholder: NSLocalizedString("GameShark (no dash) or Game Genie (with dash). Join multi-line cheats with '+'.", comment: "Add Cheat dialog placeholder, Game Boy / GBA"),
                validationHint: "",
                validator: nil
            )
        case OESystemIdentifierGenesis, OESystemIdentifierSMS, OESystemIdentifierGameGear, OESystemIdentifierSega32X, OESystemIdentifierSegaCD:
            return CheatFormat(
                placeholder: NSLocalizedString("Game Genie or Action Replay. Join multi-line cheats with '+'.", comment: "Add Cheat dialog placeholder, Sega"),
                validationHint: "",
                validator: nil
            )
        case OESystemIdentifierPSX:
            return CheatFormat(
                placeholder: NSLocalizedString("12 hex chars per code, e.g. 80097BA0 270F. Join multi-line cheats with '+'.", comment: "Add Cheat dialog placeholder, PSX"),
                validationHint: NSLocalizedString("PSX GameShark codes must be 12 hex characters (e.g. 80097BA0 270F). Type byte: 30=8-bit, 80=16-bit.", comment: "Add Cheat validation hint, PSX"),
                validator: { code in
                    let parts = code.replacingOccurrences(of: " ", with: "")
                                    .split(separator: "+")
                    guard !parts.isEmpty else { return false }
                    return parts.allSatisfy { p in
                        p.count == 12 && p.allSatisfy { $0.isHexDigit }
                    }
                }
            )
        case OESystemIdentifierPCE:
            return CheatFormat(
                placeholder: NSLocalizedString("Physical (F82DBA:02) or linear (1F0083:02) address. Join multi-line cheats with '+'.", comment: "Add Cheat dialog placeholder, PC Engine"),
                validationHint: NSLocalizedString("PC Engine codes must be a 6 hex digit address plus a 2 hex digit value, e.g. F82DBA:02 or 1F0083:02.", comment: "Add Cheat validation hint, PC Engine"),
                validator: { code in
                    let parts = code.replacingOccurrences(of: " ", with: "")
                                    .replacingOccurrences(of: "\n", with: "")
                                    .split(separator: "+")
                    guard !parts.isEmpty else { return false }
                    return parts.allSatisfy { CheatCodeValidator.isPCECode(String($0)) }
                }
            )
        case OESystemIdentifierSaturn:
            return CheatFormat(
                placeholder: NSLocalizedString("12 hex chars per code, e.g. 16073358 0003. Join multi-line cheats with '+'.", comment: "Add Cheat dialog placeholder, Saturn"),
                validationHint: NSLocalizedString("Saturn Action Replay codes must be 12 hex characters (8-char address + 4-char value), e.g. 16073358 0003. The first hex digit must be 1 (word write) or 3 (byte write).", comment: "Add Cheat validation hint, Saturn"),
                validator: { code in
                    let parts = code.replacingOccurrences(of: " ", with: "")
                                    .replacingOccurrences(of: "\n", with: "")
                                    .split(separator: "+")
                    guard !parts.isEmpty else { return false }
                    return parts.allSatisfy { CheatCodeValidator.isSaturnActionReplayCode(String($0)) }
                }
            )
        case OESystemIdentifier5200:
            return CheatFormat(
                placeholder: NSLocalizedString("Hex address + hex value, e.g. 0034:03. Join multi-line cheats with '+'.", comment: "Add Cheat dialog placeholder, Atari 5200"),
                validationHint: NSLocalizedString("Atari 5200 codes must be a hex address plus a hex value (max 4 and 2 hex digits), e.g. 0034:03. No Game Genie/GameShark format exists for this system.", comment: "Add Cheat validation hint, Atari 5200"),
                validator: { code in
                    let parts = code.replacingOccurrences(of: " ", with: "")
                                    .replacingOccurrences(of: "\n", with: "")
                                    .split(separator: "+")
                    guard !parts.isEmpty else { return false }
                    return parts.allSatisfy { CheatCodeValidator.isRawAddressValue(String($0), maxAddressHexChars: 4, maxValueHexChars: 2) }
                }
            )
        case OESystemIdentifierVB:
            return CheatFormat(
                placeholder: NSLocalizedString("8 hex digit address + 2 hex digit value, e.g. 05001234:FF. Join multi-line cheats with '+'.", comment: "Add Cheat dialog placeholder, Virtual Boy"),
                validationHint: NSLocalizedString("Virtual Boy codes must be an 8 hex digit address plus a 2 hex digit value, e.g. 05001234:FF. Only raw WRAM writes are supported (address 0500xxxx-0501xxxx); no Game Genie/GameShark format exists for this system.", comment: "Add Cheat validation hint, Virtual Boy"),
                validator: { code in
                    let parts = code.replacingOccurrences(of: " ", with: "")
                                    .replacingOccurrences(of: "\n", with: "")
                                    .split(separator: "+")
                    guard !parts.isEmpty else { return false }
                    return parts.allSatisfy { CheatCodeValidator.isRawAddressValue(String($0), addressHexChars: 8, valueHexChars: 2) }
                }
            )
        default:
            return defaultCheatFormat
        }
    }

    // MARK: - Cheat Search Code Conversion

    struct ConvertedCheat {
        let code: String
        let type: String
    }

    /// Converts a raw cheat search code (ADDRESS:VALUE) to the native format expected by the core.
    static func convertCheatSearchCode(_ code: String, for systemIdentifier: String, addressBytes: UInt8, minDataBytes: UInt8) -> ConvertedCheat {
        switch systemIdentifier {
        case OESystemIdentifierN64:
            return ConvertedCheat(code: Self.convertToGameSharkN64(code), type: OECheatTypeGameShark)
        case OESystemIdentifierPSX:
            return ConvertedCheat(code: Self.convertToGameSharkPSX(code), type: OECheatTypeGameShark)
        case OESystemIdentifierGB:
            return ConvertedCheat(code: Self.convertToGameSharkGB(code), type: OECheatTypeGameShark)
        case OESystemIdentifierNDS:
            return ConvertedCheat(code: Self.convertToActionReplayDS(code), type: OECheatTypeActionReplay)
        case OESystemIdentifierSaturn:
            return ConvertedCheat(code: Self.convertToSaturnAR(code), type: OECheatTypeActionReplay)
        default:
            return ConvertedCheat(code: Self.convertToRaw(code, addressBytes: addressBytes, minDataBytes: minDataBytes), type: OECheatTypeRaw)
        }
    }

    // MARK: Saturn Action Replay (TAAAAAAA VVVV)

    private static func convertToSaturnAR(_ code: String) -> String {
        guard let colonIdx = code.firstIndex(of: ":") else { return code }
        let addressPart = String(code[code.startIndex..<colonIdx])
        let valuePart = String(code[code.index(after: colonIdx)...])

        let address = UInt64(addressPart, radix: 16) ?? 0
        let value = UInt64(valuePart, radix: 16) ?? 0
        let byteCount = max(1, (valuePart.count + 1) / 2)

        if byteCount <= 2 {
            // Type: 1 = word (2 bytes), 3 = byte (1 byte)
            let typeNibble: UInt64 = (byteCount <= 1) ? 3 : 1
            let arAddress = (typeNibble << 28) | (address & 0x0FFFFFFF)
            return String(format: "%08X %04X", UInt32(arAddress), UInt32(value & 0xFFFF))
        }

        // Split 4-byte values into two word-writes (big-endian: high word first)
        let highWord = UInt32((value >> 16) & 0xFFFF)
        let lowWord = UInt32(value & 0xFFFF)
        let arAddr1 = (UInt64(1) << 28) | (address & 0x0FFFFFFF)
        let arAddr2 = (UInt64(1) << 28) | ((address + 2) & 0x0FFFFFFF)
        return String(format: "%08X %04X+%08X %04X", UInt32(arAddr1), highWord, UInt32(arAddr2), lowWord)
    }

    // MARK: Raw format (ADDRESS:VALUE with padding and multi-byte splitting)

    private static func convertToRaw(_ code: String, addressBytes: UInt8, minDataBytes: UInt8) -> String {
        guard let colonIdx = code.firstIndex(of: ":") else { return code }
        let addressPart = String(code[code.startIndex..<colonIdx])
        let valuePart = String(code[code.index(after: colonIdx)...])

        let hexDigits = Int(addressBytes) * 2
        let address = UInt64(addressPart, radix: 16) ?? 0
        let value = UInt64(valuePart, radix: 16) ?? 0
        let byteCount = max(1, (valuePart.count + 1) / 2)

        if byteCount <= Int(minDataBytes) {
            let mask: UInt64 = (1 << (UInt64(minDataBytes) * 8)) - 1
            let addrStr = String(format: "%0\(hexDigits)llX", address)
            let valStr = String(format: "%0\(Int(minDataBytes) * 2)X", UInt32(value & mask))
            return "\(addrStr):\(valStr)"
        }

        let chunkCount = (byteCount + Int(minDataBytes) - 1) / Int(minDataBytes)
        let chunkMask: UInt64 = (1 << (UInt64(minDataBytes) * 8)) - 1
        var codes: [String] = []
        for i in 0..<chunkCount {
            let chunk = UInt32((value >> (UInt64(i) * UInt64(minDataBytes) * 8)) & chunkMask)
            let addr = address + UInt64(i) * UInt64(minDataBytes)
            let addrStr = String(format: "%0\(hexDigits)llX", addr)
            let valStr = String(format: "%0\(Int(minDataBytes) * 2)X", chunk)
            codes.append("\(addrStr):\(valStr)")
        }
        return codes.joined(separator: "+")
    }

    // MARK: Game Boy GameShark (01VVLLHH)

    private static func convertToGameSharkGB(_ code: String) -> String {
        guard let colonIdx = code.firstIndex(of: ":") else { return code }
        let addressPart = String(code[code.startIndex..<colonIdx])
        let valuePart = String(code[code.index(after: colonIdx)...])

        let address = UInt16(addressPart, radix: 16) ?? 0
        let value = UInt64(valuePart, radix: 16) ?? 0
        let byteCount = max(1, (valuePart.count + 1) / 2)

        var codes: [String] = []
        for i in 0..<byteCount {
            let byte = UInt8((value >> (i * 8)) & 0xFF)
            let addr = address &+ UInt16(i)
            codes.append(String(format: "01%02X%02X%02X", byte, addr & 0xFF, (addr >> 8) & 0xFF))
        }
        return codes.joined(separator: "+")
    }

    // MARK: NDS Action Replay DS

    private static func convertToActionReplayDS(_ code: String) -> String {
        guard let colonIdx = code.firstIndex(of: ":") else { return code }
        let addressPart = String(code[code.startIndex..<colonIdx])
        let valuePart = String(code[code.index(after: colonIdx)...])

        let address = UInt64(addressPart, radix: 16) ?? 0
        let value = UInt64(valuePart, radix: 16) ?? 0
        let byteCount = max(1, (valuePart.count + 1) / 2)

        var codes: [String] = []
        var offset = 0
        while offset < byteCount {
            let remaining = byteCount - offset
            let addr28 = UInt32((address + UInt64(offset)) & 0x0FFFFFFF)
            let shifted = value >> (offset * 8)

            if remaining >= 4 && (addr28 % 4 == 0) {
                let val32 = UInt32(shifted & 0xFFFFFFFF)
                codes.append(String(format: "%08X %08X", 0x00000000 | addr28, val32))
                offset += 4
            } else if remaining >= 2 && (addr28 % 2 == 0) {
                let val16 = UInt32(shifted & 0xFFFF)
                codes.append(String(format: "%08X %08X", 0x10000000 | addr28, val16))
                offset += 2
            } else {
                let val8 = UInt32(shifted & 0xFF)
                codes.append(String(format: "%08X %08X", 0x20000000 | addr28, val8))
                offset += 1
            }
        }
        return codes.joined(separator: "+")
    }

    // MARK: N64 GameShark (TTXXXXXX YYYY)
    // Mupen64Plus stores RDRAM as host-native uint32 words; the cheat engine XORs byte/halfword
    // addresses (S8=3, S16=2) to find the correct raw offset. We XOR here to convert the raw
    // buffer offset (from cheat search) to the N64 virtual address the engine expects.
    
    private static func convertToGameSharkN64(_ code: String) -> String {
        guard let colonIdx = code.firstIndex(of: ":") else { return code }
        let addressPart = String(code[code.startIndex..<colonIdx])
        let valuePart = String(code[code.index(after: colonIdx)...])

        let address = UInt64(addressPart, radix: 16) ?? 0
        let value = UInt64(valuePart, radix: 16) ?? 0
        let byteCount = max(1, (valuePart.count + 1) / 2)

        let baseAddr = UInt32(address & 0x00FFFFFF)
        var codes: [String] = []
        var offset = 0
        while offset < byteCount {
            let remaining = byteCount - offset
            let rawAddr = baseAddr + UInt32(offset)

            if remaining >= 2 && (rawAddr % 2 == 0) {
                // Convert raw buffer offset to N64 virtual address (XOR 2 for halfword)
                let n64Addr = rawAddr ^ 2
                let val16 = UInt16((value >> ((byteCount - offset - 2) * 8)) & 0xFFFF)
                codes.append(String(format: "%08X%04X", 0x81000000 | n64Addr, val16))
                offset += 2
            } else {
                // Convert raw buffer offset to N64 virtual address (XOR 3 for byte)
                let n64Addr = rawAddr ^ 3
                let val8 = UInt8((value >> ((byteCount - offset - 1) * 8)) & 0xFF)
                codes.append(String(format: "%08X%04X", 0x80000000 | n64Addr, UInt16(val8)))
                offset += 1
            }
        }
        return codes.joined(separator: "+")
    }

    // MARK: PSX GameShark (TTAAAAAA VVVV — little-endian, 12 nybbles)

    private static func convertToGameSharkPSX(_ code: String) -> String {
        guard let colonIdx = code.firstIndex(of: ":") else { return code }
        let addressPart = String(code[code.startIndex..<colonIdx])
        let valuePart = String(code[code.index(after: colonIdx)...])

        let address = UInt64(addressPart, radix: 16) ?? 0
        let value = UInt64(valuePart, radix: 16) ?? 0
        let byteCount = max(1, (valuePart.count + 1) / 2)

        let baseAddr = UInt32(address & 0x00FFFFFF)
        var codes: [String] = []
        var offset = 0
        while offset < byteCount {
            let remaining = byteCount - offset
            let addr = baseAddr + UInt32(offset)

            if remaining >= 2 && (addr % 2 == 0) {
                let val16 = UInt16((value >> (offset * 8)) & 0xFFFF)
                codes.append(String(format: "%08X %04X", 0x80000000 | addr, val16))
                offset += 2
            } else {
                let val8 = UInt8((value >> (offset * 8)) & 0xFF)
                codes.append(String(format: "%08X %04X", 0x30000000 | addr, UInt16(val8)))
                offset += 1
            }
        }
        return codes.joined(separator: "+")
    }

    /// expects `sender.representedObject` to be a `Cheat` object
    @IBAction func toggleCheat(_ sender: AnyObject) {
        if isHardcoreModeEnabled { return }
        guard let cheat = sender.representedObject as? Cheat
        else { return }

        cheat.isEnabled.toggle()
        setCheat(cheat)
        saveUserCheats()
    }

    /// expects `sender.representedObject` to be a `Cheat` object
    @IBAction func editCheat(_ sender: AnyObject) {
        if isHardcoreModeEnabled { return }
        guard let cheat = sender.representedObject as? Cheat,
              cheats.contains(where: { $0 === cheat })
        else { return }

        let alert = OEAlert()

        alert.otherInputLabelText = NSLocalizedString("Title:", comment: "")
        alert.showsOtherInputField = true
        alert.otherStringValue = cheat.name

        alert.inputLabelText = NSLocalizedString("Code:", comment: "")
        alert.showsInputField = true
        alert.stringValue = cheat.code

        alert.defaultButtonTitle = NSLocalizedString("Save Cheat", comment: "")
        alert.alternateButtonTitle = NSLocalizedString("Cancel", comment: "")

        alert.inputLimit = 1000

        if alert.runModal() == .alertFirstButtonReturn {
            let newCode = alert.stringValue.trimmingCharacters(in: .whitespaces)
            guard !newCode.isEmpty else { return }

            guard let currentIndex = cheats.firstIndex(where: { $0 === cheat }) else { return }

            let edited = Cheat(code: newCode, type: cheat.type, name: alert.otherStringValue)
            edited.isEnabled = cheat.isEnabled

            if cheat.isEnabled {
                gameCoreManager?.setCheat(cheat.code, withType: cheat.type, enabled: false)
            }
            cheats[currentIndex] = edited
            if edited.isEnabled {
                setCheat(edited)
            }
            saveUserCheats()
            validateCheatCompatibility()
        }
    }

    /// expects `sender.representedObject` to be a `Cheat` object
    @IBAction func removeCheat(_ sender: AnyObject) {
        if isHardcoreModeEnabled { return }
        guard let cheat = sender.representedObject as? Cheat,
              let index = cheats.firstIndex(where: { $0 === cheat })
        else { return }

        if cheat.isEnabled {
            gameCoreManager?.setCheat(cheat.code, withType: cheat.type, enabled: false)
        }
        cheats.remove(at: index)
        saveUserCheats()
        // Only imported cheats have known-good/bad feedback worth asking about — manual/Cheat Search
        // codes aren't sourced from a shared database, so there's nothing to report back against.
        if cheat.cheatSource != nil {
            promptCheatRemovalFeedback(cheat)
        }
    }

    /// Shared by every place a cheat gets removed — the menu's Remove item and Browse Online
    /// Cheats' Remove button — so the "did it work" report is asked consistently either way.
    func promptCheatRemovalFeedback(_ cheat: Cheat) {
        guard let md5 = rom.md5Hash else { return }

        let existingStatuses = CheatFeedbackService.shared.statuses(forMD5: md5,
                                                                    systemIdentifier: systemPlugin.systemIdentifier,
                                                                    coreIdentifier: corePlugin.bundleIdentifier,
                                                                    coreVersion: corePlugin.version)
        // Already reported on for this core build — don't ask again for a value the user already gave.
        guard existingStatuses[CheatFeedbackService.key(for: cheat.code)] == nil else { return }

        let alert = OEAlert()
        alert.messageText = NSLocalizedString("Cheat Removed", comment: "Cheat removal feedback dialog title")
        alert.informativeText = NSLocalizedString("Did this cheat code work for you?", comment: "Cheat removal feedback dialog question")
        // Removing (rather than just disabling) a working cheat is unusual, so "No" gets the default/rightmost slot as the likely answer.
        alert.defaultButtonTitle = NSLocalizedString("No", comment: "Cheat removal feedback dialog option")
        alert.alternateButtonTitle = NSLocalizedString("Yes", comment: "Cheat removal feedback dialog option")
        alert.alternateButtonColor = NSColor.systemGreen.blended(withFraction: 0.65, of: .systemGray)?.withAlphaComponent(0.4)
        alert.otherButtonTitle = NSLocalizedString("I don't know", comment: "Cheat removal feedback dialog option")

        let status: CheatFeedbackStatus
        switch alert.runModal() {
        case .alertFirstButtonReturn: status = .doesNotWork
        case .alertSecondButtonReturn: status = .works
        default: status = .unknown
        }

        CheatFeedbackService.shared.setStatus(status,
                                             forCode: cheat.code,
                                             md5: md5,
                                             systemIdentifier: systemPlugin.systemIdentifier,
                                             coreIdentifier: corePlugin.bundleIdentifier,
                                             coreVersion: corePlugin.version,
                                             rawCode: cheat.rawCode,
                                             provider: cheat.cheatSource,
                                             gameName: rom.game?.displayName,
                                             serial: rom.serial,
                                             raHash: retroAchievementsSessionInfo?[OERetroAchievementsGameHashKey] as? String)
    }

    /// expects `sender.representedObject` to be a `Cheat` object
    @IBAction func setCheatStatusWorks(_ sender: AnyObject) {
        setCheatFeedbackStatus(.works, sender: sender)
    }

    /// expects `sender.representedObject` to be a `Cheat` object
    @IBAction func setCheatStatusDoesNotWork(_ sender: AnyObject) {
        setCheatFeedbackStatus(.doesNotWork, sender: sender)
    }

    /// expects `sender.representedObject` to be a `Cheat` object
    @IBAction func setCheatStatusUnknown(_ sender: AnyObject) {
        setCheatFeedbackStatus(.unknown, sender: sender)
    }

    private func setCheatFeedbackStatus(_ status: CheatFeedbackStatus, sender: AnyObject) {
        guard let cheat = sender.representedObject as? Cheat, let md5 = rom.md5Hash else { return }
        CheatFeedbackService.shared.setStatus(status,
                                             forCode: cheat.code,
                                             md5: md5,
                                             systemIdentifier: systemPlugin.systemIdentifier,
                                             coreIdentifier: corePlugin.bundleIdentifier,
                                             coreVersion: corePlugin.version,
                                             rawCode: cheat.rawCode,
                                             provider: cheat.cheatSource,
                                             gameName: rom.game?.displayName,
                                             serial: rom.serial,
                                             raHash: retroAchievementsSessionInfo?[OERetroAchievementsGameHashKey] as? String)
    }

    func setCheat(_ cheat: Cheat) {
        if isHardcoreModeEnabled { return }
        gameCoreManager?.setCheat(cheat.code, withType: cheat.type, enabled: cheat.isEnabled)
    }
    
    // MARK: - Discs
    
    var supportsMultipleDiscs: Bool {
        return corePlugin.supportsMultipleDiscs(forSystemIdentifier: systemPlugin.systemIdentifier)
    }
    
    @IBAction func setDisc(_ sender: AnyObject) {
        if let sender = sender.representedObject as? UInt {
            gameCoreManager?.setDisc(sender)
        }
    }
    
    // MARK: - File Insertion
    
    var supportsFileInsertion: Bool {
        return corePlugin.supportsFileInsertion(forSystemIdentifier: systemPlugin.systemIdentifier)
    }
    
    @IBAction func insertFile(_ sender: AnyObject?) {
        var archivedExtensions: [String] = []
        // The Archived Game document type lists all supported archive extensions, e.g. zip
        if let bundleInfo = Bundle.main.infoDictionary,
           let docTypes = bundleInfo["CFBundleDocumentTypes"] as? [[String : Any]],
           let docType = docTypes.first(where: { $0["CFBundleTypeName"] as? String == "Archived Game" }),
           let extensions = docType["CFBundleTypeExtensions"] as? [String]
        {
            archivedExtensions.append(contentsOf: extensions)
        }
        
        let validExtensions = archivedExtensions + systemPlugin.supportedTypeExtensions
        
        let system = rom.game!.system!
        let systemFolder = OELibraryDatabase.default!.romsFolderURL(for: system)
        // Seemed to need this to get NSOpenPanel to restrict to this directory on open for some reason
        let romsFolderURL = URL(fileURLWithPath: systemFolder.path, isDirectory: true)
        
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.directoryURL = romsFolderURL
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowedFileTypes = validExtensions
        
        panel.beginSheetModal(for: gameWindowController!.window!) { result in
            guard
                result == .OK,
                let url = panel.url
            else { return }
            
            let fileURL = ArchiveHelper.decompressFileInArchive(at: url) ?? url
            
            self.gameCoreManager?.insertFile(at: fileURL) { success, error in
                if !success {
                    if let error = error {
                        self.presentError(error)
                    }
                    return
                }
                
                self.isEmulationPaused = false
            }
        }
    }
    
    // MARK: - Display Mode
    
    var supportsDisplayModeChange: Bool {
        return corePlugin.supportsDisplayModeChange(forSystemIdentifier: systemPlugin.systemIdentifier)
    }
    
    @IBAction func nextDisplayMode(_ sender: Any?) {
        changeDisplayMode(directionReversed: false)
    }
    
    @IBAction func lastDisplayMode(_ sender: Any?) {
        changeDisplayMode(directionReversed: true)
    }
    
    /// expects `sender` or `sender.representedObject` to be a `Dictionary<String, Any>` object
    @IBAction func changeDisplayMode(_ sender: Any) {
        let fromMenu: Bool
        let modeDict: [String : Any]
        if let obj = (sender as AnyObject).representedObject as? [String : Any] {
            fromMenu = true
            modeDict = obj
        } else if let sender = sender as? [String : Any] {
            fromMenu = false
            modeDict = sender
        } else {
            return
        }
        
        let isSelected   = modeDict[OEGameCoreDisplayModeStateKey] as? Bool ?? false
        let isToggleable = modeDict[OEGameCoreDisplayModeAllowsToggleKey] as? Bool ?? false
        let isPrefSaveDisallowed = modeDict[OEGameCoreDisplayModeDisallowPrefSaveKey] as? Bool ?? false
        let isManual     = modeDict[OEGameCoreDisplayModeManualOnlyKey] as? Bool ?? false
        
        // Mutually exclusive option is already selected, do nothing
        if isSelected && !isToggleable {
            return
        }
        
        let displayModeKeyForCore = String(format: OEGameCoreDisplayModeKeyFormat, coreIdentifier)
        let prefKey  = modeDict[OEGameCoreDisplayModePrefKeyNameKey] as? String ?? ""
        let prefVal  = modeDict[OEGameCoreDisplayModePrefValueNameKey] as? String ?? ""
        let modeName = modeDict[OEGameCoreDisplayModeNameKey] as? String ?? ""
        let defaults = UserDefaults.standard
        var displayModeInfo: [String : Any]
        
        // Copy existing prefs
        displayModeInfo = defaults.dictionaryRepresentation()[displayModeKeyForCore] as? [String : Any] ?? [:]
        
        // Mutually exclusive option is unselected
        if !isToggleable {
            displayModeInfo[prefKey] = !prefVal.isEmpty ? prefVal : modeName
            if fromMenu && !isManual {
                lastSelectedDisplayModeOption = modeName
            }
        }
        // Toggleable option, swap YES/NO
        else if isToggleable {
            displayModeInfo[prefKey] = !isSelected
        }
        
        if !isPrefSaveDisallowed {
            defaults.set(displayModeInfo, forKey: displayModeKeyForCore)
        }
        
        gameCoreManager?.changeDisplay(withMode: modeName)
    }
    
    private func changeDisplayMode(directionReversed reverse: Bool) {
        var availableOptions: [[String : Any]] = []
        var mode: String
        var isToggleable: Bool
        var isSelected: Bool
        var isManual: Bool
        
        for optionsDict in displayModes {
            mode         = optionsDict[OEGameCoreDisplayModeNameKey] as? String ?? ""
            isToggleable = optionsDict[OEGameCoreDisplayModeAllowsToggleKey] as? Bool ?? false
            isSelected   = optionsDict[OEGameCoreDisplayModeStateKey] as? Bool ?? false
            isManual     = optionsDict[OEGameCoreDisplayModeManualOnlyKey] as? Bool ?? false
            
            if optionsDict[OEGameCoreDisplayModeSeparatorItemKey] != nil ||
                optionsDict[OEGameCoreDisplayModeLabelKey] != nil ||
                isManual {
                continue
            }
            else if !mode.isEmpty && !isToggleable {
                availableOptions.append(optionsDict)
                
                // There may be multiple, but just take the first selected and start from the top
                if lastSelectedDisplayModeOption == nil && isSelected {
                    lastSelectedDisplayModeOption = mode
                }
            }
            else if optionsDict[OEGameCoreDisplayModeGroupNameKey] != nil {
                // Submenu Items
                for subOptionsDict in optionsDict[OEGameCoreDisplayModeGroupItemsKey] as? [[String : Any]] ?? [] {
                    mode         = subOptionsDict[OEGameCoreDisplayModeNameKey] as? String ?? ""
                    isToggleable = subOptionsDict[OEGameCoreDisplayModeAllowsToggleKey] as? Bool ?? false
                    isSelected   = subOptionsDict[OEGameCoreDisplayModeStateKey] as? Bool ?? false
                    isManual     = subOptionsDict[OEGameCoreDisplayModeManualOnlyKey] as? Bool ?? false
                    
                    if subOptionsDict[OEGameCoreDisplayModeSeparatorItemKey] != nil ||
                        subOptionsDict[OEGameCoreDisplayModeLabelKey] != nil ||
                        isManual {
                        continue
                    }
                    else if !mode.isEmpty && !isToggleable {
                        availableOptions.append(subOptionsDict)
                        
                        if lastSelectedDisplayModeOption == nil && isSelected {
                            lastSelectedDisplayModeOption = mode
                        }
                    }
                }
                
                continue
            }
        }
        
        // Reverse
        if reverse {
            availableOptions.reverse()
        }
        
        // If there are multiple mutually-exclusive groups of modes we want to enumerate
        // all the combinations.
        
        // List of pref keys used by each group of mutually exclusive modes
        var prefKeys: [String] = []
        // Index of the currently selected mode for each group
        var prefKeyToSelected: [String : Int] = [:]
        // Indexes of the modes that are part of the same group
        var prefKeyToOptions: [String : NSMutableIndexSet] = [:]
        
        var i = 0
        for optionsDict in availableOptions {
            let prefKey = optionsDict[OEGameCoreDisplayModePrefKeyNameKey] as? String ?? ""
            let name = optionsDict[OEGameCoreDisplayModeNameKey] as? String ?? ""
            
            if name == lastSelectedDisplayModeOption {
                // Put the group of the last mode manually selected by the user in front of the list
                // This way the options of this group will be cycled through first
                if let index = prefKeys.firstIndex(of: prefKey) {
                    prefKeys.remove(at: index)
                }
                prefKeys.insert(prefKey, at: 0)
            }
            else if !prefKeys.contains(prefKey) {
                // Prioritize cycling all other modes in the order that they appear
                prefKeys.append(prefKey)
            }
            
            if optionsDict[OEGameCoreDisplayModeStateKey] as? Bool ?? false {
                prefKeyToSelected[prefKey] = i
            }
            
            var optionsIndexes = prefKeyToOptions[prefKey]
            if optionsIndexes == nil {
                optionsIndexes = NSMutableIndexSet()
                prefKeyToOptions[prefKey] = optionsIndexes
            }
            optionsIndexes?.add(i)
            
            i += 1
        }
        
        for prefKey in prefKeys {
            let current = prefKeyToSelected[prefKey]!
            let options = prefKeyToOptions[prefKey]!
            
            var carry = false
            var next = options.indexGreaterThanIndex(current)
            if next == NSNotFound {
                // Finished cycling through this mode; advance to the next one
                carry = true
                next = options.firstIndex
            }
            
            let nextMode = availableOptions[next]
            changeDisplayMode(nextMode)
            
            if !carry {
                break
            }
        }
    }
    
    // MARK: - Saving States
    
    var supportsSaveStates: Bool {
        return lockOnROMURL == nil && !corePlugin.saveStatesNotSupported(forSystemIdentifier: systemPlugin.systemIdentifier)
    }
    
    @objc private func saveState(_ sender: Any?) {
        if !supportsSaveStates {
            return
        }
        
        let didPauseEmulation = pauseEmulationIfNeeded()
        
        let saveGameNo = rom.saveStateCount + 1
        let date = Date()
        let formatter = DateFormatter()
        formatter.timeZone = NSTimeZone.local
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZ"
        
        let format = NSLocalizedString("Save-Game-%ld %@", comment: "default save state name")
        let proposedName = String(format: format, saveGameNo, formatter.string(from: date))
        let alert = OEAlert.saveGame(proposedName: proposedName)
        
        alert.performBlockInModalSession {
            let parentFrame = self.gameViewController.view.window?.frame ?? .zero
            let alertSize = alert.window.frame.size
            let alertX = (parentFrame.width - alertSize.width) / 2 + parentFrame.origin.x
            let alertY = (parentFrame.height - alertSize.height) / 2 + parentFrame.origin.y
            alert.window.setFrameOrigin(NSPoint(x: alertX, y: alertY))
        }
        
        if alert.runModal() == .alertFirstButtonReturn {
            if alert.stringValue.isEmpty {
                saveState(name: proposedName)
            } else {
                saveState(name: alert.stringValue)
            }
        }
        
        if didPauseEmulation {
            isEmulationPaused = false
        }
    }
    
    @objc func quickSave(_ sender: AnyObject?) {
        var slot = 0
        if let obj = sender?.representedObject as? Int {
            slot = obj
        }
        
        let name = OEDBSaveState.nameOfQuickSave(inSlot: slot)
        let didPauseEmulation = pauseEmulationIfNeeded()
        
        saveState(name: name) {
            if didPauseEmulation {
                self.isEmulationPaused = false
            }
            self.gameViewController.showQuickSaveNotification()
        }
    }
    
    private func saveState(name stateName: String, completionHandler handler: (() -> Void)? = nil) {
        guard
            supportsSaveStates,
            emulationStatus.rawValue > EmulationStatus.starting.rawValue,
            let rom = rom,
            let core = corePlugin,
            // Without this the optional chaining below would skip the closure and the
            // handler would never run, stranding canClose() and wedging the window shut.
            let gameCoreManager = gameCoreManager
        else {
            handler?()
            return
        }
        
        let temporaryDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        var temporaryStateFileURL = URL(string: UUID().uuidString, relativeTo: temporaryDirectoryURL)!
        
        temporaryStateFileURL = temporaryStateFileURL.uniqueURL { triesCount in
            return URL(string: UUID().uuidString, relativeTo: temporaryDirectoryURL)!
        }
        
        SentryService.addBreadcrumb(message: "Save state written: \(stateName)", category: "savestate")
        gameCoreManager.saveStateToFile(at: temporaryStateFileURL) { success, error in
            if !success {
                handler?()
                return
            }
            
            // Re-fetch rom in mainThreadContext for both branches — self.rom may be from a
            // different NSManagedObjectContext, and calling saveState(withName:) on a
            // cross-context object crashes (#453 fixed the else branch; this closes the gap
            // for quicksave/autosave which use the specialNamePrefix branch).
            let context = OELibraryDatabase.default!.mainThreadContext
            let romInContext = context.object(with: rom.objectID) as! OEDBRom

            var saveState: OEDBSaveState?
            if stateName.hasPrefix(OEDBSaveState.specialNamePrefix),
               let state = romInContext.saveState(withName: stateName) {
                state.coreIdentifier = core.bundleIdentifier
                state.coreVersion = core.version
                state.replaceStateFileWithFile(at: temporaryStateFileURL)
                state.timestamp = Date()
                saveState = state
            } else {
                saveState = OEDBSaveState.createSaveState(named: stateName, for: romInContext, core: core, withFile: temporaryStateFileURL, in: context)
            }
            
            guard let state = saveState else {
                handler?()
                return
            }

            // Move the rcheevos progress sidecar written by the helper (at the temp path)
            // into the save-state bundle alongside the State data file.
            let sidecarTemp = temporaryStateFileURL.appendingPathExtension("raprogress")
            let sidecarDest = state.dataFileURL.appendingPathExtension("raprogress")
            if FileManager.default.fileExists(atPath: sidecarTemp.path) {
                _ = try? FileManager.default.replaceItemAt(sidecarDest, withItemAt: sidecarTemp)
            }

            let mainContext = state.managedObjectContext
            mainContext?.perform {
                try? mainContext?.save()
            }
            
            let defaults = UserDefaults.standard
            let type = NSBitmapImageRep.FileType(rawValue: UInt(defaults.integer(forKey: OEScreenshotFileFormatKey)))!
            let properties = defaults.dictionary(forKey: OEScreenshotPropertiesKey) as! [NSBitmapImageRep.PropertyKey : Any]
            
            self.gameCoreManager?.captureSourceImage() { image in
                let newSize = self.gameViewController.defaultScreenSize
                let image = image.resized(newSize) ?? image
                let convertedData = image.representation(using: type, properties: properties)
                DispatchQueue.main.async {
                    do {
                        try convertedData?.write(to: state.screenshotURL, options: .atomic)
                    } catch {
                    }
                    handler?()
                }
            }
        }
    }
    
    // MARK: - Loading States
    
    /// expects `sender` or `sender.representedObject` to be an `OEDBSaveState` object
    @objc private func loadState(_ sender: AnyObject?) {
        // Check hardcore before pausing — if we pause first and then bail,
        // the game is left stuck paused with no resume (#447).
        if !HardcoreModePolicy.allows(.loadState, hardcoreEnabled: isHardcoreModeEnabled) {
            let alert = OEAlert()
            alert.messageText = NSLocalizedString("Save state loading is disabled in hardcore mode.", comment: "")
            alert.informativeText = NSLocalizedString("Turn off hardcore mode in Preferences ▸ RetroAchievements to load save states.", comment: "")
            alert.defaultButtonTitle = NSLocalizedString("OK", comment: "")
            if let win = gameWindowController?.window {
                alert.beginSheetModal(for: win) { _ in }
            } else {
                alert.runModal()
            }
            return
        }

        // calling pauseGame here because it might need some time to execute
        let didPause = pauseEmulationIfNeeded()

        let state: OEDBSaveState
        if let sender = sender as? OEDBSaveState {
            state = sender
        } else if let obj = (sender?.representedObject as AnyObject?) as? OEDBSaveState {
            state = obj
        } else {
            DLog("loadState: invalid sender \(String(describing: sender)), ignoring")
            if didPause { isEmulationPaused = false }
            return
        }

        loadState(state: state)
    }
    
    @objc func quickLoad(_ sender: AnyObject?) {
        var slot = 0
        if let obj = sender?.representedObject as? Int {
            slot = obj
        }
        let quicksaveState = rom.quickSaveState(inSlot: slot)
        if let quicksaveState = quicksaveState {
            loadState(quicksaveState)
        }
    }
    
    private func loadState(state: OEDBSaveState) {
        if state.rom != rom {
            return
        }

        if !HardcoreModePolicy.allows(.loadState, hardcoreEnabled: isHardcoreModeEnabled) {
            return
        }

        let loadState: (() -> Void) = {
            SentryService.addBreadcrumb(message: "Save state loaded: \(state.name)", category: "savestate")
            self.gameCoreManager?.loadStateFromFile(at: state.dataFileURL) { success, error in
                if !success {
                    if let error = error {
                        self.presentError(error)
                    }
                    return
                }
                
                self.isEmulationPaused = false
            }
        }
        
        if coreIdentifier == state.coreIdentifier {
            // Same core — guard against version mismatch before loading.
            // Save states are raw memory dumps; loading one created on a different
            // core version can corrupt internal state and crash the helper process.
            if let savedVersion = state.coreVersion,
               !savedVersion.isEmpty,
               savedVersion != corePlugin.version {
                let alert = OEAlert.coreVersionMismatch(
                    coreName: corePlugin.displayName,
                    savedVersion: savedVersion,
                    installedVersion: corePlugin.version)
                if let win = gameWindowController?.window {
                    alert.beginSheetModal(for: win) { [weak self] response in
                        guard let self else { return }
                        if response == .alertFirstButtonReturn {
                            loadState()
                        } else {
                            self.startEmulation()
                        }
                    }
                } else {
                    if alert.runModal() == .alertFirstButtonReturn {
                        loadState()
                    } else {
                        startEmulation()
                    }
                }
            } else {
                loadState()
            }
            return
        }
        
        let runWithCore: ((OECorePlugin?, Error?) -> Void) = { plugin, error in
            if let plugin = plugin {
                self.setUpGameCoreManager(using: plugin) {
                    loadState()
                }
            } else {
                if let error = error {
                    self.presentError(error)
                }
                return
            }
        }
        
        // Cores that can never resolve again: the RetroArch stubs and the older
        // *-Bridge test cores. Both were generated on this machine and appear in no
        // core feed, so "switch to that core?" can only ever fail for them.
        //
        // Deliberately narrow. A core that is merely *not installed yet* may still be
        // downloadable once the core list finishes loading — that list arrives two
        // async network hops after launch, so treating "not in coresDict right now"
        // as "gone forever" would turn a recoverable prompt into a dead end for
        // ordinary users who open a save state early in launch or while offline.
        let identifier = state.coreIdentifier
        let isRetiredCore = identifier.hasSuffix("-RetroArch")
            || identifier.hasSuffix("-Bridge")
            || identifier.hasPrefix("retroarch.")
        
        if isRetiredCore, !CoreUpdater.shared.canProvideCore(withIdentifier: identifier) {
            let unavailable = OEAlert()
            unavailable.messageText = NSLocalizedString("This save state can't be loaded.", comment: "")
            unavailable.informativeText = String(
                format: NSLocalizedString("It was created with “%@”, a core OpenEmu no longer includes. The game will start without it.", comment: ""),
                identifier)
            unavailable.defaultButtonTitle = NSLocalizedString("Continue", comment: "")
            // Not startEmulation(): that only acts on a document still in .setup. When
            // the state was picked mid-game the document is already .paused, and only
            // isEmulationPaused knows how to resume from there.
            if let win = gameWindowController?.window {
                unavailable.beginSheetModal(for: win) { [weak self] _ in
                    self?.isEmulationPaused = false
                }
            } else {
                unavailable.runModal()
                isEmulationPaused = false
            }
            return
        }
        
        let alert = OEAlert()
        alert.messageText = NSLocalizedString("This save state was created with a different core. Do you want to switch to that core now?", comment: "")
        alert.defaultButtonTitle = NSLocalizedString("Change Core", comment: "")
        alert.alternateButtonTitle = NSLocalizedString("Cancel", comment: "")
        alert.showSuppressionButton(forUDKey: OEAlert.OEAutoSwitchCoreAlertSuppressionKey)
        
        if alert.runModal() == .alertFirstButtonReturn {
            if let core = OECorePlugin.corePlugin(bundleIdentifier: state.coreIdentifier) {
                runWithCore(core, nil)
            } else {
                CoreUpdater.shared.installCore(for: state, withCompletionHandler: runWithCore)
            }
        } else {
            // Same reasoning as above: startEmulation() is a no-op once the document
            // is .paused, which it is whenever the state was chosen mid-game.
            isEmulationPaused = false
        }
    }
    
    // MARK: - Deleting States
    
    /// expects `sender` or `sender.representedObject` to be an `OEDBSaveState` object and prompts the user for confirmation
    @IBAction func deleteSaveState(_ sender: AnyObject) {
        let state: OEDBSaveState
        if let sender = sender as? OEDBSaveState {
            state = sender
        } else if let obj = (sender.representedObject as AnyObject?) as? OEDBSaveState {
            state = obj
        } else {
            assertionFailure("Invalid argument passed: \(String(describing: sender))")
            return
        }
        
        let stateName = state.name
        let alert = OEAlert.deleteSaveState(name: stateName)
        
        if alert.runModal() == .alertFirstButtonReturn {
            state.deleteAndRemoveFiles()
        }
    }
}

// MARK: - NSMenuItemValidation

extension OEGameDocument {
    
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(quickLoad(_:)):
            guard lockOnROMURL == nil else { return false }
            let slot = menuItem.representedObject != nil ? (menuItem.representedObject as? Int) ?? 0 : menuItem.tag
            return rom.quickSaveState(inSlot: slot) != nil
        case #selector(quickSave(_:)):
            return supportsSaveStates
        case #selector(toggleEmulationPaused(_:)):
            if emulationStatus == .paused {
                menuItem.title = NSLocalizedString("Resume Game", comment: "")
                return true
            } else {
                menuItem.title = NSLocalizedString("Pause Game", comment: "")
                return emulationStatus == .playing
            }
        case #selector(nextDisplayMode(_:)),
             #selector(lastDisplayMode(_:)):
            return supportsDisplayModeChange
        case #selector(showRetroAchievements(_:)):
            menuItem.title = NSLocalizedString("Achievements…", comment: "RetroAchievements menu item title")
            menuItem.isHidden = !isRetroAchievementsSessionSupported
            return isRetroAchievementsSessionSupported
        default:
            return true
        }
    }
}

// MARK: - GameViewController Methods

extension OEGameDocument {
    
    func didReceiveMouseEvent(_ event: OEEvent) {
        gameCoreManager?.handleMouseEvent(event)
    }
    
    func updateBackingScaleFactor(_ newScaleFactor: CGFloat) {
        gameCoreManager?.setBackingScaleFactor(newScaleFactor)
    }
    
    func updateBounds(_ newBounds: CGRect) {
        gameCoreManager?.setOutputBounds(newBounds)
    }
}

// MARK: - OESystemBindingsObserver

extension OEGameDocument: OESystemBindingsObserver {
    
    func systemBindings(_ sender: OESystemBindings, didSetEvent event: OEHIDEvent, forBinding bindingDescription: OEBindingDescription, playerNumber: UInt) {
        gameCoreManager?.systemBindingsDidSetEvent(event, forBinding: bindingDescription, playerNumber: playerNumber)
    }
    
    func systemBindings(_ sender: OESystemBindings, didUnsetEvent event: OEHIDEvent, forBinding bindingDescription: OEBindingDescription, playerNumber: UInt) {
        gameCoreManager?.systemBindingsDidUnsetEvent(event, forBinding: bindingDescription, playerNumber: playerNumber)
    }
}

// MARK: - OEGameCoreOwner

@objc extension OEGameDocument: OEGameCoreOwner {
    
    func saveState() {
        NSApp.sendAction(#selector(saveState(_:)), to: nil, from: nil)
        //saveState(nil)
    }
    
    func loadState() {
        // FIXME: This replaces a call from OESystemResponder which used to pass self, but passing OESystemResponder would yield the same result in -loadState: so I do not know whether this ever worked in this case. (6eeda41)
        loadState(nil)
    }
    
    func quickSave() {
        quickSave(nil)
    }
    
    func quickLoad() {
        quickLoad(nil)
    }
    
    func toggleFullScreen() {
        toggleFullScreen(self)
    }
    
    func toggleAudioMute() {
        if isMuted {
            unmute(self)
        } else {
            mute(self)
        }
    }
    
    func volumeDown() {
        volumeDown(self)
    }
    
    func volumeUp() {
        volumeUp(self)
    }
    
    func stopEmulation() {
        stopEmulation(self)
    }
    
    func resetEmulation() {
        resetEmulation(self)
    }
    
    func toggleEmulationPaused() {
        toggleEmulationPaused(self)
    }
    
    func takeScreenshot() {
        takeScreenshot(self)
    }
    
    func fastForwardGameplay(_ enable: Bool) {
        if !HardcoreModePolicy.allows(.fastForward, hardcoreEnabled: isHardcoreModeEnabled) { return }
        if emulationStatus != .playing { return }
        gameViewController.showFastForwardNotification(enable)
    }
    
    func rewindGameplay(_ enable: Bool) {
        if isHardcoreModeEnabled { return }
        let supportsRewinding = corePlugin.supportsRewinding(forSystemIdentifier: systemIdentifier)
        if !supportsRewinding || emulationStatus != .playing { return }
        gameViewController.showRewindNotification(enable)
    }

    func stepGameplayFrameForward() {
        if isHardcoreModeEnabled { return }
        if emulationStatus == .playing {
            toggleEmulationPaused(self)
        }
        if emulationStatus == .paused {
            gameViewController.showStepForwardNotification()
        }
    }

    func stepGameplayFrameBackward() {
        if isHardcoreModeEnabled { return }
        if emulationStatus == .playing {
            toggleEmulationPaused(self)
        }
        if emulationStatus == .paused {
            gameViewController.showStepBackwardNotification()
        }
    }
    
    func nextDisplayMode() {
        nextDisplayMode(self)
    }
    
    func lastDisplayMode() {
        lastDisplayMode(self)
    }
    
    func setScreenSize(_ newScreenSize: OEIntSize, aspectSize newAspectSize: OEIntSize) {
        gameViewController.setScreenSize(newScreenSize, aspectSize: newAspectSize)
    }
    
    func setDiscCount(_ discCount: UInt) {
        self.discCount = discCount
    }
    
    func setDisplayModes(_ displayModes: [[String : Any]]) {
        self.displayModes = displayModes
    }
    
    func setRemoteContextID(_ contextID: OEContextID) {
        gameViewController.setRemoteContextID(contextID)
    }
    
    func gameCoreDidTerminate() {
        if !(emulationStatus == .starting || emulationStatus == .paused) {
            return
        }
        coreDidTerminateSuddenly = true
        stopEmulation(self)
    }

    func retroAchievementsSessionUpdated(_ info: [String: Any]) {
        DispatchQueue.main.async {
            if self.retroAchievementsSessionInfo == nil {
                self.gameViewController?.clearRetroAchievementsIndicators()
            }
            let enrichedInfo = self.retroAchievementsInfoWithLiveStates(info)
            self.retroAchievementsSessionInfo = enrichedInfo
            self.updateRetroAchievementsSuppressedUnlockIDs(from: enrichedInfo)
            NotificationCenter.default.post(name: .OERetroAchievementsSessionDidChange, object: self, userInfo: enrichedInfo)
            if !self.didShowRetroAchievementsBootPlacard {
                self.didShowRetroAchievementsBootPlacard = true
                self.gameViewController?.showRetroAchievementsPlacard(
                    info: enrichedInfo,
                    hardcore: self.isHardcoreModeEnabled,
                    signedIn: OECredentialStore.shared.get(.retroAchievementsToken) != nil
                )
            }
        }
    }

    func retroAchievementsEmulatorUnrecognized() {
        DispatchQueue.main.async {
            self.gameViewController?.showRetroAchievementsUnknownEmulatorNotice()
        }
    }

    func achievementUnlocked(id: UInt32, title: String, description: String, badgeURL: String, points: UInt32) {
        DispatchQueue.main.async {
            // Defensive fallback: bridge intercepts id >= 101000001 and routes
            // it via retroAchievementsEmulatorUnrecognized() instead, so this
            // branch normally won't fire. Kept in case an older core ships the
            // warning through the legacy path.
            if self.isRetroAchievementsUnknownEmulatorWarning(title: title) {
                self.gameViewController?.showRetroAchievementsUnknownEmulatorNotice()
                return
            }
            if self.retroAchievementsSuppressedUnlockIDs.contains(id) {
                return
            }
            self.retroAchievementsSuppressedUnlockIDs.insert(id)

            SentryService.addBreadcrumb(message: "Achievement unlocked: \(title) (\(points) pts)", category: "retroachievements")

            // In-app banner — always visible regardless of Focus mode or notification settings
            self.gameViewController?.showAchievementUnlocked(title: title, description: description, badgeURL: badgeURL, points: points)

            // macOS system notification — timeSensitive breaks through Focus/DND
            let content = UNMutableNotificationContent()
            content.title = title
            content.body  = description
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "ra.achievement.\(id)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func isRetroAchievementsUnknownEmulatorWarning(title: String) -> Bool {
        let foldedTitle = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return foldedTitle.contains("unknown emulator") || foldedTitle.contains("unknown emu")
    }

    private func updateRetroAchievementsSuppressedUnlockIDs(from info: [String: Any]) {
        let requiredUnlockFlag = isHardcoreModeEnabled ? 2 : 1
        let achievements = info[OERetroAchievementsAchievementsKey] as? [[String: Any]] ?? []
        for achievement in achievements {
            guard let id = (achievement[OEAchievementIDKey] as? NSNumber)?.uint32Value else { continue }
            let unlocked = (achievement[OERetroAchievementsUnlockedKey] as? NSNumber)?.intValue ?? 0
            if (unlocked & requiredUnlockFlag) != 0 {
                retroAchievementsSuppressedUnlockIDs.insert(id)
            }
        }
    }

    private func retroAchievementsInfoWithLiveStates(_ info: [String: Any]) -> [String: Any] {
        let achievements = info[OERetroAchievementsAchievementsKey] as? [[String: Any]] ?? []
        guard !achievements.isEmpty else { return info }

        var updatedInfo = info
        updatedInfo[OERetroAchievementsAchievementsKey] = achievements.map { achievement in
            var updatedAchievement = achievement
            updatedAchievement.removeValue(forKey: OERetroAchievementsActiveChallengeKey)
            updatedAchievement.removeValue(forKey: OERetroAchievementsActiveProgressKey)

            guard let id = (achievement[OEAchievementIDKey] as? NSNumber)?.uint32Value else { return updatedAchievement }
            if retroAchievementsActiveChallengeIDs.contains(id) {
                updatedAchievement[OERetroAchievementsActiveChallengeKey] = true
            }
            if let progress = retroAchievementsActiveProgressByAchievementID[id], !progress.isEmpty {
                updatedAchievement[OERetroAchievementsActiveProgressKey] = progress
            }
            return updatedAchievement
        }
        return updatedInfo
    }

    private func refreshRetroAchievementsSessionLiveStates() {
        guard let info = retroAchievementsSessionInfo else { return }
        let updatedInfo = retroAchievementsInfoWithLiveStates(info)
        retroAchievementsSessionInfo = updatedInfo
        NotificationCenter.default.post(name: .OERetroAchievementsSessionDidChange, object: self, userInfo: updatedInfo)
    }

    func retroAchievementsEvent(_ info: [String: Any]) {
        DispatchQueue.main.async {
            self.handleRetroAchievementsEvent(info)
        }
    }

    private func handleRetroAchievementsEvent(_ info: [String: Any]) {
        guard let kind = info[OERetroAchievementsEventKindKey] as? String else { return }
        let id = (info[OERetroAchievementsEventIDKey] as? NSNumber)?.uint32Value ?? 0
        let title = info[OERetroAchievementsEventTitleKey] as? String ?? NSLocalizedString("RetroAchievements", comment: "RetroAchievements event fallback title")
        let description = info[OERetroAchievementsEventDescriptionKey] as? String ?? ""
        let badgeURL = info[OERetroAchievementsEventBadgeURLKey] as? String
        let display = info[OERetroAchievementsEventDisplayKey] as? String ?? ""

        switch kind {
        case "achievementUnlocked":
            // The dedicated achievement unlock path already shows the richer unlock
            // banner and macOS notification. Keep this event for future routing only.
            return
        case "challengeShow":
            if id != 0 { retroAchievementsActiveChallengeIDs.insert(id) }
            refreshRetroAchievementsSessionLiveStates()
            gameViewController?.showRetroAchievementsChallenge(id: id, title: title)
        case "challengeHide":
            if id != 0 { retroAchievementsActiveChallengeIDs.remove(id) }
            refreshRetroAchievementsSessionLiveStates()
            gameViewController?.hideRetroAchievementsChallenge(id: id)
        case "progressShow", "progressUpdate":
            let progress = info[OERetroAchievementsMeasuredProgressKey] as? String ?? display
            if id != 0 { retroAchievementsActiveProgressByAchievementID[id] = progress }
            refreshRetroAchievementsSessionLiveStates()
            gameViewController?.showRetroAchievementsProgress(title: title, progress: progress)
        case "progressHide":
            retroAchievementsActiveProgressByAchievementID.removeAll()
            refreshRetroAchievementsSessionLiveStates()
            gameViewController?.hideRetroAchievementsProgress()
        case "leaderboardStarted":
            gameViewController?.showRetroAchievementsEventToast(title: NSLocalizedString("Leaderboard Started", comment: "RA leaderboard started"), subtitle: title, symbolName: "flag.checkered")
        case "leaderboardFailed":
            gameViewController?.hideAllRetroAchievementsLeaderboards()
            gameViewController?.showRetroAchievementsEventToast(title: NSLocalizedString("Leaderboard Failed", comment: "RA leaderboard failed"), subtitle: title, symbolName: "xmark.circle.fill")
        case "leaderboardSubmitted":
            gameViewController?.hideAllRetroAchievementsLeaderboards()
            gameViewController?.showRetroAchievementsEventToast(title: NSLocalizedString("Leaderboard Submitted", comment: "RA leaderboard submitted"), subtitle: title, symbolName: "checkmark.seal.fill")
        case "leaderboardTrackerShow":
            gameViewController?.showRetroAchievementsLeaderboard(id: id, display: display)
        case "leaderboardTrackerUpdate":
            gameViewController?.updateRetroAchievementsLeaderboard(id: id, display: display)
        case "leaderboardTrackerHide":
            gameViewController?.hideRetroAchievementsLeaderboard(id: id)
        case "leaderboardScoreboard":
            gameViewController?.hideAllRetroAchievementsLeaderboards()
            let submitted = info[OERetroAchievementsEventSubmittedScoreKey] as? String ?? ""
            let rank = (info[OERetroAchievementsEventRankKey] as? NSNumber)?.intValue ?? 0
            let subtitle = rank > 0
                ? String(format: NSLocalizedString("%@ · Rank #%d", comment: "RA leaderboard scoreboard"), submitted, rank)
                : submitted
            gameViewController?.showRetroAchievementsEventToast(title: NSLocalizedString("Leaderboard Result", comment: "RA leaderboard result"), subtitle: subtitle, symbolName: "list.number")
        case "gameCompleted":
            let gameTitle = retroAchievementsSessionInfo?[OERetroAchievementsGameTitleKey] as? String ?? rom.game?.displayName ?? title
            let verb = isHardcoreModeEnabled ? NSLocalizedString("Mastered", comment: "RA mastered game") : NSLocalizedString("Completed", comment: "RA completed game")
            SentryService.addBreadcrumb(message: "\(verb) \(gameTitle) — all achievements earned", category: "retroachievements")
            gameViewController?.showRetroAchievementsEventToast(title: "\(verb) \(gameTitle)", subtitle: NSLocalizedString("All achievements earned", comment: "RA game completed subtitle"), badgeURL: retroAchievementsSessionInfo?[OERetroAchievementsGameBadgeURLKey] as? String, symbolName: "crown.fill")
        case "subsetCompleted":
            let verb = isHardcoreModeEnabled ? NSLocalizedString("Mastered", comment: "RA mastered subset") : NSLocalizedString("Completed", comment: "RA completed subset")
            gameViewController?.showRetroAchievementsEventToast(title: "\(verb) \(title)", subtitle: NSLocalizedString("Achievement set complete", comment: "RA subset completed subtitle"), badgeURL: badgeURL, symbolName: "crown.fill")
        case "resetRequested":
            gameCoreManager?.resetEmulation { [weak self] in
                self?.isEmulationPaused = false
            }
            gameViewController?.showRetroAchievementsEventToast(title: NSLocalizedString("Hardcore Reset", comment: "RA reset requested"), subtitle: NSLocalizedString("Restarting to apply hardcore mode.", comment: "RA reset requested subtitle"), symbolName: "arrow.clockwise.circle.fill")
        case "serverError":
            let message = info[OERetroAchievementsEventErrorMessageKey] as? String ?? description
            gameViewController?.showRetroAchievementsEventToast(title: NSLocalizedString("RetroAchievements Error", comment: "RA server error"), subtitle: message, symbolName: "exclamationmark.triangle.fill")
        case "disconnected":
            gameViewController?.showRetroAchievementsOfflineNotice()
            gameViewController?.showRetroAchievementsEventToast(title: NSLocalizedString("RetroAchievements Offline", comment: "RA disconnected"), subtitle: NSLocalizedString("Some submissions are pending retry.", comment: "RA disconnected subtitle"), symbolName: "wifi.slash")
        case "reconnected":
            gameViewController?.hideRetroAchievementsOfflineNotice()
            gameViewController?.showRetroAchievementsEventToast(title: NSLocalizedString("RetroAchievements Reconnected", comment: "RA reconnected"), subtitle: NSLocalizedString("Pending submissions completed.", comment: "RA reconnected subtitle"), symbolName: "wifi")
        default:
            return
        }
    }
}

// MARK: - Save Sync Integration

extension OEGameDocument {
    
    func performPreLaunchSyncCheckIfNeeded(completion: @escaping () -> Void) {
        guard let systemId = rom?.game?.system?.systemIdentifier,
              let gameName = rom?.game?.displayName else {
            completion()
            return
        }
        // Chain: Google Drive check → folder backup check → launch.
        performGoogleDriveSyncCheck(systemId: systemId, gameName: gameName) { [weak self] in
            guard let self else { completion(); return }
            self.performFolderBackupSyncCheck(systemId: systemId, gameName: gameName, completion: completion)
        }
    }

    private func performGoogleDriveSyncCheck(systemId: String, gameName: String, completion: @escaping () -> Void) {
        let syncManager = OESaveSyncManager.shared
        guard syncManager.isSignedIn else { completion(); return }

        syncManager.checkForNewerCloudSave(
            systemIdentifier: systemId,
            gameName: gameName
        ) { [weak self] shouldSync, cloudDate in
            guard shouldSync else { completion(); return }
            guard let self else { completion(); return }
            self.presentSyncAlert(
                providerName: "Google Drive", gameName: gameName, cloudDate: cloudDate,
                defaultButtonTitle: NSLocalizedString("Download & Play", comment: "Save Sync: download and play"),
                alternateButtonTitle: NSLocalizedString("Play Without Syncing", comment: "Save Sync: skip sync")
            ) { download in
                if download {
                    syncManager.downloadCloudSave(systemIdentifier: systemId, gameName: gameName) { _, _ in
                        completion()
                    }
                } else {
                    completion()
                }
            }
        }
    }

    private func performFolderBackupSyncCheck(systemId: String, gameName: String, completion: @escaping () -> Void) {
        let backupManager = OEFolderBackupManager.shared
        guard backupManager.isEnabled else { completion(); return }

        backupManager.checkForNewerBackup(
            systemIdentifier: systemId,
            gameName: gameName
        ) { [weak self] shouldRestore, backupDate in
            guard shouldRestore else { completion(); return }
            guard let self else { completion(); return }
            self.presentSyncAlert(
                providerName: "backup folder", gameName: gameName, cloudDate: backupDate,
                defaultButtonTitle: NSLocalizedString("Restore & Play", comment: "Save Sync: restore and play"),
                alternateButtonTitle: NSLocalizedString("Play Without Restoring", comment: "Save Sync: skip restore")
            ) { restore in
                if restore {
                    backupManager.restoreFromBackup(systemIdentifier: systemId, gameName: gameName) { _ in
                        completion()
                    }
                } else {
                    completion()
                }
            }
        }
    }

    private func presentSyncAlert(
        providerName: String,
        gameName: String,
        cloudDate: Date?,
        defaultButtonTitle: String,
        alternateButtonTitle: String,
        completion: @escaping (_ download: Bool) -> Void
    ) {
        let dateStr: String
        if let cloudDate {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            dateStr = fmt.string(from: cloudDate)
        } else {
            dateStr = "unknown date"
        }
        let alert = OEAlert()
        alert.messageText = NSLocalizedString("Newer Save Available", comment: "Save Sync alert title")
        alert.informativeText = String(
            format: NSLocalizedString(
                "A newer save for '%@' is available in your %@ (from %@). Restore it before playing?",
                comment: "Save Sync alert body: game name, provider, date"
            ),
            gameName, providerName, dateStr
        )
        alert.defaultButtonTitle   = defaultButtonTitle
        alert.alternateButtonTitle = alternateButtonTitle
        completion(alert.runModal() == .alertFirstButtonReturn)
    }
}
