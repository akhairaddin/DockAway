import Cocoa
import QuartzCore
import ServiceManagement
import Sparkle
import UniformTypeIdentifiers

private final class PulsingStatusDotView: NSView {
    private let coreLayer = CALayer()
    private let pulseLayers = (0..<3).map { _ in CALayer() }
    private let animationDurationScale: CFTimeInterval = 1.25
    private var isActive = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        for pulseLayer in pulseLayers {
            pulseLayer.backgroundColor = NSColor.clear.cgColor
            pulseLayer.borderWidth = 1
            pulseLayer.opacity = 0
            layer?.addSublayer(pulseLayer)
        }

        layer?.addSublayer(coreLayer)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 22, height: 22)
    }

    override func layout() {
        super.layout()

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        coreLayer.bounds = CGRect(x: 0, y: 0, width: 5, height: 5)
        coreLayer.position = center
        coreLayer.cornerRadius = 2.5

        for pulseLayer in pulseLayers {
            pulseLayer.bounds = CGRect(x: 0, y: 0, width: 7, height: 7)
            pulseLayer.position = center
            pulseLayer.cornerRadius = 3.5
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePulseAnimation()
    }

    func setActive(_ active: Bool) {
        // Status text is refreshed frequently. If the activity state did not
        // change, leave the existing infinite pulse timeline untouched rather
        // than making the waves visibly restart from their first frame.
        guard isActive != active else { return }

        isActive = active
        updateAppearance(animated: window != nil)
    }

    private func updateAppearance(animated: Bool = false) {
        let color = isActive ? NSColor.systemGreen : NSColor.systemRed
        let pulseColor = color.withAlphaComponent(0.65)
        let animationDuration: CFTimeInterval = 0.32 * animationDurationScale

        let previousBackgroundColor = coreLayer.presentation()?.backgroundColor ?? coreLayer.backgroundColor
        let previousShadowColor = coreLayer.presentation()?.shadowColor ?? coreLayer.shadowColor
        let previousShadowOpacity = coreLayer.presentation()?.shadowOpacity ?? coreLayer.shadowOpacity
        let previousShadowRadius = coreLayer.presentation()?.shadowRadius ?? coreLayer.shadowRadius
        let previousPulseColors = pulseLayers.map {
            $0.presentation()?.borderColor ?? $0.borderColor
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        coreLayer.backgroundColor = color.cgColor
        coreLayer.shadowColor = color.cgColor
        coreLayer.shadowOpacity = isActive ? 0.9 : 0.45
        coreLayer.shadowRadius = isActive ? 4 : 2
        coreLayer.shadowOffset = .zero
        for pulseLayer in pulseLayers {
            pulseLayer.borderColor = pulseColor.cgColor
        }
        CATransaction.commit()

        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            animate(
                coreLayer,
                keyPath: "backgroundColor",
                from: previousBackgroundColor,
                to: color.cgColor,
                duration: animationDuration
            )
            animate(
                coreLayer,
                keyPath: "shadowColor",
                from: previousShadowColor,
                to: color.cgColor,
                duration: animationDuration
            )
            animate(
                coreLayer,
                keyPath: "shadowOpacity",
                from: previousShadowOpacity,
                to: isActive ? Float(0.9) : Float(0.45),
                duration: animationDuration
            )
            animate(
                coreLayer,
                keyPath: "shadowRadius",
                from: previousShadowRadius,
                to: isActive ? CGFloat(4) : CGFloat(2),
                duration: animationDuration
            )
            for (pulseLayer, previousColor) in zip(pulseLayers, previousPulseColors) {
                animate(
                    pulseLayer,
                    keyPath: "borderColor",
                    from: previousColor,
                    to: pulseColor.cgColor,
                    duration: animationDuration
                )
            }
        }

        updatePulseAnimation(animated: animated)
    }

    private func updatePulseAnimation(animated: Bool = false) {
        if !isActive {
            stopPulseAnimation(animated: animated)
            return
        }

        guard
            window != nil,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            for pulseLayer in pulseLayers {
                pulseLayer.removeAnimation(forKey: "outwardPulse")
                pulseLayer.removeAnimation(forKey: "pulseStop")
                pulseLayer.opacity = 0
            }
            return
        }

        // AppKit may notify us about the same window attachment more than once.
        // Preserve the shared phase of a healthy animation instead of resetting
        // all three waves.
        guard pulseLayers.contains(where: {
            $0.animation(forKey: "outwardPulse") == nil
        }) else { return }

        for pulseLayer in pulseLayers {
            pulseLayer.removeAnimation(forKey: "outwardPulse")
            pulseLayer.removeAnimation(forKey: "pulseStop")
            pulseLayer.opacity = 0
        }

        let pulseDuration = 2.1 * animationDurationScale
        let waveInterval = pulseDuration / Double(pulseLayers.count)
        let timelineStart = CACurrentMediaTime()

        for (index, pulseLayer) in pulseLayers.enumerated() {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.9
            scale.toValue = 3.1

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.58
            fade.toValue = 0

            let pulse = CAAnimationGroup()
            pulse.animations = [scale, fade]
            pulse.duration = pulseDuration
            pulse.beginTime = timelineStart + (Double(index) * waveInterval)
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pulseLayer.add(pulse, forKey: "outwardPulse")
        }
    }

    private func stopPulseAnimation(animated: Bool) {
        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        for pulseLayer in pulseLayers {
            let visibleOpacity = pulseLayer.presentation()?.opacity ?? pulseLayer.opacity
            let visibleTransform = pulseLayer.presentation()?.transform ?? pulseLayer.transform

            pulseLayer.removeAnimation(forKey: "outwardPulse")
            pulseLayer.removeAnimation(forKey: "pulseStop")

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pulseLayer.opacity = 0
            pulseLayer.transform = CATransform3DIdentity
            CATransaction.commit()

            guard shouldAnimate, visibleOpacity > 0.01 else { continue }

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = visibleOpacity
            fade.toValue = 0

            let finishExpanding = CABasicAnimation(keyPath: "transform")
            finishExpanding.fromValue = visibleTransform
            finishExpanding.toValue = CATransform3DScale(visibleTransform, 1.12, 1.12, 1)

            let stop = CAAnimationGroup()
            stop.animations = [fade, finishExpanding]
            stop.duration = 0.24 * animationDurationScale
            stop.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pulseLayer.add(stop, forKey: "pulseStop")
        }
    }

    private func animate(
        _ layer: CALayer,
        keyPath: String,
        from: Any?,
        to: Any,
        duration: CFTimeInterval
    ) {
        let transition = CABasicAnimation(keyPath: keyPath)
        transition.fromValue = from
        transition.toValue = to
        transition.duration = duration
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(transition, forKey: "statusTransition.\(keyPath)")
    }
}

private final class NonHitTestingImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class DockAwayStatusView: NSVisualEffectView {
    private let statusDot = PulsingStatusDotView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let labelStack = NSStackView()
    private let pauseResumeImageView = NonHitTestingImageView()
    private var displayedActiveState: Bool?
    let pauseResumeButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 4
        layer?.shadowOffset = .zero

        statusDot.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        detailLabel.font = .systemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        labelStack.translatesAutoresizingMaskIntoConstraints = false
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = -1
        labelStack.addArrangedSubview(titleLabel)
        labelStack.addArrangedSubview(detailLabel)

        pauseResumeButton.translatesAutoresizingMaskIntoConstraints = false
        pauseResumeButton.title = ""
        pauseResumeButton.imagePosition = .imageOnly
        pauseResumeButton.imageScaling = .scaleProportionallyDown
        pauseResumeButton.bezelStyle = .circular
        pauseResumeButton.setButtonType(.momentaryPushIn)

        pauseResumeImageView.translatesAutoresizingMaskIntoConstraints = false
        pauseResumeImageView.imageScaling = .scaleProportionallyDown

        addSubview(statusDot)
        addSubview(labelStack)
        addSubview(pauseResumeButton)
        addSubview(pauseResumeImageView)

        NSLayoutConstraint.activate([
            statusDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            statusDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 22),
            statusDot.heightAnchor.constraint(equalToConstant: 22),

            labelStack.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 2),
            labelStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelStack.trailingAnchor.constraint(lessThanOrEqualTo: pauseResumeButton.leadingAnchor, constant: -6),

            pauseResumeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            pauseResumeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pauseResumeButton.widthAnchor.constraint(equalToConstant: 22),
            pauseResumeButton.heightAnchor.constraint(equalToConstant: 22),

            pauseResumeImageView.centerXAnchor.constraint(equalTo: pauseResumeButton.centerXAnchor),
            pauseResumeImageView.centerYAnchor.constraint(equalTo: pauseResumeButton.centerYAnchor),
            pauseResumeImageView.widthAnchor.constraint(equalToConstant: 12),
            pauseResumeImageView.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(
        active: Bool,
        status: String,
        inactiveTitle: String = "DockAway: Paused",
        inactiveDetail: String = " App detection paused",
        inactiveActionTitle: String = "Resume DockAway"
    ) {
        let title = active ? "DockAway: Active" : inactiveTitle
        let detail = active
            ? (status == "Desktop" ? "Desktop" : "App: \(status)")
            : inactiveDetail

        guard displayedActiveState != active
            || titleLabel.stringValue != title
            || detailLabel.stringValue != detail
        else { return }

        statusDot.setActive(active)
        titleLabel.stringValue = title
        titleLabel.textColor = active ? .labelColor : .secondaryLabelColor
        detailLabel.stringValue = detail

        let actionTitle = active ? "Stop DockAway" : inactiveActionTitle
        let symbolName = active ? "pause.fill" : "play.fill"
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        let symbolImage = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: actionTitle
        )?.withSymbolConfiguration(symbolConfiguration)

        if let symbolImage {
            let shouldAnimate = displayedActiveState.map { $0 != active } ?? false
            if shouldAnimate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                pauseResumeImageView.setSymbolImage(symbolImage, contentTransition: .replace)
            } else {
                pauseResumeImageView.image = symbolImage
            }
        }
        displayedActiveState = active
        pauseResumeImageView.contentTintColor = active ? .secondaryLabelColor : .systemGreen
        pauseResumeButton.toolTip = actionTitle
        pauseResumeButton.setAccessibilityLabel(pauseResumeButton.toolTip ?? "Toggle DockAway")
    }
}


@objc class AppDelegate: NSObject, NSApplicationDelegate {
    private static let ignoredWindowBundleIdentifiersKey = "IgnoredWindowBundleIdentifiers"

    private enum AutomaticSuspensionReason: Hashable {
        case screenLocked
        case displayAsleep
        case systemAsleep
        case sessionInactive
    }

    private struct BlacklistApplication {
        let bundleIdentifier: String
        let name: String
        let icon: NSImage?
    }

    var isQuitting = false
    private var statusItem: NSStatusItem!
    private var dockWatcher: DockWatcher!
    private var updaterController: SPUStandardUpdaterController!
    private var updateMenuItem: NSMenuItem!
    private var availableUpdateVersion: String?
    private var blacklistMenu: NSMenu!
    private var accessibilityRecoveryMenuItem: NSMenuItem?
    private var accessibilityRecoverySeparator: NSMenuItem?
    private var dockAwayStatusView: DockAwayStatusView!
    private var dockAwayEnabled = true
    private var activeStatusText = "Detecting…"
    private var automaticSuspensionReasons = Set<AutomaticSuspensionReason>()
    private var accessibilityPermissionMissing = false
    private var isWaitingForAccessibility = false
    private var accessibilityWaitWorkItem: DispatchWorkItem?
    
    // The Unix signal trapper
    private var sigtermSource: DispatchSourceSignal?

    // Menu bar glyph. Deliberately self-contained: DockWatcher knows nothing
    // about any of this and is never called from it.
    private var glyphTimer: Timer?
    private var glyphShowsDockVisible: Bool?

    // Four-finger pre-hide via private MultitouchSupport.
    // Set to false to keep the finger-count logging without acting on it.
    private let hideOnFourFingerTouch = true
    private let fourFingerThreshold = 4
    // Keep SHOW suppressed while the destination Space finishes landing.
    private let preHideRelease: TimeInterval = 0.60
    private var fourFingersDown = false
    private var fourFingerStartedInMissionControl = false
    private let multitouch = MultitouchWatcher()


    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 APP LAUNCHED")
        NSApp.setActivationPolicy(.accessory)

        setupSleepAndLockAwareness()
        
        // Sparkle keeps scheduled checks gentle: background discoveries are
        // surfaced in DockAway's menu instead of opening a surprise window.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )

        // Check quietly on every fresh launch, including Launch at Login.
        // Sparkle continues using the normal six-hour schedule afterward and
        // the gentle-reminder delegate surfaces discoveries in DockAway's menu.
        if updaterController.updater.automaticallyChecksForUpdates {
            updaterController.updater.checkForUpdatesInBackground()
        }

        accessibilityPermissionMissing = !AXIsProcessTrusted()
        setupMenuBar()
        requestAccessibilityPermission()
        
        // Arm the signal trapper
        setupSignalHandler()
    }

    // MARK: - Sleep & Session Awareness

    private var monitoringShouldRun: Bool {
        dockAwayEnabled
            && !accessibilityPermissionMissing
            && automaticSuspensionReasons.isEmpty
            && !isQuitting
    }

    private var automaticSuspensionDetail: String {
        if accessibilityPermissionMissing {
            return "Accessibility access is off"
        }
        if automaticSuspensionReasons.contains(.screenLocked)
            || automaticSuspensionReasons.contains(.sessionInactive) {
            return "Screen locked"
        }
        if automaticSuspensionReasons.contains(.systemAsleep) {
            return "Mac sleeping"
        }
        if automaticSuspensionReasons.contains(.displayAsleep) {
            return "Display asleep"
        }
        return "App detection paused"
    }

    private var inactiveStatusTitle: String {
        accessibilityPermissionMissing && dockAwayEnabled
            ? "Permission Required"
            : "DockAway: Paused"
    }

    // Stops all of DockAway's active monitoring while nobody can interact
    // with the desktop. Reasons are tracked independently because a Mac often
    // wakes while its display is still asleep or its user session is locked.
    private func setupSleepAndLockAwareness() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(macWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(macDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(displayDidSleep(_:)),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(displayDidWake(_:)),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(sessionDidResignActive(_:)),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(sessionDidBecomeActive(_:)),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )

        // macOS has public sleep and user-session notifications, but no public
        // notification dedicated specifically to Lock Screen. loginwindow's
        // distributed notifications provide the immediate lock/unlock edge.
        let distributedCenter = DistributedNotificationCenter.default()
        distributedCenter.addObserver(
            self,
            selector: #selector(screenDidLock(_:)),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        distributedCenter.addObserver(
            self,
            selector: #selector(screenDidUnlock(_:)),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )

        // Cover an app launch that occurs while this user session is already
        // locked or switched out, before a fresh notification can arrive.
        refreshCurrentSessionState()
    }

    private func refreshCurrentSessionState() {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return }

        if session["CGSSessionScreenIsLocked"] as? Bool == true {
            automaticSuspensionReasons.insert(.screenLocked)
        }
        if session[kCGSessionOnConsoleKey as String] as? Bool == false {
            automaticSuspensionReasons.insert(.sessionInactive)
        }
    }

    @objc private func macWillSleep(_ notification: Notification) {
        suspendMonitoring(for: .systemAsleep)
    }

    @objc private func macDidWake(_ notification: Notification) {
        clearAutomaticSuspension(.systemAsleep)
    }

    @objc private func displayDidSleep(_ notification: Notification) {
        suspendMonitoring(for: .displayAsleep)
    }

    @objc private func displayDidWake(_ notification: Notification) {
        clearAutomaticSuspension(.displayAsleep)
    }

    @objc private func sessionDidResignActive(_ notification: Notification) {
        suspendMonitoring(for: .sessionInactive)
    }

    @objc private func sessionDidBecomeActive(_ notification: Notification) {
        clearAutomaticSuspension(.sessionInactive)
    }

    @objc private func screenDidLock(_ notification: Notification) {
        suspendMonitoring(for: .screenLocked)
    }

    @objc private func screenDidUnlock(_ notification: Notification) {
        clearAutomaticSuspension(.screenLocked)
    }

    private func suspendMonitoring(for reason: AutomaticSuspensionReason) {
        let wasMonitoringAllowed = automaticSuspensionReasons.isEmpty
        automaticSuspensionReasons.insert(reason)

        guard wasMonitoringAllowed else {
            updateDockAwayMenuState()
            return
        }

        fourFingersDown = false
        fourFingerStartedInMissionControl = false
        dockWatcher?.stop()
        multitouch.stop()
        stopGlyphTimer()
        accessibilityWaitWorkItem?.cancel()
        accessibilityWaitWorkItem = nil
        updateDockAwayMenuState()
        print("🌙 DockAway monitoring suspended: \(automaticSuspensionDetail)")
    }

    private func clearAutomaticSuspension(_ reason: AutomaticSuspensionReason) {
        guard automaticSuspensionReasons.remove(reason) != nil else { return }

        // A wake event can arrive while loginwindow is still presenting the
        // Lock Screen. Re-read the session for wake events, but trust explicit
        // unlock/session-active notifications: the session dictionary can lag
        // those notifications briefly and would otherwise re-suspend forever.
        if reason != .screenLocked, reason != .sessionInactive {
            refreshCurrentSessionState()
        }
        guard automaticSuspensionReasons.isEmpty else {
            updateDockAwayMenuState()
            return
        }

        guard dockAwayEnabled, !isQuitting else {
            updateDockAwayMenuState()
            return
        }

        if isWaitingForAccessibility, !AXIsProcessTrusted() {
            waitForAccessibility()
            updateDockAwayMenuState()
            return
        }

        guard AXIsProcessTrusted() else {
            accessibilityPermissionWasRevoked()
            return
        }
        accessibilityPermissionMissing = false
        isWaitingForAccessibility = false

        startMonitoringIfAllowed(resetState: true)

        // Window Server can still be settling immediately after unlock. The
        // first check is instant; this quiet second pass corrects a stale list.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.monitoringShouldRun else { return }
            self.dockWatcher?.resetState()
        }
        print("☀️ DockAway monitoring resumed")
    }

    private func startMonitoringIfAllowed(resetState: Bool = false) {
        guard monitoringShouldRun else { return }
        guard AXIsProcessTrusted() else {
            accessibilityPermissionWasRevoked()
            return
        }

        if dockWatcher == nil {
            dockWatcher = DockWatcher()
        }
        dockWatcher.start()
        startMultitouchPreHide()
        startGlyphTimer()
        updateDockAwayMenuState()

        if resetState {
            dockWatcher.resetState()
        }
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        // variableLength, not squareLength: the glyph is 22x16pt, so a square
        // status item clips the wider chevron lockup.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyStatusIcon(dockVisible: isDockCurrentlyVisible())
        buildMenu()
    }

    // MARK: - Four-Finger Pre-Hide

    // Uses raw contact motion to distinguish horizontal desktop swipes,
    // upward Mission Control entry, and downward Mission Control exit.
    // Degrades to a no-op if MultitouchSupport can't be loaded.
    private func startMultitouchPreHide() {
        guard monitoringShouldRun else { return }

        multitouch.start(
            onFingerCountChange: { [weak self] fingers in
                guard let self, self.monitoringShouldRun else { return }

                guard
                    self.hideOnFourFingerTouch,
                    let watcher = self.dockWatcher
                else { return }

                if fingers >= self.fourFingerThreshold {
                    guard !self.fourFingersDown else { return }
                    self.fourFingersDown = true
                    self.fourFingerStartedInMissionControl =
                        watcher.missionControlActiveAtGestureStart()
                    print(
                        self.fourFingerStartedInMissionControl
                            ? "  🧭 Four-finger gesture began in Mission Control"
                            : "  🧭 Four-finger gesture began on Desktop"
                    )
                    if !self.fourFingerStartedInMissionControl {
                        watcher.prepareHorizontalSpacePredictionAtGestureStart()
                    }
                } else if self.fourFingersDown {
                    self.fourFingersDown = false
                    self.fourFingerStartedInMissionControl = false
                    watcher.endHorizontalSpacePredictionAtGestureEnd()
                    let releasingPreHide = watcher.endHoldHidden(
                        after: self.preHideRelease
                    )
                    let releasingVisibleHold = watcher.endHoldVisible(
                        after: self.preHideRelease
                    )
                    print(
                        releasingPreHide
                            ? "  ✋ Fingers lifted → hidden hold releases in \(self.preHideRelease)s"
                            : releasingVisibleHold
                                ? "  ✋ Fingers lifted → visible hold releases in \(self.preHideRelease)s"
                                : "  ✋ Fingers lifted → no Dock hold to release"
                    )
                }
            },
            onFourFingerMotion: { [weak self] motion in
                guard
                    let self,
                    self.monitoringShouldRun,
                    self.hideOnFourFingerTouch,
                    self.fourFingersDown,
                    let watcher = self.dockWatcher
                else { return }

                let shouldPreHide: Bool
                let movingToNextSpace: Bool?
                switch motion {
                case .horizontalLeft:
                    shouldPreHide = !self.fourFingerStartedInMissionControl
                    movingToNextSpace = true
                case .horizontalRight:
                    shouldPreHide = !self.fourFingerStartedInMissionControl
                    movingToNextSpace = false
                case .upward:
                    shouldPreHide = false
                    movingToNextSpace = nil
                case .downward:
                    shouldPreHide = self.fourFingerStartedInMissionControl
                    movingToNextSpace = nil
                }

                print("  🧭 Four-finger motion=\(motion)")

                if let movingToNextSpace,
                   !self.fourFingerStartedInMissionControl,
                   watcher.beginVisibleHoldForHorizontalSwipeIfNeeded(
                        movingToNextSpace: movingToNextSpace
                   ) {
                    print("  ✨ Dock-visible source confirmed → visible hold armed")
                    return
                }

                if motion == .downward,
                   self.fourFingerStartedInMissionControl,
                   watcher.beginVisibleHoldForMissionControlExitIfNeeded() {
                    print("  ✨ Empty Mission Control destination → visible hold armed")
                    return
                }

                guard shouldPreHide else { return }

                let armedPreHide = watcher.beginHoldHidden(
                    missionControlWasActiveAtContact:
                        self.fourFingerStartedInMissionControl
                )
                print(
                    armedPreHide
                        ? "  ⚡ Motion confirmed → hidden hold armed"
                        : "  ⚡ Motion confirmed → pre-hide suppressed"
                )
            }
        )
    }

    // MARK: - Dynamic Glyph

    // The Dock's live autohide setting. A fresh instance every call, since a
    // long-lived UserDefaults for another app's domain can serve a stale
    // snapshot of that domain.
    private func isDockCurrentlyVisible() -> Bool {
        !(UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false)
    }

    // Polls the Dock state for the sole purpose of picking a glyph.
    //
    // This is intentionally a separate loop rather than a hook inside
    // DockWatcher. It only ever reads, never calls into DockWatcher, and never
    // participates in a toggle decision — so the worst a wrong or late read can
    // do is show the wrong chevron for a fraction of a second. It cannot move
    // the Dock.
    private func startGlyphTimer() {
        guard monitoringShouldRun, glyphTimer == nil else { return }

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.monitoringShouldRun else { return }
            self.applyStatusIcon(dockVisible: self.isDockCurrentlyVisible())
        }
        timer.tolerance = 0.04
        // .common so the glyph keeps updating while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        glyphTimer = timer
    }

    private func stopGlyphTimer() {
        glyphTimer?.invalidate()
        glyphTimer = nil
    }

    // Dock up (visible)  -> up chevron at full strength.
    // Dock down (hidden) -> down chevron at full strength.
    private func applyStatusIcon(dockVisible: Bool) {
        guard glyphShowsDockVisible != dockVisible else { return }

        let name = dockVisible ? "DockAwayStatus-Up" : "DockAwayStatus-Down"
        guard let image = NSImage(named: name) else {
            print("⚠️ Missing menu bar image asset: \(name)")
            return
        }

        glyphShowsDockVisible = dockVisible
        image.isTemplate = true
        image.accessibilityDescription = dockVisible ? "Dock visible" : "Dock hidden"
        statusItem.button?.image = image
    }

    private func buildMenu() {
        let menu = NSMenu()

        let statusMenuItem = NSMenuItem()
        let statusContainer = NSView(frame: NSRect(x: 0, y: 0, width: 212, height: 46))
        let statusView = DockAwayStatusView(frame: .zero)
        statusView.translatesAutoresizingMaskIntoConstraints = false
        statusView.pauseResumeButton.target = self
        statusView.pauseResumeButton.action = #selector(toggleDockAway)
        statusView.update(
            active: monitoringShouldRun,
            status: activeStatusText,
            inactiveTitle: inactiveStatusTitle,
            inactiveDetail: dockAwayEnabled
                ? automaticSuspensionDetail
                : "App detection paused",
            inactiveActionTitle: accessibilityPermissionMissing && dockAwayEnabled
                ? "Open Accessibility Settings"
                : "Resume DockAway"
        )
        statusContainer.addSubview(statusView)
        NSLayoutConstraint.activate([
            statusView.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor, constant: 5),
            statusView.trailingAnchor.constraint(equalTo: statusContainer.trailingAnchor, constant: -5),
            statusView.topAnchor.constraint(equalTo: statusContainer.topAnchor, constant: 3),
            statusView.bottomAnchor.constraint(equalTo: statusContainer.bottomAnchor, constant: -3)
        ])
        statusMenuItem.view = statusContainer
        dockAwayStatusView = statusView
        menu.addItem(statusMenuItem)

        let accessibilityRecoveryItem = NSMenuItem(
            title: "Open Accessibility Settings…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        accessibilityRecoveryItem.target = self
        accessibilityRecoveryItem.state = .on
        accessibilityRecoveryItem.onStateImage = menuIcon(from: NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Accessibility Permission Required"
        ))
        accessibilityRecoveryItem.toolTip =
            "DockAway cannot manage the Dock until Accessibility access is restored."
        accessibilityRecoveryItem.isHidden = !accessibilityPermissionMissing
        accessibilityRecoveryMenuItem = accessibilityRecoveryItem
        menu.addItem(accessibilityRecoveryItem)

        let accessibilitySeparator = NSMenuItem.separator()
        accessibilitySeparator.isHidden = !accessibilityPermissionMissing
        accessibilityRecoverySeparator = accessibilitySeparator
        menu.addItem(accessibilitySeparator)

        let launchAtLogin = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLogin.tag = 200
        launchAtLogin.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchAtLogin)

        let blacklistItem = NSMenuItem(title: "Blacklist", action: nil, keyEquivalent: "")
        let blacklistMenu = NSMenu(title: "Blacklist")
        blacklistMenu.autoenablesItems = false
        blacklistMenu.delegate = self
        blacklistItem.submenu = blacklistMenu
        self.blacklistMenu = blacklistMenu
        rebuildBlacklistMenu()
        menu.addItem(blacklistItem)
        menu.addItem(.separator())
        
        // --- SPARKLE UPDATE MENU ITEM  ---
        let updateMenuItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        self.updateMenuItem = updateMenuItem
        refreshUpdateMenuItem()
        
        // Safety check to ensure we have a controller
        if let controller = self.updaterController {
            updateMenuItem.target = controller
            updateMenuItem.isEnabled = true
        } else {
            // If it's nil, we initialize it right here as a fallback
            self.updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: self
            )
            updateMenuItem.target = self.updaterController
            updateMenuItem.isEnabled = true
        }

        menu.addItem(updateMenuItem)

        menu.addItem(NSMenuItem(title: "About DockAway", action: #selector(showAbout), keyEquivalent: ""))
        let quitMenuItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitMenuItem.state = .on
        quitMenuItem.onStateImage = menuIcon(from: NSImage(
            systemSymbolName: "power",
            accessibilityDescription: "Quit DockAway"
        ))
        menu.addItem(quitMenuItem)

        statusItem.menu = menu
    }

    private func refreshUpdateMenuItem() {
        guard let updateMenuItem else { return }

        let updateIsAvailable = availableUpdateVersion != nil
        if let version = availableUpdateVersion {
            updateMenuItem.title = "Update Available — v\(version)"
            updateMenuItem.toolTip = "Install DockAway \(version)"
        } else {
            updateMenuItem.title = "Check for Updates..."
            updateMenuItem.toolTip = "Check for a newer version of DockAway"
        }

        let symbolName = updateIsAvailable
            ? "arrow.down.circle.fill"
            : "arrow.triangle.2.circlepath"
        updateMenuItem.state = .on
        updateMenuItem.onStateImage = menuIcon(from: NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: updateIsAvailable
                ? "Update Available"
                : "Check for Updates"
        ))
    }

    private func showAvailableUpdate(_ update: SUAppcastItem) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.availableUpdateVersion = update.displayVersionString
            self.refreshUpdateMenuItem()
        }
    }

    private func clearAvailableUpdateIndicator() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.availableUpdateVersion = nil
            self.refreshUpdateMenuItem()
        }
    }

    // MARK: - Blacklist

    private var ignoredWindowBundleIdentifiers: Set<String> {
        Set(
            UserDefaults.standard.stringArray(
                forKey: Self.ignoredWindowBundleIdentifiersKey
            ) ?? []
        )
    }

    private func saveIgnoredWindowBundleIdentifiers(_ identifiers: Set<String>) {
        UserDefaults.standard.set(
            identifiers.sorted(),
            forKey: Self.ignoredWindowBundleIdentifiersKey
        )
        dockWatcher?.updateBlacklist(identifiers)
        dockWatcher?.resetState()
    }

    private func rebuildBlacklistMenu() {
        guard let blacklistMenu else { return }

        blacklistMenu.removeAllItems()

        let ignoredIdentifiers = ignoredWindowBundleIdentifiers
        var applicationsByIdentifier = [String: BlacklistApplication]()
        var currentApplication: BlacklistApplication?

        if let runningApplication = NSWorkspace.shared.frontmostApplication,
           runningApplication.activationPolicy == .regular,
           let bundleIdentifier = runningApplication.bundleIdentifier,
           bundleIdentifier != Bundle.main.bundleIdentifier {
            currentApplication = BlacklistApplication(
                bundleIdentifier: bundleIdentifier,
                name: runningApplication.localizedName ?? bundleIdentifier,
                icon: runningApplication.icon
            )
        }

        // Keep previously blacklisted apps visible even when they are not running.
        for bundleIdentifier in ignoredIdentifiers {
            applicationsByIdentifier[bundleIdentifier] = applicationInfo(
                forBundleIdentifier: bundleIdentifier
            )
        }

        // Mos uses the same useful shortcut: show regular running apps first,
        // then offer Finder for anything that is not currently open.
        for application in NSWorkspace.shared.runningApplications {
            guard
                application.activationPolicy == .regular,
                let bundleIdentifier = application.bundleIdentifier,
                bundleIdentifier != Bundle.main.bundleIdentifier,
                bundleIdentifier != currentApplication?.bundleIdentifier
            else { continue }

            applicationsByIdentifier[bundleIdentifier] = BlacklistApplication(
                bundleIdentifier: bundleIdentifier,
                name: application.localizedName ?? bundleIdentifier,
                icon: application.icon
            )
        }

        let applications = applicationsByIdentifier.values.filter {
            $0.bundleIdentifier != currentApplication?.bundleIdentifier
        }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        if let currentApplication {
            let currentItem = blacklistMenuItem(
                for: currentApplication,
                ignoredIdentifiers: ignoredIdentifiers
            )
            currentItem.toolTip = "Current application"
            blacklistMenu.addItem(currentItem)
            blacklistMenu.addItem(.separator())
        }

        if applications.isEmpty {
            let emptyItem = NSMenuItem(
                title: currentApplication == nil
                    ? "No Running Applications"
                    : "No Other Applications",
                action: nil,
                keyEquivalent: ""
            )
            emptyItem.isEnabled = false
            blacklistMenu.addItem(emptyItem)
        } else {
            for application in applications {
                blacklistMenu.addItem(blacklistMenuItem(
                    for: application,
                    ignoredIdentifiers: ignoredIdentifiers
                ))
            }
        }

        blacklistMenu.addItem(.separator())

        let chooseItem = NSMenuItem(
            title: "Choose Application…",
            action: #selector(chooseBlacklistApplication),
            keyEquivalent: ""
        )
        chooseItem.target = self
        chooseItem.image = NSImage(systemSymbolName: "plus.app", accessibilityDescription: nil)
        blacklistMenu.addItem(chooseItem)

        let clearItem = NSMenuItem(
            title: "Remove All",
            action: #selector(clearBlacklist),
            keyEquivalent: ""
        )
        clearItem.target = self
        clearItem.isEnabled = !ignoredIdentifiers.isEmpty
        blacklistMenu.addItem(clearItem)

        blacklistMenu.addItem(.separator())

        let helpItem = NSMenuItem(title: "About Blacklist", action: nil, keyEquivalent: "")
        helpItem.attributedTitle = menuTitle(
            "About Blacklist",
            icon: NSImage(
                systemSymbolName: "questionmark.circle",
                accessibilityDescription: "Blacklist Help"
            )
        )
        helpItem.toolTip = "A blacklisted app keeps the Dock shown while it is the frontmost app on the active display. When another app moves in front, DockAway hides the Dock normally."
        helpItem.isEnabled = true
        blacklistMenu.addItem(helpItem)
    }

    private func blacklistMenuItem(
        for application: BlacklistApplication,
        ignoredIdentifiers: Set<String>
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: application.name,
            action: #selector(toggleBlacklistedApplication(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = application.bundleIdentifier
        item.state = ignoredIdentifiers.contains(application.bundleIdentifier) ? .on : .off
        item.attributedTitle = menuTitle(
            application.name,
            icon: application.icon ?? NSImage(
                systemSymbolName: "app",
                accessibilityDescription: "Application"
            )
        )
        return item
    }

    private func applicationInfo(forBundleIdentifier bundleIdentifier: String) -> BlacklistApplication {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return BlacklistApplication(
                bundleIdentifier: bundleIdentifier,
                name: bundleIdentifier,
                icon: nil
            )
        }

        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent

        return BlacklistApplication(
            bundleIdentifier: bundleIdentifier,
            name: name,
            icon: NSWorkspace.shared.icon(forFile: url.path)
        )
    }

    private func menuIcon(from image: NSImage?) -> NSImage? {
        guard let icon = image?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    private func menuTitle(_ title: String, icon sourceImage: NSImage?) -> NSAttributedString {
        guard let icon = menuIcon(from: sourceImage) else {
            return NSAttributedString(string: title)
        }

        let attachment = NSTextAttachment()
        attachment.image = icon
        attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)

        let attributedTitle = NSMutableAttributedString(attachment: attachment)
        attributedTitle.append(NSAttributedString(string: "  \(title)"))
        return attributedTitle
    }

    @objc private func toggleBlacklistedApplication(_ sender: NSMenuItem) {
        guard let bundleIdentifier = sender.representedObject as? String else { return }

        var identifiers = ignoredWindowBundleIdentifiers
        if identifiers.contains(bundleIdentifier) {
            identifiers.remove(bundleIdentifier)
        } else {
            identifiers.insert(bundleIdentifier)
        }

        saveIgnoredWindowBundleIdentifiers(identifiers)
        rebuildBlacklistMenu()
    }

    @objc private func chooseBlacklistApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Application to Blacklist"
        panel.prompt = "Blacklist"
        panel.directoryURL = FileManager.default.urls(
            for: .applicationDirectory,
            in: .localDomainMask
        ).first
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self, response == .OK else { return }

            var identifiers = self.ignoredWindowBundleIdentifiers
            for url in panel.urls {
                if let bundleIdentifier = Bundle(url: url)?.bundleIdentifier,
                   bundleIdentifier != Bundle.main.bundleIdentifier {
                    identifiers.insert(bundleIdentifier)
                }
            }

            self.saveIgnoredWindowBundleIdentifiers(identifiers)
            self.rebuildBlacklistMenu()
        }
    }

    @objc private func clearBlacklist() {
        saveIgnoredWindowBundleIdentifiers([])
        rebuildBlacklistMenu()
    }

    func updateStatus(_ text: String) {
        let applyUpdate = { [weak self] in
            guard let self, self.monitoringShouldRun else { return }
            guard self.activeStatusText != text else { return }
            self.activeStatusText = text
            self.dockAwayStatusView?.update(active: true, status: text)
        }

        if Thread.isMainThread {
            applyUpdate()
        } else {
            DispatchQueue.main.async(execute: applyUpdate)
        }
    }

    @objc private func toggleDockAway() {
        if accessibilityPermissionMissing, dockAwayEnabled {
            openAccessibilitySettings()
            return
        }

        if dockAwayEnabled {
            dockAwayEnabled = false
            fourFingersDown = false
            fourFingerStartedInMissionControl = false
            dockWatcher?.stop()
            multitouch.stop()
            stopGlyphTimer()
            updateDockAwayMenuState()
            restoreDockState()
            applyStatusIcon(dockVisible: isDockCurrentlyVisible())
            print("🔴 DockAway inactive")
        } else {
            dockAwayEnabled = true
            guard AXIsProcessTrusted() else {
                accessibilityPermissionMissing = true
                isWaitingForAccessibility = true
                let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
                AXIsProcessTrustedWithOptions(options)
                updateDockAwayMenuState()
                waitForAccessibility()
                return
            }

            accessibilityPermissionMissing = false
            startMonitoringIfAllowed(resetState: true)
            updateDockAwayMenuState()
            print("🟢 DockAway active")
        }
    }

    private func updateDockAwayMenuState() {
        let monitoringIsActive = monitoringShouldRun
        dockAwayStatusView?.update(
            active: monitoringIsActive,
            status: activeStatusText,
            inactiveTitle: inactiveStatusTitle,
            inactiveDetail: dockAwayEnabled
                ? automaticSuspensionDetail
                : "App detection paused",
            inactiveActionTitle: accessibilityPermissionMissing && dockAwayEnabled
                ? "Open Accessibility Settings"
                : "Resume DockAway"
        )
        accessibilityRecoveryMenuItem?.isHidden = !accessibilityPermissionMissing
        accessibilityRecoverySeparator?.isHidden = !accessibilityPermissionMissing
    }

    // MARK: - Launch at Login

    private func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            print("⚠️ Launch at login error: \(error)")
        }
        statusItem.menu?.item(withTag: 200)?.state = isLaunchAtLoginEnabled() ? .on : .off
    }

    // MARK: - About

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        
        let creditsText = "Copyright © Abdullah Khairaddin 2026                  All rights reserved."
        
        let attributedCredits = NSAttributedString(
            string: creditsText,
            attributes: [.paragraphStyle: paragraphStyle]
        )
        
        NSApp.orderFrontStandardAboutPanel(options: [
            NSApplication.AboutPanelOptionKey.applicationName: "DockAway",
            NSApplication.AboutPanelOptionKey.credits: attributedCredits
        ])
    }

    // MARK: - First Launch

    private func ensureDockAwayIsOn() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard
                let self,
                self.monitoringShouldRun,
                self.dockWatcher?.isRunning == true
            else { return }

            // Let DockWatcher decide the desired state. A raw ⌘⌥D here could
            // otherwise hide the Dock in the middle of Mission Control or a
            // Space swipe just because this delayed launch check fired.
            self.dockWatcher.resetState()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.monitoringShouldRun else { return }
                self.dockWatcher?.resetState()
            }
        }
    }

    private func showWelcomeIfNeeded() {
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        guard !hasLaunchedBefore else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let alert = NSAlert()
            alert.messageText = "Welcome to DockAway 👋"
            alert.informativeText = "Your Dock will now automatically appear when you are on an empty desktop and hides when an app occupies the screen.\n\n• Toggle Launch at Login from the menu bar.\n• The app runs silently and efficiently in the background.\n\nEnjoy your Extra Real Estate!"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Let's Go!")

            // An .accessory app is never frontmost, so a modal can open behind
            // whatever the user is actually looking at.
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()

            // Mark it seen only once it HAS been seen. Setting the flag up front
            // loses the welcome permanently if the app dies in the meantime —
            // which is exactly what macOS does right after an Accessibility grant.
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
        }
    }

    // MARK: - Accessibility

    private func requestAccessibilityPermission() {
        if AXIsProcessTrusted() {
            accessibilityPermissionMissing = false
            isWaitingForAccessibility = false
            dockWatcher = DockWatcher()
            startMonitoringIfAllowed()
            ensureDockAwayIsOn()
            showWelcomeIfNeeded()
        } else {
            accessibilityPermissionMissing = true
            updateDockAwayMenuState()

            let alert = NSAlert()
            alert.messageText = "But First ☝️"
            alert.informativeText = "Accessibility Permission is Required:\nDockAway is requesting accessibility permission from system settings in order to detect desktop app occupancy status. Input monitoring (Automatically enabled after accessibility permission is granted) is required to detect when the Dock should be shown or hidden on a 4 finger press."
            alert.alertStyle = .informational
            
            alert.addButton(withTitle: "Allow Access")
            alert.addButton(withTitle: "Quit")
            alert.layout()
            
            NSApp.activate(ignoringOtherApps: true)
            
            if let contentView = alert.window.contentView {
                func findTextField(in view: NSView, matching text: String) -> NSTextField? {
                    if let textField = view as? NSTextField, textField.stringValue.contains(text) {
                        return textField
                    }
                    for subview in view.subviews {
                        if let found = findTextField(in: subview, matching: text) {
                            return found
                        }
                    }
                    return nil
                }
                
                if let informativeTextField = findTextField(in: contentView, matching: "Accessibility Permission is Required:") {
                    let fullString = informativeTextField.stringValue as NSString
                    let targetLine = "Accessibility Permission is Required:"
                    let firstLineRange = fullString.range(of: targetLine)
                    let remainingRange = NSRange(location: firstLineRange.length, length: fullString.length - firstLineRange.length)
                    
                    let attributedString = NSMutableAttributedString(string: informativeTextField.stringValue)
                    
                    attributedString.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 11), range: firstLineRange)
                    attributedString.addAttribute(.foregroundColor, value: NSColor.labelColor, range: firstLineRange)
                    attributedString.addAttribute(.font, value: NSFont.systemFont(ofSize: 11), range: remainingRange)
                    attributedString.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: remainingRange)
                    
                    let paragraphStyle = NSMutableParagraphStyle()
                    paragraphStyle.lineSpacing = 2
                    paragraphStyle.paragraphSpacing = 4
                    attributedString.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: fullString.length))
                    
                    informativeTextField.attributedStringValue = attributedString
                }
            }
            
            if alert.runModal() == .alertFirstButtonReturn {
                let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
                AXIsProcessTrustedWithOptions(options)
                isWaitingForAccessibility = true
                waitForAccessibility()
            } else {
                NSApp.terminate(nil)
            }
        }
    }

    private func waitForAccessibility() {
        guard !isQuitting, automaticSuspensionReasons.isEmpty else { return }

        accessibilityWaitWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isQuitting, self.automaticSuspensionReasons.isEmpty else { return }

            if AXIsProcessTrusted() {
                self.accessibilityPermissionMissing = false
                self.isWaitingForAccessibility = false
                self.accessibilityWaitWorkItem = nil
                print("✅ Accessibility granted - starting detector")
                if self.dockWatcher == nil {
                    self.dockWatcher = DockWatcher()
                }
                self.startMonitoringIfAllowed()
                self.ensureDockAwayIsOn()
                self.showWelcomeIfNeeded()
                self.updateDockAwayMenuState()
            } else {
                self.accessibilityPermissionMissing = true
                self.updateDockAwayMenuState()
                self.waitForAccessibility()
            }
        }
        accessibilityWaitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    func accessibilityPermissionWasRevoked() {
        let handleLoss = { [weak self] in
            guard let self, !self.isQuitting else { return }
            guard !self.accessibilityPermissionMissing else { return }

            self.accessibilityPermissionMissing = true
            self.isWaitingForAccessibility = true
            self.fourFingersDown = false
            self.fourFingerStartedInMissionControl = false
            self.dockWatcher?.stop()
            self.multitouch.stop()
            self.stopGlyphTimer()
            self.updateDockAwayMenuState()
            self.waitForAccessibility()
            print("⚠️ Accessibility permission removed — DockAway paused")
        }

        if Thread.isMainThread {
            handleLoss()
        } else {
            DispatchQueue.main.async(execute: handleLoss)
        }
    }

    @objc private func openAccessibilitySettings() {
        accessibilityPermissionMissing = !AXIsProcessTrusted()
        isWaitingForAccessibility = accessibilityPermissionMissing
        updateDockAwayMenuState()

        if let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(settingsURL)
        }

        if accessibilityPermissionMissing {
            waitForAccessibility()
        } else {
            startMonitoringIfAllowed(resetState: true)
        }
    }

    // MARK: - Unix Signal & Cleanup

    private func setupSignalHandler() {
        // 1. Ignore the default sudden-death SIGTERM so we can handle it ourselves
        signal(SIGTERM, SIG_IGN)
        
        // 2. Set up a listener for the Unix signal
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            print("  ⚠️ Caught Unix SIGTERM (Activity Monitor)")
            self?.isQuitting = true
            self?.restoreDockState()
            
            // 3. Manually exit after our cleanup is finished
            exit(0)
        }
        source.resume()
        sigtermSource = source
    }

    private func restoreDockState() {
        let defaults = UserDefaults(suiteName: "com.apple.dock")
        defaults?.synchronize()
        let isHidden = defaults?.bool(forKey: "autohide") ?? false
        
        if isHidden, let watcher = dockWatcher {
            print("  ⚡ Restoring Dock visibility before termination")
            watcher.simulateOptionCommandDPublic()
            
            // The Life Support Hold: Keep the app alive just long enough for the keystroke to register
            Thread.sleep(forTimeInterval: 0.15)
        }
    }

    @objc private func quit() {
        // Polite exit (triggers applicationWillTerminate)
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        isQuitting = true
        accessibilityWaitWorkItem?.cancel()
        stopGlyphTimer()
        dockWatcher?.stop()
        multitouch.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        restoreDockState()
    }
}

// MARK: - Sparkle Gentle Reminders

extension AppDelegate: SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    // Scheduled checks never steal focus. Sparkle keeps the update session
    // ready, while DockAway changes its menu item into the gentle reminder.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !state.userInitiated, !handleShowingUpdate else { return }
        showAvailableUpdate(update)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        clearAvailableUpdateIndicator()
    }

    func standardUserDriverWillFinishUpdateSession() {
        clearAvailableUpdateIndicator()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if menu === blacklistMenu {
            rebuildBlacklistMenu()
        }
    }
}
