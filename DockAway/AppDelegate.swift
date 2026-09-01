import Cocoa
import QuartzCore
import ServiceManagement
import Sparkle
import UniformTypeIdentifiers

// Debug builds keep the transition trace that makes Dock behavior easy to
// tune in Xcode. Release builds compile the calls down to no-ops, including
// their interpolated-string work, so users do not pay for console logging.
@inline(__always)
func dockAwayDebugLog(_ message: @autoclosure () -> String) {
#if DEBUG
    print(message())
#endif
}

private final class PulsingStatusDotView: NSView {
    private enum IndicatorState: Equatable {
        case active
        case inactive
        case warning
    }

    private let coreLayer = CALayer()
    private let pulseLayers = (0..<3).map { _ in CALayer() }
    private let animationDurationScale: CFTimeInterval = 1.25
    private var indicatorState: IndicatorState = .active

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
        setIndicatorState(active ? .active : .inactive)
    }

    func setWarning(_ warning: Bool, active: Bool) {
        setIndicatorState(warning ? .warning : (active ? .active : .inactive))
    }

    private func setIndicatorState(_ state: IndicatorState) {
        guard indicatorState != state else { return }

        indicatorState = state
        updateAppearance(animated: window != nil)
    }

    private func updateAppearance(animated: Bool = false) {
        let color: NSColor
        switch indicatorState {
        case .active:
            color = .systemGreen
        case .inactive:
            color = .systemRed
        case .warning:
            color = .systemYellow
        }
        let isActive = indicatorState == .active
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
        coreLayer.shadowOpacity = isActive ? 0.9 : indicatorState == .warning ? 0.65 : 0.45
        coreLayer.shadowRadius = isActive ? 4 : indicatorState == .warning ? 3 : 2
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
                to: isActive ? Float(0.9) : indicatorState == .warning ? Float(0.65) : Float(0.45),
                duration: animationDuration
            )
            animate(
                coreLayer,
                keyPath: "shadowRadius",
                from: previousShadowRadius,
                to: isActive ? CGFloat(4) : indicatorState == .warning ? CGFloat(3) : CGFloat(2),
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
        if indicatorState != .active {
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

private final class DockAwayStatusView: NSView {
    private let contentView = NSView()
    private let statusDot = PulsingStatusDotView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let labelStack = NSStackView()
    private let pauseResumeImageView = NonHitTestingImageView()
    private var displayedActiveState: Bool?
    let pauseResumeButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let backgroundView: NSView
        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView()
            glassView.style = .regular
            glassView.cornerRadius = 8
            glassView.contentView = contentView
            if #available(macOS 27.0, *) {
                glassView.effectIsInteractive = true
            }
            backgroundView = glassView
        } else {
            let visualEffectView = NSVisualEffectView()
            visualEffectView.material = .hudWindow
            visualEffectView.blendingMode = .withinWindow
            visualEffectView.state = .active
            visualEffectView.wantsLayer = true
            visualEffectView.layer?.cornerRadius = 8
            visualEffectView.layer?.borderWidth = 0.5
            visualEffectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
            visualEffectView.layer?.shadowColor = NSColor.black.cgColor
            visualEffectView.layer?.shadowOpacity = 0.3
            visualEffectView.layer?.shadowRadius = 4
            visualEffectView.layer?.shadowOffset = .zero
            contentView.translatesAutoresizingMaskIntoConstraints = false
            visualEffectView.addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
                contentView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
                contentView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor)
            ])
            backgroundView = visualEffectView
        }
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundView)
        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
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

        contentView.addSubview(statusDot)
        contentView.addSubview(labelStack)
        contentView.addSubview(pauseResumeButton)
        contentView.addSubview(pauseResumeImageView)

        NSLayoutConstraint.activate([
            statusDot.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            statusDot.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 22),
            statusDot.heightAnchor.constraint(equalToConstant: 22),

            labelStack.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 2),
            labelStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            labelStack.trailingAnchor.constraint(lessThanOrEqualTo: pauseResumeButton.leadingAnchor, constant: -6),

            pauseResumeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            pauseResumeButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
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
        inactiveActionTitle: String = "Resume DockAway",
        warning: Bool = false,
        warningTitle: String = "No Multitouch Support:",
        warningDetail: String = "4-finger gestures off",
        warningActionTitle: String = "Retry Gesture Support"
    ) {
        let title = warning
            ? warningTitle
            : active ? "DockAway: Active" : inactiveTitle
        let detail = warning
            ? warningDetail
            : active
            ? (status == "Desktop" ? "Desktop" : "App: \(status)")
            : inactiveDetail

        guard displayedActiveState != active
            || titleLabel.stringValue != title
            || detailLabel.stringValue != detail
        else { return }

        statusDot.setWarning(warning, active: active)
        titleLabel.stringValue = title
        titleLabel.textColor = active || warning || inactiveTitle == "Permission Required"
            ? .labelColor
            : .secondaryLabelColor
        detailLabel.stringValue = detail

        let actionTitle = warning
            ? warningActionTitle
            : active ? "Stop DockAway" : inactiveActionTitle
        let symbolName = active && !warning ? "pause.fill" : "play.fill"
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
        pauseResumeImageView.contentTintColor = active && !warning ? .secondaryLabelColor : .systemGreen
        pauseResumeButton.toolTip = actionTitle
        pauseResumeButton.setAccessibilityLabel(pauseResumeButton.toolTip ?? "Toggle DockAway")
    }
}

private final class DockSliderMarkerOverlayView: NSView {
    private weak var slider: NSSlider?

    init(slider: NSSlider) {
        self.slider = slider
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let slider, let sliderCell = slider.cell as? NSSliderCell else { return }
        let trackRect = sliderCell.barRect(flipped: slider.isFlipped)
        let knobTravelStart = trackRect.minX + sliderCell.knobThickness / 2
        let knobTravelWidth = max(0, trackRect.width - sliderCell.knobThickness)
        NSColor.white.setFill()
        for position in [CGFloat(0.25), 0.5, 0.75] {
            let markerRect = NSRect(
                x: knobTravelStart + knobTravelWidth * position - 1.25,
                y: trackRect.midY - 1.25,
                width: 2.5,
                height: 2.5
            )
            NSBezierPath(ovalIn: markerRect).fill()
        }
    }
}

private final class DockSettingSlider: NSSlider {
    var commitHandler: ((Double) -> Void)?
    var interactionChangedHandler: ((Bool) -> Void)?
    private let snapMarkerValues = [25.0, 50.0, 75.0]
    private let endpointHapticDistance = 1.0
    private let markerSnapEntryDistance = 2.25
    private let markerSnapReleaseDistance = 3.25
    private let minimumHapticInterval: CFTimeInterval = 0.05
    private var previousDragValue: Double?
    private var snappedMarkerValue: Double?
    private var pendingHapticCount = 0
    private var hapticDrainTimer: Timer?
    private var lastHapticTime: CFTimeInterval = -Double.greatestFiniteMagnitude
    private var isDragging = false

    private func setInteractionActive(_ active: Bool) {
        interactionChangedHandler?(active)
    }

    override func mouseDown(with event: NSEvent) {
        resetHapticQueue()
        isDragging = true
        previousDragValue = doubleValue
        snappedMarkerValue = nil
        setInteractionActive(true)
        super.mouseDown(with: event)
        if let previousDragValue {
            applyMarkerSnap()
            performMarkerHapticsIfNeeded(from: previousDragValue, to: doubleValue)
        }
        setInteractionActive(false)
        isDragging = false
        previousDragValue = nil
        snappedMarkerValue = nil
        commitHandler?(doubleValue)
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        if isDragging, let previousDragValue {
            applyMarkerSnap()
            performMarkerHapticsIfNeeded(from: previousDragValue, to: doubleValue)
            self.previousDragValue = doubleValue
        }
        return super.sendAction(action, to: target)
    }

    override func keyDown(with event: NSEvent) {
        let previousValue = doubleValue
        setInteractionActive(true)
        super.keyDown(with: event)
        setInteractionActive(false)
        if doubleValue != previousValue {
            commitHandler?(doubleValue)
        }
    }

    private func applyMarkerSnap() {
        let rawValue = doubleValue
        if let snappedMarkerValue {
            if abs(rawValue - snappedMarkerValue) <= markerSnapReleaseDistance {
                doubleValue = snappedMarkerValue
                return
            }
            self.snappedMarkerValue = nil
        }

        guard let nearestMarker = snapMarkerValues.min(by: {
            abs(rawValue - $0) < abs(rawValue - $1)
        }), abs(rawValue - nearestMarker) <= markerSnapEntryDistance else {
            return
        }
        snappedMarkerValue = nearestMarker
        doubleValue = nearestMarker
    }

    private func performMarkerHapticsIfNeeded(from previousValue: Double, to currentValue: Double) {
        guard previousValue != currentValue else { return }

        let crossedInteriorMarkers = snapMarkerValues.filter { marker in
            (previousValue < marker && currentValue >= marker)
                || (previousValue > marker && currentValue <= marker)
        }
        let enteredMinimumEndpoint = previousValue > endpointHapticDistance
            && currentValue <= endpointHapticDistance
        let enteredMaximumEndpoint = previousValue < 100 - endpointHapticDistance
            && currentValue >= 100 - endpointHapticDistance

        let orderedMarkers = currentValue > previousValue
            ? crossedInteriorMarkers.sorted()
                + (enteredMaximumEndpoint ? [100.0] : [])
            : (enteredMinimumEndpoint ? [0.0] : [])
                + crossedInteriorMarkers.sorted(by: >)
        enqueueHaptics(orderedMarkers.count)
    }

    private func enqueueHaptics(_ count: Int) {
        guard count > 0 else { return }
        pendingHapticCount += count

        let elapsed = CACurrentMediaTime() - lastHapticTime
        if pendingHapticCount > 0, elapsed >= minimumHapticInterval {
            pendingHapticCount -= 1
            emitHaptic()
        }
        scheduleHapticDrainIfNeeded()
    }

    private func emitHaptic() {
        lastHapticTime = CACurrentMediaTime()

        NSHapticFeedbackManager.defaultPerformer.perform(
            .levelChange,
            performanceTime: .now
        )
    }

    private func scheduleHapticDrainIfNeeded() {
        guard pendingHapticCount > 0, hapticDrainTimer == nil else { return }

        let elapsed = CACurrentMediaTime() - lastHapticTime
        let delay = max(0.001, minimumHapticInterval - elapsed)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] timer in
            guard let self, self.hapticDrainTimer === timer else {
                timer.invalidate()
                return
            }
            self.hapticDrainTimer = nil
            guard self.pendingHapticCount > 0 else { return }
            self.pendingHapticCount -= 1
            self.emitHaptic()
            self.scheduleHapticDrainIfNeeded()
        }
        hapticDrainTimer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
    }

    private func resetHapticQueue() {
        hapticDrainTimer?.invalidate()
        hapticDrainTimer = nil
        pendingHapticCount = 0
        lastHapticTime = -Double.greatestFiniteMagnitude
    }
}

private final class DockSettingSliderView: NSView {
    let slider = DockSettingSlider(
        value: 50,
        minValue: 0,
        maxValue: 100,
        target: nil,
        action: nil
    )
    private let valueLabel = NSTextField(labelWithString: "macOS Default")

    init(
        leadingTitle: String,
        trailingTitle: String,
        accessibilityLabel: String,
        accessibilityHelp: String
    ) {
        super.init(frame: NSRect(x: 0, y: 0, width: 232, height: 56))

        let leadingLabel = NSTextField(labelWithString: leadingTitle)
        let trailingLabel = NSTextField(labelWithString: trailingTitle)
        for label in [leadingLabel, trailingLabel] {
            label.font = .systemFont(ofSize: 9)
            label.textColor = .white
        }

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
        valueLabel.textColor = .white
        valueLabel.alignment = .center

        slider.minValue = 0
        slider.maxValue = 100
        slider.doubleValue = 50
        slider.controlSize = .large
        slider.isContinuous = true
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        let markerOverlay = DockSliderMarkerOverlayView(slider: slider)
        markerOverlay.translatesAutoresizingMaskIntoConstraints = false
        slider.addSubview(markerOverlay)
        NSLayoutConstraint.activate([
            markerOverlay.leadingAnchor.constraint(equalTo: slider.leadingAnchor),
            markerOverlay.trailingAnchor.constraint(equalTo: slider.trailingAnchor),
            markerOverlay.topAnchor.constraint(equalTo: slider.topAnchor),
            markerOverlay.bottomAnchor.constraint(equalTo: slider.bottomAnchor)
        ])
        if #available(macOS 26.0, *) {
            slider.neutralValue = 0
            slider.tintProminence = .none
        }
        slider.setAccessibilityLabel(accessibilityLabel)
        slider.setAccessibilityHelp(accessibilityHelp)
        slider.interactionChangedHandler = { [weak self] active in
            self?.setInteractionAppearance(active)
        }

        let sliderRow = NSStackView(views: [leadingLabel, slider, trailingLabel])
        sliderRow.orientation = .horizontal
        sliderRow.alignment = .centerY
        sliderRow.spacing = 7

        let stack = NSStackView(views: [valueLabel, sliderRow])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 1
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 126)
        ])

        setInteractionAppearance(false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setPercentage(_ percentage: Double, usesSystemDefault: Bool) {
        let roundedPercentage = min(100, max(0, percentage.rounded()))
        slider.doubleValue = roundedPercentage
        valueLabel.stringValue = usesSystemDefault
            ? "macOS Default"
            : "\(Int(roundedPercentage))%"
    }

    private func setInteractionAppearance(_ active: Bool) {
        valueLabel.textColor = .white
    }
}

private final class DockSettingPersistenceRowView: NSView {
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let changeHandler: (Bool) -> Void

    init(
        title: String,
        isOn: Bool,
        width: CGFloat = 230,
        leadingInset: CGFloat = 18,
        icon: NSImage? = nil,
        changeHandler: @escaping (Bool) -> Void
    ) {
        self.changeHandler = changeHandler
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        wantsLayer = true

        checkbox.title = title
        if let icon = icon?.copy() as? NSImage {
            icon.size = NSSize(width: 16, height: 16)
            let attachment = NSTextAttachment()
            attachment.image = icon
            attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
            let attributedTitle = NSMutableAttributedString(attachment: attachment)
            attributedTitle.append(NSAttributedString(string: "  \(title)"))
            checkbox.attributedTitle = attributedTitle
        }
        checkbox.state = isOn ? .on : .off
        checkbox.target = self
        checkbox.action = #selector(toggleCheckbox(_:))
        checkbox.focusRingType = .none
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)

        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            checkbox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setOn(_ isOn: Bool) {
        checkbox.state = isOn ? .on : .off
    }

    func setTitle(_ title: String) {
        checkbox.title = title
    }

    func setControlEnabled(_ enabled: Bool) {
        checkbox.isEnabled = enabled
    }

    func animationSnapshotImage() -> NSImage? {
        layoutSubtreeIfNeeded()
        let originalTitle = checkbox.title
        let originalAttributedTitle = checkbox.attributedTitle
        let coloredTitle = NSMutableAttributedString(
            attributedString: originalAttributedTitle.length > 0
                ? originalAttributedTitle
                : NSAttributedString(string: originalTitle)
        )
        coloredTitle.addAttribute(
            .foregroundColor,
            value: NSColor.white,
            range: NSRange(location: 0, length: coloredTitle.length)
        )
        checkbox.attributedTitle = coloredTitle
        defer {
            checkbox.title = originalTitle
            checkbox.attributedTitle = originalAttributedTitle
        }

        guard let representation = bitmapImageRepForCachingDisplay(
            in: bounds
        ) else { return nil }
        cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }

    @objc private func toggleCheckbox(_ sender: NSButton) {
        changeHandler(sender.state == .on)
    }
}

private final class BlacklistGroupSeparatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 9))

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            separator.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class DockPositionRowView: NSView {
    private let buttons: [NSButton]
    private let changeHandler: (Int) -> Void

    init(
        options: [(title: String, tag: Int)],
        selectedTag: Int,
        changeHandler: @escaping (Int) -> Void
    ) {
        self.changeHandler = changeHandler
        buttons = options.map { option in
            let button = NSButton(
                checkboxWithTitle: option.title,
                target: nil,
                action: nil
            )
            button.tag = option.tag
            button.focusRingType = .none
            return button
        }
        super.init(frame: NSRect(x: 0, y: 0, width: 232, height: 28))

        for button in buttons {
            button.target = self
            button.action = #selector(selectPosition(_:))
        }

        let stack = NSStackView(views: buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .equalSpacing
        stack.spacing = 10
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -17)
        ])

        setSelectedTag(selectedTag)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setSelectedTag(_ selectedTag: Int) {
        for button in buttons {
            button.state = button.tag == selectedTag ? .on : .off
        }
    }

    func setControlsEnabled(_ enabled: Bool) {
        buttons.forEach { $0.isEnabled = enabled }
    }

    @objc private func selectPosition(_ sender: NSButton) {
        setSelectedTag(sender.tag)
        changeHandler(sender.tag)
    }
}

private final class DockSettingSectionHeaderView: NSView {
    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 232, height: 24))

        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func mouseDown(with event: NSEvent) {
        // Section headings intentionally consume clicks so the menu remains open.
    }
}

private final class BlacklistActionMenuItemView: NSView {
    private let highlightView = NSView()
    private let titleLabel: NSTextField
    private let controlEnabled: Bool
    private let actionHandler: () -> Void
    private var trackingAreaReference: NSTrackingArea?

    init(
        title: String,
        isEnabled: Bool = true,
        actionHandler: @escaping () -> Void
    ) {
        titleLabel = NSTextField(labelWithString: title)
        controlEnabled = isEnabled
        self.actionHandler = actionHandler
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 26))

        wantsLayer = true
        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = 5
        highlightView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.textColor = isEnabled ? .labelColor : .tertiaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(highlightView)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            highlightView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            highlightView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 8),
            highlightView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            highlightView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityEnabled(isEnabled)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        setHighlighted(controlEnabled)
    }

    override func mouseExited(with event: NSEvent) {
        setHighlighted(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard controlEnabled else { return }
        actionHandler()
    }

    private func setHighlighted(_ highlighted: Bool) {
        highlightView.layer?.backgroundColor = highlighted
            ? NSColor.selectedContentBackgroundColor.cgColor
            : NSColor.clear.cgColor
        titleLabel.textColor = highlighted
            ? .white
            : controlEnabled ? .labelColor : .tertiaryLabelColor
    }
}

private final class BlacklistHelpMenuItemView: NSView {
    private static let helpText = "A blacklisted app keeps the Dock shown while it is the frontmost app on the active display. When another app moves in front, DockAway hides the Dock normally."

    private let highlightView = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "About Blacklist")
    private var hoverWorkItem: DispatchWorkItem?
    private var trackingAreaReference: NSTrackingArea?
    private lazy var helpPopover = makeHelpPopover()

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 28))
        wantsLayer = true
        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = 5
        highlightView.translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(
            systemSymbolName: "questionmark.circle",
            accessibilityDescription: "Blacklist Help"
        )
        iconView.contentTintColor = .labelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(highlightView)
        addSubview(titleLabel)
        addSubview(iconView)
        NSLayoutConstraint.activate([
            highlightView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            // A custom NSMenuItem view ends before the menu's native trailing
            // gutter. Extend through that gutter so both visible margins match.
            highlightView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 8),
            highlightView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            highlightView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: iconView.leadingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: highlightView.centerYAnchor),
            iconView.trailingAnchor.constraint(equalTo: highlightView.trailingAnchor, constant: -26),
            iconView.centerYAnchor.constraint(equalTo: highlightView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("About Blacklist")
        setAccessibilityHelp(Self.helpText)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        setHighlighted(true)
        schedulePopover()
    }

    override func mouseExited(with event: NSEvent) {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        helpPopover.performClose(nil)
        setHighlighted(false)
    }

    override func mouseDown(with event: NSEvent) {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        showPopover()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            hoverWorkItem?.cancel()
            hoverWorkItem = nil
            helpPopover.performClose(nil)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func schedulePopover() {
        hoverWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.showPopover()
        }
        hoverWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }

    private func showPopover() {
        guard window != nil, !helpPopover.isShown else { return }
        helpPopover.show(relativeTo: bounds, of: self, preferredEdge: .maxX)
    }

    private func setHighlighted(_ highlighted: Bool) {
        highlightView.layer?.backgroundColor = highlighted
            ? NSColor.selectedContentBackgroundColor.cgColor
            : NSColor.clear.cgColor
        let contentColor: NSColor = highlighted ? .white : .labelColor
        iconView.contentTintColor = contentColor
        titleLabel.textColor = contentColor
    }

    private func makeHelpPopover() -> NSPopover {
        let title = NSTextField(labelWithString: "How Blacklist Works")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .labelColor

        let detail = NSTextField(wrappingLabelWithString: Self.helpText)
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 0

        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 310, height: 96))
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])

        let viewController = NSViewController()
        viewController.view = contentView

        let popover = NSPopover()
        popover.animates = true
        popover.behavior = .applicationDefined
        popover.contentSize = contentView.frame.size
        popover.contentViewController = viewController
        return popover
    }
}


@objc class AppDelegate: NSObject, NSApplicationDelegate {
    private static let ignoredWindowBundleIdentifiersKey = "IgnoredWindowBundleIdentifiers"
    private static let blacklistGroupSeparatorTag = 9_101
    private static let checkForUpdatesAtLaunchKey = "CheckForUpdatesAtLaunch"
    private static let keepDockSettingsAfterQuitKey = "KeepDockSettingsAfterQuit"
    private static let keepDockPositionAfterQuitKey = "KeepDockPositionAfterQuit"
    private static let keepDockAnimationAfterQuitKey = "KeepDockAnimationAfterQuit"
    private static let keepDockRevealDelayAfterQuitKey = "KeepDockRevealDelayAfterQuit"
    private static let dockPreferencesDomain = "com.apple.dock" as CFString
    private static let dockOrientationKey = "orientation"
    private static let dockAnimationDurationKey = "autohide-time-modifier"
    private static let dockRevealDelayKey = "autohide-delay"
    private static let maximumDockAnimationDuration: Double = 2.0
    private static let maximumDockRevealDelay: Double = 1.0
    private static let defaultDockSliderPercentage: Double = 50

    private enum UpdateFrequency: Int, CaseIterable {
        case daily = 86_400
        case everyThreeDays = 259_200
        case weekly = 604_800
        case manualOnly = 0

        var title: String {
            switch self {
            case .daily: "Daily"
            case .everyThreeDays: "Every 3 Days"
            case .weekly: "Weekly"
            case .manualOnly: "Manual Only"
            }
        }
    }

    private enum DockPosition: Int, CaseIterable {
        case bottom
        case left
        case right

        var title: String {
            switch self {
            case .bottom: "Bottom"
            case .left: "Left"
            case .right: "Right"
            }
        }

        var preferenceValue: String {
            switch self {
            case .bottom: "bottom"
            case .left: "left"
            case .right: "right"
            }
        }
    }

    private enum DockSettingPersistenceOption: Int, CaseIterable {
        case position
        case animationSpeed
        case revealDelay

        var title: String {
            switch self {
            case .position: "Dock Position"
            case .animationSpeed: "Animation Speed"
            case .revealDelay: "Reveal Delay"
            }
        }

        var userDefaultsKey: String {
            switch self {
            case .position: AppDelegate.keepDockPositionAfterQuitKey
            case .animationSpeed: AppDelegate.keepDockAnimationAfterQuitKey
            case .revealDelay: AppDelegate.keepDockRevealDelayAfterQuitKey
            }
        }

        var dockPreferenceKey: String {
            switch self {
            case .position: AppDelegate.dockOrientationKey
            case .animationSpeed: AppDelegate.dockAnimationDurationKey
            case .revealDelay: AppDelegate.dockRevealDelayKey
            }
        }
    }

    private struct DockPreferenceChange {
        let key: String
        let value: Any?
    }

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

    private struct BlacklistRowAnimationSnapshot {
        let item: NSMenuItem
        let image: NSImage
        let oldScreenFrame: NSRect
    }

    private struct BlacklistRowAnimationOverlay {
        let snapshot: BlacklistRowAnimationSnapshot
        let view: NonHitTestingImageView
    }

    private struct BlacklistRowAnimationMovement {
        let view: NonHitTestingImageView
        let startFrame: NSRect
        let endFrame: NSRect
    }

    var isQuitting = false
    private var statusItem: NSStatusItem!
    private var dockWatcher: DockWatcher!
    private var updaterController: SPUStandardUpdaterController!
    private var updateMenuItem: NSMenuItem!
    private var updateFrequencyMenu: NSMenu!
    private var checkForUpdatesAtLaunchItem: NSMenuItem!
    private var availableUpdateVersion: String?
    private var blacklistMenu: NSMenu!
    private var currentBlacklistBundleIdentifier: String?
    private var blacklistReorderSetupTimer: Timer?
    private var blacklistReorderAnimationTimer: Timer?
    private var blacklistReorderOverlayWindow: NSPanel?
    private weak var blacklistReorderOverlayParentWindow: NSWindow?
    private var blacklistReorderHiddenItems = [NSMenuItem]()
    private var dockSettingsMenu: NSMenu!
    private var dockPositionRowView: DockPositionRowView!
    private var dockAnimationSliderView: DockSettingSliderView!
    private var dockRevealDelaySliderView: DockSettingSliderView!
    private var dockSettingsPersistenceItems = [NSMenuItem]()
    private var dockSettingsPersistenceNoneRowView: DockSettingPersistenceRowView!
    private var restoreDockDefaultsRowView: DockSettingPersistenceRowView!
    private var launchAtLoginRowView: DockSettingPersistenceRowView!
    private var dockSettingsRestartInProgress = false
    private var dockRestartGeneration = 0
    private var dockAwayStatusView: DockAwayStatusView!
    private var dockAwayEnabled = true
    private var activeStatusText = "Detecting…"
    private var automaticSuspensionReasons = Set<AutomaticSuspensionReason>()
    private var accessibilityPermissionMissing = false
    private var inputMonitoringPermissionMissing = false
    private var multitouchUnavailable = false
    private var isWaitingForAccessibility = false
    private var accessibilityWaitWorkItem: DispatchWorkItem?
    private var inputMonitoringWaitWorkItem: DispatchWorkItem?
    
    // The Unix signal trapper
    private var sigtermSource: DispatchSourceSignal?

    // DockWatcher publishes its existing live state reads here. This keeps the
    // menu-bar glyph current without a permanent cosmetic polling timer.
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
        dockAwayDebugLog("🚀 APP LAUNCHED")
        NSApp.setActivationPolicy(.accessory)

        setupSleepAndLockAwareness()
        
        // Sparkle keeps scheduled checks gentle, while its updater delegate
        // reports every valid update path (manual, gentle, or automatic) so
        // DockAway can always surface the available version in its menu.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )

        checkForUpdatesAtLaunchIfEnabled()

        // Sparkle owns the selected schedule and remembers the last check date.
        // The independent launch toggle can request an immediate silent check.

        accessibilityPermissionMissing = !AXIsProcessTrusted()
        inputMonitoringPermissionMissing = !CGPreflightListenEventAccess()
        setupMenuBar()
        requestAccessibilityPermission()
        
        // Arm the signal trapper
        setupSignalHandler()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshInputMonitoringPermission()

        // A trackpad or private-framework failure can be corrected while
        // DockAway is running. Retry when the app becomes active again so the
        // warning can clear without requiring a full relaunch.
        if monitoringShouldRun,
           !inputMonitoringPermissionMissing,
           dockWatcher?.isRunning == true,
           !multitouch.isRunning {
            startMultitouchPreHide()
        }
    }

    // MARK: - Sleep & Session Awareness

    private var monitoringShouldRun: Bool {
        dockAwayEnabled
            && !accessibilityPermissionMissing
            && automaticSuspensionReasons.isEmpty
            && !dockSettingsRestartInProgress
            && !isQuitting
    }

    // Input Monitoring improves gesture timing but is not required for the
    // core Dock watcher. Keep the watcher running while still showing the
    // user that gesture smoothing needs permission.
    private var statusAppearsActive: Bool {
        monitoringShouldRun && !inputMonitoringPermissionMissing
    }

    private var multitouchWarningVisible: Bool {
        monitoringShouldRun
            && !inputMonitoringPermissionMissing
            && multitouchUnavailable
    }

    private var automaticSuspensionDetail: String {
        if dockSettingsRestartInProgress {
            return "Applying Dock settings"
        }
        if accessibilityPermissionMissing {
            return "Accessibility access is off"
        }
        if inputMonitoringPermissionMissing {
            return "Input Monitoring is off"
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
        if dockSettingsRestartInProgress {
            return "DockAway: Applying Settings"
        }
        return (accessibilityPermissionMissing || inputMonitoringPermissionMissing)
            && dockAwayEnabled
            ? "Permission Required"
            : "DockAway: Paused"
    }

    private var permissionActionTitle: String {
        accessibilityPermissionMissing
            ? "Open Accessibility Settings"
            : "Open Input Monitoring Settings"
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
        accessibilityWaitWorkItem?.cancel()
        accessibilityWaitWorkItem = nil
        inputMonitoringWaitWorkItem?.cancel()
        inputMonitoringWaitWorkItem = nil
        updateDockAwayMenuState()
        dockAwayDebugLog("🌙 DockAway monitoring suspended: \(automaticSuspensionDetail)")
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
        refreshInputMonitoringPermission()

        startMonitoringIfAllowed(resetState: true)

        // Window Server can still be settling immediately after unlock. The
        // first check is instant; this quiet second pass corrects a stale list.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.monitoringShouldRun else { return }
            self.dockWatcher?.resetState()
        }
        dockAwayDebugLog("☀️ DockAway monitoring resumed")
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
        inputMonitoringPermissionMissing = !CGPreflightListenEventAccess()
        dockWatcher.start()
        startMultitouchPreHide()
        applyStatusIcon(dockVisible: isDockCurrentlyVisible())
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
        guard
            monitoringShouldRun,
            !inputMonitoringPermissionMissing,
            dockWatcher?.isRunning == true
        else { return }

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
                    dockAwayDebugLog(
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
                    dockAwayDebugLog(
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

                dockAwayDebugLog("  🧭 Four-finger motion=\(motion)")

                if let movingToNextSpace,
                   !self.fourFingerStartedInMissionControl,
                   watcher.beginVisibleHoldForHorizontalSwipeIfNeeded(
                        movingToNextSpace: movingToNextSpace
                   ) {
                    dockAwayDebugLog("  ✨ Dock-visible source confirmed → visible hold armed")
                    return
                }

                if motion == .downward,
                   self.fourFingerStartedInMissionControl,
                   watcher.beginVisibleHoldForMissionControlExitIfNeeded() {
                    dockAwayDebugLog("  ✨ Empty Mission Control destination → visible hold armed")
                    return
                }

                guard shouldPreHide else { return }

                let armedPreHide = watcher.beginHoldHidden(
                    missionControlWasActiveAtContact:
                        self.fourFingerStartedInMissionControl
                )
                dockAwayDebugLog(
                    armedPreHide
                        ? "  ⚡ Motion confirmed → hidden hold armed"
                        : "  ⚡ Motion confirmed → pre-hide suppressed"
                )
            }
        )

        let unavailable = !multitouch.isRunning && multitouch.shouldWarnUser
        if multitouchUnavailable != unavailable {
            multitouchUnavailable = unavailable
            if unavailable {
                dockAwayDebugLog("⚠️ Four-finger gesture support unavailable")
            } else {
                dockAwayDebugLog("✅ Four-finger gesture support restored")
            }
            updateDockAwayMenuState()
        }
    }

    private func retryMultitouchSupport() {
        guard
            monitoringShouldRun,
            !inputMonitoringPermissionMissing,
            dockWatcher?.isRunning == true
        else { return }

        multitouch.stop()
        startMultitouchPreHide()
    }

    // MARK: - Dynamic Glyph

    // The Dock's live autohide setting. A fresh instance every call, since a
    // long-lived UserDefaults for another app's domain can serve a stale
    // snapshot of that domain.
    private func isDockCurrentlyVisible() -> Bool {
        !(UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false)
    }

    // DockWatcher calls this from its existing state-read and command paths.
    // A main-queue hop keeps AppKit isolated even if a future detector callback
    // arrives off-main. `applyStatusIcon` ignores unchanged values.
    func updateDockVisibilityGlyph(_ dockVisible: Bool) {
        let applyUpdate: () -> Void = { [weak self] in
            guard let self else { return }
            self.applyStatusIcon(dockVisible: dockVisible)
        }
        if Thread.isMainThread {
            applyUpdate()
        } else {
            DispatchQueue.main.async(execute: applyUpdate)
        }
    }

    // Dock up (visible)  -> up chevron at full strength.
    // Dock down (hidden) -> down chevron at full strength.
    private func applyStatusIcon(dockVisible: Bool) {
        guard glyphShowsDockVisible != dockVisible else { return }

        let name = dockVisible ? "DockAwayStatus-Up" : "DockAwayStatus-Down"
        guard let image = NSImage(named: name) else {
            dockAwayDebugLog("⚠️ Missing menu bar image asset: \(name)")
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
        let statusContainer = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 46))
        let statusView = DockAwayStatusView(frame: .zero)
        statusView.translatesAutoresizingMaskIntoConstraints = false
        statusView.pauseResumeButton.target = self
        statusView.pauseResumeButton.action = #selector(toggleDockAway)
        statusView.update(
            active: statusAppearsActive,
            status: activeStatusText,
            inactiveTitle: inactiveStatusTitle,
            inactiveDetail: dockAwayEnabled
                ? automaticSuspensionDetail
                : "App detection paused",
            inactiveActionTitle: (accessibilityPermissionMissing || inputMonitoringPermissionMissing)
                && dockAwayEnabled
                ? permissionActionTitle
                : "Resume DockAway",
            warning: multitouchWarningVisible
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

        let launchAtLogin = NSMenuItem()
        launchAtLogin.tag = 200
        let launchAtLoginRowView = DockSettingPersistenceRowView(
            title: "Launch at Login",
            isOn: isLaunchAtLoginEnabled(),
            leadingInset: 13
        ) { [weak self] _ in
            self?.toggleLaunchAtLogin()
        }
        launchAtLogin.view = launchAtLoginRowView
        self.launchAtLoginRowView = launchAtLoginRowView

        let blacklistItem = NSMenuItem(title: "Blacklist", action: nil, keyEquivalent: "")
        let blacklistMenu = NSMenu(title: "Blacklist")
        blacklistMenu.autoenablesItems = false
        blacklistMenu.delegate = self
        blacklistItem.submenu = blacklistMenu
        self.blacklistMenu = blacklistMenu
        rebuildBlacklistMenu()

        let dockSettingsItem = NSMenuItem(
            title: "Dock Settings",
            action: nil,
            keyEquivalent: ""
        )
        dockSettingsItem.state = .on
        dockSettingsItem.onStateImage = menuIcon(from: NSImage(
            systemSymbolName: "slider.horizontal.3",
            accessibilityDescription: "Dock Settings"
        ))

        let dockSettingsMenu = NSMenu(title: "Dock Settings")
        dockSettingsMenu.autoenablesItems = false
        dockSettingsMenu.delegate = self

        let positionItem = NSMenuItem()
        positionItem.view = DockSettingSectionHeaderView(title: "Dock Position:")
        let dockPositionDisplayOrder: [DockPosition] = [.left, .bottom, .right]
        let positionRowView = DockPositionRowView(
            options: dockPositionDisplayOrder.map {
                (title: $0.title, tag: $0.rawValue)
            },
            selectedTag: DockPosition.bottom.rawValue
        ) { [weak self] rawValue in
            self?.selectDockPosition(rawValue: rawValue)
        }
        let positionRowItem = NSMenuItem()
        positionRowItem.view = positionRowView

        let animationSpeedItem = NSMenuItem()
        animationSpeedItem.view = DockSettingSectionHeaderView(
            title: "Animation Speed:"
        )
        let animationSliderView = DockSettingSliderView(
            leadingTitle: "Slow",
            trailingTitle: "Instant",
            accessibilityLabel: "Dock animation speed",
            accessibilityHelp: "Adjust from zero percent slow to one hundred percent instant"
        )
        animationSliderView.slider.target = self
        animationSliderView.slider.action = #selector(previewDockAnimationSlider(_:))
        animationSliderView.slider.commitHandler = { [weak self] percentage in
            self?.commitDockAnimationSlider(percentage)
        }
        let animationSliderItem = NSMenuItem()
        animationSliderItem.view = animationSliderView

        let revealDelayItem = NSMenuItem()
        revealDelayItem.view = DockSettingSectionHeaderView(
            title: "Reveal Delay:"
        )
        let revealDelaySliderView = DockSettingSliderView(
            leadingTitle: "None",
            trailingTitle: "Long",
            accessibilityLabel: "Dock reveal delay",
            accessibilityHelp: "Adjust from zero percent no delay to one hundred percent long delay"
        )
        revealDelaySliderView.slider.target = self
        revealDelaySliderView.slider.action = #selector(previewDockRevealDelaySlider(_:))
        revealDelaySliderView.slider.commitHandler = { [weak self] percentage in
            self?.commitDockRevealDelaySlider(percentage)
        }
        let revealDelaySliderItem = NSMenuItem()
        revealDelaySliderItem.view = revealDelaySliderView

        let keepDockSettingsAfterQuitItem = NSMenuItem()
        keepDockSettingsAfterQuitItem.view = DockSettingSectionHeaderView(
            title: "Keep Dock Settings After Quit:"
        )
        var dockSettingsPersistenceItems = [NSMenuItem]()
        for option in DockSettingPersistenceOption.allCases {
            let item = NSMenuItem()
            item.tag = option.rawValue
            item.view = DockSettingPersistenceRowView(
                title: option.title,
                isOn: shouldKeepDockSettingAfterQuit(option)
            ) { [weak self] shouldKeepSetting in
                self?.setDockSettingPersistence(
                    option,
                    shouldKeepSetting: shouldKeepSetting
                )
            }
            dockSettingsPersistenceItems.append(item)
        }
        let dockSettingsPersistenceNoneRowView = DockSettingPersistenceRowView(
            title: "None",
            isOn: false
        ) { [weak self] _ in
            self?.clearDockSettingsPersistence()
        }
        let dockSettingsPersistenceNoneItem = NSMenuItem()
        dockSettingsPersistenceNoneItem.view = dockSettingsPersistenceNoneRowView

        let restoreDockDefaultsRowView = DockSettingPersistenceRowView(
            title: "Restore macOS defaults",
            isOn: false
        ) { [weak self] _ in
            self?.restoreDefaultDockSettings()
        }
        let restoreDockDefaultsItem = NSMenuItem()
        restoreDockDefaultsItem.view = restoreDockDefaultsRowView

        dockSettingsItem.submenu = dockSettingsMenu
        self.dockSettingsMenu = dockSettingsMenu
        self.dockPositionRowView = positionRowView
        self.dockAnimationSliderView = animationSliderView
        self.dockRevealDelaySliderView = revealDelaySliderView
        self.dockSettingsPersistenceItems = dockSettingsPersistenceItems
        self.dockSettingsPersistenceNoneRowView = dockSettingsPersistenceNoneRowView
        self.restoreDockDefaultsRowView = restoreDockDefaultsRowView
        refreshDockSettingsMenu()
        dockSettingsMenu.addItem(positionItem)
        dockSettingsMenu.addItem(positionRowItem)
        dockSettingsMenu.addItem(.separator())
        dockSettingsMenu.addItem(animationSpeedItem)
        dockSettingsMenu.addItem(animationSliderItem)
        dockSettingsMenu.addItem(revealDelayItem)
        dockSettingsMenu.addItem(revealDelaySliderItem)
        dockSettingsMenu.addItem(.separator())
        dockSettingsMenu.addItem(keepDockSettingsAfterQuitItem)
        dockSettingsPersistenceItems.forEach { dockSettingsMenu.addItem($0) }
        dockSettingsMenu.addItem(dockSettingsPersistenceNoneItem)
        dockSettingsMenu.addItem(.separator())
        dockSettingsMenu.addItem(restoreDockDefaultsItem)
        menu.addItem(blacklistItem)
        menu.addItem(dockSettingsItem)
        menu.addItem(.separator())
        menu.addItem(launchAtLogin)

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
                updaterDelegate: self,
                userDriverDelegate: self
            )
            updateMenuItem.target = self.updaterController
            updateMenuItem.isEnabled = true
        }

        menu.addItem(updateMenuItem)

        let updateFrequencyItem = NSMenuItem(
            title: "Update Frequency",
            action: nil,
            keyEquivalent: ""
        )
        updateFrequencyItem.state = .on
        updateFrequencyItem.onStateImage = menuIcon(from: NSImage(
            systemSymbolName: "clock.arrow.circlepath",
            accessibilityDescription: "Update Frequency"
        ))

        let updateFrequencyMenu = NSMenu(title: "Update Frequency")
        updateFrequencyMenu.autoenablesItems = false

        let checkForUpdatesAtLaunchItem = NSMenuItem()
        checkForUpdatesAtLaunchItem.tag = -1
        checkForUpdatesAtLaunchItem.toolTip =
            "Check for a new DockAway version whenever DockAway opens"
        let checkForUpdatesAtLaunchRowView = DockSettingPersistenceRowView(
            title: "Check at Launch",
            isOn: UserDefaults.standard.bool(forKey: Self.checkForUpdatesAtLaunchKey),
            width: 190,
            leadingInset: 30
        ) { [weak self] enabled in
            self?.setCheckForUpdatesAtLaunch(enabled)
        }
        checkForUpdatesAtLaunchRowView.toolTip = checkForUpdatesAtLaunchItem.toolTip
        checkForUpdatesAtLaunchItem.view = checkForUpdatesAtLaunchRowView
        updateFrequencyMenu.addItem(checkForUpdatesAtLaunchItem)
        updateFrequencyMenu.addItem(.separator())
        self.checkForUpdatesAtLaunchItem = checkForUpdatesAtLaunchItem

        for frequency in UpdateFrequency.allCases {
            let item = NSMenuItem()
            item.tag = frequency.rawValue
            item.view = DockSettingPersistenceRowView(
                title: frequency.title,
                isOn: false,
                width: 190,
                leadingInset: 30
            ) { [weak self] _ in
                self?.selectUpdateFrequency(frequency)
            }
            updateFrequencyMenu.addItem(item)
        }
        updateFrequencyItem.submenu = updateFrequencyMenu
        self.updateFrequencyMenu = updateFrequencyMenu
        refreshUpdateFrequencyMenu()
        menu.addItem(updateFrequencyItem)

        menu.addItem(NSMenuItem(title: "About DockAway", action: #selector(showAbout), keyEquivalent: ""))
        let quitMenuItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitMenuItem.state = .on
        quitMenuItem.onStateImage = menuIcon(from: NSImage(
            systemSymbolName: "power",
            accessibilityDescription: "Quit DockAway"
        ))
        menu.addItem(quitMenuItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Dock Settings

    private var dockSettingsCanRestartDock: Bool {
        guard !dockSettingsRestartInProgress, !fourFingersDown else { return false }
        if let dockWatcher {
            return dockWatcher.canRestartDockSafely
        }
        return missionControlStateForDockSettings() == false
    }

    private func missionControlStateForDockSettings() -> Bool? {
        guard let windows = CGWindowListCopyWindowInfo(
            .optionOnScreenOnly,
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        return windows.contains { info in
            let ownerName = info[kCGWindowOwnerName as String] as? String
            let layer = info[kCGWindowLayer as String] as? Int
            return ownerName == "WindowManager" && layer == 14
        }
    }

    private func dockPreferenceValue(forKey key: String) -> Any? {
        CFPreferencesCopyValue(
            key as CFString,
            Self.dockPreferencesDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }

    private func dockPreferenceIsForced(_ key: String) -> Bool {
        CFPreferencesAppValueIsForced(
            key as CFString,
            Self.dockPreferencesDomain
        )
    }

    private func dockPreferenceDouble(forKey key: String) -> Double? {
        (dockPreferenceValue(forKey: key) as? NSNumber)?.doubleValue
    }

    private var legacyKeepDockSettingsAfterQuit: Bool {
        UserDefaults.standard.object(forKey: Self.keepDockSettingsAfterQuitKey) as? Bool ?? true
    }

    private func shouldKeepDockSettingAfterQuit(
        _ option: DockSettingPersistenceOption
    ) -> Bool {
        UserDefaults.standard.object(forKey: option.userDefaultsKey) as? Bool
            ?? legacyKeepDockSettingsAfterQuit
    }

    private func setDockSettingPersistence(
        _ option: DockSettingPersistenceOption,
        shouldKeepSetting: Bool
    ) {
        UserDefaults.standard.set(shouldKeepSetting, forKey: option.userDefaultsKey)
        refreshDockSettingsPersistenceRows()
    }

    private func clearDockSettingsPersistence() {
        for option in DockSettingPersistenceOption.allCases {
            UserDefaults.standard.set(false, forKey: option.userDefaultsKey)
        }
        refreshDockSettingsPersistenceRows()
    }

    private func refreshDockSettingsPersistenceRows() {
        var keepsAnyDockSetting = false
        for item in dockSettingsPersistenceItems {
            guard
                let option = DockSettingPersistenceOption(rawValue: item.tag),
                let rowView = item.view as? DockSettingPersistenceRowView
            else { continue }

            let shouldKeepSetting = shouldKeepDockSettingAfterQuit(option)
            keepsAnyDockSetting = keepsAnyDockSetting || shouldKeepSetting
            rowView.setOn(shouldKeepSetting)
        }
        dockSettingsPersistenceNoneRowView?.setOn(!keepsAnyDockSetting)
    }

    private func refreshDockSettingsMenu() {
        guard
            let dockPositionRowView,
            let dockAnimationSliderView,
            let dockRevealDelaySliderView
        else { return }

        let canRestartDock = dockSettingsCanRestartDock
        let orientationIsForced = dockPreferenceIsForced(Self.dockOrientationKey)
        let animationIsForced = dockPreferenceIsForced(Self.dockAnimationDurationKey)
        let revealDelayIsForced = dockPreferenceIsForced(Self.dockRevealDelayKey)

        let orientation = dockPreferenceValue(
            forKey: Self.dockOrientationKey
        ) as? String ?? DockPosition.bottom.preferenceValue
        let selectedPosition = DockPosition.allCases.first {
            $0.preferenceValue == orientation
        } ?? .bottom
        dockPositionRowView.setSelectedTag(selectedPosition.rawValue)
        dockPositionRowView.setControlsEnabled(canRestartDock && !orientationIsForced)

        let animationValue = dockPreferenceDouble(
            forKey: Self.dockAnimationDurationKey
        )
        let animationPercentage = animationSliderPercentage(forDuration: animationValue)
        let animationUsesSystemDefault = animationValue == nil
            || dockSliderUsesSystemDefault(
                normalizedDockSliderPercentage(animationPercentage)
            )
        dockAnimationSliderView.setPercentage(
            animationPercentage,
            usesSystemDefault: animationUsesSystemDefault
        )
        dockAnimationSliderView.slider.isEnabled = canRestartDock && !animationIsForced

        let revealDelayValue = dockPreferenceDouble(
            forKey: Self.dockRevealDelayKey
        )
        let revealDelayPercentage = revealDelaySliderPercentage(forDelay: revealDelayValue)
        let revealDelayUsesSystemDefault = revealDelayValue == nil
            || dockSliderUsesSystemDefault(
                normalizedDockSliderPercentage(revealDelayPercentage)
            )
        dockRevealDelaySliderView.setPercentage(
            revealDelayPercentage,
            usesSystemDefault: revealDelayUsesSystemDefault
        )
        dockRevealDelaySliderView.slider.isEnabled = canRestartDock && !revealDelayIsForced
        refreshDockSettingsPersistenceRows()

        let resettableKeys = [
            Self.dockOrientationKey,
            Self.dockAnimationDurationKey,
            Self.dockRevealDelayKey
        ].filter {
            dockPreferenceValue(forKey: $0) != nil
                && !dockPreferenceIsForced($0)
        }
        let allDockSettingsUseDefaults = orientation == DockPosition.bottom.preferenceValue
            && animationUsesSystemDefault
            && revealDelayUsesSystemDefault
        if allDockSettingsUseDefaults {
            restoreDockDefaultsRowView?.setTitle("Using macOS defaults")
            restoreDockDefaultsRowView?.setOn(true)
            restoreDockDefaultsRowView?.setControlEnabled(false)
        } else {
            restoreDockDefaultsRowView?.setTitle("Restore macOS defaults")
            restoreDockDefaultsRowView?.setOn(false)
            restoreDockDefaultsRowView?.setControlEnabled(
                canRestartDock && !resettableKeys.isEmpty
            )
        }
    }

    private func animationSliderPercentage(forDuration duration: Double?) -> Double {
        guard let duration else { return Self.defaultDockSliderPercentage }
        let boundedDuration = min(Self.maximumDockAnimationDuration, max(0, duration))
        return 100 * (1 - boundedDuration / Self.maximumDockAnimationDuration)
    }

    private func animationDuration(forSliderPercentage percentage: Double) -> Double {
        Self.maximumDockAnimationDuration * (1 - percentage / 100)
    }

    private func revealDelaySliderPercentage(forDelay delay: Double?) -> Double {
        guard let delay else { return Self.defaultDockSliderPercentage }
        let boundedDelay = min(Self.maximumDockRevealDelay, max(0, delay))
        return 100 * boundedDelay / Self.maximumDockRevealDelay
    }

    private func revealDelay(forSliderPercentage percentage: Double) -> Double {
        Self.maximumDockRevealDelay * percentage / 100
    }

    private func selectDockPosition(rawValue: Int) {
        guard let position = DockPosition(rawValue: rawValue) else { return }
        applyDockPreferenceChanges([
            DockPreferenceChange(
                key: Self.dockOrientationKey,
                value: position == .bottom
                    ? nil
                    : position.preferenceValue as NSString
            )
        ])
    }

    private func normalizedDockSliderPercentage(_ value: Double) -> Double {
        min(100, max(0, value.rounded()))
    }

    private func dockSliderUsesSystemDefault(_ percentage: Double) -> Bool {
        percentage == Self.defaultDockSliderPercentage
    }

    @objc private func previewDockAnimationSlider(_ sender: NSSlider) {
        let percentage = normalizedDockSliderPercentage(sender.doubleValue)
        let usesSystemDefault = dockSliderUsesSystemDefault(percentage)
        dockAnimationSliderView?.setPercentage(
            percentage,
            usesSystemDefault: usesSystemDefault
        )
    }

    private func commitDockAnimationSlider(_ value: Double) {
        let percentage = normalizedDockSliderPercentage(value)
        let usesSystemDefault = dockSliderUsesSystemDefault(percentage)
        dockAnimationSliderView?.setPercentage(
            percentage,
            usesSystemDefault: usesSystemDefault
        )
        applyDockPreferenceChanges([
            DockPreferenceChange(
                key: Self.dockAnimationDurationKey,
                value: usesSystemDefault
                    ? nil
                    : NSNumber(value: animationDuration(forSliderPercentage: percentage))
            )
        ])
    }

    @objc private func previewDockRevealDelaySlider(_ sender: NSSlider) {
        let percentage = normalizedDockSliderPercentage(sender.doubleValue)
        let usesSystemDefault = dockSliderUsesSystemDefault(percentage)
        dockRevealDelaySliderView?.setPercentage(
            percentage,
            usesSystemDefault: usesSystemDefault
        )
    }

    private func commitDockRevealDelaySlider(_ value: Double) {
        let percentage = normalizedDockSliderPercentage(value)
        let usesSystemDefault = dockSliderUsesSystemDefault(percentage)
        dockRevealDelaySliderView?.setPercentage(
            percentage,
            usesSystemDefault: usesSystemDefault
        )
        applyDockPreferenceChanges([
            DockPreferenceChange(
                key: Self.dockRevealDelayKey,
                value: usesSystemDefault
                    ? nil
                    : NSNumber(value: revealDelay(forSliderPercentage: percentage))
            )
        ])
    }

    @objc private func restoreDefaultDockSettings() {
        guard dockSettingsCanRestartDock else {
            NSSound.beep()
            refreshDockSettingsMenu()
            return
        }

        clearDockSettingsPersistence()
        applyDockPreferenceChanges([
            DockPreferenceChange(key: Self.dockOrientationKey, value: nil),
            DockPreferenceChange(key: Self.dockAnimationDurationKey, value: nil),
            DockPreferenceChange(key: Self.dockRevealDelayKey, value: nil)
        ])
    }

    private func applyDockPreferenceChanges(_ requestedChanges: [DockPreferenceChange]) {
        guard dockSettingsCanRestartDock else {
            NSSound.beep()
            return
        }

        let changes = requestedChanges.filter {
            !dockPreferenceIsForced($0.key)
                && !dockPreferenceValuesMatch(
                    dockPreferenceValue(forKey: $0.key),
                    $0.value
                )
        }
        guard !changes.isEmpty else {
            refreshDockSettingsMenu()
            return
        }

        dockSettingsRestartInProgress = true
        dockRestartGeneration += 1
        let restartGeneration = dockRestartGeneration

        fourFingersDown = false
        fourFingerStartedInMissionControl = false
        dockWatcher?.stop()
        multitouch.stop()
        updateDockAwayMenuState()
        dockAwayStatusView?.pauseResumeButton.isEnabled = false

        for change in changes {
            CFPreferencesSetValue(
                change.key as CFString,
                change.value as CFPropertyList?,
                Self.dockPreferencesDomain,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        }

        guard CFPreferencesSynchronize(
            Self.dockPreferencesDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else {
            finishDockSettingsChange(
                generation: restartGeneration,
                errorMessage: "macOS could not save the Dock settings."
            )
            return
        }

        restartDock(
            generation: restartGeneration
        )
    }

    private func dockPreferenceValuesMatch(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs as NSNumber, rhs as NSNumber):
            return abs(lhs.doubleValue - rhs.doubleValue) < 0.001
        case let (lhs as String, rhs as String):
            return lhs == rhs
        case let (lhs as NSString, rhs as NSString):
            return lhs == rhs
        default:
            return false
        }
    }

    private func restartDock(generation: Int) {
        guard let dockApplication = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock"
        ).first else {
            finishDockSettingsChange(
                generation: generation,
                errorMessage: "Dock.app was not running, so its settings will apply the next time it opens."
            )
            return
        }

        let previousPID = dockApplication.processIdentifier
        guard kill(previousPID, SIGTERM) == 0 else {
            finishDockSettingsChange(
                generation: generation,
                errorMessage: "DockAway could not restart Dock.app."
            )
            return
        }

        waitForReplacementDock(
            previousPID: previousPID,
            generation: generation,
            attempt: 0
        )
    }

    private func waitForReplacementDock(
        previousPID: pid_t,
        generation: Int,
        attempt: Int
    ) {
        guard
            !isQuitting,
            dockSettingsRestartInProgress,
            generation == dockRestartGeneration
        else { return }

        let replacementDock = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock"
        ).first {
            !$0.isTerminated && $0.processIdentifier != previousPID
        }

        if let replacementDock, dockApplicationIsReady(replacementDock) {
            // Give the new Dock process a moment to establish its windows and
            // preference observers before DockAway resumes issuing decisions.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
                self?.finishDockSettingsChange(
                    generation: generation,
                    errorMessage: nil
                )
            }
            return
        }

        guard attempt < 80 else {
            finishDockSettingsChange(
                generation: generation,
                errorMessage: "Dock.app took too long to restart. The new settings were still saved."
            )
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForReplacementDock(
                previousPID: previousPID,
                generation: generation,
                attempt: attempt + 1
            )
        }
    }

    private func dockApplicationIsReady(_ application: NSRunningApplication) -> Bool {
        guard application.isFinishedLaunching else { return false }
        let processIdentifier = application.processIdentifier
        guard let windows = CGWindowListCopyWindowInfo(
            .optionAll,
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        return windows.contains { info in
            (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                == processIdentifier
        }
    }

    private func finishDockSettingsChange(
        generation: Int,
        errorMessage: String?
    ) {
        guard generation == dockRestartGeneration else { return }

        dockSettingsRestartInProgress = false
        dockAwayStatusView?.pauseResumeButton.isEnabled = true
        refreshDockSettingsMenu()
        applyStatusIcon(dockVisible: isDockCurrentlyVisible())

        // Re-read the live pause, permission, sleep, and session state now.
        // Any of those can change while launchd replaces Dock.app.
        startMonitoringIfAllowed()
        if dockWatcher?.isRunning == true {
            dockWatcher.repairStateAfterDockRestart()
        }
        updateDockAwayMenuState()

        if let errorMessage {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Dock Settings"
            alert.informativeText = errorMessage
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
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

    private func refreshUpdateFrequencyMenu() {
        guard let updateFrequencyMenu, let updaterController else { return }

        let checksAtLaunch = UserDefaults.standard.bool(
            forKey: Self.checkForUpdatesAtLaunchKey
        )
        checkForUpdatesAtLaunchItem?.state = checksAtLaunch ? .on : .off
        (checkForUpdatesAtLaunchItem?.view as? DockSettingPersistenceRowView)?
            .setOn(checksAtLaunch)

        let updater = updaterController.updater
        let automaticChecksEnabled = updater.automaticallyChecksForUpdates
        let currentInterval = updater.updateCheckInterval

        for item in updateFrequencyMenu.items {
            guard !item.isSeparatorItem else { continue }
            guard let frequency = UpdateFrequency(rawValue: item.tag) else { continue }
            if frequency == .manualOnly {
                item.state = automaticChecksEnabled ? .off : .on
            } else {
                let intervalMatches = abs(currentInterval - Double(frequency.rawValue)) < 1.0
                item.state = automaticChecksEnabled && intervalMatches ? .on : .off
            }
            (item.view as? DockSettingPersistenceRowView)?.setOn(item.state == .on)
        }
    }

    private func selectUpdateFrequency(_ frequency: UpdateFrequency) {
        guard let updaterController else { return }

        let updater = updaterController.updater
        if frequency == .manualOnly {
            updater.automaticallyChecksForUpdates = false
        } else {
            updater.updateCheckInterval = Double(frequency.rawValue)
            updater.automaticallyChecksForUpdates = true
        }
        refreshUpdateFrequencyMenu()
    }

    private func setCheckForUpdatesAtLaunch(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.checkForUpdatesAtLaunchKey)
        refreshUpdateFrequencyMenu()
    }

    private func checkForUpdatesAtLaunchIfEnabled() {
        guard UserDefaults.standard.bool(forKey: Self.checkForUpdatesAtLaunchKey) else {
            return
        }

        let updater = updaterController.updater
        if updater.automaticallyChecksForUpdates {
            // Preserve Sparkle's automatic-download/install preference.
            updater.checkForUpdatesInBackground()
        } else {
            // "Manual Only" disables Sparkle's background driver, so probe the
            // feed and update DockAway's menu without offering the update.
            updater.checkForUpdateInformation()
        }
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
        cancelBlacklistReorderAnimation()
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
        currentBlacklistBundleIdentifier = currentApplication?.bundleIdentifier

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
            let firstIsBlacklisted = ignoredIdentifiers.contains($0.bundleIdentifier)
            let secondIsBlacklisted = ignoredIdentifiers.contains($1.bundleIdentifier)
            if firstIsBlacklisted != secondIsBlacklisted {
                return firstIsBlacklisted
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        if let currentApplication {
            let currentItem = blacklistMenuItem(
                for: currentApplication,
                ignoredIdentifiers: ignoredIdentifiers
            )
            currentItem.toolTip = "Current application"
            currentItem.view?.toolTip = "Current application"
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
            let blacklistedApplicationCount = applications.prefix {
                ignoredIdentifiers.contains($0.bundleIdentifier)
            }.count
            for (index, application) in applications.enumerated() {
                if index == blacklistedApplicationCount,
                   blacklistedApplicationCount > 0,
                   blacklistedApplicationCount < applications.count {
                    blacklistMenu.addItem(blacklistGroupSeparator())
                }
                blacklistMenu.addItem(blacklistMenuItem(
                    for: application,
                    ignoredIdentifiers: ignoredIdentifiers
                ))
            }
        }

        blacklistMenu.addItem(.separator())

        let chooseItem = NSMenuItem()
        chooseItem.view = BlacklistActionMenuItemView(
            title: "Choose Application…"
        ) { [weak self, weak blacklistMenu] in
            blacklistMenu?.cancelTracking()
            DispatchQueue.main.async {
                self?.chooseBlacklistApplication()
            }
        }
        blacklistMenu.addItem(chooseItem)

        let clearItem = NSMenuItem()
        clearItem.view = BlacklistActionMenuItemView(
            title: "Remove All",
            isEnabled: !ignoredIdentifiers.isEmpty
        ) { [weak self, weak blacklistMenu] in
            blacklistMenu?.cancelTracking()
            DispatchQueue.main.async {
                self?.clearBlacklist()
            }
        }
        blacklistMenu.addItem(clearItem)

        blacklistMenu.addItem(.separator())

        let helpItem = NSMenuItem()
        helpItem.view = BlacklistHelpMenuItemView()
        blacklistMenu.addItem(helpItem)
    }

    private func blacklistMenuItem(
        for application: BlacklistApplication,
        ignoredIdentifiers: Set<String>
    ) -> NSMenuItem {
        let item = NSMenuItem()
        item.title = application.name
        item.representedObject = application.bundleIdentifier
        item.view = DockSettingPersistenceRowView(
            title: application.name,
            isOn: ignoredIdentifiers.contains(application.bundleIdentifier),
            leadingInset: 18,
            icon: application.icon ?? NSImage(
                systemSymbolName: "app",
                accessibilityDescription: "Application"
            )
        ) { [weak self] isBlacklisted in
            self?.setBlacklistedApplication(
                application.bundleIdentifier,
                isBlacklisted: isBlacklisted
            )
        }
        return item
    }

    private func blacklistGroupSeparator() -> NSMenuItem {
        let separator = NSMenuItem()
        separator.tag = Self.blacklistGroupSeparatorTag
        separator.isEnabled = false
        separator.view = BlacklistGroupSeparatorView(frame: .zero)
        return separator
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

    private func setBlacklistedApplication(
        _ bundleIdentifier: String,
        isBlacklisted: Bool
    ) {
        var identifiers = ignoredWindowBundleIdentifiers
        if isBlacklisted {
            identifiers.insert(bundleIdentifier)
        } else {
            identifiers.remove(bundleIdentifier)
        }

        saveIgnoredWindowBundleIdentifiers(identifiers)
        DispatchQueue.main.async { [weak self] in
            self?.reorderBlacklistApplicationItems(using: identifiers)
        }
    }

    private func reorderBlacklistApplicationItems(using ignoredIdentifiers: Set<String>) {
        guard let blacklistMenu else { return }

        cancelBlacklistReorderAnimation()

        let movableItems = blacklistMenu.items.filter { item in
            guard let bundleIdentifier = item.representedObject as? String else {
                return false
            }
            return bundleIdentifier != currentBlacklistBundleIdentifier
        }
        guard !movableItems.isEmpty else { return }

        let existingGroupSeparator = blacklistMenu.items.first {
            $0.tag == Self.blacklistGroupSeparatorTag
        }
        let oldMenuWindow = movableItems.compactMap { $0.view?.window }.first
        let animatedItems = movableItems + [existingGroupSeparator].compactMap { $0 }
        let shouldAnimate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let capturedSnapshots: [BlacklistRowAnimationSnapshot] = shouldAnimate
            ? animatedItems.compactMap { item in
                guard
                    let view = item.view,
                    let image = snapshotImage(for: view),
                    let oldScreenFrame = menuItemScreenFrame(item)
                else { return nil }
                return BlacklistRowAnimationSnapshot(
                    item: item,
                    image: image,
                    oldScreenFrame: oldScreenFrame
                )
            }
            : []
        let animationSnapshots = capturedSnapshots.count == animatedItems.count
            ? capturedSnapshots
            : []
        let animationOverlays: [BlacklistRowAnimationOverlay]
        if let oldMenuWindow, !animationSnapshots.isEmpty {
            animationOverlays = primeBlacklistRowsAnimation(
                animationSnapshots,
                above: oldMenuWindow
            )
        } else {
            animationOverlays = []
        }
        if !animationOverlays.isEmpty {
            blacklistReorderHiddenItems = animatedItems
            animatedItems.forEach {
                $0.view?.alphaValue = 0
            }
            oldMenuWindow?.displayIfNeeded()
        }

        if let existingGroupSeparator {
            blacklistMenu.removeItem(existingGroupSeparator)
        }
        movableItems.forEach { blacklistMenu.removeItem($0) }

        let sortedItems = movableItems.sorted { first, second in
            guard
                let firstIdentifier = first.representedObject as? String,
                let secondIdentifier = second.representedObject as? String
            else { return first.title.localizedCaseInsensitiveCompare(second.title) == .orderedAscending }

            let firstIsBlacklisted = ignoredIdentifiers.contains(firstIdentifier)
            let secondIsBlacklisted = ignoredIdentifiers.contains(secondIdentifier)
            if firstIsBlacklisted != secondIsBlacklisted {
                return firstIsBlacklisted
            }
            return first.title.localizedCaseInsensitiveCompare(second.title) == .orderedAscending
        }
        let itemOrderChanged = zip(movableItems, sortedItems).contains { pair in
            pair.0 !== pair.1
        }
        let blacklistedCount = sortedItems.prefix {
            guard let identifier = $0.representedObject as? String else { return false }
            return ignoredIdentifiers.contains(identifier)
        }.count

        let insertionIndex: Int
        if let currentBlacklistBundleIdentifier,
           let currentItem = blacklistMenu.items.first(where: {
               $0.representedObject as? String == currentBlacklistBundleIdentifier
           }),
           let currentIndex = blacklistMenu.items.firstIndex(of: currentItem) {
            insertionIndex = currentIndex + 2
        } else {
            insertionIndex = 0
        }

        var nextIndex = insertionIndex
        for (index, item) in sortedItems.enumerated() {
            if index == blacklistedCount,
               blacklistedCount > 0,
               blacklistedCount < sortedItems.count {
                let separator = existingGroupSeparator ?? blacklistGroupSeparator()
                blacklistMenu.insertItem(separator, at: nextIndex)
                nextIndex += 1
            }
            blacklistMenu.insertItem(item, at: nextIndex)
            nextIndex += 1
        }
        blacklistMenu.update()
        let menuWindow = sortedItems.compactMap { $0.view?.window }.first
        menuWindow?.contentView?.layoutSubtreeIfNeeded()
        sortedItems.forEach { $0.view?.superview?.layoutSubtreeIfNeeded() }

        if let menuWindow, !animationOverlays.isEmpty {
            scheduleBlacklistRowsAnimation(
                animationOverlays,
                above: menuWindow,
                expectsMovement: itemOrderChanged
            )
        } else {
            cancelBlacklistReorderAnimation()
        }
    }

    private func menuItemScreenFrame(_ item: NSMenuItem) -> NSRect? {
        guard let view = item.view, let window = view.window else { return nil }
        let windowRect = view.convert(view.bounds, to: nil)
        return window.convertToScreen(windowRect)
    }

    private func snapshotImage(for view: NSView) -> NSImage? {
        let capture = { () -> NSImage? in
            guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                return nil
            }
            view.cacheDisplay(in: view.bounds, to: representation)
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(representation)
            return image
        }

        guard let rowView = view as? DockSettingPersistenceRowView else {
            return capture()
        }
        return rowView.animationSnapshotImage()
    }

    private func primeBlacklistRowsAnimation(
        _ snapshots: [BlacklistRowAnimationSnapshot],
        above menuWindow: NSWindow
    ) -> [BlacklistRowAnimationOverlay] {
        var overlayScreenFrame = menuWindow.frame.insetBy(dx: -4, dy: -16)
        snapshots.forEach {
            overlayScreenFrame = overlayScreenFrame.union($0.oldScreenFrame)
        }

        let overlayWindow = NSPanel(
            contentRect: overlayScreenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        overlayWindow.isOpaque = false
        overlayWindow.backgroundColor = .clear
        overlayWindow.hasShadow = false
        overlayWindow.ignoresMouseEvents = true
        overlayWindow.hidesOnDeactivate = false
        overlayWindow.isReleasedWhenClosed = false
        overlayWindow.animationBehavior = .none
        overlayWindow.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        overlayWindow.level = menuWindow.level

        let overlayContentView = NSView(
            frame: NSRect(origin: .zero, size: overlayScreenFrame.size)
        )
        overlayContentView.wantsLayer = true
        overlayWindow.contentView = overlayContentView

        let overlays = snapshots.map { snapshot in
            let frame = snapshot.oldScreenFrame.offsetBy(
                dx: -overlayScreenFrame.minX,
                dy: -overlayScreenFrame.minY
            )
            let imageView = NonHitTestingImageView(frame: frame)
            imageView.image = snapshot.image
            imageView.imageScaling = .scaleAxesIndependently
            overlayContentView.addSubview(imageView)
            return BlacklistRowAnimationOverlay(snapshot: snapshot, view: imageView)
        }

        blacklistReorderOverlayWindow = overlayWindow
        blacklistReorderOverlayParentWindow = menuWindow
        menuWindow.addChildWindow(overlayWindow, ordered: .above)
        overlayWindow.order(.above, relativeTo: menuWindow.windowNumber)
        overlayWindow.displayIfNeeded()
        CATransaction.flush()
        return overlays
    }

    private func scheduleBlacklistRowsAnimation(
        _ overlays: [BlacklistRowAnimationOverlay],
        above menuWindow: NSWindow,
        expectsMovement: Bool,
        layoutAttempt: Int = 0
    ) {
        blacklistReorderSetupTimer?.invalidate()
        let setupTimer = Timer(timeInterval: 1.0 / 120.0, repeats: false) {
            [weak self, weak menuWindow] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard self.blacklistReorderSetupTimer === timer else {
                timer.invalidate()
                return
            }
            self.blacklistReorderSetupTimer = nil
            guard let menuWindow else {
                self.cancelBlacklistReorderAnimation()
                return
            }

            menuWindow.contentView?.layoutSubtreeIfNeeded()
            menuWindow.displayIfNeeded()
            self.startBlacklistRowsAnimation(
                overlays,
                above: menuWindow,
                expectsMovement: expectsMovement,
                layoutAttempt: layoutAttempt
            )
        }
        blacklistReorderSetupTimer = setupTimer
        RunLoop.main.add(setupTimer, forMode: .eventTracking)
        RunLoop.main.add(setupTimer, forMode: .common)
    }

    private func startBlacklistRowsAnimation(
        _ overlays: [BlacklistRowAnimationOverlay],
        above menuWindow: NSWindow,
        expectsMovement: Bool,
        layoutAttempt: Int
    ) {
        let destinations = overlays.map { overlay -> (BlacklistRowAnimationOverlay, NSRect?) in
            let itemIsStillInMenu = blacklistMenu.items.contains {
                $0 === overlay.snapshot.item
            }
            let newScreenFrame = itemIsStillInMenu
                ? menuItemScreenFrame(overlay.snapshot.item)
                : nil
            return (overlay, newScreenFrame)
        }
        let hasMissingApplicationDestination = destinations.contains { overlay, frame in
            overlay.snapshot.item.tag != Self.blacklistGroupSeparatorTag && frame == nil
        }
        guard !hasMissingApplicationDestination else {
            cancelBlacklistReorderAnimation()
            return
        }

        let hasVisibleMovement = destinations.contains { overlay, newScreenFrame in
            guard let newScreenFrame else { return false }
            return abs(overlay.snapshot.oldScreenFrame.midX - newScreenFrame.midX) > 0.5
                || abs(overlay.snapshot.oldScreenFrame.midY - newScreenFrame.midY) > 0.5
        }
        if expectsMovement, !hasVisibleMovement {
            if layoutAttempt < 18 {
                scheduleBlacklistRowsAnimation(
                    overlays,
                    above: menuWindow,
                    expectsMovement: true,
                    layoutAttempt: layoutAttempt + 1
                )
            } else {
                cancelBlacklistReorderAnimation()
            }
            return
        }

        guard
            let overlayWindow = blacklistReorderOverlayWindow,
            let overlayContentView = overlayWindow.contentView
        else {
            cancelBlacklistReorderAnimation()
            return
        }
        let overlayScreenFrame = overlayWindow.frame
        let movements = destinations.map { overlay, newScreenFrame in
            let endScreenFrame = newScreenFrame ?? overlay.snapshot.oldScreenFrame
            let endFrame = endScreenFrame.offsetBy(
                dx: -overlayScreenFrame.minX,
                dy: -overlayScreenFrame.minY
            )
            return BlacklistRowAnimationMovement(
                view: overlay.view,
                startFrame: overlay.view.frame,
                endFrame: endFrame
            )
        }

        let duration: CFTimeInterval = 0.64
        let startTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard
                let self,
                let activeTimer = self.blacklistReorderAnimationTimer,
                activeTimer === timer,
                self.blacklistReorderOverlayWindow === overlayWindow
            else {
                timer.invalidate()
                return
            }

            let linearProgress = min(
                1,
                max(0, (CACurrentMediaTime() - startTime) / duration)
            )
            let easedProgress = linearProgress * linearProgress
                * (3 - 2 * linearProgress)
            let progress = CGFloat(easedProgress)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for movement in movements {
                let start = movement.startFrame
                let end = movement.endFrame
                movement.view.frame = NSRect(
                    x: start.minX + (end.minX - start.minX) * progress,
                    y: start.minY + (end.minY - start.minY) * progress,
                    width: start.width + (end.width - start.width) * progress,
                    height: start.height + (end.height - start.height) * progress
                )
            }
            CATransaction.commit()
            overlayContentView.needsDisplay = true
            overlayWindow.displayIfNeeded()

            if linearProgress >= 1 {
                self.finishBlacklistReorderAnimation(timer)
            }
        }
        blacklistReorderAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishBlacklistReorderAnimation(_ timer: Timer) {
        guard blacklistReorderAnimationTimer === timer else { return }
        timer.invalidate()
        blacklistReorderAnimationTimer = nil

        let menuWindow = blacklistReorderHiddenItems.first?.view?.window
        blacklistReorderHiddenItems.forEach {
            $0.view?.alphaValue = 1
        }
        blacklistReorderHiddenItems.removeAll()
        menuWindow?.displayIfNeeded()
        if let overlayWindow = blacklistReorderOverlayWindow {
            blacklistReorderOverlayParentWindow?.removeChildWindow(overlayWindow)
        }
        blacklistReorderOverlayParentWindow = nil
        blacklistReorderOverlayWindow?.orderOut(nil)
        blacklistReorderOverlayWindow = nil
    }

    private func cancelBlacklistReorderAnimation() {
        blacklistReorderSetupTimer?.invalidate()
        blacklistReorderSetupTimer = nil
        blacklistReorderAnimationTimer?.invalidate()
        blacklistReorderAnimationTimer = nil

        let menuWindow = blacklistReorderHiddenItems.first?.view?.window
        blacklistReorderHiddenItems.forEach {
            $0.view?.alphaValue = 1
        }
        blacklistReorderHiddenItems.removeAll()
        menuWindow?.displayIfNeeded()
        if let overlayWindow = blacklistReorderOverlayWindow {
            blacklistReorderOverlayParentWindow?.removeChildWindow(overlayWindow)
        }
        blacklistReorderOverlayParentWindow = nil
        blacklistReorderOverlayWindow?.orderOut(nil)
        blacklistReorderOverlayWindow = nil
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
        let applicationCount = ignoredWindowBundleIdentifiers.count
        if applicationCount >= 2 {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Remove All Blacklisted Apps?"
            alert.informativeText = "Are you sure you want to remove \(applicationCount) apps from the blacklist?"
            alert.addButton(withTitle: "Remove All")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true

            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        saveIgnoredWindowBundleIdentifiers([])
        rebuildBlacklistMenu()
    }

    func updateStatus(_ text: String) {
        let applyUpdate = { [weak self] in
            guard let self, self.monitoringShouldRun else { return }
            guard self.activeStatusText != text else { return }
            self.activeStatusText = text
            self.updateDockAwayMenuState()
        }

        if Thread.isMainThread {
            applyUpdate()
        } else {
            DispatchQueue.main.async(execute: applyUpdate)
        }
    }

    @objc private func toggleDockAway() {
        guard !dockSettingsRestartInProgress else {
            NSSound.beep()
            return
        }

        if dockAwayEnabled, multitouchWarningVisible {
            retryMultitouchSupport()
            return
        }

        if dockAwayEnabled {
            if accessibilityPermissionMissing {
                openAccessibilitySettings()
                return
            }
            if inputMonitoringPermissionMissing {
                openInputMonitoringSettings()
                return
            }
        }

        if dockAwayEnabled {
            dockAwayEnabled = false
            fourFingersDown = false
            fourFingerStartedInMissionControl = false
            dockWatcher?.stop()
            multitouch.stop()
            inputMonitoringWaitWorkItem?.cancel()
            inputMonitoringWaitWorkItem = nil
            updateDockAwayMenuState()
            restoreDockState()
            applyStatusIcon(dockVisible: isDockCurrentlyVisible())
            dockAwayDebugLog("🔴 DockAway inactive")
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
            dockAwayDebugLog("🟢 DockAway active")
        }
    }

    private func updateDockAwayMenuState() {
        dockAwayStatusView?.update(
            active: statusAppearsActive,
            status: activeStatusText,
            inactiveTitle: inactiveStatusTitle,
            inactiveDetail: dockAwayEnabled
                ? automaticSuspensionDetail
                : "App detection paused",
            inactiveActionTitle: (accessibilityPermissionMissing || inputMonitoringPermissionMissing)
                && dockAwayEnabled
                ? permissionActionTitle
                : "Resume DockAway",
            warning: multitouchWarningVisible
        )
        dockAwayStatusView?.pauseResumeButton.isEnabled = !dockSettingsRestartInProgress
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
            dockAwayDebugLog("⚠️ Launch at login error: \(error)")
        }
        launchAtLoginRowView?.setOn(isLaunchAtLoginEnabled())
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
            alert.informativeText = "Accessibility Permission is Required:\nDockAway uses Accessibility to detect window changes and manage the Dock. Input Monitoring is a separate optional permission used for early four-finger gesture detection; if it is missing, DockAway will show a direct shortcut in its menu."
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
                dockAwayDebugLog("✅ Accessibility granted - starting detector")
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
            self.updateDockAwayMenuState()
            self.waitForAccessibility()
            dockAwayDebugLog("⚠️ Accessibility permission removed — DockAway paused")
        }

        if Thread.isMainThread {
            handleLoss()
        } else {
            DispatchQueue.main.async(execute: handleLoss)
        }
    }

    @objc private func openAccessibilitySettings() {
        if !AXIsProcessTrusted() {
            let options: NSDictionary = [
                kAXTrustedCheckOptionPrompt.takeRetainedValue(): true
            ]
            _ = AXIsProcessTrustedWithOptions(options)
        }

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

    // MARK: - Input Monitoring Permission

    @discardableResult
    private func refreshInputMonitoringPermission() -> Bool {
        let permissionIsGranted = CGPreflightListenEventAccess()
        inputMonitoringPermissionMissing = !permissionIsGranted

        if permissionIsGranted {
            inputMonitoringWaitWorkItem?.cancel()
            inputMonitoringWaitWorkItem = nil
            startMultitouchPreHide()
        } else {
            fourFingersDown = false
            fourFingerStartedInMissionControl = false
            multitouch.stop()
        }

        updateDockAwayMenuState()
        return permissionIsGranted
    }

    private func waitForInputMonitoringPermission() {
        guard
            !isQuitting,
            dockAwayEnabled,
            automaticSuspensionReasons.isEmpty,
            inputMonitoringPermissionMissing
        else { return }

        inputMonitoringWaitWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isQuitting else { return }
            self.inputMonitoringWaitWorkItem = nil
            if !self.refreshInputMonitoringPermission() {
                self.waitForInputMonitoringPermission()
            } else {
                dockAwayDebugLog("✅ Input Monitoring granted - gesture smoothing enabled")
            }
        }
        inputMonitoringWaitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    @objc private func openInputMonitoringSettings() {
        // This user-initiated request lets macOS present its native permission
        // prompt. The Settings link remains useful when the app is already in
        // the list but its switch is off.
        _ = CGRequestListenEventAccess()

        if let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ) {
            NSWorkspace.shared.open(settingsURL)
        }

        inputMonitoringPermissionMissing = !CGPreflightListenEventAccess()
        updateDockAwayMenuState()
        if inputMonitoringPermissionMissing {
            waitForInputMonitoringPermission()
        } else {
            startMultitouchPreHide()
        }
    }

    // MARK: - Unix Signal & Cleanup

    private func setupSignalHandler() {
        // 1. Ignore the default sudden-death SIGTERM so we can handle it ourselves
        signal(SIGTERM, SIG_IGN)
        
        // 2. Set up a listener for the Unix signal
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            dockAwayDebugLog("  ⚠️ Caught Unix SIGTERM (Activity Monitor)")
            self?.isQuitting = true
            self?.restoreDockState()
            self?.restoreDefaultDockPreferencesBeforeExitIfNeeded()
            
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
            dockAwayDebugLog("  ⚡ Restoring Dock visibility before termination")
            watcher.simulateOptionCommandDPublic()
            applyStatusIcon(dockVisible: true)
            
            // The Life Support Hold: Keep the app alive just long enough for the keystroke to register
            Thread.sleep(forTimeInterval: 0.15)
        }
    }

    private func restoreDefaultDockPreferencesBeforeExitIfNeeded() {
        let resettableKeys: [String] = DockSettingPersistenceOption.allCases.compactMap { option in
            let key = option.dockPreferenceKey
            guard
                !shouldKeepDockSettingAfterQuit(option),
                dockPreferenceValue(forKey: key) != nil,
                !dockPreferenceIsForced(key)
            else { return nil }
            return key
        }
        guard !resettableKeys.isEmpty else { return }

        for key in resettableKeys {
            CFPreferencesSetValue(
                key as CFString,
                nil,
                Self.dockPreferencesDomain,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        }

        guard CFPreferencesSynchronize(
            Self.dockPreferencesDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else {
            dockAwayDebugLog("⚠️ Could not restore the default Dock settings before exit")
            return
        }

        if let dockApplication = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock"
        ).first {
            _ = kill(dockApplication.processIdentifier, SIGTERM)
        }
    }

    @objc private func quit() {
        // Polite exit (triggers applicationWillTerminate)
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        isQuitting = true
        cancelBlacklistReorderAnimation()
        accessibilityWaitWorkItem?.cancel()
        inputMonitoringWaitWorkItem?.cancel()
        dockWatcher?.stop()
        multitouch.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        restoreDockState()
        restoreDefaultDockPreferencesBeforeExitIfNeeded()
    }
}

// MARK: - Sparkle Update Discovery

extension AppDelegate: SPUUpdaterDelegate {
    // This callback is shared by Sparkle's manual, scheduled, and automatic
    // update drivers. Keep the menu indicator independent of whether the user
    // has enabled automatic downloads and installation.
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        showAvailableUpdate(item)
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
        } else if menu === dockSettingsMenu {
            refreshDockSettingsMenu()
        } else if menu === statusItem.menu {
            // The menu opening is an event-driven opportunity to reflect a
            // manual Dock shortcut or a permission changed in System Settings.
            applyStatusIcon(dockVisible: isDockCurrentlyVisible())
            refreshInputMonitoringPermission()
            refreshDockSettingsMenu()
            refreshUpdateFrequencyMenu()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === blacklistMenu {
            cancelBlacklistReorderAnimation()
        }
    }
}
