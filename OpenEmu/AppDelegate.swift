/*
 Copyright (c) 2016, OpenEmu Team

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

import Cocoa
import OpenEmuSystem
import OpenEmuKit
import OpenEmuBase
import UserNotifications

private var appearancePrefChangedKVOContext = 0

protocol CachedLastPlayedInfoItem {}
extension String: CachedLastPlayedInfoItem {}
extension OEDBRom: CachedLastPlayedInfoItem {}

@NSApplicationMain
@objc(OEApplicationDelegate)
@objcMembers
class AppDelegate: NSObject, UNUserNotificationCenterDelegate {
    
    static let websiteAddress = "https://github.com/OpenEmu-Silicon/OpenEmu-Silicon"
    static let userGuideAddress = "https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/wiki"
    static let releaseNotesAddress = "https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/releases"
    static let feedbackAddress = "https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues/new/choose"
    static let bugReportAddress = "https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues/new"

    @IBOutlet weak var fileMenu: NSMenu!
    @IBOutlet weak var helpMenu: NSMenu!
    
    lazy var mainWindowController = MainWindowController(windowNibName: "MainWindow")
    
    lazy var preferencesWindowController = PreferencesWindowController(windowNibName: "Preferences")
    
    var documentController = GameDocumentController.shared
    
    var restoreWindow = false
    var libraryDidLoadObserverForRestoreWindow: NSObjectProtocol?

    /// Result of the most recent orphaned-RetroArch-plugin sweep, surfaced in
    /// core-inventory.txt so we can confirm the cleanup ran.
    fileprivate var orphanedRACleanupReport: (removed: [String], clearedDefaults: [String], failed: [(String, String)]) = ([], [], [])

    /// Result of the most recent SUFeedURL refresh sweep on installed core plugins.
    fileprivate var feedURLRefreshReport: (refreshed: [String], failed: [(String, String)]) = ([], [])
    
    var hidEventsMonitor: Any?
    var keyboardEventsMonitor: Any?
    var unhandledEventsMonitor: Any?
    
    var cachedLastPlayedInfo = [CachedLastPlayedInfoItem]()
    
    var logHIDEvents = false {
        
        didSet {
            
            if let hidEventsMonitor = hidEventsMonitor {
                OEDeviceManager.shared.removeMonitor(hidEventsMonitor)
                self.hidEventsMonitor = nil
            }
            
            if logHIDEvents {
                hidEventsMonitor = OEDeviceManager.shared.addGlobalEventMonitorHandler { handler, event in
                    if event.type != .keyboard {
                        os_log(.info, log: .event_hid, "%{public}@", event)
                    }
                    return true
                }
            }
        }
    }
    
    var logKeyboardEvents = false {
        
        didSet {
            
            if let keyboardEventsMonitor = keyboardEventsMonitor {
                OEDeviceManager.shared.removeMonitor(keyboardEventsMonitor)
                self.keyboardEventsMonitor = nil
            }
            
            if logKeyboardEvents {
                keyboardEventsMonitor = OEDeviceManager.shared.addGlobalEventMonitorHandler { handler, event in
                    if event.type == .keyboard {
                        os_log(.info, log: .event_keyboard, "%{public}@", event)
                    }
                    return true
                }
            }
        }
    }

    var backgroundControllerPlay = false {
        didSet {
            updateEventHandlers()
        }
    }
    
    var libraryLoaded = false
    var reviewingUnsavedDocuments = false
    
    typealias StartupQueueClosure = () -> Void
    var startupQueue = [StartupQueueClosure]()
    
    override init() {
        
        super.init()

        // Get the game library path.
        let libraryDirectory = URL.oeApplicationSupportDirectory
            .appendingPathComponent("Game Library", isDirectory: true)
        let path = (libraryDirectory.path as NSString).abbreviatingWithTildeInPath
        
        #if !DEBUG
            UserDefaults.standard.removeObject(forKey: OEGameCoreManagerModePreferenceKey)
        #endif
        
        // Register defaults.
        UserDefaults.standard.register(defaults: [
            OELibraryDatabase.defaultDatabasePathKey: path,
            OELibraryDatabase.databasePathKey: path,
            OECopyToLibraryKey: true,
            OEAutomaticallyGetInfoKey: true,
            OEGameVolumeKey: 0.5,
            "defaultCore.openemu.system.nes": "org.openemu.Nestopia",
            "defaultCore.openemu.system.snes": "org.openemu.SNES9x",
            OEDBGame.displayGameTitleKey: true,
            OEBackgroundPauseKey: true,
            OEBackgroundControllerPlayKey: true,
            "logsHIDEvents": false,
            "logsHIDEventsNoKeyboard": false,
            OEDBSaveStatesMedia.showsAutoSavesKey: true,
            OEDBSaveStatesMedia.showsQuickSavesKey: true,
            OEForcePopoutGameWindowKey: true,
            OEPopoutGameWindowIntegerScalingOnlyKey: true,
            OEGameLayerNotificationView.OEShowNotificationsKey : true,
            OEAppearance.Application.key: OEAppearance.Application.dark.rawValue,
            OEAppearance.HUDBar.key: OEAppearance.HUDBar.vibrant.rawValue,
            OEAppearance.ControlsPrefs.key: OEAppearance.ControlsPrefs.wood.rawValue,
            OEGameCoreManagerModePreferenceKey: NSStringFromClass(OEXPCGameCoreManager.self),
            RAHardcoreEnabledKey: true,
        ])
        
        // Don't let an old setting override automatically checking for app updates.
        if let automaticChecksEnabled = UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool, automaticChecksEnabled == false {
            UserDefaults.standard.removeObject(forKey: "SUEnableAutomaticChecks")
        }

        // Trigger Objective-C +initialize methods in these classes.
        _ = OEControllerDescription.self

        // Must precede registerClass(): that call enumerates the Cores folder and
        // caches the result for the rest of the launch, so a stub deleted after it
        // would stay in the in-memory plugin list until the next restart.
        removeOrphanedRetroArchPlugins()

        OECorePlugin.registerClass()
        OESystemPlugin.registerClass()
        
        // Reset preferences for default cores when migrating to 2.0.3. This is an attempt at cleanup after 9d5d696d07fe651f44f16f8bf8b98c87d90fe53f and d36e9ad4b7097f21ffbbe32d9cea3b72a390bc0f and for getting as many users as possible onto mGBA.
        OEVersionMigrationController.default.addMigratorTarget(self, selector: #selector(migrationRemoveCoreDefaults), forVersion: "2.0.3")
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NSUserDefaultsController.shared.removeObserver(self, forKeyPath: "values.\(OEAppearance.Application.key)", context: &appearancePrefChangedKVOContext)
    }
    
    // MARK: - Library Database
    
    func loadDatabase() {
        
        let defaults = UserDefaults.standard
        
        let defaultDatabasePath = (defaults.string(forKey: OELibraryDatabase.defaultDatabasePathKey)! as NSString).expandingTildeInPath
        let databasePath: String
        if let databasePathDefault = defaults.string(forKey: OELibraryDatabase.databasePathKey) {
            databasePath = (databasePathDefault as NSString).expandingTildeInPath
        } else {
            databasePath = defaultDatabasePath
        }
        
        let create = !FileManager.default.fileExists(atPath: databasePath) && databasePath == defaultDatabasePath
        
        let userDBSelectionRequest = NSEvent.modifierFlags.contains(.option)
        let databaseURL = URL(fileURLWithPath: databasePath)
        // If user holds down alt key.
        if userDBSelectionRequest {
            // We ask the user to either select/create one or quit OpenEmu.
            performDatabaseSelection()
        } else {
            loadDatabaseAsynchronously(from: databaseURL, createIfNecessary: create)
        }
    }
    
    fileprivate func loadDatabaseAsynchronously(from url: URL, createIfNecessary: Bool) {
        
        if createIfNecessary {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }
        
        do {
            
            try OELibraryDatabase.load(from: url)
            
            assert(OELibraryDatabase.default != nil, "No database available!")
            
            // Must run before any game can load (and so before Browse Online Cheats can open),
            // so the cached cheat databases on disk still reflect whatever produced the existing
            // feedback entries, before this session gets a chance to refresh them.
            CheatFeedbackService.shared.migrateIfNeeded()
            
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .libraryDidLoad, object: OELibraryDatabase.default!)
            }
            
        } catch {
            
            if (error as? CocoaError)?.code == .persistentStoreIncompatibleVersionHash {
                
                let migrator = LibraryMigrator(storeURL: url)
                
                DispatchQueue.global(qos: .default).async {
                    
                    do {
                        
                        try migrator.runMigration()
                        
                        self.loadDatabaseAsynchronously(from: url, createIfNecessary: createIfNecessary)
                        
                    } catch {
                        
                        DLog("Your library can't be opened with this version of OpenEmu.")
                        DLog("\(error)")
                        
                        DispatchQueue.main.async {
                            
                            if (error as NSError).code == 0 { // Foundation._GenericObjCError.nilError
                                let alert = NSAlert()
                                alert.alertStyle = .critical
                                alert.messageText = NSLocalizedString("Your library can’t be opened with this version of OpenEmu.", comment: "")
                                alert.runModal()
                            } else {
                                NSAlert(error: error).runModal()
                            }
                            
                            NSApp.terminate(self)
                        }
                    }
                }
                
            } else {
                DispatchQueue.main.async {
                    self.documentController.presentError(error)
                    self.performDatabaseSelection()
                }
            }
        }
    }
    
    fileprivate func performDatabaseSelection() {
        
        // Set up alert with "Quit", "Select", and "Create".
        let alert = OEAlert()
        alert.messageText = NSLocalizedString("Choose OpenEmu Library", comment: "")
        alert.informativeText = NSLocalizedString("OpenEmu needs a library to continue. You may choose an existing OpenEmu library or create a new one", comment: "")
        alert.defaultButtonTitle = NSLocalizedString("Choose Library…", comment: "")
        alert.alternateButtonTitle = NSLocalizedString("Create Library…", comment: "")
        alert.otherButtonTitle = NSLocalizedString("Quit", comment: "")
        
        switch alert.runModal() {
            
        case .alertThirdButtonReturn:
            NSApp.terminate(self)
            return
            
        case .alertFirstButtonReturn:
            
            let openPanel = NSOpenPanel()
            
            openPanel.canChooseFiles = true
            openPanel.allowedFileTypes = [OELibraryDatabase.databaseFileExtension]
            openPanel.canChooseDirectories = false
            openPanel.allowsMultipleSelection = false
            
            openPanel.begin { result in
                
                if result == .OK {
                    
                    let databaseURL = openPanel.url!.deletingLastPathComponent()
                    
                    self.loadDatabaseAsynchronously(from: databaseURL, createIfNecessary: false)
                    
                } else {
                    openPanel.orderOut(nil)
                    self.performDatabaseSelection()
                }
            }
            
        case .alertSecondButtonReturn:
            
            let savePanel = NSSavePanel()
            
            savePanel.nameFieldStringValue = "OpenEmu Library"
            
            if savePanel.runModal() == .OK {
                
                let databaseURL = savePanel.url!
                try? FileManager.default.removeItem(at: databaseURL)
                try? FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: true, attributes: nil)
                
                loadDatabaseAsynchronously(from: databaseURL, createIfNecessary: true)
                
            } else {
                performDatabaseSelection()
            }
            
        default:
            break
        }
    }
    
    // MARK: -

    fileprivate func validateDefaultPluginAssignments() {

        // Remove Higan WIP systems as defaults if found, since our core port does not support them.
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "defaultCore.openemu.system.gb") == "org.openemu.Higan" {
            defaults.removeObject(forKey: "defaultCore.openemu.system.gb")
        }
        if defaults.string(forKey: "defaultCore.openemu.system.gba") == "org.openemu.Higan" {
            defaults.removeObject(forKey: "defaultCore.openemu.system.gba")
        }
        if defaults.string(forKey: "defaultCore.openemu.system.nes") == "org.openemu.Higan" {
            defaults.removeObject(forKey: "defaultCore.openemu.system.nes")
        }

        // Remove system defaults for deprecated core plugins.
        if defaults.string(forKey: "defaultCore.openemu.system.gba") == "org.openemu.VisualBoyAdvance" {
            defaults.removeObject(forKey: "defaultCore.openemu.system.gba")
        }
        if defaults.string(forKey: "defaultCore.openemu.system.gg") == "org.openemu.CrabEmu" ||
           defaults.string(forKey: "defaultCore.openemu.system.gg") == "org.openemu.TwoMbit" {
            defaults.removeObject(forKey: "defaultCore.openemu.system.gg")
        }
        if defaults.string(forKey: "defaultCore.openemu.system.ngp") == "org.openemu.NeoPop" {
            defaults.removeObject(forKey: "defaultCore.openemu.system.ngp")
        }
        if defaults.string(forKey: "defaultCore.openemu.system.saturn") == "org.openemu.Yabause" {
            defaults.removeObject(forKey: "defaultCore.openemu.system.saturn")
        }
        if defaults.string(forKey: "defaultCore.openemu.system.sms") == "org.openemu.CrabEmu" ||
           defaults.string(forKey: "defaultCore.openemu.system.sms") == "org.openemu.TwoMbit" {
            defaults.removeObject(forKey: "defaultCore.openemu.system.sms")
        }
        if defaults.string(forKey: "defaultCore.openemu.system.gc") == "org.openemu.Dolphin_Core" {
            defaults.removeObject(forKey: "defaultCore.openemu.system.gc")
        }
    }

    /// Removes RetroArch bridge stub plugins left over from before the libretro
    /// bridge was retired.
    ///
    /// Those bundles were generated by OpenEmu itself: each holds a copy of the
    /// OE-side libretro translator binary and an Info.plist naming
    /// `OEGameCoreClass = OELibretroCoreTranslator`. That class no longer exists
    /// in the app, so a stub left on disk is still enumerated by
    /// `OECorePlugin.allPlugins` but cannot resolve its principal class — and
    /// `OECorePlugin.controller` is an implicitly-unwrapped optional, so the
    /// first call site that touches it crashes.
    ///
    /// Must run before any plugin enumeration in `applicationWillFinishLaunching`,
    /// and before `refreshStaleCoreFeedURLs()` so that sweep doesn't rewrite and
    /// re-sign a bundle that is about to be deleted.
    ///
    /// Scope is strictly `~/Library/Application Support/OpenEmu/Cores/`. Save
    /// states, battery saves, and the user's own RetroArch install are untouched
    /// — the stub only ever pointed at an external `.dylib` by path.
    ///
    /// Deliberately not gated on a one-shot "already migrated" default: after the
    /// first launch the sweep is a single directory listing that matches nothing,
    /// and staying unconditional means a restored backup or a downgrade/upgrade
    /// round-trip gets cleaned too.
    fileprivate func removeOrphanedRetroArchPlugins() {
        orphanedRACleanupReport = ([], [], [])

        let fm = FileManager.default
        let coresDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenEmu/Cores")

        var removed: [String] = []
        var removedBundleIDs = Set<String>()
        var failed: [(String, String)] = []

        if let entries = try? fm.contentsOfDirectory(at: coresDir, includingPropertiesForKeys: nil) {
            for plugin in entries where plugin.pathExtension == "oecoreplugin" {
                let name = plugin.deletingPathExtension().lastPathComponent

                // Read the plist first — both to identify the bundle and to
                // capture its identifier before the bundle disappears.
                let plistURL = plugin.appendingPathComponent("Contents/Info.plist")
                let plist: [String: Any]? = {
                    guard
                        let data = try? Data(contentsOf: plistURL),
                        let parsed = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
                    else { return nil }
                    return parsed
                }()

                // Two independent signals: the filename convention the picker
                // used, and the plist contents that actually predict an
                // unloadable bundle.
                let matchesName = name.hasSuffix("-RetroArch")
                let matchesPlist = (plist?["OEGameCoreClass"] as? String) == "OELibretroCoreTranslator"
                    || plist?["OELibretroCorePath"] != nil
                guard matchesName || matchesPlist else { continue }

                let bundleID = (plist?["CFBundleIdentifier"] as? String) ?? "org.openemu.\(name)"

                do {
                    try fm.removeItem(at: plugin)
                    removed.append(name)
                    removedBundleIDs.insert(bundleID)
                    os_log(.info, log: .default, "Removed orphaned RetroArch core plugin: %{public}@ (libretro bridge support was removed in OpenEmu 1.3.1)", plugin.lastPathComponent)
                } catch {
                    // Deleting can fail on a read-only volume, a locked bundle, or
                    // odd permissions. Leaving the bundle in place is the one
                    // genuinely bad outcome: it stays a `.oecoreplugin`, so
                    // `registerClass()` below still enumerates it, it still shows up
                    // under "Play With…", and picking it force-unwraps a nil
                    // controller in OpenEmuHelperApp and takes down the helper.
                    // Renaming the extension is enough to make it invisible to
                    // enumeration, and is a cheaper filesystem operation than the
                    // delete that just failed, so it can succeed where that didn't.
                    let disabled = plugin.deletingPathExtension()
                        .appendingPathExtension("oecoreplugin-disabled")
                    do {
                        try fm.moveItem(at: plugin, to: disabled)
                        removed.append("\(name) (disabled in place)")
                        removedBundleIDs.insert(bundleID)
                        os_log(.error, log: .default,
                               "Could not delete orphaned RetroArch core plugin %{public}@ (%{public}@); renamed it to %{public}@ so it is no longer loaded.",
                               plugin.lastPathComponent, error.localizedDescription, disabled.lastPathComponent)
                    } catch {
                        failed.append((plugin.lastPathComponent, error.localizedDescription))
                        os_log(.error, log: .default, "Failed to remove or disable orphaned RetroArch core plugin %{public}@: %{public}@", plugin.lastPathComponent, error.localizedDescription)
                    }
                }
            }
        }

        // Clear any `defaultCore.<systemID>` pref pointing at a bundle we just
        // removed, at a stub deleted by hand in some earlier session, or at the
        // legacy synthetic `retroarch.<dylib>` ID that never resolved at all.
        // Clearing rather than remapping is correct: with no RA cores left the
        // resolver falls through to the system's native core, or reports "no
        // core" the same way PlayStation 2 and Sega VMU already do.
        let defaults = UserDefaults.standard
        var clearedDefaults: [String] = []
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("defaultCore.") {
            guard let stored = value as? String else { continue }
            guard removedBundleIDs.contains(stored)
                    || stored.hasSuffix("-RetroArch")
                    || stored.hasPrefix("retroarch.")
            else { continue }

            defaults.removeObject(forKey: key)
            clearedDefaults.append(key)
            os_log(.info, log: .default, "Cleared stale core preference %{public}@ (pointed at removed RetroArch core %{public}@)", key, stored)
        }

        if !removed.isEmpty || !clearedDefaults.isEmpty {
            os_log(.info, log: .default, "Orphaned RetroArch cleanup: removed %ld plugin(s), cleared %ld core preference(s)", removed.count, clearedDefaults.count)
        }

        orphanedRACleanupReport = (removed, clearedDefaults, failed)
    }

    /// Walks every installed `*.oecoreplugin` and
    /// rewrites a stale `SUFeedURL` in its `Info.plist` to the canonical
    /// canonical org-hosted appcast. Sparkle and `CoreUpdater` both read the URL
    /// from the installed plist, so cores installed before the URL migration
    /// stay frozen on the dormant upstream URL until this runs.
    ///
    /// Staleness is detected by prefix: any URL that doesn't start with
    /// `canonicalPrefix` is rewritten to `<prefix><lowercased-bundle-suffix>.xml`.
    ///
    /// Rewriting the plist breaks the bundle's existing seal (Info.plist is part
    /// of what codesign hashes), so each touched plugin is re-signed ad hoc
    /// afterward. `disable-library-validation` only waives the "same signing
    /// team" check — it does not let the OS load a bundle whose signature no
    /// longer matches its own contents, so skipping this step leaves the core
    /// unloadable (confirmed via a real crash: a plugin left in this state
    /// fails `OECorePlugin.corePlugin(bundleAtURL:)`, which force-unwraps to nil
    /// in `OpenEmuHelperApp.load(withStartupInfo:)`).
    fileprivate func refreshStaleCoreFeedURLs() {
        let canonicalPrefix = "https://raw.githubusercontent.com/OpenEmu-Silicon/OpenEmu-Silicon/main/Appcasts/"
        feedURLRefreshReport = ([], [])

        let coresDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenEmu/Cores")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: coresDir, includingPropertiesForKeys: nil) else {
            return
        }

        var refreshed: [String] = []
        var failed: [(String, String)] = []

        for plugin in entries where plugin.pathExtension == "oecoreplugin" {
            let plistURL = plugin.appendingPathComponent("Contents/Info.plist")
            guard
                let data  = try? Data(contentsOf: plistURL),
                var plist = (try? PropertyListSerialization.propertyList(from: data, options: [.mutableContainers], format: nil)) as? [String: Any]
            else {
                continue
            }

            guard
                let bundleID    = plist["CFBundleIdentifier"] as? String,
                let currentURL  = plist["SUFeedURL"] as? String
            else {
                continue
            }

            if currentURL.hasPrefix(canonicalPrefix) {
                continue
            }

            let suffix = (bundleID.split(separator: ".").last.map(String.init) ?? "").lowercased()
            guard !suffix.isEmpty else {
                continue
            }
            let canonical = canonicalPrefix + suffix + ".xml"

            do {
                plist["SUFeedURL"] = canonical
                let newData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try newData.write(to: plistURL)

                guard Self.resealPluginSignature(at: plugin) else {
                    // Re-signing failed — put the original plist back so this plugin's
                    // SUFeedURL is still stale on the next launch and the loop above
                    // (`if currentURL.hasPrefix(canonicalPrefix) { continue }`) doesn't
                    // treat it as already handled. Without this, a plugin that failed to
                    // re-sign here would be silently reported as refreshed and then
                    // never retried, left permanently unloadable.
                    try? data.write(to: plistURL)
                    failed.append((plugin.lastPathComponent, "re-sign failed after SUFeedURL rewrite"))
                    os_log(.error, log: .default, "SUFeedURL refresh: re-sign failed for %{public}@ — reverted plist so it retries next launch", plugin.lastPathComponent)
                    continue
                }

                refreshed.append(plugin.deletingPathExtension().lastPathComponent)
                os_log(.info, log: .default, "SUFeedURL refresh: rewrote %{public}@ to %{public}@", plugin.lastPathComponent, canonical)
            } catch {
                failed.append((plugin.lastPathComponent, error.localizedDescription))
                os_log(.error, log: .default, "SUFeedURL refresh failed for %{public}@: %{public}@", plugin.lastPathComponent, error.localizedDescription)
            }
        }

        feedURLRefreshReport = (refreshed, failed)
        os_log(.info, log: .default, "SUFeedURL refresh summary: refreshed=%{public}d failed=%{public}d", refreshed.count, failed.count)
    }

    /// Re-seals a plugin bundle after `refreshStaleCoreFeedURLs` has edited its
    /// Info.plist in place. Runs synchronously and ad hoc (`-`) — a Developer-ID
    /// re-sign would need the org's private signing key, which isn't present on
    /// an end-user machine, and `disable-library-validation` (set on both the
    /// host and the helper) is exactly the entitlement that already lets this
    /// app load ad-hoc-signed plugins, the same mechanism `CoreDownload` relies
    /// on for freshly downloaded cores. This only downgrades trust for a plugin
    /// this code just modified; an untouched Developer-ID-signed plugin is left
    /// alone entirely.
    ///
    /// Returns whether the re-sign actually succeeded, so the caller can avoid
    /// reporting a plugin as fixed — and marking its feed URL as no longer
    /// stale — when it isn't.
    @discardableResult
    private static func resealPluginSignature(at pluginURL: URL) -> Bool {
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", pluginURL.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        do {
            try sign.run()
            sign.waitUntilExit()
            if sign.terminationStatus != 0 {
                os_log(.error, log: .default, "Re-sign after SUFeedURL refresh failed (status %d) for %{public}@", sign.terminationStatus, pluginURL.lastPathComponent)
                return false
            }
            return true
        } catch {
            os_log(.error, log: .default, "Failed to launch codesign after SUFeedURL refresh for %{public}@: %{public}@", pluginURL.lastPathComponent, error.localizedDescription)
            return false
        }
    }

    /// One-shot diagnostic written at startup so we can see what core plugins
    /// actually loaded and which systems they advertise. Output goes to
    /// ~/Library/Logs/OpenEmu/core-inventory.txt — easier to read than the
    /// unified log, and survives across launches. Useful when triaging
    /// "core X doesn't appear in the picker for system Y" reports.
    fileprivate func logCorePluginInventory() {
        let plugins = OECorePlugin.allPlugins.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }

        var out = ""
        out += "=== OpenEmu core plugin inventory ===\n"
        out += "timestamp: \(Date())\n"
        out += "loaded: \(plugins.count) plugins\n\n"

        let r = orphanedRACleanupReport
        out += "--- Orphaned RetroArch plugin cleanup ---\n"
        out += "removed or disabled:   \(r.removed)\n"
        out += "cleared defaults:      \(r.clearedDefaults)\n"
        if r.failed.isEmpty {
            out += "failed this launch:    []\n\n"
        } else {
            out += "failed this launch:\n"
            for (name, err) in r.failed {
                out += "  \(name): \(err)\n"
            }
            out += "\n"
        }

        out += "--- All plugins (sorted) ---\n"
        for p in plugins {
            let bid = p.bundleIdentifier
            let systems = p.systemIdentifiers.joined(separator: ",")
            out += "  \(p.displayName) [\(bid)] systems=[\(systems)]\n"
        }

        // Per-system rollup for the systems most commonly affected.
        let systemsOfInterest = [
            "openemu.system.psx", "openemu.system.snes", "openemu.system.psp",
            "openemu.system.gba", "openemu.system.c64",  "openemu.system.arcade",
            "openemu.system.n64", "openemu.system.dc",   "openemu.system.saturn",
            "openemu.system.nds", "openemu.system.gc",   "openemu.system.wii",
            "openemu.system.ps2",
        ]
        out += "\n--- Per-system rollup ---\n"
        for sysID in systemsOfInterest {
            let matched = OECorePlugin.corePlugins(forSystemIdentifier: sysID)
                .map { $0.displayName }
                .sorted()
            out += "  \(sysID): [\(matched.joined(separator: ", "))]\n"
        }

        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/OpenEmu")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let outURL = logsDir.appendingPathComponent("core-inventory.txt")
        try? out.write(to: outURL, atomically: true, encoding: .utf8)
    }

    fileprivate func loadPlugins(with library: OELibraryDatabase) {
        // Register all system controllers with the bindings controller.
        for plugin in OESystemPlugin.allPlugins {
            if let controller = plugin.controller {
                OEBindingsController.register(controller)
            }
        }

        
        let context = library.mainThreadContext
        for plugin in OESystemPlugin.allPlugins {
            if plugin.controller != nil {
                let system = OEDBSystem.system(for: plugin, in: context)
                // Only auto-enable on first encounter (enabled == nil).
                // If the user explicitly disabled a system, respect that choice.
                if system.isEnabledByDefault {
                    system.isEnabled = true
                }
            }
        }
        
        library.disableSystemsWithoutPlugin()
        try? library.mainThreadContext.save()
    }
    
    fileprivate func removeIncompatibleSaveStates(from database: OELibraryDatabase) {
        let context = database.mainThreadContext

        // Remove save states for deprecated core plugins.
        // Get incompatible save states by version.
        // Genesis Plus GX is especially known for breaking compatibility.
        let currentDesmumeCoreVersion = OECorePlugin.corePlugin(bundleIdentifier: "org.openemu.desmume")?.version
        let incompatibleSaveStates = context.allObjects(ofType: OEDBSaveState.self).filter {
            ($0.coreIdentifier == "org.openemu.CrabEmu" &&
                ($0.location.contains("GameGear/") ||
                 $0.location.contains("SegaMasterSystem/") ||
                 $0.location.contains("SG-1000/"))) ||
            ($0.coreIdentifier == "org.openemu.desmume" && currentDesmumeCoreVersion == "0.9.12" &&
                ($0.coreVersion == "0.9.10" ||
                 $0.coreVersion == "0.9.10.1" ||
                 $0.coreVersion == "0.9.10.2" ||
                 $0.coreVersion == "0.9.11")) ||
            ($0.coreIdentifier == "org.openemu.GenesisPlus" &&
                ($0.coreVersion == "1.7.4" ||
                 $0.coreVersion == "1.7.4.1" ||
                 $0.coreVersion == "1.7.4.2" ||
                 $0.coreVersion == "1.7.4.3" ||
                 $0.coreVersion == "1.7.4.4" ||
                 $0.coreVersion == "1.7.4.5" ||
                 $0.coreVersion == "1.7.4.6")) ||
            ($0.coreIdentifier == "org.openemu.Mupen64Plus" &&
                ($0.coreVersion == "2.5.3" ||
                 $0.coreVersion == "2.5.2" ||
                 $0.coreVersion == "2.5.1" ||
                 $0.coreVersion == "2.5" ||
                 $0.coreVersion == "2.0.1" ||
                 $0.coreVersion == "2.0")) ||
            $0.coreIdentifier == "org.openemu.NeoPop" ||
            $0.coreIdentifier == "org.openemu.TwoMbit" ||
            $0.coreIdentifier == "org.openemu.VisualBoyAdvance" ||
            $0.coreIdentifier == "org.openemu.Dolphin_Core"
        }
        
        guard !incompatibleSaveStates.isEmpty else { return }

        // Build a human-readable list of affected cores for the alert.
        let coreDisplayNames: [String: String] = [
            "org.openemu.CrabEmu":          "CrabEmu (Game Gear / Master System / SG-1000)",
            "org.openemu.desmume":          "DeSmuME (Nintendo DS)",
            "org.openemu.GenesisPlus":      "Genesis Plus GX (Genesis / Mega Drive)",
            "org.openemu.Mupen64Plus":      "Mupen64Plus (Nintendo 64)",
            "org.openemu.NeoPop":           "NeoPop (Neo Geo Pocket)",
            "org.openemu.TwoMbit":          "TwoMbit",
            "org.openemu.VisualBoyAdvance": "VisualBoyAdvance (Game Boy / GBA)",
            "org.openemu.Dolphin_Core":     "Dolphin (GameCube / Wii)",
        ]
        let affectedCores = Set(incompatibleSaveStates.compactMap { $0.coreIdentifier })
            .sorted()
            .map { coreDisplayNames[$0] ?? $0 }
            .joined(separator: "\n")
        let count = incompatibleSaveStates.count

        let alert = NSAlert()
        alert.messageText = "\(count) Incompatible Save State\(count == 1 ? "" : "s") Found"
        alert.informativeText = """
            The following save states were created with older core versions and are no longer \
            compatible. Loading them would cause a crash.

            Affected cores:
            \(affectedCores)

            You can keep them now and back up the files in:
            ~/Library/Application Support/OpenEmu/Save States/
            before deleting, or remove them immediately.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Save States")
        alert.addButton(withTitle: "Keep for Now")

        if alert.runModal() == .alertFirstButtonReturn {
            os_log(.info, log: .default, "Removing %d incompatible save state(s).", count)
            for saveState in incompatibleSaveStates {
                saveState.deleteAndRemoveFiles()
            }
            try? context.save()
        } else {
            os_log(.info, log: .default, "User deferred deletion of %d incompatible save state(s).", count)
        }
    }
    
    fileprivate func setUpHIDSupport() {
        #if DEBUG
        // Suppress the Input Monitoring alert in debug builds so it doesn't
        // re-trigger after every rebuild or TCC reset during development.
        // Grant the permission once via System Settings → Privacy & Security →
        // Input Monitoring; this key prevents the nag alert from firing again.
        UserDefaults.standard.set(true, forKey: "pleaseDoNotAnnoyMeWithThePermissionsAlertEveryTimeIRunThisAppFromXcode")
        #endif

        // Set up OEBindingsController.
        _ = OEBindingsController.self
        let dm = OEDeviceManager.shared
        if #available(macOS 10.15, *) {
            #if DEBUG
            // In debug builds, always call requestAccess() regardless of what
            // IOHIDCheckAccess reports. IOHIDCheckAccess may return .granted based
            // on the production app's TCC bundle-ID entry, causing the switch below
            // to hit default:break — but macOS HID event delivery is gated on the
            // specific binary being registered, so the debug binary never receives
            // events. IOHIDRequestAccess is idempotent when permission is already
            // granted (returns true, no dialog), so this is safe to call every launch.
            dm.requestAccess()
            #else
            switch dm.accessType {
            case .unknown:
                // TCC may return "unknown" on subsequent launches when the app lacks a
                // stable Developer ID signature, even though the user already granted
                // access. Avoid re-prompting if we recorded a prior grant — the
                // permission is still in effect even if IOHIDCheckAccess can't confirm it.
                let previouslyGrantedKey = "OEInputMonitoringPreviouslyGranted"
                if !UserDefaults.standard.bool(forKey: previouslyGrantedKey) {
                    if dm.requestAccess() {
                        UserDefaults.standard.set(true, forKey: previouslyGrantedKey)
                    }
                }

            case .denied:
                // User explicitly revoked — clear our cached grant so we prompt again
                // if they ever re-grant and TCC falls back to unknown.
                UserDefaults.standard.removeObject(forKey: "OEInputMonitoringPreviouslyGranted")
                DispatchQueue.main.async {
                    self.showInputMonitoringPermissionsAlert()
                }

            default:
                // Permission already granted. Call requestAccess() anyway — it is idempotent
                // (returns true, no dialog) but ensures HID event delivery is active for this
                // binary. IOHIDCheckAccess returning .granted does not activate delivery; that
                // requires IOHIDRequestAccess to be called. Same reason the DEBUG path always
                // calls it unconditionally.
                _ = dm.requestAccess()
            }
            #endif
            // Re-enumerate keyboards in case permission was granted after init.
            dm.rescanKeyboardDevices()
        }
    }

    fileprivate func showInputMonitoringPermissionsAlert() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "pleaseDoNotAnnoyMeWithThePermissionsAlertEveryTimeIRunThisAppFromXcode") {
            return
        }
        #endif

        // Suppress the alert if the user has already dismissed it this session.
        let suppressionKey = OEAlert.OEInputMonitoringAlertSuppressionKey
        if UserDefaults.standard.bool(forKey: suppressionKey) {
            return
        }

        let alert = OEAlert()
        alert.messageText = NSLocalizedString("ALERT_INPUT_MONITORING_HEADLINE", comment:"Headline for Input Monitoring permissions")
        var informativeText = NSLocalizedString("ALERT_INPUT_MONITORING_PART1", comment:"Message for Input Monitoring permissions")
        informativeText += "\n\n"
        if #available(macOS 26, *) {
            informativeText += NSLocalizedString("ALERT_INPUT_MONITORING_PART2_TAHOE", comment:"Message for Input Monitoring permissions on macOS 26+")
        } else if #available(macOS 12.0, *) {
            informativeText += NSLocalizedString("ALERT_INPUT_MONITORING_PART2_MONTEREY", comment:"Message for Input Monitoring permissions")
        } else {
            informativeText += NSLocalizedString("ALERT_INPUT_MONITORING_PART2", comment:"Message for Input Monitoring permissions")
        }
        alert.informativeText = informativeText

        if #available(macOS 13.0, *) {
            alert.defaultButtonTitle = NSLocalizedString("Open System Settings", comment:"Button to open System Settings for Input Monitoring permission")
        } else {
            alert.defaultButtonTitle = NSLocalizedString("Open System Preferences", comment:"Button to open System Preferences for Input Monitoring permission")
        }
        alert.alternateButtonTitle = NSLocalizedString("Ignore", comment: "")
        alert.otherButtonTitle = NSLocalizedString("Reset Permission", comment: "Button to reset the Input Monitoring permission when toggling it in System Settings hasn't fixed keyboard input")

        UserDefaults.standard.set(true, forKey: suppressionKey)

        guard let window = mainWindowController.window else { return }
        alert.beginSheetModal(for: window) { res in
            switch res {
            case .alertFirstButtonReturn:
                if #available(macOS 13.0, *) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent")!)
                } else {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                }
            case .alertThirdButtonReturn:
                self.resetInputMonitoringPermission(nil)
            default:
                break
            }
        }
    }

    /// Clears a stale/corrupted Input Monitoring TCC grant for this app via
    /// `tccutil reset` and re-triggers the OS permission prompt. This is the
    /// same fix users have had to achieve manually by deleting and
    /// reinstalling the app when toggling the permission in System Settings
    /// alone didn't resolve broken keyboard input (see issue #628).
    @IBAction fileprivate func resetInputMonitoringPermission(_ sender: Any?) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }

        let script = "do shell script \"/usr/bin/tccutil reset ListenEvent \(bundleID)\" with administrator privileges"
        guard let appleScript = NSAppleScript(source: script) else { return }

        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if let error = error {
            // -128 is the user cancelling the administrator-privileges prompt.
            if error[NSAppleScript.errorNumber] as? Int16 != -128 {
                os_log(.error, log: .default, "Failed to reset Input Monitoring permission { error = %{public}@ }",
                       (error[NSAppleScript.errorMessage] as? String) ?? "unknown")
            }
            return
        }

        UserDefaults.standard.removeObject(forKey: "OEInputMonitoringPreviouslyGranted")
        UserDefaults.standard.removeObject(forKey: OEAlert.OEInputMonitoringAlertSuppressionKey)

        // Re-requesting access in this same process immediately after the
        // reset is unreliable: IOHIDRequestAccess can race with tccd and
        // silently add a disabled entry instead of showing the consent
        // dialog. Relaunching gives the OS a fresh process to prompt
        // against, which is how this request behaves reliably at normal
        // app launch.
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Permission reset", comment: "Headline shown after successfully resetting Input Monitoring permission")
        alert.informativeText = NSLocalizedString("OpenEmu needs to relaunch to request Input Monitoring access again.", comment: "Message shown after successfully resetting Input Monitoring permission")
        alert.addButton(withTitle: NSLocalizedString("Relaunch Now", comment: "Button to relaunch OpenEmu after resetting Input Monitoring permission"))
        alert.runModal()

        relaunchToReapplyInputMonitoringPermission()
    }

    private func relaunchToReapplyInputMonitoringPermission() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = Bundle.main.bundlePath
        let script = "(while /bin/kill -0 \(pid) >&/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"\(path)\") &"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()

        NSApp.terminate(self)
    }
    
    // MARK: - Help Menu
    
    @IBAction func showOEHelp(_ sender: AnyObject?) {
        NSWorkspace.shared.open(URL(string: AppDelegate.userGuideAddress)!)
    }
    
    @IBAction func showOEReleaseNotes(_ sender: AnyObject?) {
        NSWorkspace.shared.open(URL(string: AppDelegate.releaseNotesAddress)!)
    }
    
    @IBAction func showOEWebSite(_ sender: AnyObject?) {
        NSWorkspace.shared.open(URL(string: AppDelegate.websiteAddress)!)
    }
    
    @IBAction func showOEIssues(_ sender: AnyObject?) {
        NSWorkspace.shared.open(URL(string: AppDelegate.feedbackAddress)!)
    }

    @IBAction func showReportBug(_ sender: AnyObject?) {
        let macOSVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let body = """
            **macOS Version:** \(macOSVersion)
            **App Version:** \(appVersion)

            **Description:**
            <!-- Please describe the bug here -->

            **Steps to Reproduce:**
            1.
            2.

            **Expected Behavior:**

            **Actual Behavior:**
            """
        var components = URLComponents(string: AppDelegate.bugReportAddress)!
        components.queryItems = [
            URLQueryItem(name: "labels", value: "bug"),
            URLQueryItem(name: "body", value: body),
        ]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    @IBAction func showAppSupportFolder(_ sender: AnyObject?) {
        NSWorkspace.shared.open(.oeApplicationSupportDirectory)
    }
    
    @IBAction func showOpenEmuWindow(_ sender: AnyObject?) {
        mainWindowController.showWindow(sender)
    }
    
    // MARK: - Preferences Window
    
    @IBAction func showPreferencesWindow(_ sender: AnyObject?) {
        preferencesWindowController.showWindow(nil)
    }
    
    // MARK: - KVO
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        
        if context == &appearancePrefChangedKVOContext {
            switch OEAppearance.application {
                case .dark:
                    NSApp.appearance = NSAppearance(named: .darkAqua)
                case .light:
                    NSApp.appearance = NSAppearance(named: .aqua)
                default:
                    NSApp.appearance = nil
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    // MARK: - Migration
    
    @objc(migrationForceUpdateCores:)
    func migrationForceUpdateCores() throws {
        CoreUpdater.shared.checkForUpdatesAndInstall()
    }
    
    @objc(migrationRemoveCoreDefaults:)
    func migrationRemoveCoreDefaults() throws {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.contains("defaultCore.openemu.system.") {
            defaults.removeObject(forKey: key)
        }
    }
    
    // MARK: - Bindings Reset Message
    
    @objc(didRepairBindings:)
    func didRepairBindings(_ notif: NSNotification!) {
        let alert = OEAlert()
        alert.messageText = NSLocalizedString("An issue was detected with one of your controllers.", comment:"Headline for bindings repaired alert")
        alert.informativeText = NSLocalizedString("The button profile for one of your controllers does not match the profile detected the last time it was connected to OpenEmu. Some of the controls associated to the affected controller were reset.\n\nYou can go to the Controls preferences to check which associations were affected.", comment:"Message for bindings repaired alert")
        alert.defaultButtonTitle = NSLocalizedString("OK", comment:"")
        alert.runModal()
    }
    
    // MARK: - Debug
    
    @IBAction func OEDebug_logResponderChain(_ sender: AnyObject?) {
        os_log(.info, log: .default, "NSApp.KeyWindow: %{public}@", String(describing: NSApp.keyWindow))
        
        if let keyWindow = NSApp.keyWindow {
            
            var responderChain = [NSResponder]()
            var responder = keyWindow.firstResponder
            
            while let nextResponder = responder?.nextResponder {
                responderChain.append(nextResponder)
                responder = nextResponder
            }
            
            let output = responderChain.reduce("Responder Chain: ") { $0 + " -> \($1)" }
            
            os_log(.info, log: .default, "%{public}@", output)
        }
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    
    func numberOfItems(in menu: NSMenu) -> Int {
        guard let database = OELibraryDatabase.default else {
            return 0
        }
        
        let lastPlayedInfo = database.lastPlayedRomsBySystem
        if lastPlayedInfo.isEmpty {
            cachedLastPlayedInfo.removeAll()
            return 1
        }
        
        let count = lastPlayedInfo.values.reduce(0) { $0 + 1 /*system name*/ + $1.count }
        
        var lastPlayed = [CachedLastPlayedInfoItem]()
        lastPlayed.reserveCapacity(count)
        
        let sortedSystems = lastPlayedInfo.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        for system in sortedSystems {
            lastPlayed.append(system)
            lastPlayed += lastPlayedInfo[system]!
        }
        
        cachedLastPlayedInfo = lastPlayed
        
        return count
    }
    
    func menu(_ menu: NSMenu, update item: NSMenuItem, at index: Int, shouldCancel: Bool) -> Bool {
        
        item.state = .off
        
        guard !cachedLastPlayedInfo.isEmpty else {
            item.title = NSLocalizedString("No game played yet!", comment: "")
            item.isEnabled = false
            item.indentationLevel = 0
            return true
        }
        
        switch cachedLastPlayedInfo[index] {
            
        case let string as String:
            item.title = string
            item.isEnabled = false
            item.indentationLevel = 0
            item.action = nil
            item.representedObject = nil
            
        case let rom as OEDBRom:
            guard let title = rom.game?.displayName else {
                return false
            }
            item.title = title
            item.isEnabled = true
            item.indentationLevel = 1
            item.target = mainWindowController
            item.action = #selector(MainWindowController.launchLastPlayedROM(_:))
            item.representedObject = rom
            
        default:
            break
        }
        
        return true
    }
    
    fileprivate func updateControlsMenu() {
        
        let saveStateSlotCount = 10
        
        let loadItemTag = 2
        let saveItemTag = 1
        
        let mainMenu = NSApp.mainMenu!
        let controlsItem = mainMenu.item(at: 4)
        let controlsMenu = controlsItem!.submenu!
        
        let currentLoadItem = controlsMenu.item(withTag: loadItemTag)!
        let currentSaveItem = controlsMenu.item(withTag: saveItemTag)!
        
        let useSlots = UserDefaults.standard.bool(forKey: OEDBSaveState.useQuickSaveSlotsKey)
        
        let newLoadItem: NSMenuItem
        let newSaveItem: NSMenuItem
        
        if useSlots {
            
            newLoadItem = NSMenuItem(title: NSLocalizedString("Quick Load", comment: "Quick Load Menu Item"), action: nil, keyEquivalent: "")
            newSaveItem = NSMenuItem(title: NSLocalizedString("Quick Save", comment: "Quick Save Menu Item"), action: nil, keyEquivalent: "")
            
            let loadMenu = NSMenu()
            let saveMenu = NSMenu()
            
            for i in 1..<saveStateSlotCount {
                
                let loadTitle = String(format: NSLocalizedString("Slot %ld", comment: "Slotted Quick Load Menu Item"), i)
                let saveTitle = String(format: NSLocalizedString("Slot %ld", comment: "Slotted Quick Save Menu Item"), i)
                
                let loadItem = NSMenuItem(title: loadTitle, action: #selector(OEGameDocument.quickLoad(_:)), keyEquivalent: "")
                let saveItem = NSMenuItem(title: saveTitle, action: #selector(OEGameDocument.quickSave(_:)), keyEquivalent: "")
                
                let keyEquivalent = "\(i)"
                loadItem.keyEquivalent = keyEquivalent
                loadItem.keyEquivalentModifierMask = [.shift, .command]
                saveItem.keyEquivalent = keyEquivalent
                saveItem.keyEquivalentModifierMask = [.command]
                
                loadItem.representedObject = i
                saveItem.representedObject = i
                
                loadMenu.addItem(loadItem)
                saveMenu.addItem(saveItem)
            }
            
            newLoadItem.submenu = loadMenu
            newSaveItem.submenu = saveMenu
            
        } else {
            
            newLoadItem = NSMenuItem(title: NSLocalizedString("Quick Load", comment: "Quick Load Menu Item"), action: #selector(OEGameDocument.quickLoad(_:)), keyEquivalent: "l")
            newLoadItem.representedObject = "0"
            newSaveItem = NSMenuItem(title: NSLocalizedString("Quick Save", comment: "Quick Save Menu Item"), action: #selector(OEGameDocument.quickSave(_:)), keyEquivalent: "s")
            newSaveItem.representedObject = "0"
        }
        
        newLoadItem.tag = loadItemTag
        newSaveItem.tag = saveItemTag
        
        var items = controlsMenu.items
        controlsMenu.removeAllItems()
        
        let loadItemIndex = items.firstIndex(of: currentLoadItem)!
        items[loadItemIndex] = newLoadItem
        
        let saveItemIndex = items.firstIndex(of: currentSaveItem)!
        items[saveItemIndex] = newSaveItem
        
        for item in items {
            controlsMenu.addItem(item)
        }
        
        controlsMenu.autoenablesItems = true
        controlsMenu.update()
    }
}

// MARK: - OpenEmuApplicationDelegateProtocol

@objc extension AppDelegate: OpenEmuApplicationDelegateProtocol {
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        refreshStaleCoreFeedURLs()

        atexit {
            // Always remove the XPC broker registered with launchd.
            // If the app was executed under App Translocation,
            // the broker may refer to an invalid path, so this ensures
            // it is re-registered on next launch.
            try? LaunchControl.remove(service: "org.openemu.broker")
        }
        
        if AppMover.isAppQuarantined() {
            AppMover.removeQuarantineAttribute()
            // TODO: trigger a relaunch?
        }
        AppMover.moveIfNecessary()
        
        NSUserDefaultsController.shared.addObserver(self, forKeyPath: "values.\(OEAppearance.Application.key)", options: [.initial], context: &appearancePrefChangedKVOContext)
        
        NotificationCenter.default.addObserver(self, selector: #selector(removeLibraryDidLoadObserverForRestoreWindowFromNotificationCenter), name: NSApplication.didFinishRestoringWindowsNotification, object: nil)
    }
    
    func removeLibraryDidLoadObserverForRestoreWindowFromNotificationCenter(_ notification: Notification) {
        
        let notificationCenter = NotificationCenter.default
        
        if let observer = libraryDidLoadObserverForRestoreWindow {
            notificationCenter.removeObserver(observer)
            libraryDidLoadObserverForRestoreWindow = nil
        }
        
        notificationCenter.removeObserver(self, name: NSApplication.didFinishRestoringWindowsNotification, object: nil)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Get the “Customize Touch Bar…” menu to display in the View menu.
        NSApp.isAutomaticCustomizeTouchBarMenuItemEnabled = true
        
        let notificationCenter = NotificationCenter.default
        
        notificationCenter.addObserver(self, selector: #selector(libraryDatabaseDidLoad), name: .libraryDidLoad, object: nil)
        notificationCenter.addObserver(self, selector: #selector(openPreferencePane), name: PreferencesWindowController.openPaneNotificationName, object: nil)
        
        NSDocumentController.shared.clearRecentDocuments(nil)

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        OEDBGame.startObservingDisplayPreference()
        validateDefaultPluginAssignments()
        logCorePluginInventory()

        DispatchQueue.main.async {
            self.loadDatabase()
        }

        /* Check if there is at least one metal-enabled device in the system.
         * Informs users that are using unsupported hacks for installing macOS on old machines,
         * so that we do not get issues like #4020 posted */
        let metalDevices = MTLCopyAllDevices()
        if metalDevices.count == 0 {
            let metalAlert = NSAlert()
            metalAlert.messageText = NSLocalizedString("Your Mac is too old for this version of OpenEmu", comment: "Message for the alert which appears when no Metal-enabled GPUs are detected")
            metalAlert.informativeText = NSLocalizedString("Since version 2.1, OpenEmu requires a GPU which supports Metal. Metal is available on all Macs that support macOS 10.14 or later.\n\nAs OpenEmu does not work with your current hardware/software configuration, it will now close.", comment: "Informative text for the alert which appears when no Metal-enabled GPUs are detected")
            metalAlert.addButton(withTitle: NSLocalizedString("Quit OpenEmu", comment: "Button title for the alert which appears when no Metal-enabled GPUs are detected"))
            metalAlert.runModal()
            NSApp.terminate(nil)
        }
    }
    
    
    func libraryDatabaseDidLoad(notification: Notification) {
        
        libraryLoaded = true

        guard let database = notification.object as? OELibraryDatabase else {
            return
        }

        OECoreMigration.resignCoresIfNeeded()
        OECoreMigration.runIfNeeded()
        loadPlugins(with: database)

        CoreUpdater.shared.checkForNewCores { _ in
            CoreUpdater.shared.checkForUpdatesAndInstall()
        }

        if !restoreWindow {
            _ = mainWindowController.window
        }
        
        // Remove the Open Recent menu item.
        let openDocumentMenuItemIndex = fileMenu.indexOfItem(withTarget: nil, andAction: #selector(NSDocumentController.openDocument(_:)))
        
        if openDocumentMenuItemIndex >= 0 && fileMenu.item(at: openDocumentMenuItemIndex + 1)!.hasSubmenu {
            fileMenu.removeItem(at: openDocumentMenuItemIndex + 1)
        }
        
        // Run Migration Manager.
        OEVersionMigrationController.default.runMigrationIfNeeded()
        
        // Set up HID support.
        setUpHIDSupport()
        
        // Start Save Sync Manager
        OESaveSyncManager.shared.startMonitoring()
        OEFolderBackupManager.shared.start()

        // Replace quicksave/quickload items with menus if required.
        updateControlsMenu()
        
        // Preload shader plug-ins so HUD controls bar and gameplay preferences load faster.
        _ = OEShaderStore.shared
        
        if !restoreWindow {
            mainWindowController.showWindow(nil)
        }

        // Deferred from applicationDidFinishLaunching so the main window is visible
        // before any modal alerts appear. Showing a runModal alert before the window
        // rendered caused a CA transaction hang on macOS 26 (OPENEM-SILICON-8 et al).
        SentryService.configureIfNeeded()
        removeIncompatibleSaveStates(from: database)

        let userDefaultsController = NSUserDefaultsController.shared
        bind(.logHIDEvents, to: userDefaultsController, withKeyPath: "values.logsHIDEvents", options: nil)
        bind(.logKeyboardEvents, to: userDefaultsController, withKeyPath: "values.logsHIDEventsNoKeyboard", options: nil)
        bind(.backgroundControllerPlay, to: userDefaultsController, withKeyPath: "values.backgroundControllerPlay", options: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey), name: NSWindow.didBecomeKeyNotification, object: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(deviceManagerDidChangeGlobalEventMonitor(_:)), name: .OEDeviceManagerDidAddGlobalEventMonitorHandler, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(deviceManagerDidChangeGlobalEventMonitor(_:)), name: .OEDeviceManagerDidRemoveGlobalEventMonitorHandler, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(gameDocumentSetupDidFinish(_:)), name: .OEGameDocumentSetupDidFinish, object: nil)

        for startupQueueItem in startupQueue {
            startupQueueItem()
        }
        startupQueue.removeAll()
    }
    
    func openPreferencePane(_ notification: Notification) {
        preferencesWindowController.showWindow(with: notification)
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        
        for window in sender.windows {
            
            if window.windowController is MainWindowController,
               !window.isVisible,
               sender.mainWindow == nil {
                
                window.makeKeyAndOrderFront(self)
                return false
            }
        }
        return true
    }
    
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if libraryLoaded {
            mainWindowController.showWindow(self)
        } else {
            startupQueue.append { [unowned self] in
                self.mainWindowController.showWindow(self)
            }
        }
        return false
    }
    
    // NOTE: When using ‘application:openURLs:’, “Document URLs that have an associated NSDocument class
    // will be opened through NSDocumentController.”, thereby bypassing the startupQueue.
    // FIXME: Handle ´PluginDocument´s
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "com.openemu.openemu" && url.host == "oauth2callback" {
                OESaveSyncManager.shared.handleOAuthRedirect(url: url)
                return
            }
        }
    }
    
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.compactMap { URL(fileURLWithPath: $0) }
        
        guard UserDefaults.standard.bool(forKey: SetupAssistant.hasFinishedKey) else {
            NSApp.reply(toOpenOrPrint: .cancel)
            return
        }
        
        let block: StartupQueueClosure = {
            
            if urls.count == 1 {
                
                let url = urls.first!
                self.documentController.openDocument(withContentsOf: url, display: true) { (document, documentWasAlreadyOpen, error) in
                    if error != nil {
                        self.documentController.presentError(error!)
                    }
                    NSApp.reply(toOpenOrPrint: document != nil ? .success : .failure)
                }
                
            } else {
                
                let reply: NSApplication.DelegateReply
                let importer = OELibraryDatabase.default!.importer
                if importer.importItems(at: urls) {
                    reply = .success
                } else {
                    reply = .failure
                }
                
                NSApp.reply(toOpenOrPrint: reply)
            }
        }
        
        if libraryLoaded {
            block()
        } else {
            startupQueue.append(block)
        }
    }
    
    func gameDocumentSetupDidFinish(_ notification: Notification) {
        updateEventHandlers()
    }
    
    @objc func deviceManagerDidChangeGlobalEventMonitor(_ notification: Notification) {
        updateEventHandlers()
    }
    
    func applicationDidResignActive(_ notification: Notification) {
        updateEventHandlers()
    }
    
    func applicationDidBecomeActive(_ notification: Notification) {
        updateEventHandlers()
        if #available(macOS 10.15, *) {
            OEDeviceManager.shared.rescanKeyboardDevices()
        }
    }
    
    @objc func windowDidBecomeKey(notification: Notification) {
        updateEventHandlers()
    }
    
    func spotlightStatusDidChange(for application: OpenEmuApplication) {
        updateEventHandlers()
    }
    
    func application(_ application: OpenEmuApplication, didBeginModalSessionForWindow window: NSWindow) {
        updateEventHandlers()
    }
    
    fileprivate var shouldHandleControllerEvents: Bool {
        if NSApp.modalWindow != nil {
            return false
        }

        if OEDeviceManager.shared.hasEventMonitor {
            return false
        }

        if OEApp.isSpotlightFrontmost {
            return false
        }

        if NSApp.isActive {
            return true
        }

        return backgroundControllerPlay
    }

    fileprivate var shouldHandleKeyboardEvents: Bool {
        if NSApp.modalWindow != nil {
            return false
        }

        if OEApp.isSpotlightFrontmost {
            return false
        }

        return NSApp.isActive
    }
    
    func updateEventHandlers() {
        let block = {
            let games = NSApp.orderedDocuments.compactMap({$0 as? OEGameDocument})
            guard games.count > 0 else { return }
            
            if let game = games.first {
                game.handleEvents = self.shouldHandleControllerEvents
                game.handleKeyboardEvents = self.shouldHandleKeyboardEvents
            }
            
            games.dropFirst().forEach {
                $0.handleEvents = false
                $0.handleKeyboardEvents = false
            }
        }
        
        if #available(macOS 13.0, *) {
            // Workaround; the documents in NSApp.orderedDocuments are not yet in the correct order on Ventura,
            // so when switching between game documents, the previous one would be chosen to handle input.
            DispatchQueue.main.async(execute: block)
        } else {
            block()
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // macOS suppresses banners for foreground apps by default; opt back in so
        // achievement notifications pop up while a game is running.
        completionHandler([.banner, .sound])
    }
}
