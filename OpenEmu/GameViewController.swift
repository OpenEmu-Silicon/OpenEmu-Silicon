// Copyright (c) 2020, OpenEmu Team
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
import Network
import OpenEmuBase.OEGeometry
import OpenEmuSystem
import OpenEmuKit

// TODO: Messages to remote layer:
// - Change bounds
// - Start Syphon
// - Native screenshot
//
// Messages from remote layer:
// - Default screen size/aspect size - DONE?

@objc(OEGameViewController)
@objcMembers
final class GameViewController: NSViewController {
    
    /// arbitrary default screen size with 4:3 ratio
    private let defaultSize = CGSize(width: 400, height: 300)
    private(set) var defaultScreenSize = CGSize.zero
    private var aspectSize = OEIntSize()
    private var screenSize = OEIntSize()
    
    private var scaledView: OEScaledGameLayerView!
    private(set) var gameView: OEGameLayerView!
    private var notificationView: OEGameLayerNotificationView!
    private var achievementBannerView: OEAchievementBannerView!
    private var retroAchievementsPlacardView: OERetroAchievementsPlacardView!
    private var retroAchievementsEventToastView: OERetroAchievementsEventToastView!
    private var retroAchievementsIndicatorStackView: OERetroAchievementsIndicatorStackView!
    private var retroAchievementsNoticeView: OERetroAchievementsNoticeView!
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "org.openemu.ra-network-monitor")
    private var isNetworkOffline = false
    private var isRetroAchievementsTransportOffline = false

    // Save Sync status badge
    
    var controlsWindow: GameControlsBar!
    weak var document: OEGameDocument!
    weak var integralScalingDelegate: GameIntegralScalingDelegate?
    
    var shaderControl: ShaderControl!
    private var shaderWindowController: ShaderParametersWindowController!
    
    private var token: NSObjectProtocol?
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    init(document: OEGameDocument) {
        super.init(nibName: nil, bundle: nil)
        
        self.document = document
        
        defaultScreenSize = defaultSize
        
        controlsWindow = GameControlsBar(gameViewController: self)
        controlsWindow.isReleasedWhenClosed = false
        shaderControl = ShaderControl(document: document)
        shaderWindowController = ShaderParametersWindowController(control: shaderControl)
        
        scaledView = OEScaledGameLayerView(frame: NSRect(origin: .zero, size: NSSize(width: 1, height: 1)))
        view = scaledView
        
        gameView = OEGameLayerView(frame: view.bounds)
        gameView.delegate = self
        scaledView.contentView = gameView
        scaledView.setContentViewSizeFill(animated: false)
        
        notificationView = OEGameLayerNotificationView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        notificationView.translatesAutoresizingMaskIntoConstraints = false
        notificationView.cell?.setAccessibilityElement(false)
        view.addSubview(notificationView)
        
        NSLayoutConstraint.activate([
            notificationView.widthAnchor.constraint(equalToConstant: 28),
            notificationView.heightAnchor.constraint(equalToConstant: 28),
            notificationView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 60),
            notificationView.topAnchor.constraint(equalTo: view.topAnchor, constant: 10)
        ])
        
        achievementBannerView = OEAchievementBannerView(frame: .zero)
        achievementBannerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(achievementBannerView)

        retroAchievementsPlacardView = OERetroAchievementsPlacardView(frame: .zero)
        retroAchievementsPlacardView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(retroAchievementsPlacardView)

        retroAchievementsEventToastView = OERetroAchievementsEventToastView(frame: .zero)
        retroAchievementsEventToastView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(retroAchievementsEventToastView)

        retroAchievementsIndicatorStackView = OERetroAchievementsIndicatorStackView(frame: .zero)
        retroAchievementsIndicatorStackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(retroAchievementsIndicatorStackView)

        retroAchievementsNoticeView = OERetroAchievementsNoticeView(frame: .zero)
        retroAchievementsNoticeView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(retroAchievementsNoticeView)

        NSLayoutConstraint.activate([
            achievementBannerView.widthAnchor.constraint(equalToConstant: OEAchievementBannerView.bannerWidth),
            achievementBannerView.heightAnchor.constraint(equalToConstant: OEAchievementBannerView.bannerHeight),
            achievementBannerView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            achievementBannerView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),

            retroAchievementsPlacardView.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.82),
            // Absolute width cap: long warning copy wraps inside the placard
            // instead of stretching it to whatever the host frame allows. Keeps
            // the rendered game frame ratio stable.
            retroAchievementsPlacardView.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            retroAchievementsPlacardView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            retroAchievementsPlacardView.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),

            retroAchievementsEventToastView.widthAnchor.constraint(equalToConstant: 390),
            retroAchievementsEventToastView.heightAnchor.constraint(equalToConstant: 62),
            retroAchievementsEventToastView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            retroAchievementsEventToastView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),

            retroAchievementsIndicatorStackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            retroAchievementsIndicatorStackView.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),

            retroAchievementsNoticeView.leadingAnchor.constraint(equalTo: notificationView.trailingAnchor, constant: 10),
            retroAchievementsNoticeView.centerYAnchor.constraint(equalTo: notificationView.centerYAnchor),
        ])

        networkMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isNetworkOffline = path.status != .satisfied
                self.updateRetroAchievementsOfflineNotice()
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
        
        token = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: gameView, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            
            self.controlsWindow.repositionOnGameWindow()
        }
    }
    
    deinit {
        if let token = token {
            NotificationCenter.default.removeObserver(token)
            self.token = nil
        }
        
        networkMonitor.cancel()

        shaderWindowController.close()
        shaderWindowController = nil

        controlsWindow.gameWindow = nil
        controlsWindow.close()
        controlsWindow = nil
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        
        guard let window = rootWindow else { return }
        
        controlsWindow.gameWindow = window
        controlsWindow.repositionOnGameWindow()
        
        window.makeFirstResponder(gameView)
    }
    
    override func viewWillDisappear() {
        super.viewWillDisappear()

        controlsWindow.hide(animated: false, hideCursor: false)
        controlsWindow.gameWindow = nil
    }
    
    private var rootWindow: NSWindow? {
        var window = gameView.window
        while window?.parent != nil {
            window = window?.parent
        }
        return window
    }
    
    // MARK: - Game View Control
    
    func gameViewSetIntegralSize(_ size: NSSize, animated: Bool) {
        scaledView.setContentViewSize(size, animated: animated)
    }
    
    func gameViewFillSuperView() {
        scaledView.setContentViewSizeFill(animated: false)
    }
    
    override func viewDidLayout() {
        document.updateBounds(gameView.bounds)
    }
    
    // MARK: - Controlling Emulation
    
    var supportsCheats: Bool {
        document.supportsCheats
    }

    var supportsCheatSearch: Bool {
        document.supportsCheatSearch
    }

    var supportsOnlineCheats: Bool {
        document.supportsOnlineCheats
    }

    var supportsSaveStates: Bool {
        document.supportsSaveStates
    }
    
    var supportsMultipleDiscs: Bool {
        document.supportsMultipleDiscs
    }
    
    var supportsFileInsertion: Bool {
        document.supportsFileInsertion
    }
    
    var supportsDisplayModeChange: Bool {
        document.supportsDisplayModeChange
    }
    
    var coreIdentifier: String {
        document.coreIdentifier
    }
    
    var systemIdentifier: String {
        document.systemIdentifier
    }
    
    @IBAction func takeScreenshot(_ sender: Any?) {
        document.takeScreenshot(sender)
    }
    
    func reflectVolume(_ volume: Float) {
        controlsWindow.reflectVolume(volume)
    }
    
    func reflectEmulationPaused(_ isPaused: Bool) {
        controlsWindow.reflectEmulationPaused(isPaused)
    }
    
    func toggleControlsVisibility(_ sender: NSMenuItem) {
        sender.state = sender.state == .off ? .on : .off
        controlsWindow.canShow = sender.state == .off
        if sender.state == .on {
            controlsWindow.hide()
        }
    }
    
    // MARK: - HUD Bar Actions
    
    func selectShader(_ sender: NSMenuItem) {
        let shaderName = sender.title
        if let shader = OEShaderStore.shared.shader(withName: shaderName) {
            shaderControl.changeShader(shader)
        }
    }
    
    func configureShader(_ sender: Any?) {
        shaderWindowController.showWindow(sender)
    }
    
    // MARK: - OEGameCoreOwner Methods
    
    func setRemoteContextID(_ contextID: OEContextID) {
        gameView.remoteContextID = contextID
    }
    
    func setScreenSize(_ newScreenSize: OEIntSize, aspectSize newAspectSize: OEIntSize) {
        screenSize = newScreenSize
        aspectSize = newAspectSize
        // Should never happen
        if newScreenSize.isEmpty && newAspectSize.isEmpty {
            defaultScreenSize = defaultSize
        }
        else {
            // Some cores may initially report a 0x0 screenRect on launch, so use aspectSize instead.
            if newScreenSize.isEmpty {
                screenSize = aspectSize
            }
            let correct = screenSize.corrected(forAspectSize: aspectSize)
            defaultScreenSize = CGSize(width: Int(correct.width), height: Int(correct.height))
        }
        
        gameView.setScreenSize(screenSize, aspectSize: aspectSize)
        integralScalingDelegate?.gameScreenSizeDidChange()
    }
}

// MARK: - NSMenuItemValidation

extension GameViewController: NSMenuItemValidation {
    
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleControlsVisibility(_:)):
            if controlsWindow.canShow {
                menuItem.state = .off
            } else {
                menuItem.state = .on
            }
            return true
        default:
            return true
        }
    }
}

// MARK: - OEGameViewDelegate

extension GameViewController: OEGameViewDelegate {
    
    func gameView(_ gameView: OEGameLayerView, didReceiveMouseEvent event: OEEvent) {
        document.didReceiveMouseEvent(event)
    }
    
    func gameView(_ gameView: OEGameLayerView, updateBounds newBounds: CGRect) {
        document.updateBounds(newBounds)
    }
    
    func gameView(_ gameView: OEGameLayerView, updateBackingScaleFactor newScaleFactor: CGFloat) {
        document.updateBackingScaleFactor(newScaleFactor)
    }
}

// MARK: - Notifications

extension GameViewController {
    
    func showQuickSaveNotification() {
        notificationView.showQuickSave()
    }
    
    func showScreenShotNotification() {
        notificationView.showScreenShot()
    }
    
    func showFastForwardNotification(_ enable: Bool) {
        notificationView.showFastForward(enabled: enable)
    }
    
    func showRewindNotification(_ enable: Bool) {
        notificationView.showRewind(enabled: enable)
    }

    func announceHardcoreModeChange(_ enable: Bool) {
        notificationView.announceHardcoreModeChange(enabled: enable)
    }

    func showStepForwardNotification() {
        notificationView.showStepForward()
    }
    
    func showStepBackwardNotification() {
        notificationView.showStepBackward()
    }

    func showAchievementUnlocked(title: String, description: String, badgeURL: String, points: UInt32) {
        achievementBannerView.show(title: title, description: description, badgeURL: badgeURL, points: points)
    }

    func showRetroAchievementsEventToast(title: String, subtitle: String, badgeURL: String? = nil, symbolName: String = "trophy.fill") {
        retroAchievementsEventToastView.show(title: title, subtitle: subtitle, badgeURL: badgeURL, symbolName: symbolName)
    }

    /// Hardcore always shows the trackers (RetroAchievements asks for it);
    /// softcore follows the user's preference.
    private func refreshRetroAchievementsIndicatorVisibility() {
        let showInSoftcore = UserDefaults.standard.bool(forKey: RAShowTrackersSoftcoreKey)
        retroAchievementsIndicatorStackView.isSuppressed = !(document.isHardcoreModeEnabled || showInSoftcore)
    }

    func showRetroAchievementsChallenge(id: UInt32, title: String) {
        refreshRetroAchievementsIndicatorVisibility()
        retroAchievementsIndicatorStackView.showChallenge(id: id, title: title)
    }

    func hideRetroAchievementsChallenge(id: UInt32) {
        refreshRetroAchievementsIndicatorVisibility()
        retroAchievementsIndicatorStackView.hideChallenge(id: id)
    }

    func showRetroAchievementsLeaderboard(id: UInt32, display: String) {
        refreshRetroAchievementsIndicatorVisibility()
        retroAchievementsIndicatorStackView.showLeaderboard(id: id, display: display)
    }

    func updateRetroAchievementsLeaderboard(id: UInt32, display: String) {
        refreshRetroAchievementsIndicatorVisibility()
        retroAchievementsIndicatorStackView.updateLeaderboard(id: id, display: display)
    }

    func hideRetroAchievementsLeaderboard(id: UInt32) {
        refreshRetroAchievementsIndicatorVisibility()
        retroAchievementsIndicatorStackView.hideLeaderboard(id: id)
    }

    func hideAllRetroAchievementsLeaderboards() {
        refreshRetroAchievementsIndicatorVisibility()
        retroAchievementsIndicatorStackView.hideAllLeaderboards()
    }

    func showRetroAchievementsProgress(title: String, progress: String) {
        refreshRetroAchievementsIndicatorVisibility()
        retroAchievementsIndicatorStackView.showProgress(title: title, progress: progress)
    }

    func hideRetroAchievementsProgress() {
        refreshRetroAchievementsIndicatorVisibility()
        retroAchievementsIndicatorStackView.hideProgress()
    }

    func showRetroAchievementsUnknownEmulatorNotice() {
        // Replaces the older on-screen chip overlay (which overlapped the game
        // video; see #579) with a placard that explains the consequence in
        // plain language and auto-hides. RA attaches a "warning achievement"
        // (id >= 101000001) when the connecting emulator isn't on its
        // hardcore-compliant allowlist — server-side this means hardcore
        // unlocks for the session save as Softcore until OpenEmu-Silicon is
        // approved.
        retroAchievementsPlacardView.showEmulatorUnrecognizedWarning()
    }

    func showRetroAchievementsOfflineNotice() {
        isRetroAchievementsTransportOffline = true
        updateRetroAchievementsOfflineNotice()
    }

    func hideRetroAchievementsOfflineNotice() {
        isRetroAchievementsTransportOffline = false
        updateRetroAchievementsOfflineNotice()
    }

    private func updateRetroAchievementsOfflineNotice() {
        let shouldShowOffline = isRetroAchievementsTransportOffline || (isNetworkOffline && document?.retroAchievementsSessionInfo != nil)
        if shouldShowOffline {
            retroAchievementsNoticeView.showOfflineWarning()
        } else {
            retroAchievementsNoticeView.hideOfflineWarning()
        }
    }

    func clearRetroAchievementsIndicators() {
        retroAchievementsIndicatorStackView.clear()
        isRetroAchievementsTransportOffline = false
        retroAchievementsNoticeView.clear()
    }

    func showRetroAchievementsPlacard(info: [String: Any], hardcore: Bool, signedIn: Bool) {
        retroAchievementsPlacardView.show(info: info, hardcore: hardcore, signedIn: signedIn)
        updateRetroAchievementsOfflineNotice()
    }
}

// MARK: - RetroAchievements Boot Placard

private final class OERetroAchievementsPlacardView: NSVisualEffectView {

    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let modeLabel = NSTextField(labelWithString: "")
    private var hideWorkItem: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        alphaValue = 0
        isHidden = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2
        titleLabel.cell?.wraps = true
        titleLabel.cell?.isScrollable = false
        titleLabel.preferredMaxLayoutWidth = 380
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .systemFont(ofSize: 14, weight: .medium)
        summaryLabel.textColor = .labelColor
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        // Wrap long warning copy (e.g. emulator-unrecognized notice) to at most
        // 3 lines so the placard width stays bounded and doesn't push the
        // surrounding layout. preferredMaxLayoutWidth seeds the intrinsic size
        // calculation; the hard width cap on the placard itself does the rest.
        summaryLabel.maximumNumberOfLines = 3
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.cell?.wraps = true
        summaryLabel.cell?.isScrollable = false
        summaryLabel.preferredMaxLayoutWidth = 380

        modeLabel.font = .systemFont(ofSize: 14, weight: .bold)
        modeLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [titleLabel, summaryLabel, modeLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageView)
        addSubview(textStack)

        // textStack drives placard height when text wraps to multiple lines;
        // when the summary is short (e.g. boot placard "Logged in · …"), the
        // minimum-height constraint below keeps the placard at least tall
        // enough for the 72pt imageView plus padding. Using .defaultHigh on
        // the `equalTo` pins lets AutoLayout relax them gracefully when the
        // minimum height wins instead of triggering an unsatisfiable-
        // constraints warning. Surfaced by the second adversarial-review pass.
        let textTop = textStack.topAnchor.constraint(equalTo: topAnchor, constant: 12)
        textTop.priority = .defaultHigh
        let textBottom = textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        textBottom.priority = .defaultHigh

        NSLayoutConstraint.activate([
            // Placard height floor: 72pt image + 12pt top + 12pt bottom.
            heightAnchor.constraint(greaterThanOrEqualToConstant: 96),

            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            imageView.widthAnchor.constraint(equalToConstant: 72),
            imageView.heightAnchor.constraint(equalToConstant: 72),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),

            textStack.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 12),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            textTop,
            textBottom,
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(info: [String: Any], hardcore: Bool, signedIn: Bool) {
        hideWorkItem?.cancel()
        isHidden = false

        imageView.image = nil

        if let status = info[OERetroAchievementsSessionStatusKey] as? String {
            titleLabel.stringValue = sessionStatusTitle(status)
            summaryLabel.stringValue = sessionStatusMessage(status, info: info)
            modeLabel.stringValue = NSLocalizedString("Achievements unavailable", comment: "RetroAchievements placard unavailable mode")
            modeLabel.textColor = .systemYellow
            imageView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        } else {
            titleLabel.stringValue = info[OERetroAchievementsGameTitleKey] as? String ?? NSLocalizedString("RetroAchievements", comment: "RetroAchievements placard fallback title")

            let unlocked = (info[OERetroAchievementsUnlockedCountKey] as? NSNumber)?.intValue ?? 0
            let total = (info[OERetroAchievementsAchievementCountKey] as? NSNumber)?.intValue ?? 0
            let points = (info[OERetroAchievementsUnlockedPointsKey] as? NSNumber)?.intValue ?? 0
            let totalPoints = (info[OERetroAchievementsTotalPointsKey] as? NSNumber)?.intValue ?? 0
            let account = signedIn ? NSLocalizedString("Logged in", comment: "RetroAchievements placard signed in") : NSLocalizedString("Not logged in", comment: "RetroAchievements placard signed out")
            summaryLabel.stringValue = String(format: NSLocalizedString("%@ · %d of %d achievements · %d of %d points", comment: "RetroAchievements boot placard summary"), account, unlocked, total, points, totalPoints)

            modeLabel.stringValue = hardcore ? NSLocalizedString("Hardcore Mode", comment: "RetroAchievements hardcore mode") : NSLocalizedString("Softcore Mode", comment: "RetroAchievements softcore mode")
            modeLabel.textColor = .labelColor

            if let urlString = info[OERetroAchievementsGameBadgeURLKey] as? String, let url = URL(string: urlString) {
                URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                    guard let data, let image = NSImage(data: data) else { return }
                    DispatchQueue.main.async { self?.imageView.image = image }
                }.resume()
            }
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                self?.animator().alphaValue = 0
            } completionHandler: {
                self?.isHidden = true
            }
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)
    }

    /// Public placard variant for the RA "unknown emulator" warning, surfaced
    /// when rcheevos sends a warning achievement (id >= 101000001). Auto-hides
    /// like the boot placard. See #579 for why this replaces the chip overlay.
    func showEmulatorUnrecognizedWarning() {
        hideWorkItem?.cancel()
        isHidden = false
        imageView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        titleLabel.stringValue = NSLocalizedString(
            "Emulator Awaiting Approval",
            comment: "RetroAchievements unknown emulator placard title")
        summaryLabel.stringValue = NSLocalizedString(
            "Hardcore unlocks will save as Softcore until OpenEmu-Silicon is approved by RetroAchievements.",
            comment: "RetroAchievements unknown emulator placard explanation")
        modeLabel.stringValue = NSLocalizedString("Softcore enforced", comment: "RetroAchievements unknown emulator mode label")
        modeLabel.textColor = .systemYellow

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                self?.animator().alphaValue = 0
            } completionHandler: {
                self?.isHidden = true
            }
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: workItem)
    }

    private func sessionStatusTitle(_ status: String) -> String {
        switch status {
        case OERetroAchievementsSessionStatusUnrecognized:
            return NSLocalizedString("RetroAchievements: Game Not Recognized", comment: "RetroAchievements unrecognized game placard title")
        case OERetroAchievementsSessionStatusLoginFailed:
            return NSLocalizedString("RetroAchievements Sign-In Failed", comment: "RetroAchievements login failed placard title")
        default:
            return NSLocalizedString("RetroAchievements Unavailable", comment: "RetroAchievements unavailable placard title")
        }
    }

    private func sessionStatusMessage(_ status: String, info: [String: Any]) -> String {
        switch status {
        case OERetroAchievementsSessionStatusUnrecognized:
            return NSLocalizedString("No achievement set was found for this game/hash.", comment: "RetroAchievements unrecognized game placard message")
        case OERetroAchievementsSessionStatusLoginFailed:
            if let message = info[OERetroAchievementsSessionErrorMessageKey] as? String, !message.isEmpty {
                return message
            }
            return NSLocalizedString("Please sign in again from Preferences → Achievements.", comment: "RetroAchievements login failed placard message")
        default:
            if let message = info[OERetroAchievementsSessionErrorMessageKey] as? String, !message.isEmpty {
                return message
            }
            return NSLocalizedString("RetroAchievements could not load for this session.", comment: "RetroAchievements unavailable placard message")
        }
    }
}

// MARK: - RetroAchievements Game Window

private final class OEFlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

final class RetroAchievementsGameViewController: NSViewController {

    private static let imageCache = NSCache<NSURL, NSImage>()

    private weak var document: OEGameDocument?
    private var sessionObserver: NSObjectProtocol?
    private let contentStack = NSStackView()
    private var selectedSetID: Int?

    init(document: OEGameDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
        sessionObserver = NotificationCenter.default.addObserver(forName: .OERetroAchievementsSessionDidChange, object: document, queue: .main) { [weak self] _ in
            self?.reloadContent()
            self?.scrollToTop()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let sessionObserver { NotificationCenter.default.removeObserver(sessionObserver) }
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 560))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        container.addSubview(scrollView)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 14
        contentStack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = OEFlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)
        scrollView.documentView = documentView

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])

        view = container
        reloadContent()
        scrollToTop()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        scrollToTop()
    }

    private func reloadContent() {
        guard isViewLoaded else { return }
        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard let document else { return }
        let info = document.retroAchievementsSessionInfo
        contentStack.addArrangedSubview(makeHeader(info: info, document: document))

        let sets = info?[OERetroAchievementsSetsKey] as? [[String: Any]] ?? []
        let achievements = info?[OERetroAchievementsAchievementsKey] as? [[String: Any]] ?? []
        let setOrder = orderedSetIDs(from: sets, achievements: achievements)
        let selectableSetIDs = setOrder.filter { setID in
            achievements.contains { (($0[OERetroAchievementsSetIDKey] as? NSNumber)?.intValue ?? -1) == setID }
        }
        let validSelectionIDs = selectableSetIDs.isEmpty ? setOrder : selectableSetIDs
        if selectedSetID == nil || !(selectedSetID.map { validSelectionIDs.contains($0) } ?? false) {
            selectedSetID = validSelectionIDs.first
        }
        if selectableSetIDs.count > 1 {
            contentStack.addArrangedSubview(makeSetSelector(sets: sets, achievements: achievements, setOrder: selectableSetIDs))
        }

        if achievements.isEmpty {
            let message = sessionStatusMessage(info: info, document: document)
                ?? (info == nil
                    ? NSLocalizedString("Waiting for RetroAchievements game metadata from the emulator core. If this stays empty, confirm you are signed in and the active core/game supports RetroAchievements.", comment: "RetroAchievements waiting message")
                    : NSLocalizedString("No achievements were reported for this game.", comment: "RetroAchievements empty list message"))
            contentStack.addArrangedSubview(makeBodyLabel(message, color: .secondaryLabelColor))
            scrollToTop()
            return
        }

        let selectedID = selectedSetID ?? setOrder.first ?? -1
        let setAchievements = achievements.filter {
            (($0[OERetroAchievementsSetIDKey] as? NSNumber)?.intValue ?? -1) == selectedID
        }
        let activeAchievements = setAchievements.filter(isActiveAchievement)
        if !activeAchievements.isEmpty {
            contentStack.addArrangedSubview(makeBucketLabel(NSLocalizedString("Active Now", comment: "RetroAchievements active achievements section title")))
            for achievement in activeAchievements {
                contentStack.addArrangedSubview(makeAchievementRow(achievement))
            }
        }

        let inactiveAchievements = setAchievements.filter { !isActiveAchievement($0) }
        let bucketGroups = Dictionary(grouping: inactiveAchievements) { achievement in
            achievement[OERetroAchievementsBucketTitleKey] as? String ?? NSLocalizedString("Achievements", comment: "RetroAchievements default bucket")
        }
        let bucketOrder = inactiveAchievements.compactMap { $0[OERetroAchievementsBucketTitleKey] as? String }.uniqued()
        for bucket in bucketOrder {
            contentStack.addArrangedSubview(makeBucketLabel(bucket))
            for achievement in bucketGroups[bucket] ?? [] {
                contentStack.addArrangedSubview(makeAchievementRow(achievement))
            }
        }
        scrollToTop()
    }

    private func scrollToTop() {
        guard let scrollView = view.subviews.compactMap({ $0 as? NSScrollView }).first,
              let documentView = scrollView.documentView else { return }
        documentView.layoutSubtreeIfNeeded()
        DispatchQueue.main.async {
            documentView.layoutSubtreeIfNeeded()
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func makeHeader(info: [String: Any]?, document: OEGameDocument) -> NSView {
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 16

        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 96, height: 96))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        imageView.widthAnchor.constraint(equalToConstant: 96).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 96).isActive = true
        if let urlString = info?[OERetroAchievementsGameBadgeURLKey] as? String { loadImage(urlString, into: imageView) }
        header.addArrangedSubview(imageView)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 6
        header.addArrangedSubview(textStack)

        let title = info?[OERetroAchievementsGameTitleKey] as? String ?? document.rom.game?.displayName ?? NSLocalizedString("Achievements", comment: "RetroAchievements window fallback title")
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        textStack.addArrangedSubview(titleLabel)

        let unlocked = (info?[OERetroAchievementsUnlockedCountKey] as? NSNumber)?.intValue
        let total = (info?[OERetroAchievementsAchievementCountKey] as? NSNumber)?.intValue
        let points = (info?[OERetroAchievementsUnlockedPointsKey] as? NSNumber)?.intValue
        let totalPoints = (info?[OERetroAchievementsTotalPointsKey] as? NSNumber)?.intValue
        let progress = sessionStatusMessage(info: info, document: document)
            ?? (unlocked != nil && total != nil && points != nil && totalPoints != nil
                ? String(format: NSLocalizedString("Unlocked %d of %d achievements · %d of %d points", comment: "RetroAchievements summary"), unlocked!, total!, points!, totalPoints!)
                : summaryText(document: document))
        textStack.addArrangedSubview(makeBodyLabel(progress, color: .labelColor))

        let mode = document.isHardcoreModeEnabled ? NSLocalizedString("Hardcore Mode", comment: "RetroAchievements hardcore mode") : NSLocalizedString("Softcore Mode", comment: "RetroAchievements softcore mode")
        let modeLabel = makePill(mode, color: document.isHardcoreModeEnabled ? .systemRed : .systemBlue)
        textStack.addArrangedSubview(modeLabel)

        if let hash = info?[OERetroAchievementsGameHashKey] as? String, !hash.isEmpty {
            textStack.addArrangedSubview(makeBodyLabel(String(format: NSLocalizedString("Hash: %@", comment: "RetroAchievements hash label"), hash), color: .secondaryLabelColor))
        }

        return header
    }

    private func makeSetSelector(sets: [[String: Any]], achievements: [[String: Any]], setOrder: [Int]) -> NSView {
        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 10

        let label = makeBodyLabel(NSLocalizedString("Achievement Set:", comment: "RetroAchievements set selector label"), color: .secondaryLabelColor)
        container.addArrangedSubview(label)

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(selectAchievementSet(_:))
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        for setID in setOrder {
            let setAchievements = achievements.filter { (($0[OERetroAchievementsSetIDKey] as? NSNumber)?.intValue ?? -1) == setID }
            let title = setTitle(for: setID, sets: sets, achievements: setAchievements)
            let count = setAchievementCount(for: setID, sets: sets, achievements: setAchievements)
            let itemTitle = count > 0 ? "\(title) (\(count))" : title
            popup.addItem(withTitle: itemTitle)
            popup.lastItem?.representedObject = setID
            if setID == selectedSetID {
                popup.select(popup.lastItem)
            }
        }

        container.addArrangedSubview(popup)
        return container
    }

    @objc private func selectAchievementSet(_ sender: NSPopUpButton) {
        selectedSetID = sender.selectedItem?.representedObject as? Int
        reloadContent()
        scrollToTop()
    }

    private func orderedSetIDs(from sets: [[String: Any]], achievements: [[String: Any]]) -> [Int] {
        let explicitSetIDs = sets.compactMap { ($0[OERetroAchievementsSetIDKey] as? NSNumber)?.intValue }
        let achievementSetIDs = achievements.compactMap { ($0[OERetroAchievementsSetIDKey] as? NSNumber)?.intValue }
        return (explicitSetIDs + achievementSetIDs).uniqued()
    }

    private func setTitle(for setID: Int, sets: [[String: Any]], achievements: [[String: Any]]) -> String {
        if let set = sets.first(where: { ($0[OERetroAchievementsSetIDKey] as? NSNumber)?.intValue == setID }),
           let title = set[OERetroAchievementsSetTitleKey] as? String {
            return title
        }
        if let title = achievements.compactMap({ $0[OERetroAchievementsSetTitleKey] as? String }).first {
            return title
        }
        return NSLocalizedString("Achievement Set", comment: "RetroAchievements set fallback title")
    }

    private func setAchievementCount(for setID: Int, sets: [[String: Any]], achievements: [[String: Any]]) -> Int {
        if let set = sets.first(where: { ($0[OERetroAchievementsSetIDKey] as? NSNumber)?.intValue == setID }),
           let count = (set[OERetroAchievementsSetAchievementCountKey] as? NSNumber)?.intValue {
            return count
        }
        return achievements.count
    }

    private func makeAchievementRow(_ info: [String: Any]) -> NSView {
        let isActive = isActiveAchievement(info)
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        row.layer?.cornerRadius = 8
        row.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 56, height: 56))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.widthAnchor.constraint(equalToConstant: 56).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let state = (info[OERetroAchievementsStateKey] as? NSNumber)?.intValue ?? 0
        let imageURL = (state == 2 ? info[OEAchievementBadgeURLKey] : info[OERetroAchievementsBadgeLockedURLKey]) as? String
        if let imageURL { loadImage(imageURL, into: imageView) }
        row.addArrangedSubview(imageView)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        row.addArrangedSubview(textStack)

        let title = info[OEAchievementTitleKey] as? String ?? NSLocalizedString("Untitled Achievement", comment: "RetroAchievements missing title")
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        if isActive { titleLabel.textColor = .systemOrange }
        textStack.addArrangedSubview(titleLabel)

        if let description = info[OEAchievementDescriptionKey] as? String, !description.isEmpty {
            textStack.addArrangedSubview(makeBodyLabel(description, color: .secondaryLabelColor))
        }

        let points = (info[OEAchievementPointsKey] as? NSNumber)?.intValue ?? 0
        var details = [String(format: NSLocalizedString("%d points", comment: "RetroAchievements points label"), points)]
        if let typeLabel = achievementTypeLabel(info[OERetroAchievementsTypeKey] as? NSNumber) {
            details.append(typeLabel)
        }
        if (info[OERetroAchievementsActiveChallengeKey] as? Bool) == true {
            details.append(NSLocalizedString("Challenge Active", comment: "RetroAchievements active challenge label"))
        }
        if let activeProgress = info[OERetroAchievementsActiveProgressKey] as? String, !activeProgress.isEmpty {
            details.append(String(format: NSLocalizedString("Active: %@", comment: "RetroAchievements active progress label"), activeProgress))
        } else if let measured = info[OERetroAchievementsMeasuredProgressKey] as? String, !measured.isEmpty {
            details.append(measured)
        }
        if let rarity = info[OERetroAchievementsRarityKey] as? NSNumber, rarity.floatValue > 0 {
            details.append(String(format: NSLocalizedString("%.1f%% unlocked", comment: "RetroAchievements rarity label"), rarity.floatValue))
        }
        textStack.addArrangedSubview(makeBodyLabel(details.joined(separator: " · "), color: isActive ? .labelColor : .tertiaryLabelColor))

        return row
    }

    private func isActiveAchievement(_ info: [String: Any]) -> Bool {
        if (info[OERetroAchievementsActiveChallengeKey] as? Bool) == true { return true }
        if let activeProgress = info[OERetroAchievementsActiveProgressKey] as? String, !activeProgress.isEmpty { return true }
        return false
    }

    private func achievementTypeLabel(_ number: NSNumber?) -> String? {
        guard let type = number?.intValue else { return nil }
        switch type {
        case 1:
            return NSLocalizedString("Missable", comment: "RetroAchievements achievement type")
        case 2:
            return NSLocalizedString("Progression", comment: "RetroAchievements achievement type")
        case 3:
            return NSLocalizedString("Win Condition", comment: "RetroAchievements achievement type")
        default:
            return nil
        }
    }

    private func makeBucketLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        return label
    }

    private func makeBodyLabel(_ text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = color
        return label
    }

    private func makePill(_ text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = color
        return label
    }

    private func sessionStatusMessage(info: [String: Any]?, document: OEGameDocument) -> String? {
        guard let status = info?[OERetroAchievementsSessionStatusKey] as? String else { return nil }
        switch status {
        case OERetroAchievementsSessionStatusUnrecognized:
            return NSLocalizedString("RetroAchievements is enabled, but no achievement set was found for this game/hash.", comment: "RetroAchievements unrecognized game window message")
        case OERetroAchievementsSessionStatusLoginFailed:
            if let message = info?[OERetroAchievementsSessionErrorMessageKey] as? String, !message.isEmpty {
                return message
            }
            return NSLocalizedString("RetroAchievements sign-in failed. Please sign in again from Preferences → Achievements.", comment: "RetroAchievements login failed window message")
        default:
            if let message = info?[OERetroAchievementsSessionErrorMessageKey] as? String, !message.isEmpty {
                return message
            }
            return NSLocalizedString("RetroAchievements could not load for this session.", comment: "RetroAchievements generic load failure window message")
        }
    }

    private func summaryText(document: OEGameDocument) -> String {
        let signedIn = OECredentialStore.shared.get(.retroAchievementsToken) != nil
        let account = signedIn ? NSLocalizedString("Signed in", comment: "RetroAchievements signed in state") : NSLocalizedString("Not signed in", comment: "RetroAchievements signed out state")
        let supported = document.corePlugin.supportsRetroAchievements(forSystemIdentifier: document.systemIdentifier)
        let support = supported ? NSLocalizedString("Core supports RetroAchievements", comment: "RetroAchievements core supported state") : NSLocalizedString("This core has not declared RetroAchievements support", comment: "RetroAchievements core unsupported state")
        return "\(account) · \(support)"
    }

    private func loadImage(_ urlString: String, into imageView: NSImageView) {
        guard let url = URL(string: urlString) else { return }
        let cacheKey = url as NSURL
        if let image = Self.imageCache.object(forKey: cacheKey) {
            imageView.image = image
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            Self.imageCache.setObject(image, forKey: cacheKey)
            DispatchQueue.main.async { imageView.image = image }
        }.resume()
    }
}
