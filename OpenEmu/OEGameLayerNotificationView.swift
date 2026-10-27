// Copyright (c) 2019, OpenEmu Team
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

// MARK: - Achievement Banner

final class OEAchievementBannerView: NSView {

    static let bannerWidth:  CGFloat = 430
    static let bannerHeight: CGFloat = 82

    private let headerLabel = NSTextField(labelWithString: "Achievement Unlocked!")
    private let titleLabel  = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let ptsLabel    = NSTextField(labelWithString: "")
    private let iconView    = NSImageView()
    private var imageTask: URLSessionDataTask?
    private var currentBadgeURL: URL?

    private var hideWorkItem: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.88).cgColor
        alphaValue = 0

        let iconConfig = NSImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: "trophy.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)
        iconView.contentTintColor = .systemYellow
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 6
        iconView.layer?.masksToBounds = true
        addSubview(iconView)

        headerLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        headerLabel.textColor = .systemYellow
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerLabel)

        titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        descriptionLabel.font = .systemFont(ofSize: 11, weight: .regular)
        descriptionLabel.textColor = NSColor(white: 0.82, alpha: 1)
        descriptionLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(descriptionLabel)

        ptsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        ptsLabel.textColor = NSColor(white: 0.75, alpha: 1)
        ptsLabel.alignment = .right
        ptsLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ptsLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 52),
            iconView.heightAnchor.constraint(equalToConstant: 52),

            ptsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            ptsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            ptsLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),

            headerLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: ptsLabel.leadingAnchor, constant: -8),
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 13),

            titleLabel.leadingAnchor.constraint(equalTo: headerLabel.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: ptsLabel.leadingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 3),

            descriptionLabel.leadingAnchor.constraint(equalTo: headerLabel.leadingAnchor),
            descriptionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
        ])
    }

    func show(title: String, description: String, badgeURL: String, points: UInt32) {
        titleLabel.stringValue = title
        descriptionLabel.stringValue = description
        ptsLabel.stringValue   = points > 0 ? "+\(points) pts" : ""

        imageTask?.cancel()
        currentBadgeURL = nil
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: "trophy.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)
        if let url = URL(string: badgeURL), !badgeURL.isEmpty {
            currentBadgeURL = url
            imageTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let data, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async {
                    guard self?.currentBadgeURL == url else { return }
                    self?.iconView.image = image
                }
            }
            imageTask?.resume()
        }

        hideWorkItem?.cancel()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }

        let item = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.5
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self?.animator().alphaValue = 0
            }
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: item)
    }
}

// MARK: - RetroAchievements Event Views

final class OERetroAchievementsEventToastView: NSVisualEffectView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let imageView = NSImageView()
    private var hideWorkItem: DispatchWorkItem?
    private var imageTask: URLSessionDataTask?
    private var currentBadgeURL: URL?

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
        imageView.layer?.cornerRadius = 5
        imageView.layer?.masksToBounds = true
        addSubview(imageView)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 38),
            imageView.heightAnchor.constraint(equalToConstant: 38),

            titleLabel.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(title: String, subtitle: String, badgeURL: String? = nil, symbolName: String = "trophy.fill") {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        hideWorkItem?.cancel()
        imageTask?.cancel()
        currentBadgeURL = nil
        isHidden = false

        let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        imageView.contentTintColor = .systemYellow
        if let badgeURL, let url = URL(string: badgeURL), !badgeURL.isEmpty {
            currentBadgeURL = url
            imageTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let data, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async {
                    guard self?.currentBadgeURL == url else { return }
                    self?.imageView.image = image
                }
            }
            imageTask?.resume()
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        let item = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self?.animator().alphaValue = 0
            } completionHandler: { self?.isHidden = true }
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: item)
    }
}

private final class OERetroAchievementsChipLabel: NSView {
    private let label = NSTextField(labelWithString: "")

    var stringValue: String {
        get { label.stringValue }
        set { label.stringValue = newValue; invalidateIntrinsicContentSize() }
    }

    var font: NSFont? {
        get { label.font }
        set { label.font = newValue; invalidateIntrinsicContentSize() }
    }

    var textColor: NSColor? {
        get { label.textColor }
        set { label.textColor = newValue }
    }

    var lineBreakMode: NSLineBreakMode {
        get { label.lineBreakMode }
        set { label.lineBreakMode = newValue }
    }

    var maximumNumberOfLines: Int {
        get { label.maximumNumberOfLines }
        set { label.maximumNumberOfLines = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    convenience init(labelWithString string: String) {
        self.init(frame: .zero)
        stringValue = string
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class OERetroAchievementsNoticeView: NSStackView {
    private let offlineLabel = OERetroAchievementsChipLabel(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .horizontal
        alignment = .centerY
        spacing = 6
        isHidden = true
        configureChip(offlineLabel, color: .systemRed)
        offlineLabel.isHidden = true
        addArrangedSubview(offlineLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // showUnknownEmulatorWarning() previously surfaced the "RA: Unknown
    // emulator" chip here. The chip overlapped the video (see #579); the host
    // now shows an auto-hiding placard via
    // GameViewController.showRetroAchievementsUnknownEmulatorNotice() instead.

    func showOfflineWarning() {
        offlineLabel.stringValue = NSLocalizedString("RA: Offline", comment: "RetroAchievements offline compact notice")
        offlineLabel.isHidden = false
        updateVisibility()
    }

    func hideOfflineWarning() {
        offlineLabel.isHidden = true
        updateVisibility()
    }

    func clear() {
        offlineLabel.isHidden = true
        updateVisibility()
    }

    private func configureChip(_ label: OERetroAchievementsChipLabel, color: NSColor) {
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.wantsLayer = true
        label.layer?.backgroundColor = color.withAlphaComponent(0.82).cgColor
        label.layer?.cornerRadius = 8
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
    }

    private func updateVisibility() {
        isHidden = offlineLabel.isHidden
    }
}

final class OERetroAchievementsIndicatorStackView: NSStackView {
    /// Leaderboard tracker and progress chips are transient: they auto-dismiss
    /// this long after their last show/update, regardless of whether a
    /// matching hide event ever arrives. They're informational blips, not
    /// state the player needs to keep checking back on (see #638).
    private static let transientDismissInterval: TimeInterval = 5

    /// Only one challenge chip is ever shown at a time — the most recently
    /// shown active challenge — since a challenge is the one thing (e.g. a
    /// timed challenge) the player actually needs ongoing visible status on.
    /// It has no auto-dismiss timer; it persists until its matching hide
    /// event arrives.
    private var challengeTitles: [UInt32: String] = [:]
    private var challengeOrder: [UInt32] = []
    private let challengeChip = OERetroAchievementsChipLabel(labelWithString: "")

    private var leaderboardViews: [UInt32: OERetroAchievementsChipLabel] = [:]
    private var leaderboardTimers: [UInt32: Timer] = [:]
    private let progressLabel = OERetroAchievementsChipLabel(labelWithString: "")
    private var progressTimer: Timer?
    /// The latest progress text, kept even while suppressed by an active
    /// challenge so it can be revealed (with a fresh dismiss clock) once the
    /// challenge ends, instead of expiring unseen in the background.
    private var pendingProgressText: String?

    private var hasActiveChallenge: Bool { !challengeOrder.isEmpty }

    /// When true the chips are kept off screen. State is still tracked, so
    /// turning this off brings back whatever is currently active.
    var isSuppressed = false {
        didSet {
            guard isSuppressed != oldValue else { return }
            updateArrangedSubviews()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .vertical
        alignment = .trailing
        spacing = 6
        isHidden = true
        configureChip(challengeChip, color: .systemOrange)
        configureChip(progressLabel, color: .systemGreen)
        progressLabel.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        for timer in leaderboardTimers.values { timer.invalidate() }
        progressTimer?.invalidate()
    }

    func showChallenge(id: UInt32, title: String) {
        challengeTitles[id] = title
        challengeOrder.removeAll { $0 == id }
        challengeOrder.append(id)
        updateArrangedSubviews()
    }

    func hideChallenge(id: UInt32) {
        guard challengeTitles.removeValue(forKey: id) != nil else { return }
        challengeOrder.removeAll { $0 == id }
        // Reveal any progress that arrived (and was suppressed) while a
        // challenge was active, giving it a fresh full dismiss window now
        // that the player can actually see it.
        if !hasActiveChallenge, let text = pendingProgressText {
            progressLabel.stringValue = text
            progressLabel.isHidden = false
            resetProgressDismissTimer()
        }
        updateArrangedSubviews()
    }

    func showLeaderboard(id: UInt32, display: String) {
        let label = leaderboardViews[id] ?? makeChip(color: .systemBlue)
        label.stringValue = "Leaderboard: \(display)"
        if leaderboardViews[id] == nil {
            leaderboardViews[id] = label
        }
        resetLeaderboardDismissTimer(id: id)
        updateArrangedSubviews()
    }

    func updateLeaderboard(id: UInt32, display: String) {
        guard let label = leaderboardViews[id] else { return }
        label.stringValue = "Leaderboard: \(display)"
        resetLeaderboardDismissTimer(id: id)
        updateArrangedSubviews()
    }

    func hideLeaderboard(id: UInt32) {
        leaderboardTimers.removeValue(forKey: id)?.invalidate()
        guard leaderboardViews.removeValue(forKey: id) != nil else { return }
        updateArrangedSubviews()
    }

    func hideAllLeaderboards() {
        for timer in leaderboardTimers.values { timer.invalidate() }
        leaderboardTimers.removeAll()
        leaderboardViews.removeAll()
        updateArrangedSubviews()
    }

    func showProgress(title: String, progress: String) {
        let text = progress.isEmpty ? title : "\(title): \(progress)"
        // RA can re-send the same progress value on a cadence of its own even
        // when nothing has actually changed. Only treat this as a fresh,
        // pertinent update if the value is different from what's already
        // pending — otherwise a steady drip of unchanged pings would keep
        // resetting the dismiss clock and the chip would never disappear.
        guard pendingProgressText != text else { return }
        pendingProgressText = text

        if hasActiveChallenge {
            // Don't start the dismiss clock on a toast the player can't even
            // see yet — it would expire in the background and never be
            // shown at all. hideChallenge(id:) reveals it once possible.
            progressTimer?.invalidate()
            progressTimer = nil
            progressLabel.isHidden = true
        } else {
            progressLabel.stringValue = text
            progressLabel.isHidden = false
            resetProgressDismissTimer()
        }
        updateArrangedSubviews()
    }

    func hideProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
        pendingProgressText = nil
        progressLabel.isHidden = true
        updateArrangedSubviews()
    }

    func clear() {
        for timer in leaderboardTimers.values { timer.invalidate() }
        leaderboardTimers.removeAll()
        progressTimer?.invalidate()
        progressTimer = nil
        pendingProgressText = nil
        challengeTitles.removeAll()
        challengeOrder.removeAll()
        leaderboardViews.removeAll()
        progressLabel.isHidden = true
        updateArrangedSubviews()
    }

    private func resetLeaderboardDismissTimer(id: UInt32) {
        leaderboardTimers.removeValue(forKey: id)?.invalidate()
        leaderboardTimers[id] = Timer.scheduledTimer(withTimeInterval: Self.transientDismissInterval, repeats: false) { [weak self] _ in
            self?.hideLeaderboard(id: id)
        }
    }

    private func resetProgressDismissTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: Self.transientDismissInterval, repeats: false) { [weak self] _ in
            self?.hideProgress()
        }
    }

    /// Rebuilds the stack's arranged subviews from current state: the single
    /// most-recently-active challenge chip (if any), followed by transient
    /// progress/leaderboard chips. The progress toast is suppressed entirely
    /// while a challenge is active (kept hidden by showProgress/hideChallenge
    /// above) — a challenge is the thing worth the player's attention, and
    /// stacking a progress ping on top of it just reintroduces the clutter
    /// this indicator is meant to avoid.
    private func updateArrangedSubviews() {
        for view in arrangedSubviews { removeArrangedSubview(view); view.removeFromSuperview() }

        if let currentChallengeID = challengeOrder.last, let title = challengeTitles[currentChallengeID] {
            challengeChip.stringValue = "Challenge: \(title)"
            addArrangedSubview(challengeChip)
        }
        if !progressLabel.isHidden { addArrangedSubview(progressLabel) }
        for label in leaderboardViews.values { addArrangedSubview(label) }

        isHidden = arrangedSubviews.isEmpty || isSuppressed
    }

    private func makeChip(color: NSColor) -> OERetroAchievementsChipLabel {
        let label = OERetroAchievementsChipLabel(labelWithString: "")
        configureChip(label, color: color)
        return label
    }

    private func configureChip(_ label: OERetroAchievementsChipLabel, color: NSColor) {
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.wantsLayer = true
        label.layer?.backgroundColor = color.withAlphaComponent(0.82).cgColor
        label.layer?.cornerRadius = 8
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
    }
}

// MARK: - HUD Icon Notification

@IBDesignable
final class OEGameLayerNotificationView: NSImageView {
    
    static let OEShowNotificationsKey = "OEShowNotifications"

    public var disableNotifications: Bool = false
    
    lazy var quicksaveImage     = NSImage(named: "hud_quicksave_notification")
    lazy var screenshotImage    = NSImage(named: "hud_screenshot_notification")
    lazy var fastForwardImage   = NSImage(named: "hud_fastforward_notification")
    lazy var rewindImage        = NSImage(named: "hud_rewind_notification")
    lazy var stepForwardImage   = NSImage(named: "hud_stepforward_notification")
    lazy var stepBackwardImage  = NSImage(named: "hud_stepbackward_notification")

    var isFastForwarding: Bool  = false
    var isRewinding: Bool       = false

    override var wantsUpdateLayer: Bool { return true }
    
    var showNotifications: Bool {
        return UserDefaults.standard.bool(forKey: Self.OEShowNotificationsKey)
    }
    
    // MARK: - Initialization
    
    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.setup()
    }
    
    required public init?(coder: NSCoder) {
        super.init(coder: coder)
        self.setup()
    }
    
    private func setup() {
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    
    // MARK: - Notifications
    
    @objc public func showFastForward(enabled: Bool) {
        performNotification(img: fastForwardImage, enabled: enabled, state: &isFastForwarding)
        if enabled {
            postAccessibilityNotification(announcement: NSLocalizedString("Fast Forward", tableName: "ControlLabels", comment: ""))
        }
    }
    
    @objc public func showRewind(enabled: Bool) {
        performNotification(img: rewindImage, enabled: enabled, state: &isRewinding)
        if enabled {
            postAccessibilityNotification(announcement: NSLocalizedString("Rewind", tableName: "ControlLabels", comment: ""))
        }
    }

    /// Hardcore mode has no HUD overlay of its own — the game-start info popover
    /// already shows a "Hardcore Mode" pill, so a persistent lock icon on top of
    /// gameplay was redundant. VoiceOver users still get an announcement.
    @objc public func announceHardcoreModeChange(enabled: Bool) {
        guard enabled else { return }
        postAccessibilityNotification(announcement: NSLocalizedString("Hardcore Mode", tableName: "ControlLabels", comment: ""))
    }

    @objc public func showQuickSave() {
        performShowHideNotification(img: quicksaveImage)
        postAccessibilityNotification(announcement: NSLocalizedString("Quick Save", tableName: "ControlLabels", comment: ""))
    }
    
    @objc public func showScreenShot() {
        performShowHideNotification(img: screenshotImage)
        postAccessibilityNotification(announcement: NSLocalizedString("Screenshot", tableName: "ControlLabels", comment: ""))
    }
    
    @objc public func showStepForward() {
        performShowHideNotification(img: stepForwardImage)
        postAccessibilityNotification(announcement: NSLocalizedString("Step Forward", tableName: "ControlLabels", comment: ""))
    }
    
    @objc public func showStepBackward() {
        performShowHideNotification(img: stepBackwardImage)
        postAccessibilityNotification(announcement: NSLocalizedString("Step Backward", tableName: "ControlLabels", comment: ""))
    }

    @objc public func showAchievementUnlocked() {
        let config = NSImage.SymbolConfiguration(pointSize: 64, weight: .regular)
        let img = NSImage(systemSymbolName: "trophy.fill", accessibilityDescription: "Achievement Unlocked")?
            .withSymbolConfiguration(config)
        performShowHideNotification(img: img)
        postAccessibilityNotification(announcement: NSLocalizedString("Achievement Unlocked", tableName: "ControlLabels", comment: ""))
    }
    
    // MARK: - Animation
    
    func performShowHideNotification(img: NSImage?) {
        if !self.showNotifications {
            return
        }
        
        CATransaction.begin()
        CATransaction.disableActions()
        self.image = img
        self.layer?.opacity = 0.0
        CATransaction.commit()
        
        self.layer?.add(makeFadeInOutAnimation(), forKey: "fadeInOutAnim")
    }
    
    func makeFadeInOutAnimation() -> CAAnimation {
        let opacityAnimation = CAKeyframeAnimation(keyPath: "opacity")
        opacityAnimation.duration = 1.75
        opacityAnimation.fillMode = .forwards
        opacityAnimation.values = [ 0, 1, 1, 0 ]
        opacityAnimation.keyTimes = [ 0, 0.15, 0.85, 1 ]
        return opacityAnimation
    }
    
    func performNotification(img: NSImage?, enabled: Bool, state: inout Bool) {
        if !self.showNotifications {
            return
        }
        
        if enabled && state {
            return
        }

        guard let layer = self.layer else {
            return
        }

        state = enabled

        var localImg = img
        var localEnabled = enabled

        // Rewind + Fast Forward = Fast Rewind
        if localImg == fastForwardImage && isRewinding {
            return
        }

        // Resume fast forward notification after rewind ends if fast forward is still pressed
        if localImg == rewindImage && !enabled && isFastForwarding {
            localImg = fastForwardImage
            localEnabled = true
        }

        layer.removeAllAnimations()
        if localEnabled {
            CATransaction.begin()
            CATransaction.disableActions()
            CATransaction.commit()
            image = localImg
            layer.add(makeFadeAnimation(from: 0), forKey: "fadeInAnim")
            layer.opacity = 1.0
        } else {
            layer.add(makeFadeAnimation(from: layer.opacity), forKey: "fadeOutAnim")
            layer.opacity = 0.0
        }
    }
    
    func makeFadeAnimation(from: Float) -> CAAnimation {
        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.duration = 0.25
        opacityAnimation.fillMode = .forwards
        opacityAnimation.fromValue = from
        return opacityAnimation
    }
    
    // MARK: - Accessibility
    func postAccessibilityNotification(announcement: String) {
        NSAccessibility.post(element: NSApp.mainWindow as Any,
                        notification: .announcementRequested,
                            userInfo: [.announcement: announcement,
                                           .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
