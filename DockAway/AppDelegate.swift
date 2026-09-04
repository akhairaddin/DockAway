import Cocoa
import IOKit.hid
import IOKit.hidsystem
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

private final class AppIconShineView: NSView {
    private let maskImage: NSImage
    private let iconMaskLayer = CALayer()
    private let shineLayer = CAGradientLayer()

    init(maskImage: NSImage) {
        self.maskImage = maskImage
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = true

        shineLayer.colors = [
            NSColor.clear.cgColor,
            NSColor.white.withAlphaComponent(0.42).cgColor,
            NSColor.clear.cgColor
        ]
        shineLayer.locations = [0, 0.5, 1]
        shineLayer.startPoint = CGPoint(x: 1, y: 1)
        shineLayer.endPoint = CGPoint(x: 2, y: 2)
        shineLayer.opacity = 0

        layer?.addSublayer(shineLayer)
        layer?.mask = iconMaskLayer
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()

        var imageRect = bounds
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shineLayer.frame = bounds
        iconMaskLayer.frame = bounds
        iconMaskLayer.contents = maskImage.cgImage(
            forProposedRect: &imageRect,
            context: nil,
            hints: nil
        )
        iconMaskLayer.contentsGravity = .resizeAspect
        iconMaskLayer.contentsScale = scale
        CATransaction.commit()
    }

    func play(after delay: TimeInterval) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.window != nil else { return }
            self.layoutSubtreeIfNeeded()

            let startPoint = CABasicAnimation(keyPath: "startPoint")
            startPoint.fromValue = CGPoint(x: -1, y: -1)
            startPoint.toValue = CGPoint(x: 1, y: 1)

            let endPoint = CABasicAnimation(keyPath: "endPoint")
            endPoint.fromValue = CGPoint(x: 0, y: 0)
            endPoint.toValue = CGPoint(x: 2, y: 2)

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, 1, 1, 0]
            opacity.keyTimes = [0, 0.12, 0.78, 1]

            let shine = CAAnimationGroup()
            shine.animations = [startPoint, endPoint, opacity]
            shine.duration = 1.28
            shine.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            self.shineLayer.removeAnimation(forKey: "appIconShine")
            self.shineLayer.add(shine, forKey: "appIconShine")
        }
    }

    @objc func replay(_ sender: Any?) {
        play(after: 0)
    }
}

private final class PermissionAttentionRingView: NSView {
    private let ringLayers = (0..<2).map { _ in CAShapeLayer() }
    private var isEmitting = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        for ringLayer in ringLayers {
            ringLayer.fillColor = NSColor.clear.cgColor
            ringLayer.strokeColor = NSColor.systemGreen.withAlphaComponent(0.68).cgColor
            ringLayer.lineWidth = 1.15
            ringLayer.opacity = 0
            layer?.addSublayer(ringLayer)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for ringLayer in ringLayers {
            ringLayer.frame = bounds
            ringLayer.path = CGPath(
                ellipseIn: bounds.insetBy(dx: 4, dy: 4),
                transform: nil
            )
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateEmissionAnimation()
    }

    func setEmitting(_ emitting: Bool) {
        guard isEmitting != emitting else { return }
        isEmitting = emitting
        updateEmissionAnimation()
    }

    private func updateEmissionAnimation() {
        guard
            isEmitting,
            window != nil,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            for ringLayer in ringLayers {
                ringLayer.removeAnimation(forKey: "permissionAttentionRing")
                ringLayer.opacity = 0
            }
            return
        }

        guard ringLayers.contains(where: {
            $0.animation(forKey: "permissionAttentionRing") == nil
        }) else { return }

        let duration: CFTimeInterval = 2.4
        let interval = duration / Double(ringLayers.count)
        let timelineStart = CACurrentMediaTime()

        for (index, ringLayer) in ringLayers.enumerated() {
            ringLayer.removeAnimation(forKey: "permissionAttentionRing")
            ringLayer.opacity = 0

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.82
            scale.toValue = 1.38

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, 0.52, 0]
            opacity.keyTimes = [0, 0.16, 1]

            let emission = CAAnimationGroup()
            emission.animations = [scale, opacity]
            emission.duration = duration
            emission.beginTime = timelineStart + (Double(index) * interval)
            emission.repeatCount = .infinity
            emission.timingFunction = CAMediaTimingFunction(name: .easeOut)
            emission.fillMode = .backwards
            ringLayer.add(emission, forKey: "permissionAttentionRing")
        }
    }
}

private final class DockAwayStatusView: NSView {
    private let contentView = NSView()
    private let statusDot = PulsingStatusDotView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let labelStack = NSStackView()
    private let permissionAttentionView = PermissionAttentionRingView(frame: .zero)
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
        permissionAttentionView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(statusDot)
        contentView.addSubview(labelStack)
        contentView.addSubview(permissionAttentionView)
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

            permissionAttentionView.centerXAnchor.constraint(equalTo: pauseResumeButton.centerXAnchor),
            permissionAttentionView.centerYAnchor.constraint(equalTo: pauseResumeButton.centerYAnchor),
            permissionAttentionView.widthAnchor.constraint(equalToConstant: 34),
            permissionAttentionView.heightAnchor.constraint(equalToConstant: 34),

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
        let permissionRequired = !active
            && !warning
            && inactiveTitle == "Permission Required"

        permissionAttentionView.setEmitting(permissionRequired)

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
    private let indicatorBaseImageView = NonHitTestingImageView()
    private let indicatorMarkImageView = NonHitTestingImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let changeHandler: (Bool) -> Void
    private let itemIcon: NSImage?
    private var displayedIsOn: Bool?
    private var controlEnabled = true

    init(
        title: String,
        isOn: Bool,
        width: CGFloat = 230,
        leadingInset: CGFloat = 18,
        titleLeadingAdjustment: CGFloat = 0,
        fullRowHitTarget: Bool = true,
        icon: NSImage? = nil,
        changeHandler: @escaping (Bool) -> Void
    ) {
        itemIcon = icon?.copy() as? NSImage
        self.changeHandler = changeHandler
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        wantsLayer = true

        checkbox.title = title
        checkbox.state = isOn ? .on : .off
        checkbox.target = self
        checkbox.action = #selector(toggleCheckbox(_:))
        checkbox.focusRingType = .none
        checkbox.isTransparent = true
        checkbox.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = checkbox.font
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setAccessibilityElement(false)
        updateTitle(title)

        for imageView in [indicatorBaseImageView, indicatorMarkImageView] {
            imageView.imageScaling = .scaleProportionallyDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.setAccessibilityElement(false)
        }
        indicatorMarkImageView.wantsLayer = true

        addSubview(indicatorBaseImageView)
        addSubview(indicatorMarkImageView)
        addSubview(titleLabel)
        addSubview(checkbox)

        var rowConstraints: [NSLayoutConstraint] = [
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor),
            checkbox.topAnchor.constraint(equalTo: topAnchor),
            checkbox.bottomAnchor.constraint(equalTo: bottomAnchor),
            indicatorBaseImageView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: leadingInset
            ),
            indicatorBaseImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            indicatorBaseImageView.widthAnchor.constraint(equalToConstant: 20),
            indicatorBaseImageView.heightAnchor.constraint(equalToConstant: 20),
            indicatorMarkImageView.centerXAnchor.constraint(equalTo: indicatorBaseImageView.centerXAnchor),
            indicatorMarkImageView.centerYAnchor.constraint(equalTo: indicatorBaseImageView.centerYAnchor),
            indicatorMarkImageView.widthAnchor.constraint(equalTo: indicatorBaseImageView.widthAnchor),
            indicatorMarkImageView.heightAnchor.constraint(equalTo: indicatorBaseImageView.heightAnchor),
            titleLabel.leadingAnchor.constraint(
                equalTo: indicatorBaseImageView.trailingAnchor,
                constant: 6 + titleLeadingAdjustment
            ),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -12
            ),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ]
        rowConstraints.append(
            fullRowHitTarget
                ? checkbox.trailingAnchor.constraint(equalTo: trailingAnchor)
                : checkbox.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 16)
        )
        NSLayoutConstraint.activate(rowConstraints)

        updateIndicatorImages()
        setIndicatorState(isOn, animated: false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setOn(_ isOn: Bool) {
        setIndicatorState(isOn, animated: true)
    }

    func setTitle(_ title: String) {
        updateTitle(title)
    }

    func setControlEnabled(_ enabled: Bool) {
        controlEnabled = enabled
        checkbox.isEnabled = enabled
        titleLabel.alphaValue = enabled ? 1 : 0.45
        indicatorBaseImageView.alphaValue = enabled ? 1 : 0.45
        guard let markLayer = indicatorMarkImageView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        markLayer.opacity = displayedIsOn == true
            ? (enabled ? 1 : 0.45)
            : 0
        CATransaction.commit()
    }

    @objc private func toggleCheckbox(_ sender: NSButton) {
        let requestedState = sender.state == .on
        let previousDisplayedState = displayedIsOn
        changeHandler(requestedState)

        // Model-backed rows refresh synchronously through setOn(_:). Blacklist
        // rows refresh on the next run-loop turn, so reflect their accepted
        // native checkbox state here without disturbing radio-style rows.
        if displayedIsOn == previousDisplayedState,
           (checkbox.state == .on) == requestedState {
            setIndicatorState(requestedState, animated: true)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateIndicatorImages()
    }

    private func updateTitle(_ title: String) {
        // Keep the native checkbox as the interaction and accessibility
        // element. The visible title is rendered by titleLabel so its column
        // can be aligned independently from the checkbox glyph.
        checkbox.title = ""
        checkbox.setAccessibilityLabel(title)

        guard let icon = itemIcon?.copy() as? NSImage else {
            titleLabel.stringValue = title
            return
        }

        icon.size = NSSize(width: 16, height: 16)
        let attachment = NSTextAttachment()
        attachment.image = icon
        attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
        let attributedTitle = NSMutableAttributedString(attachment: attachment)
        attributedTitle.append(NSAttributedString(string: "  \(title)"))
        titleLabel.attributedStringValue = attributedTitle
    }

    private func updateIndicatorImages() {
        let usesAppSymbol = NSImage(
            systemSymbolName: "checkmark.app.fill",
            accessibilityDescription: nil
        ) != nil
        let baseSymbolName = usesAppSymbol ? "app.fill" : "square.fill"
        let markSymbolName = usesAppSymbol
            ? "checkmark.app.fill"
            : "checkmark.square.fill"
        let sizeConfiguration = NSImage.SymbolConfiguration(
            pointSize: 19,
            weight: .medium
        )
        let baseConfiguration = sizeConfiguration.applying(
            NSImage.SymbolConfiguration(paletteColors: [.tertiaryLabelColor])
        )
        let markConfiguration = sizeConfiguration.applying(
            NSImage.SymbolConfiguration(
                paletteColors: [.white, .clear]
            )
        )

        indicatorBaseImageView.image = NSImage(
            systemSymbolName: baseSymbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(baseConfiguration)
        indicatorMarkImageView.image = NSImage(
            systemSymbolName: markSymbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(markConfiguration)
    }

    private func setIndicatorState(_ isOn: Bool, animated: Bool) {
        let previousState = displayedIsOn
        checkbox.state = isOn ? .on : .off
        guard previousState != isOn else { return }
        displayedIsOn = isOn

        guard let markLayer = indicatorMarkImageView.layer else {
            indicatorMarkImageView.alphaValue = isOn ? 1 : 0
            return
        }

        let finalOpacity: Float = isOn ? (controlEnabled ? 1 : 0.45) : 0
        let animationKey = "checkboxCheckmarkToggle"
        let presentationLayer = markLayer.presentation()
        let animationWasRunning = markLayer.animation(forKey: animationKey) != nil
        let startingOpacity = presentationLayer?.opacity ?? markLayer.opacity
        let presentedTransform = presentationLayer?.transform ?? markLayer.transform
        let presentedScale = max(
            0.01,
            hypot(presentedTransform.m11, presentedTransform.m12)
        )
        let shouldAnimate = animated
            && previousState != nil
            && window != nil
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        markLayer.removeAnimation(forKey: animationKey)
        markLayer.opacity = finalOpacity
        markLayer.transform = CATransform3DIdentity

        guard shouldAnimate else {
            CATransaction.commit()
            return
        }

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        let group = CAAnimationGroup()
        let duration: CFTimeInterval

        if isOn {
            opacity.values = [startingOpacity, finalOpacity * 0.72, finalOpacity]
            opacity.keyTimes = [0, 0.42, 1]
            scale.values = [
                animationWasRunning ? presentedScale : 0.86,
                1.025,
                1.0
            ]
            scale.keyTimes = [0, 0.68, 1]
            scale.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeInEaseOut)
            ]
            duration = 0.30
        } else {
            opacity.values = [startingOpacity, 0]
            opacity.keyTimes = [0, 1]
            scale.values = [presentedScale, 0.94]
            scale.keyTimes = [0, 1]
            scale.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut)]
            duration = 0.19
        }

        opacity.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        opacity.duration = duration
        scale.duration = duration
        group.animations = [opacity, scale]
        group.duration = duration
        markLayer.add(group, forKey: animationKey)
        CATransaction.commit()
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
    private var controlEnabled: Bool
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
            highlightView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
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

    func setControlEnabled(_ enabled: Bool) {
        controlEnabled = enabled
        setHighlighted(false)
        titleLabel.textColor = enabled ? .labelColor : .tertiaryLabelColor
        setAccessibilityEnabled(enabled)
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
            highlightView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            highlightView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            highlightView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: iconView.leadingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: highlightView.centerYAnchor),
            iconView.trailingAnchor.constraint(equalTo: highlightView.trailingAnchor, constant: -10),
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

private func laterEmphasizedText(
    _ text: String,
    font: NSFont,
    color: NSColor,
    alignment: NSTextAlignment = .left
) -> NSAttributedString {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = alignment
    let attributedText = NSMutableAttributedString(
        string: text,
        attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
    )
    for phrase in ["“Later”", "“Continue”"] {
        let range = (text as NSString).range(of: phrase)
        if range.location != NSNotFound {
            attributedText.addAttribute(
                .font,
                value: NSFont.systemFont(ofSize: font.pointSize, weight: .bold),
                range: range
            )
        }
    }
    return attributedText
}

private final class PermissionSetupRowView: NSView {
    private let statusCircleImageView = NSImageView()
    private let statusGrantedCircleImageView = NSImageView()
    private let statusCheckmarkImageView = NSImageView()
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private let actionButton = NSButton(title: "Allow", target: nil, action: nil)
    private let requestAction: () -> Void
    private var grantedState: Bool?
    private var actionAvailable = true
    private var checkmarkAnimationGeneration = 0
    private var circleAnimationGeneration = 0

    init(title: String, detail: String, requestAction: @escaping () -> Void) {
        titleLabel = NSTextField(labelWithString: title)
        detailLabel = NSTextField(wrappingLabelWithString: detail)
        self.requestAction = requestAction
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        layer?.backgroundColor = rowBackgroundColor(granted: false).cgColor

        for imageView in [
            statusCircleImageView,
            statusGrantedCircleImageView,
            statusCheckmarkImageView
        ] {
            imageView.imageScaling = .scaleProportionallyDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.setAccessibilityElement(false)
        }
        statusCircleImageView.image = NSImage(
            systemSymbolName: "circle",
            accessibilityDescription: "Permission required"
        )
        statusCircleImageView.contentTintColor = .secondaryLabelColor
        statusGrantedCircleImageView.image = NSImage(
            systemSymbolName: "circle.fill",
            accessibilityDescription: "Granted"
        )
        statusGrantedCircleImageView.contentTintColor = .systemGreen
        statusGrantedCircleImageView.alphaValue = 0
        statusCheckmarkImageView.image = NSImage(
            systemSymbolName: "checkmark",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 8.5, weight: .bold)
        )
        statusCheckmarkImageView.contentTintColor = .white
        statusCheckmarkImageView.isHidden = true

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor

        let detailFont = NSFont.systemFont(ofSize: 11.5)
        detailLabel.font = detailFont
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.attributedStringValue = laterEmphasizedText(
            detail,
            font: detailFont,
            color: .secondaryLabelColor
        )

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .large
        actionButton.target = self
        actionButton.action = #selector(requestPermission)
        actionButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(statusCircleImageView)
        addSubview(statusGrantedCircleImageView)
        addSubview(statusCheckmarkImageView)
        addSubview(textStack)
        addSubview(actionButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 78),
            statusCircleImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            statusCircleImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusCircleImageView.widthAnchor.constraint(equalToConstant: 30),
            statusCircleImageView.heightAnchor.constraint(equalToConstant: 30),
            statusGrantedCircleImageView.centerXAnchor.constraint(equalTo: statusCircleImageView.centerXAnchor),
            statusGrantedCircleImageView.centerYAnchor.constraint(equalTo: statusCircleImageView.centerYAnchor),
            statusGrantedCircleImageView.widthAnchor.constraint(equalTo: statusCircleImageView.widthAnchor),
            statusGrantedCircleImageView.heightAnchor.constraint(equalTo: statusCircleImageView.heightAnchor),
            statusCheckmarkImageView.centerXAnchor.constraint(equalTo: statusCircleImageView.centerXAnchor),
            statusCheckmarkImageView.centerYAnchor.constraint(equalTo: statusCircleImageView.centerYAnchor),
            statusCheckmarkImageView.widthAnchor.constraint(equalToConstant: 10),
            statusCheckmarkImageView.heightAnchor.constraint(equalToConstant: 10),
            textStack.leadingAnchor.constraint(equalTo: statusCircleImageView.trailingAnchor, constant: 11),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -12),
            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88)
        ])

        setGranted(false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setGranted(_ granted: Bool) {
        guard grantedState != granted else { return }
        let shouldAnimate = grantedState != nil
        grantedState = granted

        guard shouldAnimate else {
            applyGrantedAppearance(granted)
            return
        }

        let oldBackgroundColor = layer?.backgroundColor
        let newBackgroundColor = rowBackgroundColor(granted: granted).cgColor
        let backgroundAnimation = CABasicAnimation(keyPath: "backgroundColor")
        backgroundAnimation.fromValue = oldBackgroundColor
        backgroundAnimation.toValue = newBackgroundColor
        backgroundAnimation.duration = 0.36
        backgroundAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(backgroundAnimation, forKey: "permissionBackgroundTransition")
        layer?.backgroundColor = newBackgroundColor

        if granted {
            applyCircleAppearance(false)
            setCheckmarkVisible(false, animated: false)
        } else {
            applyCircleAppearance(true)
            setCheckmarkVisible(true, animated: false)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            actionButton.animator().alphaValue = 0.55
        } completionHandler: { [weak self] in
            guard let self, self.grantedState == granted else { return }
            self.applyActionAppearance(granted)
            if granted {
                self.transitionCircleAppearance(toGranted: true) { [weak self] in
                    guard let self, self.grantedState == true else { return }
                    self.setCheckmarkVisible(true, animated: true)
                }
            } else {
                self.setCheckmarkVisible(false, animated: true) { [weak self] in
                    guard let self, self.grantedState == false else { return }
                    self.transitionCircleAppearance(toGranted: false)
                }
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.actionButton.animator().alphaValue = 1
            }
        }
    }

    func setActionAvailable(_ available: Bool) {
        guard actionAvailable != available else { return }
        actionAvailable = available
        applyGrantedAppearance(grantedState == true)
    }

    private func applyGrantedAppearance(
        _ granted: Bool,
        animateCheckmark: Bool = false
    ) {
        applyCircleAppearance(granted)
        setCheckmarkVisible(granted, animated: animateCheckmark)
        applyActionAppearance(granted)
    }

    private func applyCircleAppearance(_ granted: Bool) {
        circleAnimationGeneration += 1
        statusCircleImageView.alphaValue = granted ? 0 : 1
        statusGrantedCircleImageView.alphaValue = granted ? 1 : 0
    }

    private func transitionCircleAppearance(
        toGranted granted: Bool,
        completion: (() -> Void)? = nil
    ) {
        circleAnimationGeneration += 1
        let generation = circleAnimationGeneration
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        guard !reduceMotion else {
            applyCircleAppearance(granted)
            completion?()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.40
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            statusCircleImageView.animator().alphaValue = granted ? 0 : 1
            statusGrantedCircleImageView.animator().alphaValue = granted ? 1 : 0
        } completionHandler: { [weak self] in
            guard
                let self,
                self.grantedState == granted,
                self.circleAnimationGeneration == generation
            else { return }
            self.statusCircleImageView.alphaValue = granted ? 0 : 1
            self.statusGrantedCircleImageView.alphaValue = granted ? 1 : 0
            completion?()
        }
    }

    private func applyActionAppearance(_ granted: Bool) {
        actionButton.title = granted ? "Granted" : (actionAvailable ? "Allow" : "Next")
        actionButton.isEnabled = !granted && actionAvailable
        actionButton.alphaValue = granted || actionAvailable ? 1 : 0.55
        layer?.backgroundColor = rowBackgroundColor(granted: granted).cgColor
    }

    private func setCheckmarkVisible(
        _ visible: Bool,
        animated: Bool,
        completion: (() -> Void)? = nil
    ) {
        checkmarkAnimationGeneration += 1
        let generation = checkmarkAnimationGeneration
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        guard animated, !reduceMotion else {
            statusCheckmarkImageView.isHidden = !visible
            statusCheckmarkImageView.layer?.mask = nil
            completion?()
            return
        }

        statusCheckmarkImageView.isHidden = false
        statusCheckmarkImageView.wantsLayer = true
        guard let markLayer = statusCheckmarkImageView.layer else {
            completion?()
            return
        }
        let markSize = markLayer.bounds.size
        let mask = CALayer()
        mask.backgroundColor = NSColor.white.cgColor
        mask.anchorPoint = CGPoint(x: 0, y: 0.5)
        mask.position = CGPoint(x: 0, y: markSize.height / 2)
        let fullBounds = CGRect(
            x: 0,
            y: -markSize.height / 2,
            width: markSize.width,
            height: markSize.height
        )
        let hiddenBounds = CGRect(
            x: 0,
            y: -markSize.height / 2,
            width: 0,
            height: markSize.height
        )
        mask.bounds = visible ? hiddenBounds : fullBounds
        markLayer.mask = mask

        let reveal = CABasicAnimation(keyPath: "bounds.size.width")
        reveal.fromValue = visible ? 0 : markSize.width
        reveal.toValue = visible ? markSize.width : 0
        reveal.duration = 0.38
        reveal.timingFunction = CAMediaTimingFunction(
            controlPoints: 0.2,
            0.75,
            0.25,
            1
        )
        mask.bounds = visible ? fullBounds : hiddenBounds
        mask.add(reveal, forKey: "checkmarkDraw")

        guard !visible else {
            completion?()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + reveal.duration) { [weak self] in
            guard
                let self,
                self.checkmarkAnimationGeneration == generation,
                self.grantedState == false
            else { return }
            self.statusCheckmarkImageView.isHidden = true
            completion?()
        }
    }

    private func rowBackgroundColor(granted: Bool) -> NSColor {
        granted
            ? NSColor.systemGreen.withAlphaComponent(0.08)
            : NSColor.controlBackgroundColor.withAlphaComponent(0.38)
    }

    @objc private func requestPermission() {
        requestAction()
    }
}

private final class PermissionSetupView: NSView {
    private let accessibilityRow: PermissionSetupRowView
    private let inputMonitoringRow: PermissionSetupRowView
    private let instructionLabel = NSTextField(
        wrappingLabelWithString: "Grant both permissions, then return here to continue."
    )
    private var setupStateCode = 0

    var instructionView: NSTextField {
        instructionLabel
    }

    init(
        requestAccessibility: @escaping () -> Void,
        requestInputMonitoring: @escaping () -> Void
    ) {
        accessibilityRow = PermissionSetupRowView(
            title: "Accessibility",
            detail: "Detects window changes and manages Dock visibility.",
            requestAction: requestAccessibility
        )
        inputMonitoringRow = PermissionSetupRowView(
            title: "Input Monitoring",
            detail: "Enable it, then choose “Later” when macOS asks to quit.",
            requestAction: requestInputMonitoring
        )
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 165))

        instructionLabel.font = .systemFont(ofSize: 11.5)
        instructionLabel.textColor = .secondaryLabelColor
        instructionLabel.alignment = .center

        let stack = NSStackView(views: [inputMonitoringRow, accessibilityRow])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool,
        inputMonitoringRestartPending: Bool,
        inputMonitoringSettingsOpen: Bool
    ) {
        accessibilityRow.setGranted(accessibilityGranted)
        inputMonitoringRow.setGranted(
            inputMonitoringGranted || inputMonitoringRestartPending
        )
        let inputMonitoringReady = inputMonitoringGranted || inputMonitoringRestartPending
        accessibilityRow.setActionAvailable(
            accessibilityGranted || inputMonitoringReady
        )

        let newStateCode: Int
        if accessibilityGranted && inputMonitoringGranted {
            newStateCode = 4
        } else if accessibilityGranted && inputMonitoringRestartPending {
            newStateCode = 3
        } else if inputMonitoringReady {
            newStateCode = 2
        } else if inputMonitoringSettingsOpen {
            newStateCode = 1
        } else {
            newStateCode = 0
        }
        guard newStateCode != setupStateCode else { return }
        setupStateCode = newStateCode

        if instructionLabel.alphaValue < 0.01 {
            applyInstruction(for: newStateCode)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            instructionLabel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.setupStateCode == newStateCode else { return }
            self.applyInstruction(for: newStateCode)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.instructionLabel.animator().alphaValue = 1
            }
        }
    }

    private func applyInstruction(for stateCode: Int) {
        switch stateCode {
        case 0:
            instructionLabel.stringValue =
                "Start with Input Monitoring so DockAway can verify it correctly."
            instructionLabel.textColor = .secondaryLabelColor
        case 1:
            let instruction =
                "After turning DockAway on, choose “Later” in the Quit & Reopen prompt."
            instructionLabel.attributedStringValue = laterEmphasizedText(
                instruction,
                font: NSFont.systemFont(ofSize: 11.5),
                color: .secondaryLabelColor,
                alignment: .center
            )
        case 2:
            let instruction =
                "Perfect. DockAway will restart after “Continue”. Now allow Accessibility."
            instructionLabel.attributedStringValue = laterEmphasizedText(
                instruction,
                font: NSFont.systemFont(ofSize: 11.5),
                color: .secondaryLabelColor,
                alignment: .center
            )
        case 3:
            let instruction = "You're all set! Click “Continue” to restart DockAway."
            instructionLabel.attributedStringValue = laterEmphasizedText(
                instruction,
                font: NSFont.systemFont(ofSize: 11.5),
                color: .systemGreen,
                alignment: .center
            )
        default:
            instructionLabel.stringValue = "You're all set! DockAway is ready."
            instructionLabel.textColor = .systemGreen
        }
    }
}


private final class OnboardingPrimaryButton: NSButton {
    private var isMouseDown = false
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    convenience init(title: String, target: Any?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target as AnyObject?
        self.action = action
        updateVisualState(animated: false)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 88, height: 28)
    }

    private func configure() {
        wantsLayer = true
        isBordered = false
        focusRingType = .none
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        updateVisualState(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        updateVisualState(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        isMouseDown = false
        updateVisualState(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isMouseDown = true
        updateVisualState(animated: false)
        super.mouseDown(with: event)
        isMouseDown = false
        updateVisualState(animated: true)
    }

    override var isEnabled: Bool {
        didSet { updateVisualState(animated: true) }
    }

    override var title: String {
        didSet { updateVisualState(animated: false) }
    }

    private func updateVisualState(animated: Bool = true) {
        guard let layer else { return }
        let targetBgColor: CGColor
        let targetTitle: NSAttributedString

        if isEnabled {
            let baseColor = NSColor.controlAccentColor
            let color: NSColor
            if isMouseDown {
                color = baseColor.blended(withFraction: 0.25, of: .black) ?? baseColor
            } else if isHovered {
                color = baseColor.blended(withFraction: 0.15, of: .white) ?? baseColor
            } else {
                color = baseColor
            }
            targetBgColor = color.cgColor
            targetTitle = NSAttributedString(
                string: title,
                attributes: [
                    .foregroundColor: NSColor.white,
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
                ]
            )
        } else {
            targetBgColor = NSColor.white.withAlphaComponent(0.08).cgColor
            targetTitle = NSAttributedString(
                string: title,
                attributes: [
                    .foregroundColor: NSColor.white.withAlphaComponent(0.35),
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium)
                ]
            )
        }

        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let anim = CABasicAnimation(keyPath: "backgroundColor")
            anim.fromValue = layer.backgroundColor
            anim.toValue = targetBgColor
            anim.duration = 0.30
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(anim, forKey: "colorTransition")
        }
        layer.backgroundColor = targetBgColor
        attributedTitle = targetTitle
    }
}


@objc class AppDelegate: NSObject, NSApplicationDelegate {
    private static let ignoredWindowBundleIdentifiersKey = "IgnoredWindowBundleIdentifiers"
    private static let checkForUpdatesAtLaunchKey = "CheckForUpdatesAtLaunch"
    private static let keepDockSettingsAfterQuitKey = "KeepDockSettingsAfterQuit"
    private static let keepDockPositionAfterQuitKey = "KeepDockPositionAfterQuit"
    private static let keepDockAnimationAfterQuitKey = "KeepDockAnimationAfterQuit"
    private static let keepDockRevealDelayAfterQuitKey = "KeepDockRevealDelayAfterQuit"
    private static let permissionSetupCompletedKey = "PermissionSetupCompleted"
    private static let showStartedPopoverAfterRelaunchKey =
        "ShowStartedPopoverAfterPermissionRelaunch"
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

    var isQuitting = false
    private var statusItem: NSStatusItem!
    private var startedPopover: NSPopover?
    private var startedPopoverCloseWorkItem: DispatchWorkItem?
    private var startedPopoverLocalEventMonitor: Any?
    private var startedPopoverGlobalEventMonitor: Any?
    private weak var startedPopoverContentView: NSView?
    private weak var startedPopoverCelebrationButton: NSButton?
    private var startedPopoverConfettiWindows: [NSPanel] = []
    private var startedPopoverConfettiCloseWorkItems: [DispatchWorkItem] = []
    private var dockWatcher: DockWatcher!
    private var updaterController: SPUStandardUpdaterController!
    private var updateMenuItem: NSMenuItem!
    private var updateFrequencyMenu: NSMenu!
    private var checkForUpdatesAtLaunchItem: NSMenuItem!
    private var availableUpdateVersion: String?
    private var blacklistMenu: NSMenu!
    private weak var blacklistClearActionView: BlacklistActionMenuItemView?
    private var currentBlacklistBundleIdentifier: String?
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
    private var permissionSetupInProgress = false
    private var permissionSetupWindow: NSPanel?
    private var permissionSetupTimer: Timer?
    private weak var permissionSetupContinueButton: NSButton?
    private weak var permissionSetupLaunchAtLoginRowView: DockSettingPersistenceRowView?
    private var inputMonitoringSettingsVisitInProgress = false
    private var inputMonitoringSettingsWasFrontmost = false
    private var inputMonitoringRestartPending = false
    private var inputMonitoringPermissionProbe: Process?
    private var inputMonitoringPermissionProbeLastRun = Date.distantPast
    private var permissionRelaunchScheduled = false
    private var isPermissionRelaunching = false
    private var isWaitingForAccessibility = false
    private var accessibilityWaitWorkItem: DispatchWorkItem?
    private var inputMonitoringWaitWorkItem: DispatchWorkItem?
    private var inputMonitoringRegistrationManager: IOHIDManager?
    private var permissionHealthTimer: Timer?
    
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

    private var inputMonitoringAccessGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }


    func applicationDidFinishLaunching(_ notification: Notification) {
        dockAwayDebugLog("🚀 APP LAUNCHED")
        NSApp.setActivationPolicy(.accessory)

        // These are first-run defaults only. UserDefaults preserves any later
        // choice the user makes in the Update Frequency menu.
        UserDefaults.standard.register(defaults: [
            Self.checkForUpdatesAtLaunchKey: true
        ])

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
        inputMonitoringPermissionMissing = !inputMonitoringAccessGranted
        setupMenuBar()
        requestAccessibilityPermission()
        startPermissionHealthMonitoring()
        
        // Arm the signal trapper
        setupSignalHandler()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !AXIsProcessTrusted(), !accessibilityPermissionMissing {
            accessibilityPermissionWasRevoked()
        }
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

    // Input Monitoring is part of DockAway's required setup for reliable
    // gesture timing. Keep the core watcher alive only so the menu can guide
    // the user through restoring the missing permission.
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
        "Restore Permissions"
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
        inputMonitoringPermissionMissing = !inputMonitoringAccessGranted
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
            leadingInset: 11,
            titleLeadingAdjustment: -3
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
            width: 170,
            leadingInset: 20
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
                width: 170,
                leadingInset: 20
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
            restoreDockDefaultsRowView?.setControlEnabled(false)
            restoreDockDefaultsRowView?.setOn(true)
        } else {
            restoreDockDefaultsRowView?.setTitle("Restore macOS defaults")
            restoreDockDefaultsRowView?.setControlEnabled(
                canRestartDock && !resettableKeys.isEmpty
            )
            restoreDockDefaultsRowView?.setOn(false)
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
        blacklistClearActionView?.setControlEnabled(!identifiers.isEmpty)
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
        let clearActionView = BlacklistActionMenuItemView(
            title: "Remove All",
            isEnabled: !ignoredIdentifiers.isEmpty
        ) { [weak self] in
            self?.clearBlacklist()
        }
        clearItem.view = clearActionView
        blacklistClearActionView = clearActionView
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
            alert.informativeText = "Are you sure you want to\nremove \(applicationCount) apps from the blacklist?"
            alert.addButton(withTitle: "Remove All")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true

            alert.layout()
            if let contentView = alert.window.contentView {
                if let imageView = contentView.subviews.first(where: { $0 is NSImageView }) {
                    imageView.frame.origin.x = floor((contentView.bounds.width - imageView.frame.width) / 2)
                }
                for subview in contentView.subviews {
                    guard let textField = subview as? NSTextField,
                          textField.stringValue == alert.messageText || textField.stringValue == alert.informativeText
                    else { continue }
                    textField.alignment = .center
                    let paragraphStyle = NSMutableParagraphStyle()
                    paragraphStyle.alignment = .center
                    let attributed = NSMutableAttributedString(attributedString: textField.attributedStringValue)
                    attributed.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: attributed.length))
                    textField.attributedStringValue = attributed
                }
            }

            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        saveIgnoredWindowBundleIdentifiers([])
        for item in blacklistMenu.items {
            guard
                item.representedObject is String,
                let rowView = item.view as? DockSettingPersistenceRowView
            else { continue }
            rowView.setOn(false)
        }
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

        if dockAwayEnabled,
           accessibilityPermissionMissing || inputMonitoringPermissionMissing {
            statusItem.menu?.cancelTracking()
            DispatchQueue.main.async { [weak self] in
                self?.requestAccessibilityPermission()
            }
            return
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
                updateDockAwayMenuState()
                requestAccessibilityPermission()
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
        let isEnabled = isLaunchAtLoginEnabled()
        launchAtLoginRowView?.setOn(isEnabled)
        permissionSetupLaunchAtLoginRowView?.setOn(isEnabled)
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

    // MARK: - Permission Setup

    private func requestAccessibilityPermission() {
        accessibilityPermissionMissing = !AXIsProcessTrusted()
        inputMonitoringPermissionMissing = !inputMonitoringAccessGranted
        updateDockAwayMenuState()

        guard accessibilityPermissionMissing || inputMonitoringPermissionMissing else {
            completePermissionSetup()
            return
        }

        UserDefaults.standard.set(false, forKey: Self.permissionSetupCompletedKey)
        presentPermissionSetup()
    }

    private func presentPermissionSetup() {
        guard !permissionSetupInProgress, !isQuitting else { return }
        permissionSetupInProgress = true

        let setupView = PermissionSetupView(
            requestAccessibility: { [weak self] in
                self?.openAccessibilitySettings()
            },
            requestInputMonitoring: { [weak self] in
                self?.openInputMonitoringSettings()
            }
        )

        let (
            setupWindow,
            continueButton,
            entranceViews,
            welcomeEmojiView,
            iconShineView
        ) = makePermissionSetupWindow(setupView: setupView)
        permissionSetupWindow = setupWindow
        permissionSetupContinueButton = continueButton
        continueButton.isEnabled = false
        var continueReady = false

        let refreshSetupState = { [weak self, weak continueButton] in
            guard let self else { return }
            self.refreshInputMonitoringSettingsVisit()
            let accessibilityGranted = AXIsProcessTrusted()
            let inputMonitoringGranted = self.inputMonitoringAccessGranted
            let inputMonitoringReady = inputMonitoringGranted
                || self.inputMonitoringRestartPending
            let ready = accessibilityGranted && inputMonitoringReady
            self.accessibilityPermissionMissing = !accessibilityGranted
            self.inputMonitoringPermissionMissing = !inputMonitoringGranted
            self.isWaitingForAccessibility = !accessibilityGranted
            setupView.update(
                accessibilityGranted: accessibilityGranted,
                inputMonitoringGranted: inputMonitoringGranted,
                inputMonitoringRestartPending: self.inputMonitoringRestartPending,
                inputMonitoringSettingsOpen: self.inputMonitoringSettingsVisitInProgress
            )

            if !self.permissionRelaunchScheduled, ready != continueReady {
                continueReady = ready
                continueButton?.isEnabled = ready
            }
            self.updateDockAwayMenuState()
        }

        let refreshTimer = Timer(timeInterval: 0.4, repeats: true) { _ in
            refreshSetupState()
        }
        permissionSetupTimer = refreshTimer
        RunLoop.main.add(refreshTimer, forMode: .common)

        // Keep this window modeless. System Settings needs to be able to quit
        // and reopen DockAway after Input Monitoring changes, and a nested
        // modal application loop can interfere with that lifecycle handoff.
        NSApp.activate(ignoringOtherApps: true)
        setupWindow.center()
        let finalFrame = setupWindow.frame
        preparePermissionSetupEntrance(
            window: setupWindow,
            revealViews: entranceViews
        )
        refreshSetupState()
        setupWindow.makeKeyAndOrderFront(nil)
        animatePermissionSetupEntrance(
            window: setupWindow,
            finalFrame: finalFrame,
            revealViews: entranceViews,
            welcomeEmojiView: welcomeEmojiView
        )
        iconShineView.play(after: 1.08)
    }

    private func makePermissionSetupWindow(
        setupView: PermissionSetupView
    ) -> (
        window: NSPanel,
        continueButton: NSButton,
        entranceViews: [NSView],
        welcomeEmojiView: NSView,
        iconShineView: AppIconShineView
    ) {
        let windowSize = NSSize(width: 540, height: 515)
        let panelCornerRadius: CGFloat = 28
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let contentView = NSView(frame: NSRect(origin: .zero, size: windowSize))
        let backgroundView: NSView
        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView(frame: NSRect(origin: .zero, size: windowSize))
            // The standard glass treatment gives the panel a defined rim and
            // keeps the content behind the window visible.
            glassView.style = .regular
            glassView.tintColor = NSColor.white.withAlphaComponent(0.035)
            glassView.cornerRadius = panelCornerRadius
            glassView.wantsLayer = true
            glassView.layer?.cornerRadius = panelCornerRadius
            glassView.layer?.cornerCurve = .continuous
            glassView.layer?.masksToBounds = true
            glassView.layer?.borderWidth = 1
            glassView.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
            if #available(macOS 27.0, *) {
                glassView.effectIsInteractive = true
            }
            glassView.contentView = contentView
            backgroundView = glassView
        } else {
            let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: windowSize))
            effectView.material = .popover
            effectView.blendingMode = .behindWindow
            effectView.state = .active
            effectView.wantsLayer = true
            effectView.layer?.cornerRadius = panelCornerRadius
            effectView.layer?.cornerCurve = .continuous
            effectView.layer?.masksToBounds = true
            effectView.layer?.borderWidth = 1
            effectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
            contentView.translatesAutoresizingMaskIntoConstraints = false
            effectView.addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
                contentView.topAnchor.constraint(equalTo: effectView.topAnchor),
                contentView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor)
            ])
            backgroundView = effectView
        }
        backgroundView.autoresizingMask = [.width, .height]
        panel.contentView = backgroundView

        let titleLabel = NSTextField(labelWithString: "Welcome to DockAway")
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = .labelColor

        let titleEmojiLabel = NSButton(
            title: "👋🏻",
            target: self,
            action: #selector(highFiveWelcomeHand(_:))
        )
        titleEmojiLabel.font = .systemFont(ofSize: 20)
        titleEmojiLabel.isBordered = false
        titleEmojiLabel.focusRingType = .none
        if let buttonCell = titleEmojiLabel.cell as? NSButtonCell {
            buttonCell.highlightsBy = []
            buttonCell.showsStateBy = []
        }
        titleEmojiLabel.toolTip = "High five!"
        titleEmojiLabel.setAccessibilityLabel("Wave hello to DockAway")
        titleEmojiLabel.setAccessibilityHelp("Gives the DockAway welcome hand a high five.")

        let welcomeEmojiView = NSView()
        welcomeEmojiView.translatesAutoresizingMaskIntoConstraints = false
        welcomeEmojiView.wantsLayer = true

        let titleContainer = NSView()
        titleContainer.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleEmojiLabel.translatesAutoresizingMaskIntoConstraints = false
        welcomeEmojiView.addSubview(titleEmojiLabel)
        titleContainer.addSubview(titleLabel)
        titleContainer.addSubview(welcomeEmojiView)
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: titleContainer.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: titleContainer.centerYAnchor),
            welcomeEmojiView.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            welcomeEmojiView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            welcomeEmojiView.widthAnchor.constraint(equalToConstant: 28),
            welcomeEmojiView.heightAnchor.constraint(equalToConstant: 28),
            welcomeEmojiView.trailingAnchor.constraint(
                lessThanOrEqualTo: titleContainer.trailingAnchor
            ),
            titleEmojiLabel.centerXAnchor.constraint(equalTo: welcomeEmojiView.centerXAnchor),
            titleEmojiLabel.centerYAnchor.constraint(equalTo: welcomeEmojiView.centerYAnchor),
            titleContainer.heightAnchor.constraint(equalToConstant: 28)
        ])

        let appIconImage = NSApp.applicationIconImage
            ?? NSImage(size: NSSize(width: 92, height: 92))
        let iconShineView = AppIconShineView(maskImage: appIconImage)
        iconShineView.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSButton(
            image: appIconImage,
            target: iconShineView,
            action: #selector(AppIconShineView.replay(_:))
        )
        iconView.isBordered = false
        iconView.imagePosition = .imageOnly
        iconView.imageScaling = .scaleProportionallyUpOrDown
        if let buttonCell = iconView.cell as? NSButtonCell {
            buttonCell.highlightsBy = []
            buttonCell.showsStateBy = []
        }
        iconView.setAccessibilityLabel("DockAway app icon")
        iconView.setAccessibilityHelp("Plays the icon shine animation.")
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let iconContainer = NSView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(iconView)
        iconContainer.addSubview(iconShineView)

        titleLabel.alignment = .center
        NSLayoutConstraint.activate([
            iconContainer.heightAnchor.constraint(equalToConstant: 92),
            iconView.widthAnchor.constraint(equalToConstant: 92),
            iconView.heightAnchor.constraint(equalToConstant: 92),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconShineView.leadingAnchor.constraint(equalTo: iconView.leadingAnchor),
            iconShineView.trailingAnchor.constraint(equalTo: iconView.trailingAnchor),
            iconShineView.topAnchor.constraint(equalTo: iconView.topAnchor),
            iconShineView.bottomAnchor.constraint(equalTo: iconView.bottomAnchor)
        ])

        let introductionLabel = NSTextField(
            wrappingLabelWithString: "Let's get started by setting up these two macOS permissions to unlock DockAway's window and gesture detection for a smooth experience."
        )
        introductionLabel.font = .systemFont(ofSize: 13)
        introductionLabel.textColor = .labelColor
        introductionLabel.maximumNumberOfLines = 2
        introductionLabel.alignment = .center

        let permissionHeading = NSTextField(labelWithString: "Please enable the following permissions:")
        permissionHeading.font = .systemFont(ofSize: 13, weight: .medium)
        permissionHeading.textColor = .labelColor

        let launchAtLoginContainer = DockSettingPersistenceRowView(
            title: "Launch DockAway at Login",
            isOn: isLaunchAtLoginEnabled(),
            width: 460,
            leadingInset: 20,
            titleLeadingAdjustment: 8,
            fullRowHitTarget: false
        ) { [weak self] _ in
            self?.toggleLaunchAtLogin()
        }
        launchAtLoginContainer.translatesAutoresizingMaskIntoConstraints = false
        permissionSetupLaunchAtLoginRowView = launchAtLoginContainer

        let quitButton = NSButton(
            title: "Quit",
            target: self,
            action: #selector(cancelPermissionSetup)
        )
        let continueButton = OnboardingPrimaryButton(
            title: "Continue",
            target: self,
            action: #selector(continuePermissionSetup)
        )
        quitButton.bezelStyle = .automatic
        quitButton.controlSize = .large
        quitButton.translatesAutoresizingMaskIntoConstraints = false
        quitButton.widthAnchor.constraint(equalToConstant: 88).isActive = true
        quitButton.keyEquivalent = "\u{1b}"
        if #available(macOS 26.0, *) {
            quitButton.borderShape = .capsule
        }

        continueButton.controlSize = .large
        continueButton.translatesAutoresizingMaskIntoConstraints = false
        continueButton.widthAnchor.constraint(equalToConstant: 88).isActive = true
        continueButton.keyEquivalent = "\r"

        let buttonStack = NSStackView(views: [quitButton, continueButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 10
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let bottomControlsSpacer = NSView()
        bottomControlsSpacer.translatesAutoresizingMaskIntoConstraints = false
        bottomControlsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottomControlsSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bottomControlsRow = NSStackView(
            views: [launchAtLoginContainer, bottomControlsSpacer, buttonStack]
        )
        bottomControlsRow.orientation = .horizontal
        bottomControlsRow.alignment = .centerY
        bottomControlsRow.spacing = 0
        bottomControlsRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bottomControlsRow.heightAnchor.constraint(equalToConstant: 32),
            launchAtLoginContainer.widthAnchor.constraint(equalToConstant: 250),
            launchAtLoginContainer.heightAnchor.constraint(equalToConstant: 26),
            bottomControlsSpacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 14)
        ])

        let contentStack = NSStackView(
            views: [
                iconContainer,
                titleContainer,
                introductionLabel,
                permissionHeading,
                setupView,
                bottomControlsRow
            ]
        )
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 13
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setCustomSpacing(18, after: iconContainer)
        contentStack.setCustomSpacing(16, after: introductionLabel)
        contentStack.setCustomSpacing(14, after: setupView)
        buttonStack.setHuggingPriority(.required, for: .horizontal)

        contentView.addSubview(contentStack)
        setupView.instructionView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(setupView.instructionView)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 34),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -34),
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 30),
            iconContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            titleContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            introductionLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            setupView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            bottomControlsRow.widthAnchor.constraint(
                equalTo: contentStack.widthAnchor,
                constant: -14
            ),
            setupView.instructionView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            setupView.instructionView.centerXAnchor.constraint(equalTo: contentStack.centerXAnchor),
            setupView.instructionView.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor,
                constant: -18
            ),
            contentStack.bottomAnchor.constraint(
                lessThanOrEqualTo: setupView.instructionView.topAnchor,
                constant: -12
            )
        ])

        let entranceViews: [NSView] = [
            iconContainer,
            titleContainer,
            introductionLabel,
            permissionHeading,
            setupView,
            bottomControlsRow,
            setupView.instructionView
        ]
        return (
            panel,
            continueButton,
            entranceViews,
            welcomeEmojiView,
            iconShineView
        )
    }

    private func preparePermissionSetupEntrance(
        window: NSPanel,
        revealViews: [NSView]
    ) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.alphaValue = 0
        if !reduceMotion {
            let finalFrame = window.frame
            let zoomScale: CGFloat = 0.94
            let initialSize = NSSize(
                width: finalFrame.width * zoomScale,
                height: finalFrame.height * zoomScale
            )
            var initialFrame = NSRect(
                x: finalFrame.midX - (initialSize.width / 2),
                y: finalFrame.midY - (initialSize.height / 2),
                width: initialSize.width,
                height: initialSize.height
            )
            initialFrame.origin.y -= 9
            window.setFrame(initialFrame, display: false)
        }

        for view in revealViews {
            view.alphaValue = 0
            guard !reduceMotion else { continue }
            view.wantsLayer = true
            view.layer?.transform = CATransform3DMakeTranslation(0, 12, 0)
        }
    }

    private func animatePermissionSetupEntrance(
        window: NSPanel,
        finalFrame: NSRect,
        revealViews: [NSView],
        welcomeEmojiView: NSView
    ) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let windowAnimationDuration: TimeInterval = reduceMotion ? 0.24 : 0.78

        NSAnimationContext.runAnimationGroup { context in
            context.duration = windowAnimationDuration
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.22,
                0.61,
                0.36,
                1.00
            )
            window.animator().alphaValue = 1
            if !reduceMotion {
                window.animator().setFrame(finalFrame, display: true)
            }
        }

        let firstStageStart: TimeInterval = reduceMotion
            ? 0.04
            : windowAnimationDuration + 0.06
        let firstStageStagger: TimeInterval = reduceMotion ? 0 : 0.09
        let firstStageDuration: TimeInterval = reduceMotion ? 0.20 : 0.72
        let secondStageStart = firstStageStart
            + firstStageStagger
            + firstStageDuration
            + (reduceMotion ? 1.08 : 1.18)
        let thirdStageStart = secondStageStart + 2.0

        for (index, view) in revealViews.enumerated() {
            let delay: TimeInterval
            switch index {
            case 0:
                delay = firstStageStart
            case 1:
                delay = firstStageStart + firstStageStagger
            case 2:
                delay = secondStageStart
            case 3:
                delay = thirdStageStart - 0.25
            default:
                let thirdStageStagger = reduceMotion
                    ? 0
                    : Double(index - 3) * 0.09
                delay = thirdStageStart + thirdStageStagger
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                [weak self, weak window, weak view] in
                guard
                    let self,
                    let window,
                    let view,
                    self.permissionSetupWindow === window
                else { return }

                if !reduceMotion, let layer = view.layer {
                    let slideAnimation = CABasicAnimation(keyPath: "transform")
                    slideAnimation.fromValue = CATransform3DMakeTranslation(0, 12, 0)
                    slideAnimation.toValue = CATransform3DIdentity
                    slideAnimation.duration = 0.72
                    slideAnimation.timingFunction = CAMediaTimingFunction(
                        controlPoints: 0.16,
                        0.84,
                        0.30,
                        1.00
                    )
                    layer.transform = CATransform3DIdentity
                    layer.add(slideAnimation, forKey: "permissionEntranceSlide")
                }

                NSAnimationContext.runAnimationGroup { context in
                    context.duration = reduceMotion ? 0.20 : 0.62
                    context.timingFunction = CAMediaTimingFunction(
                        controlPoints: 0.16,
                        0.84,
                        0.30,
                        1.00
                    )
                    view.animator().alphaValue = 1
                }
            }
        }

        guard !reduceMotion else { return }
        let welcomeWaveDelay = windowAnimationDuration + 0.54
        DispatchQueue.main.asyncAfter(deadline: .now() + welcomeWaveDelay) {
            [weak self, weak window, weak welcomeEmojiView] in
            guard
                let self,
                let window,
                let welcomeEmojiView,
                self.permissionSetupWindow === window
            else { return }
            self.animateWelcomeEmojiWave(welcomeEmojiView)
        }
    }

    private func animateWelcomeEmojiWave(_ emojiView: NSView) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        emojiView.wantsLayer = true
        emojiView.layoutSubtreeIfNeeded()
        guard let layer = emojiView.layer else { return }

        let wristAnchor = CGPoint(x: 0.46, y: -0.12)
        let oldAnchor = layer.anchorPoint
        let oldPosition = layer.position
        layer.anchorPoint = wristAnchor
        layer.position = CGPoint(
            x: oldPosition.x + ((wristAnchor.x - oldAnchor.x) * layer.bounds.width),
            y: oldPosition.y + ((wristAnchor.y - oldAnchor.y) * layer.bounds.height)
        )

        func cartoonHandTransform(
            rotation: CGFloat,
            horizontalScale: CGFloat,
            shear: CGFloat
        ) -> CATransform3D {
            var transform = CGAffineTransform(rotationAngle: rotation)
            transform = transform.concatenating(
                CGAffineTransform(
                    a: horizontalScale,
                    b: shear * 0.28,
                    c: shear,
                    d: 1,
                    tx: 0,
                    ty: 0
                )
            )
            return CATransform3DMakeAffineTransform(transform)
        }

        let wave = CAKeyframeAnimation(keyPath: "transform")
        wave.values = [
            cartoonHandTransform(rotation: 0, horizontalScale: 1, shear: 0),
            cartoonHandTransform(rotation: -0.07, horizontalScale: 0.99, shear: -0.018),
            cartoonHandTransform(rotation: 0.105, horizontalScale: 1.014, shear: 0.026),
            cartoonHandTransform(rotation: -0.082, horizontalScale: 0.992, shear: -0.021),
            cartoonHandTransform(rotation: 0.06, horizontalScale: 1.008, shear: 0.016),
            cartoonHandTransform(rotation: -0.032, horizontalScale: 0.996, shear: -0.009),
            cartoonHandTransform(rotation: 0.012, horizontalScale: 1.002, shear: 0.004),
            cartoonHandTransform(rotation: 0, horizontalScale: 1, shear: 0),
            cartoonHandTransform(rotation: 0, horizontalScale: 1, shear: 0)
        ]
        wave.keyTimes = [0, 0.035, 0.07, 0.105, 0.14, 0.175, 0.21, 0.235, 1]
        wave.timingFunctions = (0..<8).map { _ in
            CAMediaTimingFunction(name: .easeInEaseOut)
        }
        wave.duration = 10
        wave.repeatCount = .infinity
        wave.calculationMode = .cubic
        wave.isRemovedOnCompletion = true
        layer.add(wave, forKey: "welcomeWave")
    }

    @objc private func highFiveWelcomeHand(_ sender: NSButton) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        sender.wantsLayer = true
        guard let layer = sender.layer else { return }

        let highFive = CAKeyframeAnimation(keyPath: "transform.scale")
        highFive.values = [1, 1.28, 0.97, 1.035, 1]
        highFive.keyTimes = [0, 0.30, 0.58, 0.80, 1]
        highFive.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        highFive.duration = 0.56
        highFive.calculationMode = .cubic

        layer.removeAnimation(forKey: "welcomeHighFive")
        layer.add(highFive, forKey: "welcomeHighFive")
    }

    @objc private func continuePermissionSetup() {
        guard
            AXIsProcessTrusted(),
            inputMonitoringAccessGranted || inputMonitoringRestartPending
        else { return }

        dismissPermissionSetup()
        UserDefaults.standard.set(
            true,
            forKey: Self.showStartedPopoverAfterRelaunchKey
        )
        completePermissionSetup(allowStartedPopover: false)
        scheduleRelaunchAfterPermissionSetup()
    }

    @objc private func cancelPermissionSetup() {
        dismissPermissionSetup()
        NSApp.terminate(self)
    }

    private func dismissPermissionSetup() {
        permissionSetupTimer?.invalidate()
        permissionSetupTimer = nil
        permissionSetupWindow?.orderOut(nil)
        permissionSetupWindow = nil
        permissionSetupContinueButton = nil
        permissionSetupLaunchAtLoginRowView = nil
        permissionSetupInProgress = false
    }

    private func scheduleRelaunchAfterPermissionSetup() {
        guard !permissionRelaunchScheduled, !isQuitting else { return }
        permissionRelaunchScheduled = true

        // Give the setup window a brief moment to dismiss before the new
        // process takes over, keeping the restart quiet and intentional.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            guard let self, !self.isQuitting else { return }

            self.isPermissionRelaunching = true
            do {
                try self.launchRelaunchHelper()
                NSApp.terminate(nil)
            } catch {
                self.isPermissionRelaunching = false
                self.permissionRelaunchScheduled = false
                UserDefaults.standard.set(
                    false,
                    forKey: Self.showStartedPopoverAfterRelaunchKey
                )
                self.showDockAwayStartedPopover()
                dockAwayDebugLog("⚠️ Could not prepare DockAway relaunch after permission setup: \(error)")
            }
        }
    }

    private func launchRelaunchHelper() throws {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            """
            old_pid="$1"
            app_path="$2"
            while /bin/kill -0 "$old_pid" 2>/dev/null; do
                /bin/sleep 0.1
            done
            exec /usr/bin/open -n "$app_path"
            """,
            "DockAway-permission-relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundlePath
        ]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
    }

    private func completePermissionSetup(allowStartedPopover: Bool = true) {
        let defaults = UserDefaults.standard
        let isFirstCompletedSetup = !defaults.bool(
            forKey: Self.permissionSetupCompletedKey
        )
        let shouldShowAfterRelaunch = defaults.bool(
            forKey: Self.showStartedPopoverAfterRelaunchKey
        )
        let shouldShowStartedPopover = allowStartedPopover
            && (isFirstCompletedSetup || shouldShowAfterRelaunch)
        defaults.set(true, forKey: Self.permissionSetupCompletedKey)
        if shouldShowStartedPopover {
            defaults.set(false, forKey: Self.showStartedPopoverAfterRelaunchKey)
        }
        accessibilityPermissionMissing = false
        inputMonitoringPermissionMissing = false
        isWaitingForAccessibility = false
        accessibilityWaitWorkItem?.cancel()
        accessibilityWaitWorkItem = nil
        inputMonitoringWaitWorkItem?.cancel()
        inputMonitoringWaitWorkItem = nil

        if dockWatcher == nil {
            dockWatcher = DockWatcher()
        }
        startMonitoringIfAllowed()
        ensureDockAwayIsOn()
        updateDockAwayMenuState()

        if shouldShowStartedPopover {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
                self?.showDockAwayStartedPopover()
            }
        }
    }

    private func showDockAwayStartedPopover() {
        showMenuBarPopover(
            symbolName: "checkmark.circle.fill",
            symbolDescription: "DockAway started",
            symbolColor: .systemGreen,
            title: "DockAway has successfully started",
            detail: "You can manage it from the menu bar.",
            contentSize: NSSize(width: 275, height: 60),
            celebrationEmoji: "🎉"
        )
    }

    private func showPermissionRevokedPopover() {
        guard
            !permissionSetupInProgress,
            !permissionRelaunchScheduled,
            UserDefaults.standard.bool(forKey: Self.permissionSetupCompletedKey)
        else { return }

        let title: String
        let detail: String
        if accessibilityPermissionMissing && inputMonitoringPermissionMissing {
            title = "DockAway permissions were revoked"
            detail = "Restore Accessibility and Input Monitoring from the menu bar."
        } else if accessibilityPermissionMissing {
            title = "Accessibility permission was revoked"
            detail = "DockAway is paused. Click the menubar icon and press the resume button to restore access."
        } else if inputMonitoringPermissionMissing {
            title = "Input Monitoring permission was revoked"
            detail = "Gesture detection is paused. Click the menu bar icon to restore access."
        } else {
            return
        }

        showMenuBarPopover(
            symbolName: "exclamationmark.triangle.fill",
            symbolDescription: "DockAway permission required",
            symbolColor: .systemOrange,
            title: title,
            detail: detail,
            contentSize: NSSize(width: 325, height: 76)
        )
    }

    private func showMenuBarPopover(
        symbolName: String,
        symbolDescription: String,
        symbolColor: NSColor,
        title: String,
        detail: String,
        contentSize: NSSize,
        celebrationEmoji: String? = nil
    ) {
        guard let statusButton = statusItem?.button else { return }

        startedPopoverCloseWorkItem?.cancel()
        startedPopover?.close()
        closeStartedPopoverConfetti()

        let statusImage = NSImageView()
        statusImage.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: symbolDescription
        )
        statusImage.contentTintColor = symbolColor
        statusImage.imageScaling = .scaleProportionallyDown
        statusImage.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusImage.widthAnchor.constraint(equalToConstant: 28),
            statusImage.heightAnchor.constraint(equalToConstant: 28)
        ])

        let titleLabel = celebrationEmoji == nil
            ? NSTextField(wrappingLabelWithString: title)
            : NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = celebrationEmoji == nil ? 2 : 1
        if celebrationEmoji != nil {
            titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let titleView: NSView
        let celebrationButton: NSButton?
        if let celebrationEmoji {
            let emojiButton = NSButton(
                title: celebrationEmoji,
                target: self,
                action: #selector(replayStartedPopoverConfetti(_:))
            )
            emojiButton.font = .systemFont(ofSize: 14)
            emojiButton.isBordered = false
            emojiButton.focusRingType = .none
            emojiButton.toolTip = "Celebrate again"
            emojiButton.setAccessibilityLabel("Celebrate again")
            emojiButton.setContentHuggingPriority(.required, for: .horizontal)

            let titleStack = NSStackView(views: [titleLabel, emojiButton])
            titleStack.orientation = .horizontal
            titleStack.alignment = .firstBaseline
            titleStack.spacing = 3
            titleView = titleStack
            celebrationButton = emojiButton
        } else {
            titleView = titleLabel
            celebrationButton = nil
        }

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2

        let textStack = NSStackView(views: [titleView, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3

        let stack = NSStackView(views: [statusImage, textStack])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView(frame: NSRect(origin: .zero, size: contentSize))
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])

        let viewController = NSViewController()
        viewController.view = contentView

        let popover = NSPopover()
        popover.animates = true
        popover.behavior = .applicationDefined
        popover.contentSize = contentView.frame.size
        popover.contentViewController = viewController
        popover.show(
            relativeTo: statusButton.bounds,
            of: statusButton,
            preferredEdge: .minY
        )
        startedPopover = popover
        startedPopoverContentView = contentView
        startedPopoverCelebrationButton = celebrationButton
        monitorStartedPopoverDismissal()

        if let celebrationButton {
            DispatchQueue.main.async { [weak self, weak celebrationButton, weak contentView, weak popover] in
                guard
                    let self,
                    let celebrationButton,
                    let contentView,
                    let popover,
                    self.startedPopover === popover
                else { return }
                contentView.layoutSubtreeIfNeeded()
                self.animatePopoverConfetti(
                    from: celebrationButton,
                    in: contentView
                )
            }
        }
    }

    @objc private func replayStartedPopoverConfetti(_ sender: NSButton) {
        guard
            sender === startedPopoverCelebrationButton,
            let contentView = startedPopoverContentView,
            startedPopover != nil
        else { return }

        animatePopoverConfetti(from: sender, in: contentView)
    }

    private func animatePopoverConfetti(from emojiLabel: NSView, in contentView: NSView) {
        guard
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            let popoverWindow = contentView.window
        else { return }

        let emojiFrameInWindow = emojiLabel.convert(emojiLabel.bounds, to: nil)
        let emojiFrameOnScreen = popoverWindow.convertToScreen(emojiFrameInWindow)
        let emitterPoint = CGPoint(
            x: emojiFrameOnScreen.midX,
            y: emojiFrameOnScreen.midY
        )
        let overlaySize = NSSize(width: 250, height: 230)
        var overlayFrame = NSRect(
            x: emitterPoint.x - 34,
            y: emitterPoint.y - 112,
            width: overlaySize.width,
            height: overlaySize.height
        )
        if let screenFrame = popoverWindow.screen?.frame {
            overlayFrame.origin.x = min(
                max(overlayFrame.minX, screenFrame.minX),
                screenFrame.maxX - overlayFrame.width
            )
            overlayFrame.origin.y = min(
                max(overlayFrame.minY, screenFrame.minY),
                screenFrame.maxY - overlayFrame.height
            )
        }

        let overlayView = NSView(frame: NSRect(origin: .zero, size: overlaySize))
        overlayView.wantsLayer = true
        overlayView.layer?.backgroundColor = NSColor.clear.cgColor
        overlayView.layer?.masksToBounds = true

        let overlayWindow = NSPanel(
            contentRect: overlayFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        overlayWindow.isOpaque = false
        overlayWindow.backgroundColor = .clear
        overlayWindow.hasShadow = false
        overlayWindow.ignoresMouseEvents = true
        overlayWindow.isReleasedWhenClosed = false
        overlayWindow.isFloatingPanel = true
        overlayWindow.hidesOnDeactivate = false
        overlayWindow.animationBehavior = .none
        overlayWindow.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
        overlayWindow.level = NSWindow.Level(
            rawValue: popoverWindow.level.rawValue + 1
        )
        overlayWindow.contentView = overlayView
        overlayWindow.orderFrontRegardless()
        startedPopoverConfettiWindows.append(overlayWindow)

        let origin = CGPoint(
            x: emitterPoint.x - overlayFrame.minX,
            y: emitterPoint.y - overlayFrame.minY
        )
        let colors: [NSColor] = [
            .systemPink,
            .systemYellow,
            .systemBlue,
            .systemGreen,
            .systemPurple,
            .systemOrange
        ]
        let animationStart = CACurrentMediaTime() + 0.08

        func cubicPoint(
            from start: CGPoint,
            control1: CGPoint,
            control2: CGPoint,
            to end: CGPoint,
            progress: CGFloat
        ) -> CGPoint {
            let inverse = 1 - progress
            let startWeight = inverse * inverse * inverse
            let firstControlWeight = 3 * inverse * inverse * progress
            let secondControlWeight = 3 * inverse * progress * progress
            let endWeight = progress * progress * progress
            return CGPoint(
                x: start.x * startWeight
                    + control1.x * firstControlWeight
                    + control2.x * secondControlWeight
                    + end.x * endWeight,
                y: start.y * startWeight
                    + control1.y * firstControlWeight
                    + control2.y * secondControlWeight
                    + end.y * endWeight
            )
        }

        let particleCount = 22
        for index in 0..<particleCount {
            let particle = CALayer()
            let particleSize: CGSize
            switch index % 3 {
            case 0:
                let diameter = CGFloat.random(in: 3.0...4.5)
                particleSize = CGSize(width: diameter, height: diameter)
            case 1:
                particleSize = CGSize(
                    width: CGFloat.random(in: 2.5...3.8),
                    height: CGFloat.random(in: 6.0...8.0)
                )
            default:
                particleSize = CGSize(
                    width: CGFloat.random(in: 3.0...4.5),
                    height: CGFloat.random(in: 5.0...7.0)
                )
            }
            particle.bounds = CGRect(origin: .zero, size: particleSize)
            particle.position = origin
            particle.backgroundColor = colors[index % colors.count].cgColor
            particle.cornerRadius = index % 3 == 0
                ? particleSize.width / 2
                : min(particleSize.width, particleSize.height) * 0.34
            overlayView.layer?.addSublayer(particle)

            let fanPosition = CGFloat(index) / CGFloat(particleCount - 1)
            let launchAngleDegrees = 18
                + (56 * fanPosition)
                + CGFloat.random(in: -3.5...3.5)
            let launchAngle = launchAngleDegrees * .pi / 180
            let launchDistance = CGFloat.random(in: 66...104)
            let apexOffset = CGPoint(
                x: cos(launchAngle) * launchDistance,
                y: min(sin(launchAngle) * launchDistance, 78)
            )
            let fallHorizontalTravel = CGFloat.random(in: 18...44)
            let fallDistance = CGFloat.random(in: 68...106)
            let apex = CGPoint(
                x: origin.x + apexOffset.x,
                y: origin.y + apexOffset.y
            )
            let landing = CGPoint(
                x: apex.x + fallHorizontalTravel,
                y: apex.y - fallDistance
            )

            let apexTime: CGFloat = 0.46
            let horizontalApexVelocity = CGFloat.random(in: 72...92)
            let launchControl = CGPoint(
                x: origin.x + apexOffset.x * 0.36,
                y: origin.y + apexOffset.y * 0.46
            )
            let ascentControl = CGPoint(
                x: apex.x - horizontalApexVelocity * apexTime / 3,
                y: apex.y
            )
            let descentControl = CGPoint(
                x: apex.x + horizontalApexVelocity * (1 - apexTime) / 3,
                y: apex.y
            )
            let landingControl = CGPoint(
                x: landing.x - fallHorizontalTravel * 0.42,
                y: landing.y + fallDistance * 0.42
            )

            let sampleCount = 72
            let positionValues: [NSValue] = (0...sampleCount).map { sample in
                let progress = CGFloat(sample) / CGFloat(sampleCount)
                let point: CGPoint
                if progress <= apexTime {
                    point = cubicPoint(
                        from: origin,
                        control1: launchControl,
                        control2: ascentControl,
                        to: apex,
                        progress: progress / apexTime
                    )
                } else {
                    point = cubicPoint(
                        from: apex,
                        control1: descentControl,
                        control2: landingControl,
                        to: landing,
                        progress: (progress - apexTime) / (1 - apexTime)
                    )
                }
                return NSValue(point: point)
            }

            let position = CAKeyframeAnimation(keyPath: "position")
            position.values = positionValues
            position.calculationMode = .linear

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, 1, 1, 0]
            opacity.keyTimes = [0, 0.10, 0.76, 1]

            let rotation = CABasicAnimation(keyPath: "transform.rotation")
            rotation.fromValue = 0
            rotation.toValue = CGFloat.random(in: -2.5...2.5) * .pi

            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.72, 1, 0.92]
            scale.keyTimes = [0, 0.28, 1]

            let group = CAAnimationGroup()
            group.animations = [position, opacity, rotation, scale]
            group.duration = Double.random(in: 1.95...2.30)
            group.beginTime = animationStart
                + Double(index % 6) * 0.06
                + Double(index / 6) * 0.13
            group.fillMode = .backwards
            particle.opacity = 0
            particle.add(group, forKey: "popoverConfetti")
        }

        emojiLabel.wantsLayer = true
        let emojiPop = CAKeyframeAnimation(keyPath: "transform.scale")
        emojiPop.values = [1, 1.18, 0.96, 1]
        emojiPop.keyTimes = [0, 0.34, 0.68, 1]
        emojiPop.duration = 0.72
        emojiPop.beginTime = animationStart
        emojiPop.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        emojiLabel.layer?.add(emojiPop, forKey: "celebrationPop")

        let closeWorkItem = DispatchWorkItem { [weak self, weak overlayWindow] in
            guard let self, let overlayWindow else { return }
            overlayWindow.orderOut(nil)
            self.startedPopoverConfettiWindows.removeAll { $0 === overlayWindow }
        }
        startedPopoverConfettiCloseWorkItems.append(closeWorkItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.35, execute: closeWorkItem)
    }

    private func closeStartedPopoverConfetti() {
        startedPopoverConfettiCloseWorkItems.forEach { $0.cancel() }
        startedPopoverConfettiCloseWorkItems.removeAll()
        startedPopoverConfettiWindows.forEach { $0.orderOut(nil) }
        startedPopoverConfettiWindows.removeAll()
    }

    private func monitorStartedPopoverDismissal() {
        removeStartedPopoverEventMonitors()

        let mouseEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]
        startedPopoverLocalEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: mouseEvents
        ) { [weak self] event in
            if self?.startedPopoverCelebrationButtonContainsMouse() == true {
                return event
            }
            // Close before returning the event so a status-item click still
            // reaches the DockAway menu instead of being consumed.
            let statusItemWasClicked = self?.statusItemContainsMouse() == true
            self?.closeStartedPopover()
            if statusItemWasClicked {
                self?.reopenStatusMenuAfterPopoverClick()
            }
            return event
        }
        startedPopoverGlobalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: mouseEvents
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let statusItemWasClicked = self.statusItemContainsMouse()
                let shouldReopenMenu = self.startedPopover != nil && statusItemWasClicked
                self.closeStartedPopover()
                if shouldReopenMenu {
                    self.reopenStatusMenuAfterPopoverClick()
                }
            }
        }
    }

    private func statusItemContainsMouse() -> Bool {
        guard
            let button = statusItem?.button,
            let window = button.window
        else { return false }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = window.convertToScreen(buttonFrameInWindow)
        return buttonFrameOnScreen.contains(NSEvent.mouseLocation)
    }

    private func startedPopoverCelebrationButtonContainsMouse() -> Bool {
        guard
            let button = startedPopoverCelebrationButton,
            let window = button.window
        else { return false }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = window.convertToScreen(buttonFrameInWindow)
        return buttonFrameOnScreen.contains(NSEvent.mouseLocation)
    }

    private func reopenStatusMenuAfterPopoverClick() {
        DispatchQueue.main.async { [weak self] in
            guard
                let self,
                self.statusItem?.menu != nil,
                let button = self.statusItem?.button
            else { return }

            // The popover normally consumes the status-item click while it is
            // visible. Re-present the native status menu for that same click.
            button.performClick(nil)
        }
    }

    private func removeStartedPopoverEventMonitors() {
        if let monitor = startedPopoverLocalEventMonitor {
            NSEvent.removeMonitor(monitor)
            startedPopoverLocalEventMonitor = nil
        }
        if let monitor = startedPopoverGlobalEventMonitor {
            NSEvent.removeMonitor(monitor)
            startedPopoverGlobalEventMonitor = nil
        }
    }

    private func closeStartedPopover() {
        startedPopoverCloseWorkItem?.cancel()
        startedPopoverCloseWorkItem = nil
        removeStartedPopoverEventMonitors()
        closeStartedPopoverConfetti()
        startedPopover?.close()
        startedPopover = nil
        startedPopoverContentView = nil
        startedPopoverCelebrationButton = nil
    }

    // MARK: - Accessibility

    private func startPermissionHealthMonitoring() {
        permissionHealthTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard
                let self,
                !self.isQuitting,
                !self.permissionSetupInProgress,
                !self.permissionRelaunchScheduled
            else { return }

            if !AXIsProcessTrusted(), !self.accessibilityPermissionMissing {
                self.accessibilityPermissionWasRevoked()
            }

            let inputMonitoringShouldBeMissing = !self.inputMonitoringAccessGranted
            if inputMonitoringShouldBeMissing != self.inputMonitoringPermissionMissing {
                self.refreshInputMonitoringPermission()
            }
        }
        permissionHealthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
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
                if self.permissionSetupInProgress {
                    self.refreshInputMonitoringPermission()
                    self.updateDockAwayMenuState()
                    return
                }
                if self.dockWatcher == nil {
                    self.dockWatcher = DockWatcher()
                }
                self.startMonitoringIfAllowed()
                self.ensureDockAwayIsOn()
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
            self.showPermissionRevokedPopover()
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
        let permissionWasMissing = inputMonitoringPermissionMissing
        let permissionIsGranted = inputMonitoringAccessGranted
        inputMonitoringPermissionMissing = !permissionIsGranted

        if permissionIsGranted {
            resetInputMonitoringSettingsVisit()
            inputMonitoringWaitWorkItem?.cancel()
            inputMonitoringWaitWorkItem = nil
            stopInputMonitoringRegistrationAttempt()
            startMultitouchPreHide()
        } else {
            fourFingersDown = false
            fourFingerStartedInMissionControl = false
            multitouch.stop()
        }

        updateDockAwayMenuState()
        if !permissionIsGranted, !permissionWasMissing {
            showPermissionRevokedPopover()
        }
        return permissionIsGranted
    }

    private func refreshInputMonitoringSettingsVisit() {
        guard inputMonitoringSettingsVisitInProgress else { return }

        if inputMonitoringAccessGranted {
            inputMonitoringRestartPending = false
            return
        }

        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let systemSettingsIsFrontmost = frontmostBundleIdentifier == "com.apple.systempreferences"
            || frontmostBundleIdentifier == "com.apple.SystemSettings"

        if systemSettingsIsFrontmost {
            inputMonitoringSettingsWasFrontmost = true
        }

        guard inputMonitoringSettingsWasFrontmost else { return }
        runInputMonitoringPermissionProbeIfNeeded()
    }

    private func runInputMonitoringPermissionProbeIfNeeded() {
        guard
            inputMonitoringPermissionProbe == nil,
            Date().timeIntervalSince(inputMonitoringPermissionProbeLastRun) >= 0.5,
            let executableURL = Bundle.main.executableURL
        else { return }

        inputMonitoringPermissionProbeLastRun = Date()
        let probe = Process()
        probe.executableURL = executableURL
        probe.arguments = ["--dockaway-input-monitoring-probe"]
        probe.standardInput = FileHandle.nullDevice
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        probe.terminationHandler = { [weak self, weak probe] finishedProbe in
            DispatchQueue.main.async {
                guard let self else { return }
                if let probe, self.inputMonitoringPermissionProbe === probe {
                    self.inputMonitoringPermissionProbe = nil
                }
                guard self.inputMonitoringSettingsVisitInProgress else { return }

                // The current process remains denied until it restarts, while
                // each fresh copy sees the permission state macOS has recorded
                // right now. Keep probing throughout onboarding so turning the
                // switch back off immediately clears the pending grant.
                self.inputMonitoringRestartPending =
                    finishedProbe.terminationReason == .exit
                    && finishedProbe.terminationStatus == EXIT_SUCCESS
            }
        }

        inputMonitoringPermissionProbe = probe
        do {
            try probe.run()
        } catch {
            inputMonitoringPermissionProbe = nil
            dockAwayDebugLog("⚠️ Could not run Input Monitoring permission probe: \(error)")
        }
    }

    private func resetInputMonitoringSettingsVisit() {
        inputMonitoringSettingsVisitInProgress = false
        inputMonitoringSettingsWasFrontmost = false
        inputMonitoringRestartPending = false
    }

    private func startInputMonitoringRegistrationAttempt() {
        guard inputMonitoringRegistrationManager == nil else { return }

        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        inputMonitoringRegistrationManager = manager

        // Opening a manager is the actual protected listen operation. Apple's
        // IOHID contract requests access on the process's behalf here, which
        // gives TCC a concrete DockAway client to add to Input Monitoring.
        _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func stopInputMonitoringRegistrationAttempt() {
        guard let manager = inputMonitoringRegistrationManager else { return }
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        _ = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        inputMonitoringRegistrationManager = nil
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
        // Open the native privacy pane directly. Calling IOHIDRequestAccess or
        // opening an IOHID manager here triggers an additional protected-device
        // consent dialog that is unnecessary because onboarding already explains
        // how to enable Input Monitoring in System Settings.
        inputMonitoringSettingsVisitInProgress = true
        inputMonitoringSettingsWasFrontmost = false
        inputMonitoringRestartPending = false
        updateDockAwayMenuState()
        if let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ) {
            NSWorkspace.shared.open(settingsURL)
        }
        waitForInputMonitoringPermission()
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
        closeStartedPopover()
        permissionHealthTimer?.invalidate()
        permissionHealthTimer = nil
        accessibilityWaitWorkItem?.cancel()
        inputMonitoringWaitWorkItem?.cancel()
        stopInputMonitoringRegistrationAttempt()
        dockWatcher?.stop()
        multitouch.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        if !isPermissionRelaunching {
            restoreDockState()
            restoreDefaultDockPreferencesBeforeExitIfNeeded()
        }
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
            closeStartedPopover()
            // The menu opening is an event-driven opportunity to reflect a
            // manual Dock shortcut or a permission changed in System Settings.
            applyStatusIcon(dockVisible: isDockCurrentlyVisible())
            refreshInputMonitoringPermission()
            refreshDockSettingsMenu()
            refreshUpdateFrequencyMenu()
        }
    }
}
