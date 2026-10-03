import Cocoa
import IOKit.hid
import IOKit.hidsystem
import OSLog
import QuartzCore
import ServiceManagement
import Sparkle
import UniformTypeIdentifiers

// Debug builds keep the transition trace that makes Dock behavior easy to
// tune in Xcode, and mirror it to the unified log so it survives launches
// outside Xcode (`log show --predicate 'subsystem == "AK.DockAway"'`).
// Release builds compile the calls down to no-ops, including their
// interpolated-string work, so users do not pay for console logging.
@inline(__always)
func dockAwayDebugLog(_ message: @autoclosure () -> String) {
#if DEBUG
    let text = message()
    print(text)
    Logger(subsystem: "AK.DockAway", category: "Debug").notice("\(text, privacy: .public)")
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
        NSSize(width: 18, height: 18)
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

/// A circular button that brightens under the pointer, like the circular
/// controls in Control Center. Menus do not give buttons hover feedback, so
/// the button tracks the pointer itself and fades in a system fill.
private final class HoverHighlightButton: NSButton {
    var onHoverChange: ((Bool) -> Void)?
    private(set) var isHovered = false
    private var hoverArea: NSTrackingArea?
    private let hoverLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        hoverLayer.opacity = 0
        layer?.addSublayer(hoverLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Keep the fill above any bezel layers AppKit adds during layout.
        if layer?.sublayers?.last !== hoverLayer {
            layer?.addSublayer(hoverLayer)
        }
        hoverLayer.frame = bounds
        hoverLayer.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.commit()
        updateHoverColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHoverColor()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        hoverArea = area
        addTrackingArea(area)
        let pointerInside = window.map {
            bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil))
        } ?? false
        setHovered(pointerInside, animated: false)
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false, animated: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Reopening the menu must not show a stale hover from last time.
        setHovered(false, animated: false)
    }

    private func setHovered(_ hovered: Bool, animated: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        CATransaction.begin()
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            CATransaction.setAnimationDuration(0.15)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        hoverLayer.opacity = hovered ? 1 : 0
        CATransaction.commit()
        onHoverChange?(hovered)
    }

    private func updateHoverColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            hoverLayer.backgroundColor = NSColor.secondarySystemFill.cgColor
        }
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
    private let desktopLabel = NSTextField(labelWithString: "")
    private let titleRow = NSStackView()
    private let detailStack = NSStackView()
    private let labelStack = NSStackView()
    /// Inset for detail & desktop labels to align under the pulsing status dot.
    /// statusDot is 18 pt wide with its 5 pt dot centered at midX (9 pt), so the circle's
    /// leading edge begins at 6.5 pt. Setting an inset of 6.5 pt aligns the text flush under the dot.
    private static let detailLeadingInset: CGFloat = 6.5
    private let permissionAttentionView = PermissionAttentionRingView(frame: .zero)
    private let pauseResumeImageView = NonHitTestingImageView()
    private var displayedActiveState: Bool?
    private var displayedWarning = false
    let pauseResumeButton = HoverHighlightButton()

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

        desktopLabel.font = .systemFont(ofSize: 9.5, weight: .regular)
        desktopLabel.textColor = .secondaryLabelColor
        desktopLabel.lineBreakMode = .byTruncatingTail

        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 2
        titleRow.addArrangedSubview(statusDot)
        titleRow.addArrangedSubview(titleLabel)

        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 1
        detailStack.edgeInsets = NSEdgeInsets(top: 0, left: Self.detailLeadingInset, bottom: 0, right: 0)
        detailStack.addArrangedSubview(detailLabel)
        detailStack.addArrangedSubview(desktopLabel)

        labelStack.translatesAutoresizingMaskIntoConstraints = false
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 1
        labelStack.addArrangedSubview(titleRow)
        labelStack.addArrangedSubview(detailStack)

        pauseResumeButton.translatesAutoresizingMaskIntoConstraints = false
        pauseResumeButton.title = ""
        pauseResumeButton.imagePosition = .imageOnly
        pauseResumeButton.imageScaling = .scaleProportionallyDown
        pauseResumeButton.bezelStyle = .circular
        pauseResumeButton.setButtonType(.momentaryPushIn)
        pauseResumeButton.onHoverChange = { [weak self] _ in
            self?.updatePauseResumeTint()
        }

        pauseResumeImageView.translatesAutoresizingMaskIntoConstraints = false
        pauseResumeImageView.imageScaling = .scaleProportionallyDown
        permissionAttentionView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(labelStack)
        contentView.addSubview(permissionAttentionView)
        contentView.addSubview(pauseResumeButton)
        contentView.addSubview(pauseResumeImageView)

        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 18),
            statusDot.heightAnchor.constraint(equalToConstant: 18),

            labelStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 11),
            labelStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            labelStack.trailingAnchor.constraint(lessThanOrEqualTo: pauseResumeButton.leadingAnchor, constant: -6),

            titleRow.trailingAnchor.constraint(lessThanOrEqualTo: labelStack.trailingAnchor),
            detailStack.trailingAnchor.constraint(lessThanOrEqualTo: labelStack.trailingAnchor),

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
        desktopStatus: String? = nil,
        inactiveTitle: String = "DockAway: Paused",
        inactiveDetail: String = "App detection paused",
        inactiveActionTitle: String = "Resume DockAway",
        warning: Bool = false,
        warningTitle: String = "No Multitouch Support:",
        warningDetail: String = "4-finger gestures off",
        warningActionTitle: String = "Retry Gesture Support"
    ) {
        let title = warning
            ? warningTitle
            : active ? "DockAway: Active" : inactiveTitle
        let desktop = (active && !warning) ? (desktopStatus ?? "") : ""
        let isOnDesktop = status == "Desktop"

        let detail: String
        if warning {
            detail = warningDetail
        } else if !active {
            detail = inactiveDetail
        } else if isOnDesktop {
            detail = !desktop.isEmpty ? desktop : "Desktop:"
        } else {
            detail = "App: \(status)"
        }

        let showDesktop = !isOnDesktop && !desktop.isEmpty
        let desktopText = showDesktop ? desktop : ""

        let permissionRequired = !active
            && !warning
            && inactiveTitle == "Permission Required"

        permissionAttentionView.setEmitting(permissionRequired)

        desktopLabel.stringValue = desktopText
        desktopLabel.isHidden = !showDesktop

        guard displayedActiveState != active
            || titleLabel.stringValue != title
            || detailLabel.stringValue != detail
            || desktopLabel.stringValue != desktopText
            || desktopLabel.isHidden != !showDesktop
        else { return }

        displayedActiveState = active
        statusDot.setWarning(warning, active: active)
        titleLabel.stringValue = title
        titleLabel.textColor = active || warning || inactiveTitle == "Permission Required"
            ? .labelColor
            : .secondaryLabelColor
        detailLabel.stringValue = detail

        let actionTitle = warning
            ? warningActionTitle
            : active ? "Pause DockAway" : inactiveActionTitle
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
        displayedWarning = warning
        updatePauseResumeTint()
        pauseResumeButton.toolTip = actionTitle
        pauseResumeButton.setAccessibilityLabel(pauseResumeButton.toolTip ?? "Toggle DockAway")
    }

    /// The pause glyph rests at secondary emphasis and rises to full emphasis
    /// under the pointer. The resume glyph stays green in both states.
    private func updatePauseResumeTint() {
        let showsPause = displayedActiveState == true && !displayedWarning
        pauseResumeImageView.contentTintColor = showsPause
            ? (pauseResumeButton.isHovered ? .labelColor : .secondaryLabelColor)
            : .systemGreen
    }
}

private final class DockSliderTrackAccentView: NSView {
    override var isFlipped: Bool { true }
    weak var slider: DockSettingSlider?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let slider, let sliderCell = slider.cell as? NSSliderCell else { return }
        let trackRect = sliderCell.barRect(flipped: slider.isFlipped)
        let knobRect = sliderCell.knobRect(flipped: slider.isFlipped)

        let fillWidth: CGFloat
        if slider.doubleValue <= slider.minValue {
            fillWidth = 0
        } else if slider.doubleValue >= slider.maxValue {
            fillWidth = trackRect.width
        } else {
            fillWidth = max(0, knobRect.midX - trackRect.minX)
        }

        if fillWidth > 0 {
            let fillRect = NSRect(x: trackRect.minX, y: trackRect.minY, width: fillWidth, height: trackRect.height)
            let radius = trackRect.height / 2
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let baseColor = slider.isEnabled
                ? NSColor.systemBlue
                : NSColor.systemBlue.withAlphaComponent(0.4)

            let accentColor: NSColor
            if let rgb = baseColor.usingColorSpace(.deviceRGB) {
                if isDark {
                    let alpha: CGFloat = 0.14
                    let r = max(0, min(1, (rgb.redComponent - alpha) / (1 - alpha)))
                    let g = max(0, min(1, (rgb.greenComponent - alpha) / (1 - alpha)))
                    let b = max(0, min(1, (rgb.blueComponent - alpha) / (1 - alpha)))
                    accentColor = NSColor(deviceRed: r, green: g, blue: b, alpha: rgb.alphaComponent)
                } else {
                    let alpha: CGFloat = 0.14
                    let r = max(0, min(1, rgb.redComponent / (1 - alpha)))
                    let g = max(0, min(1, rgb.greenComponent / (1 - alpha)))
                    let b = max(0, min(1, rgb.blueComponent / (1 - alpha)))
                    accentColor = NSColor(deviceRed: r, green: g, blue: b, alpha: rgb.alphaComponent)
                }
            } else {
                accentColor = baseColor
            }

            accentColor.setFill()
            fillPath.fill()
        }

        let knobTravelStart = trackRect.minX + sliderCell.knobThickness / 2
        let knobTravelWidth = max(0, trackRect.width - sliderCell.knobThickness)
        let knobTravelEnd = knobTravelStart + knobTravelWidth

        // Endpoint label dots (positioned between track and endpoint labels, matching stock macOS)
        let dotRadius: CGFloat = 1.0
        let dotCenterY = trackRect.maxY + 4.0
        NSColor.tertiaryLabelColor.setFill()
        for cx in [knobTravelStart, knobTravelEnd] {
            if abs(knobRect.midX - cx) <= (sliderCell.knobThickness / 2 - 1.0) {
                continue
            }
            let dotRect = NSRect(
                x: cx - dotRadius,
                y: dotCenterY - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
            NSBezierPath(ovalIn: dotRect).fill()
        }

        let markerRadius: CGFloat = 1.6

        for pos in slider.snapMarkerPositions {
            let cx = knobTravelStart + knobTravelWidth * CGFloat(pos)
            let cy = trackRect.midY

            // Hide checkpoint if covered by the knob pill
            if abs(cx - knobRect.midX) <= (sliderCell.knobThickness / 2 - 1.0) {
                continue
            }

            let markerRect = NSRect(
                x: cx - markerRadius,
                y: cy - markerRadius,
                width: markerRadius * 2,
                height: markerRadius * 2
            )

            if fillWidth > 0 && cx <= knobRect.midX {
                NSColor.white.withAlphaComponent(0.85).setFill()
                NSBezierPath(ovalIn: markerRect).fill()
            } else {
                let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let markerColor = isDark
                    ? NSColor.white.withAlphaComponent(0.45)
                    : NSColor.black.withAlphaComponent(0.30)
                markerColor.setFill()
                NSBezierPath(ovalIn: markerRect).fill()
            }
        }
    }
}

private final class DockSettingSlider: NSSlider {
    private let trackAccentView = DockSliderTrackAccentView()

    override var doubleValue: Double {
        didSet {
            trackAccentView.needsDisplay = true
            suppressNativeTrackFill()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTrackAccentView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTrackAccentView()
    }

    convenience init(
        value: Double,
        minValue: Double,
        maxValue: Double,
        target: Any?,
        action: Selector?
    ) {
        self.init(frame: .zero)
        self.minValue = minValue
        self.maxValue = maxValue
        self.doubleValue = value
        self.target = target as AnyObject?
        self.action = action
    }

    private func setupTrackAccentView() {
        trackAccentView.slider = self
        trackAccentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trackAccentView, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            trackAccentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            trackAccentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            trackAccentView.topAnchor.constraint(equalTo: topAnchor),
            trackAccentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 6)
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        suppressNativeTrackFill()
        DispatchQueue.main.async { [weak self] in
            self?.suppressNativeTrackFill()
        }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        suppressNativeTrackFill()
        DispatchQueue.main.async { [weak self] in
            self?.suppressNativeTrackFill()
        }
    }

    override func layout() {
        super.layout()
        suppressNativeTrackFill()
    }

    private func suppressNativeTrackFill() {
        guard let root = layer else { return }
        func hideIn(_ layer: CALayer) {
            if let sublayers = layer.sublayers, sublayers.count == 3 {
                let h0 = sublayers[0].bounds.height
                let h1 = sublayers[1].bounds.height
                let h2 = sublayers[2].bounds.height
                if abs(h0 - 6.0) < 1.0 && abs(h1 - 6.0) < 1.0 && abs(h2 - 6.0) < 1.0 {
                    if !sublayers[1].isHidden {
                        sublayers[1].isHidden = true
                        sublayers[1].opacity = 0
                    }
                    if !sublayers[2].isHidden {
                        sublayers[2].isHidden = true
                        sublayers[2].opacity = 0
                    }
                    return
                }
            }
            for sub in layer.sublayers ?? [] {
                hideIn(sub)
            }
        }
        hideIn(root)
    }

    var commitHandler: ((Double) -> Void)?
    var interactionChangedHandler: ((Bool) -> Void)?
    var snapMarkerPositions: [Double] = [0.25, 0.50, 0.75]
    var snapMarkerValues: [Double] {
        get {
            snapMarkerPositions.map { minValue + (maxValue - minValue) * $0 }
        }
        set {
            guard maxValue > minValue else { return }
            snapMarkerPositions = newValue.map { ($0 - minValue) / (maxValue - minValue) }
        }
    }
    private var endpointHapticDistance: Double { (maxValue - minValue) * 0.01 }
    private var baseMarkerSnapEntryDistance: Double { (maxValue - minValue) * 0.0225 }
    private var baseMarkerSnapReleaseDistance: Double { (maxValue - minValue) * 0.0325 }
    private let minimumHapticInterval: CFTimeInterval = 0.05
    private var previousDragValue: Double?
    private var snappedMarkerValue: Double?
    private var pendingHapticCount = 0
    private var hapticDrainTimer: Timer?
    private var lastHapticTime: CFTimeInterval = -Double.greatestFiniteMagnitude
    private(set) var isDragging = false

    private func setInteractionActive(_ active: Bool) {
        interactionChangedHandler?(active)
    }

    override func mouseDown(with event: NSEvent) {
        resetHapticQueue()
        isDragging = true
        trackAccentView.needsDisplay = true
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
        trackAccentView.needsDisplay = true
        commitHandler?(doubleValue)
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        suppressNativeTrackFill()
        if isDragging {
            if let previousDragValue {
                applyMarkerSnap()
                performMarkerHapticsIfNeeded(from: previousDragValue, to: doubleValue)
                self.previousDragValue = doubleValue
            }
            trackAccentView.needsDisplay = true
        }
        return super.sendAction(action, to: target)
    }

    override func keyDown(with event: NSEvent) {
        let previousValue = doubleValue
        setInteractionActive(true)
        super.keyDown(with: event)
        setInteractionActive(false)
        if doubleValue != previousValue {
            trackAccentView.needsDisplay = true
            commitHandler?(doubleValue)
        }
    }

    private func applyMarkerSnap() {
        let rawValue = doubleValue
        if let snappedMarkerValue {
            if abs(rawValue - snappedMarkerValue) <= markerSnapReleaseDistance(
                for: snappedMarkerValue
            ) {
                doubleValue = snappedMarkerValue
                return
            }
            self.snappedMarkerValue = nil
        }

        guard let nearestMarker = snapMarkerValues.min(by: {
            abs(rawValue - $0) < abs(rawValue - $1)
        }), abs(rawValue - nearestMarker) <= markerSnapEntryDistance(
            for: nearestMarker
        ) else {
            return
        }
        snappedMarkerValue = nearestMarker
        doubleValue = nearestMarker
    }

    private func markerSnapEntryDistance(for marker: Double) -> Double {
        min(baseMarkerSnapEntryDistance, nearestCheckpointDistance(to: marker) * 0.25)
    }

    private func markerSnapReleaseDistance(for marker: Double) -> Double {
        min(baseMarkerSnapReleaseDistance, nearestCheckpointDistance(to: marker) * 0.45)
    }

    private func nearestCheckpointDistance(to marker: Double) -> Double {
        let neighboringValues = [minValue, maxValue] + snapMarkerValues.filter {
            abs($0 - marker) > Double.ulpOfOne
        }
        return neighboringValues.map { abs($0 - marker) }.min()
            ?? (maxValue - minValue)
    }

    private func performMarkerHapticsIfNeeded(from previousValue: Double, to currentValue: Double) {
        guard previousValue != currentValue else { return }

        let crossedInteriorMarkers = snapMarkerValues.filter { marker in
            (previousValue < marker && currentValue >= marker)
                || (previousValue > marker && currentValue <= marker)
        }
        let enteredMinimumEndpoint = previousValue > minValue + endpointHapticDistance
            && currentValue <= minValue + endpointHapticDistance
        let enteredMaximumEndpoint = previousValue < maxValue - endpointHapticDistance
            && currentValue >= maxValue - endpointHapticDistance

        let orderedMarkers = currentValue > previousValue
            ? crossedInteriorMarkers.sorted()
                + (enteredMaximumEndpoint ? [maxValue] : [])
            : (enteredMinimumEndpoint ? [minValue] : [])
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
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { frame.size }

    let slider = DockSettingSlider(
        value: 50,
        minValue: 0,
        maxValue: 100,
        target: nil,
        action: nil
    )
    private let titleLabel: NSTextField
    private let leadingLabel: NSTextField
    private let trailingLabel: NSTextField
    private let valueLabel = NSTextField(labelWithString: "macOS Default")
    private(set) var helpButton: DockSettingHelpButton?
    var helpControl: NSView? { helpButton }

    init(
        title: String,
        leadingTitle: String,
        trailingTitle: String,
        accessibilityLabel: String,
        accessibilityHelp: String,
        width: CGFloat = 240,
        helpHeading: String? = nil,
        helpTextProvider: (() -> String)? = nil
    ) {
        titleLabel = NSTextField(labelWithString: title)
        leadingLabel = NSTextField(labelWithString: leadingTitle)
        trailingLabel = NSTextField(labelWithString: trailingTitle)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 62))
        autoresizingMask = [.width]

        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.textColor = .labelColor
        titleLabel.setContentHuggingPriority(.required, for: .vertical)
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        for label in [leadingLabel, trailingLabel] {
            label.font = .systemFont(ofSize: 10)
            label.textColor = .labelColor
            label.setContentHuggingPriority(.required, for: .vertical)
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        trailingLabel.alignment = .right

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
        valueLabel.textColor = .labelColor
        valueLabel.alignment = .center
        valueLabel.setContentHuggingPriority(.required, for: .vertical)
        valueLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        slider.minValue = 0
        slider.maxValue = 100
        slider.doubleValue = 50
        slider.controlSize = .regular
        slider.isContinuous = true
        slider.numberOfTickMarks = 0
        slider.trackFillColor = .systemBlue
        if #available(macOS 26.0, *) {
            // Ask the native renderer to show the accent-colored track even
            // in a menu, without replacing the interactive glass knob.
            slider.tintProminence = .primary
        }
        slider.setAccessibilityLabel(accessibilityLabel)
        slider.setAccessibilityHelp(accessibilityHelp)
        slider.interactionChangedHandler = { [weak self] active in
            self?.setInteractionAppearance(active)
        }
        slider.setContentHuggingPriority(.required, for: .vertical)
        slider.setContentCompressionResistancePriority(.required, for: .vertical)
        slider.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(slider)
        addSubview(leadingLabel)
        addSubview(valueLabel)
        addSubview(trailingLabel)

        let leadingInset: CGFloat = 20
        let trailingInset: CGFloat = -20
        let helpTrailingInset: CGFloat = -12

        var constraints: [NSLayoutConstraint] = [
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),

            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: trailingInset),
            slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            leadingLabel.leadingAnchor.constraint(equalTo: slider.leadingAnchor),
            leadingLabel.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 4),

            trailingLabel.trailingAnchor.constraint(equalTo: slider.trailingAnchor),
            trailingLabel.centerYAnchor.constraint(equalTo: leadingLabel.centerYAnchor),

            valueLabel.centerXAnchor.constraint(equalTo: slider.centerXAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: leadingLabel.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingLabel.trailingAnchor, constant: 4),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingLabel.leadingAnchor, constant: -4)
        ]

        let bottomConstraint = leadingLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        bottomConstraint.priority = .defaultLow
        constraints.append(bottomConstraint)

        if let helpTextProvider {
            let button = DockSettingHelpButton(
                heading: helpHeading ?? title,
                textProvider: helpTextProvider
            )
            self.helpButton = button
            super.toolTip = nil
            slider.toolTip = nil
            addSubview(button)
            constraints.append(contentsOf: [
                button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: helpTrailingInset),
                button.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 16),
                button.heightAnchor.constraint(equalToConstant: 16),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8)
            ])
        } else {
            constraints.append(titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: trailingInset))
        }

        NSLayoutConstraint.activate(constraints)

        setInteractionAppearance(false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var toolTip: String? {
        get {
            if helpButton != nil { return nil }
            return super.toolTip
        }
        set {
            if helpButton != nil {
                super.toolTip = nil
                slider.toolTip = nil
            } else {
                super.toolTip = newValue
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview != nil ? convert(point, from: superview) : point
        if let helpButton, helpButton.frame.insetBy(dx: -4, dy: -4).contains(local) {
            return helpButton
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        if let helpButton, helpButton.frame.insetBy(dx: -4, dy: -4).contains(localPoint) {
            helpButton.performHelpAction(self)
            return
        }
    }

    func setPercentage(_ percentage: Double, usesSystemDefault: Bool) {
        let roundedPercentage = min(100, max(0, percentage.rounded()))
        slider.doubleValue = roundedPercentage
        slider.needsDisplay = true
        valueLabel.stringValue = usesSystemDefault
            ? "macOS Default"
            : "\(Int(roundedPercentage))%"
    }

    func setValue(_ value: Double, displayText: String) {
        if !slider.isDragging {
            slider.doubleValue = min(slider.maxValue, max(slider.minValue, value))
            slider.needsDisplay = true
        }
        valueLabel.stringValue = displayText
    }

    private func setInteractionAppearance(_ active: Bool) {
        valueLabel.textColor = .labelColor
    }
}

private final class PillPaddingSlidersView: NSView {
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { frame.size }

    let slider = DockSettingSlider(
        value: 8,
        minValue: 0,
        maxValue: 24,
        target: nil,
        action: nil
    )
    var horizontalSlider: DockSettingSlider { slider }

    private let titleLabel = NSTextField(labelWithString: "Pill Padding")
    private let valueLabel = NSTextField(labelWithString: "8 pt")
    private let leadingLabel = NSTextField(labelWithString: "Compact")
    private let trailingLabel = NSTextField(labelWithString: "Spacious")
    private(set) var helpButton: DockSettingHelpButton?
    var helpControl: NSView? { helpButton }

    init(width: CGFloat = 280) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 62))
        autoresizingMask = [.width]

        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.textColor = .labelColor
        titleLabel.setContentHuggingPriority(.required, for: .vertical)
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        for label in [leadingLabel, trailingLabel] {
            label.font = .systemFont(ofSize: 9.5)
            label.textColor = .labelColor
            label.setContentHuggingPriority(.required, for: .vertical)
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        trailingLabel.alignment = .right

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
        valueLabel.textColor = .labelColor
        valueLabel.alignment = .center
        valueLabel.setContentHuggingPriority(.required, for: .vertical)
        valueLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        slider.controlSize = .regular
        slider.isContinuous = true
        slider.numberOfTickMarks = 0
        slider.trackFillColor = .systemBlue
        if #available(macOS 26.0, *) {
            slider.tintProminence = .primary
        }
        slider.setContentHuggingPriority(.required, for: .vertical)
        slider.setContentCompressionResistancePriority(.required, for: .vertical)
        slider.translatesAutoresizingMaskIntoConstraints = false

        slider.minValue = 0
        slider.maxValue = 24
        slider.doubleValue = 8
        slider.snapMarkerValues = [8.0]
        slider.setAccessibilityLabel("Pill padding")
        slider.setAccessibilityHelp("Adjust padding inside the pill. Default is 8 points.")

        let help = DockSettingHelpButton(
            heading: "Pill Padding",
            textProvider: {
                "Fine-tunes the inner horizontal spacing inside the pill capsule.\n\n• Controls spacing to the left and right of the numbers.\n• Default padding is 8 pt."
            }
        )
        self.helpButton = help

        addSubview(titleLabel)
        addSubview(help)
        addSubview(slider)
        addSubview(leadingLabel)
        addSubview(valueLabel)
        addSubview(trailingLabel)

        let leadingInset: CGFloat = 20
        let helpTrailingInset: CGFloat = -12

        var constraints: [NSLayoutConstraint] = [
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: help.leadingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),

            help.trailingAnchor.constraint(equalTo: trailingAnchor, constant: helpTrailingInset),
            help.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            help.widthAnchor.constraint(equalToConstant: 16),
            help.heightAnchor.constraint(equalToConstant: 16),

            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            leadingLabel.leadingAnchor.constraint(equalTo: slider.leadingAnchor),
            leadingLabel.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 4),

            trailingLabel.trailingAnchor.constraint(equalTo: slider.trailingAnchor),
            trailingLabel.centerYAnchor.constraint(equalTo: leadingLabel.centerYAnchor),

            valueLabel.centerXAnchor.constraint(equalTo: slider.centerXAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: leadingLabel.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingLabel.trailingAnchor, constant: 4),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingLabel.leadingAnchor, constant: -4)
        ]

        let bottomConstraint = leadingLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        bottomConstraint.priority = .defaultLow
        constraints.append(bottomConstraint)

        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var toolTip: String? {
        get {
            if helpButton != nil { return nil }
            return super.toolTip
        }
        set {
            if helpButton != nil {
                super.toolTip = nil
                slider.toolTip = nil
            } else {
                super.toolTip = newValue
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview != nil ? convert(point, from: superview) : point
        if let helpButton, helpButton.frame.insetBy(dx: -4, dy: -4).contains(local) {
            return helpButton
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        if let helpButton, helpButton.frame.insetBy(dx: -4, dy: -4).contains(localPoint) {
            helpButton.performHelpAction(self)
            return
        }
    }

    func update(horizontal: Double, vertical: Double = 3.0) {
        let h = min(24, max(0, horizontal.rounded()))
        if !slider.isDragging {
            slider.doubleValue = h
            slider.needsDisplay = true
        }
        valueLabel.stringValue = "\(Int(h)) pt"
    }
}


private final class BlacklistGroupSeparatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 190, height: 9))

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

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 28)
    }

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
        autoresizingMask = [.width]

        for button in buttons {
            button.target = self
            button.action = #selector(selectPosition(_:))
        }

        let stack = NSStackView(views: buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
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
    init(
        title: String,
        width: CGFloat = 232,
        leadingInset: CGFloat = 20,
        font: NSFont? = nil,
        centered: Bool = false
    ) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        autoresizingMask = [.width]

        let label = NSTextField(labelWithString: title)
        label.font = font ?? .menuFont(ofSize: 0)
        label.textColor = font != nil ? .secondaryLabelColor : .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        var constraints = [
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        ]
        if centered {
            label.alignment = .center
            constraints.append(label.centerXAnchor.constraint(equalTo: centerXAnchor))
        } else {
            constraints.append(label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset))
        }
        NSLayoutConstraint.activate(constraints)

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

private final class DockSettingHandToggleHeaderView: NSView {
    private let toggle = DockMenuSwitch()
    private let changeHandler: (Bool) -> Void

    init(
        title: String,
        isOn: Bool,
        width: CGFloat,
        leadingInset: CGFloat = 18,
        trailingInset: CGFloat = 18,
        changeHandler: @escaping (Bool) -> Void
    ) {
        self.changeHandler = changeHandler
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        autoresizingMask = [.width]

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        toggle.controlSize = .small
        toggle.state = isOn ? .on : .off
        toggle.setAccessibilityLabel("Enable \(title.replacingOccurrences(of: ":", with: "")) Shortcuts")
        toggle.target = self
        toggle.action = #selector(toggleChanged(_:))
        toggle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toggle)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -10),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailingInset),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = superview != nil ? convert(point, from: superview) : point
        guard bounds.contains(localPoint) else { return nil }
        if toggle.frame.contains(localPoint) {
            return toggle.hitTest(localPoint) ?? toggle
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        // Only the switch is interactive; clicking the section title is inert.
    }

    func setOn(_ enabled: Bool) {
        toggle.state = enabled ? .on : .off
    }

    @objc private func toggleChanged(_ sender: DockMenuSwitch) {
        changeHandler(sender.state == .on)
    }
}

private final class BlacklistActionMenuItemView: NSView {
    private let highlightView = NSView()
    private let titleLabel: NSTextField
    private var iconView: NSImageView?
    private var controlEnabled: Bool
    private let actionHandler: () -> Void
    private var trackingAreaReference: NSTrackingArea?

    init(
        title: String,
        isEnabled: Bool = true,
        width: CGFloat = 190,
        titleLeadingInset: CGFloat = 22,
        icon: NSImage? = nil,
        iconTrailingInset: CGFloat = 8.5,
        iconOnLeading: Bool = false,
        iconLeadingInset: CGFloat? = nil,
        actionHandler: @escaping () -> Void
    ) {
        titleLabel = NSTextField(labelWithString: title)
        controlEnabled = isEnabled
        self.actionHandler = actionHandler
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        autoresizingMask = [.width]

        wantsLayer = true
        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = 5
        highlightView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.textColor = isEnabled ? .labelColor : .tertiaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(highlightView)
        addSubview(titleLabel)

        var constraints: [NSLayoutConstraint] = [
            highlightView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            highlightView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            highlightView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            highlightView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ]

        if let icon {
            let iv = NSImageView()
            iv.image = icon
            iv.contentTintColor = isEnabled ? .labelColor : .tertiaryLabelColor
            iv.translatesAutoresizingMaskIntoConstraints = false
            self.iconView = iv
            addSubview(iv)
            if iconOnLeading {
                constraints.append(contentsOf: [
                    iv.leadingAnchor.constraint(equalTo: highlightView.leadingAnchor,
                                                constant: iconLeadingInset ?? iconTrailingInset),
                    iv.centerYAnchor.constraint(equalTo: centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: icon.size.width > 0 ? icon.size.width : 16),
                    iv.heightAnchor.constraint(equalToConstant: icon.size.height > 0 ? icon.size.height : 16),
                    titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: titleLeadingInset),
                    titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
                ])
            } else {
                constraints.append(contentsOf: [
                    iv.trailingAnchor.constraint(equalTo: highlightView.trailingAnchor, constant: -iconTrailingInset),
                    iv.centerYAnchor.constraint(equalTo: centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: icon.size.width > 0 ? icon.size.width : 16),
                    iv.heightAnchor.constraint(equalToConstant: icon.size.height > 0 ? icon.size.height : 16),
                    titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: iv.leadingAnchor, constant: -8)
                ])
            }
        } else {
            self.iconView = nil
            constraints.append(contentsOf: [
                titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: titleLeadingInset),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
            ])
        }

        NSLayoutConstraint.activate(constraints)

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
        _ = accessibilityPerformPress()
    }

    override func accessibilityPerformPress() -> Bool {
        guard controlEnabled else { return false }
        actionHandler()
        return true
    }

    @objc func performMenuAction(_ sender: Any?) {
        _ = accessibilityPerformPress()
    }

    func setControlEnabled(_ enabled: Bool) {
        controlEnabled = enabled
        setHighlighted(false)
        let contentColor: NSColor = enabled ? .labelColor : .tertiaryLabelColor
        titleLabel.textColor = contentColor
        iconView?.contentTintColor = contentColor
        setAccessibilityEnabled(enabled)
    }

    private func setHighlighted(_ highlighted: Bool) {
        highlightView.layer?.backgroundColor = highlighted
            ? NSColor.selectedContentBackgroundColor.cgColor
            : NSColor.clear.cgColor
        let contentColor: NSColor = highlighted
            ? .white
            : controlEnabled ? .labelColor : .tertiaryLabelColor
        titleLabel.textColor = contentColor
        iconView?.contentTintColor = contentColor
    }
}

private typealias MenuActionItemView = BlacklistActionMenuItemView

private final class BlacklistHelpMenuItemView: NSView {
    private static let helpText = "A blacklisted app keeps the Dock shown while it is the frontmost app on the active display. When another app moves in front, DockAway hides the Dock normally."
    private var heading = "How 'Blacklist' Works"
    private var textProvider: () -> String = { BlacklistHelpMenuItemView.helpText }

    private let highlightView = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "About Blacklist")
    private var hoverWorkItem: DispatchWorkItem?
    private var trackingAreaReference: NSTrackingArea?
    private lazy var helpPopover = makeHelpPopover()

    init(titleLeadingInset: CGFloat = 22, iconTrailingInset: CGFloat = 10) {
        super.init(frame: NSRect(x: 0, y: 0, width: 190, height: 28))
        autoresizingMask = [.width]
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
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: titleLeadingInset),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: iconView.leadingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: highlightView.centerYAnchor),
            iconView.trailingAnchor.constraint(equalTo: highlightView.trailingAnchor, constant: -iconTrailingInset),
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

    convenience override init(frame frameRect: NSRect) {
        self.init(titleLeadingInset: 22, iconTrailingInset: 10)
    }

    convenience init(
        title: String,
        heading: String,
        width: CGFloat? = nil,
        titleLeadingInset: CGFloat = 22,
        iconTrailingInset: CGFloat = 10,
        text: @escaping () -> String
    ) {
        self.init(titleLeadingInset: titleLeadingInset, iconTrailingInset: iconTrailingInset)
        titleLabel.stringValue = title
        self.heading = heading
        textProvider = text
        setAccessibilityLabel(title)
        iconView.setAccessibilityLabel(title)
        frame.size.width = max(
            width ?? 190,
            ceil(titleLabel.intrinsicContentSize.width) + 64
        )
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
        _ = accessibilityPerformPress()
    }

    override func accessibilityPerformPress() -> Bool {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        showPopover()
        return true
    }

    @objc func performMenuAction(_ sender: Any?) {
        _ = accessibilityPerformPress()
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
        helpPopover = makeHelpPopover()
        setAccessibilityHelp(textProvider())
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
        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .labelColor

        let text = textProvider()
        let detail = NSTextField(wrappingLabelWithString: text)
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 0

        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false

        let detailHeight = (text as NSString).boundingRect(
            with: NSSize(width: 282, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 11.5)]).height
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 310, height: max(96, ceil(detailHeight) + 46)))
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
    private let grantedTitle: String
    private var grantedState: Bool?
    private var actionAvailable = true
    private var checkmarkAnimationGeneration = 0
    private var circleAnimationGeneration = 0

    init(title: String, detail: String, grantedTitle: String = "Granted", requestAction: @escaping () -> Void) {
        titleLabel = NSTextField(labelWithString: title)
        detailLabel = NSTextField(wrappingLabelWithString: detail)
        self.requestAction = requestAction
        self.grantedTitle = grantedTitle
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
            accessibilityDescription: grantedTitle
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

    func setDetail(_ detail: String) {
        guard detailLabel.stringValue != detail else { return }
        detailLabel.attributedStringValue = laterEmphasizedText(
            detail,
            font: detailLabel.font ?? .systemFont(ofSize: 11.5),
            color: .secondaryLabelColor
        )
    }

    private func applyActionAppearance(_ granted: Bool) {
        actionButton.title = granted ? grantedTitle : (actionAvailable ? "Allow" : "Next")
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
        wrappingLabelWithString: "Start with Accessibility so DockAway can manage Dock visibility."
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
            detail: "Allows DockAway to detect window changes and manage Dock visibility.",
            requestAction: requestAccessibility
        )
        inputMonitoringRow = PermissionSetupRowView(
            title: "Input Access",
            detail: "Checks whether macOS allows the input access used by DockAway.",
            grantedTitle: "Available",
            requestAction: requestInputMonitoring
        )
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 165))

        instructionLabel.font = .systemFont(ofSize: 11.5)
        instructionLabel.textColor = .secondaryLabelColor
        instructionLabel.alignment = .center

        let stack = NSStackView(views: [accessibilityRow, inputMonitoringRow])
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
        inputMonitoringSettingsOpen: Bool,
        checkingPermissions: Bool = false
    ) {
        accessibilityRow.setGranted(accessibilityGranted)
        inputMonitoringRow.setGranted(
            inputMonitoringGranted || inputMonitoringRestartPending
        )
        let inputMonitoringReady = inputMonitoringGranted || inputMonitoringRestartPending
        if checkingPermissions {
            inputMonitoringRow.setDetail("Checking input access…")
        } else if inputMonitoringReady {
            inputMonitoringRow.setDetail("Input access is already available. No additional permission is needed.")
        } else if accessibilityGranted {
            inputMonitoringRow.setDetail("Enable Input Monitoring in System Settings. Choose “Later” if macOS asks to quit and reopen.")
        } else {
            inputMonitoringRow.setDetail("Checks whether macOS allows the input access used by DockAway.")
        }
        accessibilityRow.setActionAvailable(true)
        inputMonitoringRow.setActionAvailable(
            accessibilityGranted || inputMonitoringReady
        )

        let newStateCode: Int
        if checkingPermissions {
            newStateCode = -1
        } else if !accessibilityGranted {
            // Recovery can leave Input Monitoring granted already. Never
            // block repairing Accessibility or imply both permissions are ready.
            newStateCode = 0
        } else if inputMonitoringGranted {
            newStateCode = 4
        } else if inputMonitoringRestartPending {
            newStateCode = 3
        } else if inputMonitoringSettingsOpen {
            newStateCode = 1
        } else {
            newStateCode = 2
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
        case -1:
            instructionLabel.stringValue = "Checking access… Please wait."
            instructionLabel.textColor = .secondaryLabelColor
        case 0:
            instructionLabel.stringValue =
                "Start with Accessibility so DockAway can manage Dock visibility."
            instructionLabel.textColor = .secondaryLabelColor
        case 1:
            let instruction =
                "Enable Input Monitoring, then choose “Later” if macOS asks to quit and reopen."
            instructionLabel.attributedStringValue = laterEmphasizedText(
                instruction,
                font: NSFont.systemFont(ofSize: 11.5),
                color: .secondaryLabelColor,
                alignment: .center
            )
        case 2:
            let instruction =
                "Accessibility is ready. Enable Input Monitoring in System Settings."
            instructionLabel.attributedStringValue = laterEmphasizedText(
                instruction,
                font: NSFont.systemFont(ofSize: 11.5),
                color: .secondaryLabelColor,
                alignment: .center
            )
        default:
            let instruction = "Click “Continue” to finish setup."
            instructionLabel.attributedStringValue = laterEmphasizedText(
                instruction,
                font: NSFont.systemFont(ofSize: 11.5),
                color: .systemGreen,
                alignment: .center
            )
        }
    }
}


final class OnboardingPrimaryButton: NSButton {
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            updateVisualState(animated: false)
        }
    }

    private func updateVisualState(animated: Bool = true) {
        guard let layer else { return }
        let targetBgColor: CGColor
        let targetTitle: NSAttributedString

        if isEnabled {
            let baseColor = NSColor.systemBlue
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
            targetBgColor = NSColor.quaternaryLabelColor.cgColor
            targetTitle = NSAttributedString(
                string: title,
                attributes: [
                    .foregroundColor: NSColor.disabledControlTextColor,
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
    private weak var aboutPanelWindow: NSWindow?
    private static let ignoredWindowBundleIdentifiersKey = "IgnoredWindowBundleIdentifiers"
    private static let checkForUpdatesAtLaunchKey = "CheckForUpdatesAtLaunch"
    private static let desktopIndicatorAppearanceKey = "DesktopIndicatorAppearance"
    private static let desktopIndicatorTextBadgeKey = "DesktopIndicatorTextBadge"
    private static let desktopIndicatorHierarchyKey = "DesktopIndicatorTextHierarchy"
    private static let desktopIndicatorAccentKey = "DesktopIndicatorTextAccent"
    private static let desktopIndicatorSlashKey = "DesktopIndicatorTextSlash"
    private static let desktopIndicatorSeparatorKey = "DesktopIndicatorTextSeparator"
    private static let desktopIndicatorPillKey = "DesktopIndicatorTextPill"
    private static let desktopIndicatorEncapsulateKey = "DesktopIndicatorEncapsulate"
    private static let desktopIndicatorRoundPillKey = "DesktopIndicatorRoundPill"
    private static let desktopManagerEnabledKey = "desktopManagerEnabled"
    static let openDockAwayShortcutEnabledKey = DockAwayHotKey.preferenceKey
    private static let keepDockSettingsAfterQuitKey = "KeepDockSettingsAfterQuit"
    private static let keepDockPositionAfterQuitKey = "KeepDockPositionAfterQuit"
    private static let keepDockAnimationAfterQuitKey = "KeepDockAnimationAfterQuit"
    private static let keepDockRevealDelayAfterQuitKey = "KeepDockRevealDelayAfterQuit"
    private static let permissionSetupCompletedKey = "PermissionSetupCompleted"
    private static let initialRevealDelayHandledKey = "InitialRevealDelayHandled"
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

    private enum DesktopIndicatorAppearance: Int, CaseIterable {
        case none = 0
        case systemText = 1
        case compactSlash = 2
        case pillBadge = 3
        case activeBadge = 4
        case hierarchical = 5

        var title: String {
            switch self {
            case .none: "None"
            case .systemText: "Menubar Desktop Indicator"
            case .compactSlash: "Compact Slash"
            case .pillBadge: "Pill Badge"
            case .activeBadge: "Active Desktop Badge"
            case .hierarchical: "Hierarchical Typography"
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
    private var dockWatcher: DockWatcher! {
        didSet {
            dockWatcher?.onAccessibilityEvent = { [weak self] pid, element, notification in
                self?.cursorTeleportManager?.handleAccessibilityEvent(
                    processIdentifier: pid,
                    windowElement: element,
                    notification: notification
                )
                if notification == kAXWindowCreatedNotification || notification == kAXWindowDeminiaturizedNotification {
                    self?.chromiumWebAppPlacementController.handleWindowCreated(
                        processIdentifier: pid,
                        windowElement: element
                    )
                }
            }
        }
    }
    private var updaterController: SPUStandardUpdaterController!
    private var updateMenuItem: NSMenuItem!
    private var updateFrequencyMenu: NSMenu!
    private var checkForUpdatesAtLaunchItem: NSMenuItem!
    private var desktopIndicatorAppearanceMenu: NSMenu?
    private var desktopIndicatorPreviewContext: String?
    private var availableUpdateVersion: String?
    private var blacklistMenu: NSMenu!
    private weak var blacklistClearActionView: BlacklistActionMenuItemView?
    private var currentBlacklistBundleIdentifier: String?
    private weak var hoverActivationBlacklistMenu: NSMenu?
    private weak var hoverActivationBlacklistClearActionView: BlacklistActionMenuItemView?
    private var dockSettingsMenu: NSMenu!
    private var dockPositionRowView: DockPositionRowView!
    private var dockAnimationSliderView: DockSettingSliderView!
    private var dockRevealDelaySliderView: DockSettingSliderView!
    private var dockSettingsPersistenceItems = [NSMenuItem]()
    private var dockSettingsPersistenceNoneRowView: DockSettingPersistenceRowView!
    private var restoreDockDefaultsRowView: DockSettingPersistenceRowView!
    private var dockIconClickMinimizeRowView: DockSettingPersistenceRowView?
    private var dockIconClickHideRowView: DockSettingPersistenceRowView?
    private var launchAtLoginRowView: DockSettingPersistenceRowView!
    private var dockSettingsRestartInProgress = false
    private var dockRestartGeneration = 0
    private let dockRestartController = DockRestartController()
    private var dockRestartIsManual = false
    private weak var restartDockMenuItem: NSMenuItem?
    private weak var restartDockRowView: DockAwayMenuRowView?
    private weak var advancedSettingsMenu: NSMenu?
    private var dockAwayStatusView: DockAwayStatusView!
    private var dockAwayEnabled = true
    private var activeStatusText = "Detecting…"
    private var activeDesktopStatusText: String?
    private let desktopSwitcher = DesktopSwitcher()
    private var desktopCreationInProgress = false
    private var statusMenuIsOpen = false
    private var settingsMenuPreviousApplication: NSRunningApplication?
    private var desktopTilesView: DesktopDisplaySectionsView?
    private var desktopDisplaySections: [DesktopDisplaySection] = []
    private var pendingDisplayLayoutRefresh = false
    private var displayAccentGlobalMonitor: Any?
    private var displayAccentLocalMonitor: Any?
    private var lastAccentDisplayID: CGDirectDisplayID?
    private var desktopTilesMenuItem: NSMenuItem?
    private var desktopTileSnapshot: DesktopSelectionSnapshot?
    private var desktopIconRefreshTask: Task<Void, Never>?
    private var desktopMenuRestoreGeneration: UInt = 0
    private var pendingDesktopMenuRestoreGeneration: UInt?
    private var pendingRestoredKeyboardSpaceID: UInt64?
    private weak var dockAwaySettingsMenu: NSMenu?
    private var desktopManagerRowView: DockSettingToggleRowView?
    private weak var desktopChangeTooltipMenu: NSMenu?
    private var desktopChangeTooltipRowView: DockSettingToggleRowView?
    private var desktopChangeTooltipDurationSliderView: DockSettingSliderView?
    private var desktopChangeTooltipDisplayUnderneathRowView: DockSettingToggleRowView?
    private let desktopChangeTooltip = DesktopChangeTooltip()
    private var teleportCursorRowView: DockSettingPersistenceRowView?
    private var teleportWindowMoveRowView: DockSettingPersistenceRowView?
    private var lockSoundRowView: DockSettingPersistenceRowView?
    private var unlockSoundRowView: DockSettingPersistenceRowView?
    private var screenshotClipboardRowView: DockSettingPersistenceRowView?
    private var greenButtonFillRowView: DockSettingPersistenceRowView?
    private var finderDeleteKeyRowView: DockSettingPersistenceRowView?
    private var quickLookCopyOrientationRowView: DockSettingPersistenceRowView?
    private var hoverActivationEnabledRowView: DockSettingToggleRowView?
    private var hoverActivationPointerStopRowView: DockSettingToggleRowView?
    private var hoverActivationRaiseRowView: DockSettingPersistenceRowView?
    private var hoverActivationDelaySliderView: DockSettingSliderView?
    private var keyboardNavigationRowViews: [DockSettingKeyRebindRowView] = []
    private var keyboardNavigationEnabledRowView: DockSettingToggleRowView?
    private var keyboardNavigationHandToggleRows: [NavigationHand: DockSettingHandToggleHeaderView] = [:]
    private var resetKeyboardControlsRowView: DockSettingResetControlsRowView?
    private weak var keyboardNavigationMenu: NSMenu?
    private weak var displayOrderMenu: NSMenu?
    private var displayOrderRows: [DisplayListOrder: DockSettingPersistenceRowView] = [:]
    private var openShortcutHotKey: DockAwayHotKey?
    private var cursorTeleportManager: CursorTeleportManager?
    private let lockscreenSoundPlayer = LockscreenSoundPlayer()
    private let mutedVolumeMenuBarController = MutedVolumeMenuBarController()
    private weak var mutedVolumeMenuBarRow: DockSettingPersistenceRowView?
    private let screenshotClipboardManager = ScreenshotClipboardManager.shared
    private let greenButtonFillController = GreenButtonFillController()
    private let finderDeleteKeyController = FinderDeleteKeyController()
    private let quickLookCopyOrientationManager = QuickLookCopyOrientationManager()
    private let hoverActivationController = HoverActivationController()
    private let dockIconClickMinimizeController = DockIconClickMinimizeController()
    private let chromiumWebAppPlacementController = ChromiumWebAppPlacementController()
    private weak var chromiumWebAppPlacementRowView: DockSettingPersistenceRowView?
    private let desktopKeyboardCapture = DesktopMenuKeyboardCapture()
    private var isTeleportCursorEnabled: Bool {
        get {
            CursorTeleportPreference.isAppActivationTeleportEnabled
        }
        set {
            CursorTeleportPreference.isAppActivationTeleportEnabled = newValue
        }
    }
    private var isTeleportWindowMoveEnabled: Bool {
        get {
            CursorTeleportPreference.isWindowMoveTeleportEnabled
        }
        set {
            CursorTeleportPreference.isWindowMoveTeleportEnabled = newValue
        }
    }
    private var isDesktopManagerEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: Self.desktopManagerEnabledKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.desktopManagerEnabledKey)
        }
    }
    private var isOpenShortcutEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: Self.openDockAwayShortcutEnabledKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.openDockAwayShortcutEnabledKey)
        }
    }
    private var desktopMenuStatus: String? {
        guard let snapshot = desktopTileSnapshot else { return activeDesktopStatusText }
        guard let index = snapshot.desktopIDs.firstIndex(of: snapshot.currentID) else {
            return "Desktop: Fullscreen"
        }
        return "Desktop: \(index + 1) of \(snapshot.desktopIDs.count)"
    }
    private var automaticSuspensionReasons = Set<AutomaticSuspensionReason>()
    private var accessibilityPermissionMissing = false
    private var inputMonitoringPermissionMissing = false
    private var multitouchUnavailable = false
    private var dockShortcutWarning: String?

    private var dockShortcutWarningVisible: Bool {
        statusAppearsActive && dockShortcutWarning != nil
    }

    func updateDockShortcutWarning(_ message: String?) {
        guard dockShortcutWarning != message else { return }
        dockShortcutWarning = message
        updateDockAwayMenuState()
    }
    private var permissionSetupInProgress = false
    private var permissionSetupWindow: NSPanel?
    private weak var permissionSetupView: PermissionSetupView?
    private let permissionMonitor = PermissionMonitor()
    private let runtimePermissionAccess = RuntimePermissionAccess()
    private var permissionContinuePending = false
    private var permissionContinueGeneration = 0
    private var permissionSetupRequested = false
    private var permissionSetupTimer: Timer?
    private weak var permissionSetupContinueButton: NSButton?
    private weak var permissionSetupLaunchAtLoginRowView: DockSettingPersistenceRowView?
    private weak var permissionSetupDesktopManagerRowView: OnboardingDesktopManagerRowView?
    private weak var permissionSetupKeyboardSettingsView: OnboardingKeyboardSettingsView?
    private weak var permissionSetupContentStack: NSStackView?
    private var onboardingCurrentStep = 1
    private var inputMonitoringSettingsVisitInProgress = false
    private var inputMonitoringRestartPending: Bool {
        permissionMonitor.snapshot?.inputMonitoringGranted == true
            && !processInputMonitoringAccessGranted
    }
    private var permissionRelaunchScheduled = false
    private var isPermissionRelaunching = false
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
    private var fourFingerStartedWithKnownState = false
    private var fourFingerStartedInMissionControl = false
    private let multitouch = MultitouchWatcher()

    private var processInputMonitoringAccessGranted: Bool {
        runtimePermissionAccess.snapshot?.inputMonitoringGranted == true
    }

    private var inputMonitoringAccessGranted: Bool {
        permissionMonitor.snapshot?.inputMonitoringGranted == true
            && processInputMonitoringAccessGranted
    }

    private var accessibilityAccessGranted: Bool {
        permissionMonitor.snapshot?.accessibilityGranted == true
            && runtimePermissionAccess.snapshot?.accessibilityGranted == true
    }

    private var permissionRestartRequired: Bool {
        permissionMonitor.snapshot?.allGranted == true
            && (!accessibilityAccessGranted || !inputMonitoringAccessGranted)
    }

    private var permissionRecoveryRequired: Bool {
        permissionMonitor.snapshot == nil || accessibilityPermissionMissing
            || inputMonitoringPermissionMissing || permissionRestartRequired
    }


    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = DockAwayTheme.current.appearance
        dockAwayDebugLog("🚀 APP LAUNCHED")
        mutedVolumeMenuBarController.recoverPreviousSession()
        mutedVolumeMenuBarController.onDisabled = { [weak self] in
            self?.mutedVolumeMenuBarRow?.setOn(false)
        }
        mutedVolumeMenuBarController.setEnabled(UserDefaults.standard.bool(forKey: MutedVolumeMenuBarController.preferenceKey))
        NSApp.setActivationPolicy(.accessory)

        // These are first-run defaults only. UserDefaults preserves any later
        // choice the user makes in the Update Frequency menu.
        UserDefaults.standard.register(defaults: [
            Self.checkForUpdatesAtLaunchKey: true,
            Self.desktopIndicatorAppearanceKey: DesktopIndicatorAppearance.systemText.rawValue,
            Self.desktopManagerEnabledKey: true,
            Self.openDockAwayShortcutEnabledKey: true,
            LockscreenSoundPlayer.Event.lock.preferenceKey: false,
            LockscreenSoundPlayer.Event.unlock.preferenceKey: false,
            ScreenshotClipboardManager.preferenceKey: false,
            GreenButtonFillController.preferenceKey: false,
            FinderDeleteKeyController.preferenceKey: false,
            QuickLookCopyOrientationManager.preferenceKey: false,
            HoverActivationController.enabledPreferenceKey: false,
            HoverActivationController.delayPreferenceKey: HoverActivationController.defaultDelay,
            HoverActivationController.waitsForPointerToStopPreferenceKey: false,
            HoverActivationController.raisesWindowPreferenceKey: false,
            HoverActivationController.protectedBundleIdentifiersPreferenceKey: [String](),
            DockIconClickMinimizeController.preferenceKey: false,
            DockIconClickMinimizeController.hidePreferenceKey: false,
            CursorTeleportPreference.appActivationPreferenceKey: true,
            CursorTeleportPreference.windowMovePreferenceKey: true,
            "moveCursorToSelectedDisplay": true,
            ChromiumWebAppPlacementController.preferenceKey: true,
            DisplayListOrder.preferenceKey: DisplayListOrder.activeFirst.rawValue
        ])

        if screenshotClipboardManager.isEnabled {
            screenshotClipboardManager.startMonitoring()
        }

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

        accessibilityPermissionMissing = true
        inputMonitoringPermissionMissing = !inputMonitoringAccessGranted
        setupMenuBar()
        setupOpenShortcutHotKey()
        finderDeleteKeyController.isSuppressed = { [weak self] in
            self?.statusMenuIsOpen == true
        }
        let teleportManager = CursorTeleportManager()
        teleportManager.isMissionControlActive = { [weak self] in
            self?.dockWatcher?.isMissionControlActive == true
        }
        teleportManager.onWindowMoveTransitionStarted = { [weak self] in
            self?.dockWatcher?.protectWindowMoveTransition()
        }
        teleportManager.start()
        self.cursorTeleportManager = teleportManager
        dockIconClickMinimizeController.onWillHideApplication = { [weak self] in
            self?.cursorTeleportManager?.suppressNextApplicationActivationTeleport()
        }
        chromiumWebAppPlacementController.cursorTeleportManager = cursorTeleportManager
        chromiumWebAppPlacementController.currentSpaceProvider = { [weak self] displayID in
            self?.dockWatcher?.desktopSelection(on: displayID)?.currentID
        }
        refreshChromiumWebAppPlacementController()
        refreshFinderDeleteKeyController()
        refreshQuickLookCopyOrientationManager()
        hoverActivationController.isSuppressed = { [weak self] in
            guard let self else { return true }
            return self.statusMenuIsOpen
                || !self.automaticSuspensionReasons.isEmpty
                || self.dockWatcher?.isMissionControlActive == true
        }
        refreshHoverActivationController()
        startPermissionHealthMonitoring()
        runtimePermissionAccess.start { [weak self] in
            guard let self, !self.isQuitting else { return }
            // A local capability result must never replace the independently
            // observed System Settings state, or force an early setup decision.
            if self.permissionMonitor.snapshot != nil || !self.permissionMonitor.state.isChecking {
                self.applyPermissionSnapshot(self.permissionMonitor.snapshot)
            }
        }
        requestAccessibilityPermission()
        
        // Arm the signal trapper
        setupSignalHandler()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !permissionContinuePending {
            permissionMonitor.refresh(force: true)
        }
        if dockShortcutWarning != nil, DockShortcut.current() != nil {
            updateDockShortcutWarning(nil)
            dockWatcher?.resetState()
        }

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
            && !inputMonitoringPermissionMissing
            && accessibilityAccessGranted
            && inputMonitoringAccessGranted
            && !permissionSetupInProgress
            && !permissionRelaunchScheduled
            && automaticSuspensionReasons.isEmpty
            && !dockSettingsRestartInProgress
            && !isQuitting
    }

    // Both permissions are required. The menu remains available for recovery
    // while the watcher and gesture monitoring are stopped.
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
            return dockRestartIsManual ? "Restarting the macOS Dock" : "Applying Dock settings"
        }
        if permissionMonitor.snapshot == nil {
            return "Unable to confirm permissions. Checking again…"
        }
        if permissionRestartRequired {
            return "Finish setup to activate access"
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
            return dockRestartIsManual ? "DockAway: Restarting Dock" : "DockAway: Applying Settings"
        }
        return permissionRecoveryRequired
            && dockAwayEnabled
            ? "Permission Required"
            : "DockAway: Paused"
    }

    private var permissionActionTitle: String {
        permissionRestartRequired ? "Finish Permission Setup" : "Restore Permissions"
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
        lockscreenSoundPlayer.playIfEnabled(.lock)
        suspendMonitoring(for: .screenLocked)
    }

    @objc private func screenDidUnlock(_ notification: Notification) {
        clearAutomaticSuspension(.screenLocked)
        lockscreenSoundPlayer.playIfEnabled(.unlock)
    }

    private func suspendMonitoring(for reason: AutomaticSuspensionReason) {
        desktopChangeTooltip.dismiss()
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
        permissionMonitor.stop()
        permissionContinueGeneration += 1
        if runtimePermissionAccess.isChecking {
            runtimePermissionAccess.invalidate()
        }
        permissionContinuePending = false
        renderPermissionSetupState()
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

        permissionMonitor.refresh(force: true)

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
        guard accessibilityAccessGranted else {
            accessibilityPermissionWasRevoked()
            return
        }

        if dockWatcher == nil {
            dockWatcher = DockWatcher()
        }
        dockWatcher.start()
        startMultitouchPreHide()
        applyStatusIcon(dockVisible: isDockCurrentlyVisible())
        refreshDesktopTiles()
        updateMenuBarDesktopBadge()
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
        statusItem.button?.imagePosition = .imageLeading
        applyStatusIcon(dockVisible: isDockCurrentlyVisible())
        updateMenuBarDesktopBadge()
        buildMenu()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(self, selector: #selector(handleSpaceDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func handleSpaceDidChange() {
        hoverActivationController.beginSpaceTransition()
        refreshDesktopTiles()
        updateMenuBarDesktopBadge()
        refreshDesktopIndicatorAppearanceMenu()
        refreshDisplayOrderMenu()
    }

    private var currentDesktopIndicatorAppearance: DesktopIndicatorAppearance {
        DesktopIndicatorPreference.isEnabled() ? .systemText : .none
    }

    private var indicatorEditingDisplay: String?

    private func indicatorDisplayKey(_ id: CGDirectDisplayID) -> String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return "display-\(id)"
    }

    private func displayTextStyle(_ key: String) -> DesktopIndicatorTextStyle {
        guard let data = UserDefaults.standard.dictionary(forKey: "displayIndicatorStyles")?[key] as? Data,
              var style = try? JSONDecoder().decode(DesktopIndicatorTextStyle.self, from: data) else { return globalDesktopTextStyle }
        if style.accentOnlyWhenActive == nil { style.accentOnlyWhenActive = globalDesktopTextStyle.accentOnlyWhenActive }
        if style.fillOnlyWhenActive == nil { style.fillOnlyWhenActive = globalDesktopTextStyle.fillOnlyWhenActive }
        if style.pillOnlyWhenActive == nil { style.pillOnlyWhenActive = globalDesktopTextStyle.pillOnlyWhenActive }
        if style.pillPaddingHorizontal == nil { style.pillPaddingHorizontal = globalDesktopTextStyle.pillPaddingHorizontal }
        if style.pillPaddingVertical == nil { style.pillPaddingVertical = globalDesktopTextStyle.pillPaddingVertical }
        return style
    }

    private var cleanDesktopTextStyle: DesktopIndicatorTextStyle {
        indicatorEditingDisplay.map { displayTextStyle($0) } ?? globalDesktopTextStyle
    }

    private var singleDisplayTextStyle: DesktopIndicatorTextStyle {
        (desktopDisplaySections.first.map { displayTextStyle(indicatorDisplayKey($0.snapshot.displayID)) } ?? globalDesktopTextStyle).resolvedForDisplay(isActive: true)
    }

    private var globalDesktopTextStyle: DesktopIndicatorTextStyle {
        let defaults = UserDefaults.standard
        let legacy = defaults.integer(forKey: Self.desktopIndicatorAppearanceKey)
        let badge = (defaults.object(forKey: Self.desktopIndicatorTextBadgeKey) as? Int)
            .flatMap(DesktopIndicatorTextStyle.Badge.init(rawValue:)) ?? (legacy == 4 ? .filled : .none)
        let hierarchical = defaults.object(forKey: Self.desktopIndicatorHierarchyKey) as? Bool ?? (legacy == 5)
        let accent = defaults.object(forKey: Self.desktopIndicatorAccentKey) as? Bool ?? true
        let slash = defaults.object(forKey: Self.desktopIndicatorSlashKey) as? Bool ?? (legacy == 2)
        let separator = defaults.string(forKey: Self.desktopIndicatorSeparatorKey)
            .flatMap(DesktopIndicatorTextStyle.Separator.init(rawValue:)) ?? (slash ? .slash : .of)
        let pill = defaults.object(forKey: Self.desktopIndicatorPillKey) as? Bool ?? (legacy == 3)
        let encapsulate = defaults.bool(forKey: Self.desktopIndicatorEncapsulateKey)
        let round = defaults.bool(forKey: Self.desktopIndicatorRoundPillKey)
        let opacity = defaults.object(forKey: "desktopIndicatorPillOpacity") as? Double ?? 0.08
        let paddingH = defaults.object(forKey: "desktopIndicatorPillPaddingH") as? Double ?? 8.0
        let paddingV = defaults.object(forKey: "desktopIndicatorPillPaddingV") as? Double ?? 3.0
        return DesktopIndicatorTextStyle(badge: badge, hierarchical: hierarchical, usesAccentColor: accent, separator: separator, usesPill: pill, pillOpacity: opacity, encapsulatesDockIndicator: encapsulate, usesRoundPill: round,
            accentOnlyWhenActive: defaults.bool(forKey: "accentActiveDisplayCount"),
            fillOnlyWhenActive: defaults.bool(forKey: "fillActiveDisplayCount"),
            pillOnlyWhenActive: defaults.bool(forKey: "pillActiveDisplayOnly"),
            pillPaddingHorizontal: paddingH,
            pillPaddingVertical: paddingV)
    }

    private func saveCleanDesktopTextStyle(_ style: DesktopIndicatorTextStyle) {
        var overrides = UserDefaults.standard.dictionary(forKey: "displayIndicatorStyles") ?? [:]
        if let key = indicatorEditingDisplay {
            overrides[key] = try? JSONEncoder().encode(style)
            UserDefaults.standard.set(overrides, forKey: "displayIndicatorStyles")
            return
        }
        // All Displays changes only the edited properties, preserving other differences.
        if let oldData = try? JSONEncoder().encode(globalDesktopTextStyle),
           let newData = try? JSONEncoder().encode(style),
           let old = try? JSONSerialization.jsonObject(with: oldData) as? [String: Any],
           let new = try? JSONSerialization.jsonObject(with: newData) as? [String: Any] {
            for (key, value) in overrides {
                guard let data = value as? Data,
                      var fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                for (field, value) in new where !NSDictionary(dictionary: [field: value]).isEqual(to: [field: old[field] as Any]) {
                    fields[field] = value
                }
                overrides[key] = try? JSONSerialization.data(withJSONObject: fields)
            }
            UserDefaults.standard.set(overrides, forKey: "displayIndicatorStyles")
        }
        UserDefaults.standard.set(style.badge.rawValue, forKey: Self.desktopIndicatorTextBadgeKey)
        UserDefaults.standard.set(style.fillOnlyWhenActive ?? false, forKey: "fillActiveDisplayCount")
        UserDefaults.standard.set(style.accentOnlyWhenActive ?? false, forKey: "accentActiveDisplayCount")
        UserDefaults.standard.set(style.accentOnlyWhenActive ?? false, forKey: "accentedActiveDisplayCount")
        UserDefaults.standard.set(style.hierarchical, forKey: Self.desktopIndicatorHierarchyKey)
        UserDefaults.standard.set(style.usesAccentColor, forKey: Self.desktopIndicatorAccentKey)
        UserDefaults.standard.set(style.separator.rawValue, forKey: Self.desktopIndicatorSeparatorKey)
        UserDefaults.standard.set(style.usesPill, forKey: Self.desktopIndicatorPillKey)
        UserDefaults.standard.set(style.pillOpacity, forKey: "desktopIndicatorPillOpacity")
        UserDefaults.standard.set(style.encapsulatesDockIndicator, forKey: Self.desktopIndicatorEncapsulateKey)
        UserDefaults.standard.set(style.usesRoundPill, forKey: Self.desktopIndicatorRoundPillKey)
        UserDefaults.standard.set(style.pillOnlyWhenActive ?? false, forKey: "pillActiveDisplayOnly")
        UserDefaults.standard.set(style.pillPaddingHorizontal ?? 8.0, forKey: "desktopIndicatorPillPaddingH")
        UserDefaults.standard.set(style.pillPaddingVertical ?? 3.0, forKey: "desktopIndicatorPillPaddingV")
    }

    private func currentDesktopInfo() -> (current: Int, total: Int, isFS: Bool) {
        if let snapshot = desktopTileSnapshot {
            let total = max(1, snapshot.desktopIDs.count)
            if let index = snapshot.desktopIDs.firstIndex(of: snapshot.currentID) {
                return (index + 1, total, false)
            } else {
                return (1, total, true)
            }
        } else if let text = activeDesktopStatusText {
            if text == "Desktop: Fullscreen" {
                return (1, 1, true)
            } else if text.hasPrefix("Desktop: ") {
                let rest = text.dropFirst("Desktop: ".count)
                let parts = rest.components(separatedBy: " of ")
                if parts.count == 2, let c = Int(parts[0]), let t = Int(parts[1]) {
                    return (c, max(1, t), false)
                }
            }
        }
        return (1, 1, false)
    }

    private static func makePillBadgeImage(text: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let width = max(30, textSize.width + 12)
        let height: CGFloat = 16
        return NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            NSColor(white: 0.35, alpha: 0.7).setFill()
            path.fill()

            let pStyle = NSMutableParagraphStyle()
            pStyle.alignment = .center
            let str = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: NSColor.white,
                .paragraphStyle: pStyle
            ])
            str.draw(in: NSRect(x: 0, y: (height - textSize.height) / 2 - 0.5, width: width, height: textSize.height))
            return true
        }
    }

    private static func makeActiveBoxImage(numberText: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        let textSize = (numberText as NSString).size(withAttributes: [.font: font])
        let width = max(15, textSize.width + 6)
        let height: CGFloat = 15
        return NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5)
            NSColor.systemBlue.setFill()
            path.fill()

            let pStyle = NSMutableParagraphStyle()
            pStyle.alignment = .center
            let str = NSAttributedString(string: numberText, attributes: [
                .font: font,
                .foregroundColor: NSColor.white,
                .paragraphStyle: pStyle
            ])
            str.draw(in: NSRect(x: 0, y: (height - textSize.height) / 2 - 0.5, width: width, height: textSize.height))
            return true
        }
    }

    private func updateMenuBarDesktopBadge(liveCustomization: Bool = false, refreshMenu: Bool = true) {
        // Keep the status item's anchor stable while a desktop drop settles.
        // menuDidClose applies the deferred appearance and number update.
        if refreshMenu { refreshDesktopIndicatorAppearanceMenu() }
        // Explicit appearance edits must remain visible while customizing, even
        // when an unrelated display-list update is waiting for tracking to end.
        if statusMenuIsOpen && pendingDisplayLayoutRefresh && !liveCustomization { return }
        guard let button = statusItem?.button else { return }

        let appearance = currentDesktopIndicatorAppearance
        let style = singleDisplayTextStyle
        button.imagePosition = appearance != .none && style.usesPill && style.encapsulatesDockIndicator ? .noImage : .imageLeading
        guard appearance != .none else {
            button.title = ""
            button.attributedTitle = NSAttributedString()
            return
        }

        if let group = groupedDisplayIndicatorText() {
            button.imagePosition = .noImage
            button.attributedTitle = group
            return
        }

        let (currentNum, totalNum, isFS) = currentDesktopInfo()

        switch appearance {
        case .none:
            button.title = ""
            button.attributedTitle = NSAttributedString()

        case .systemText:
            button.attributedTitle = style.text(current: currentNum, total: totalNum, isFullscreen: isFS, dockIndicator: button.image)

        case .compactSlash:
            let text = isFS ? "FS" : "\(currentNum)/\(totalNum)"
            let font = NSFont.monospacedDigitSystemFont(ofSize: 12.0, weight: .medium)
            button.attributedTitle = NSAttributedString(string: text, attributes: [.font: font])

        case .pillBadge:
            let text = isFS ? "FS" : "\(currentNum) of \(totalNum)"
            let pill = Self.makePillBadgeImage(text: text)
            let att = NSTextAttachment()
            att.image = pill
            att.bounds = CGRect(x: 0, y: -3, width: pill.size.width, height: pill.size.height)
            button.attributedTitle = NSAttributedString(attachment: att)

        case .activeBadge:
            if isFS {
                let box = Self.makeActiveBoxImage(numberText: "FS")
                let att = NSTextAttachment()
                att.image = box
                att.bounds = CGRect(x: 0, y: -3, width: box.size.width, height: box.size.height)
                button.attributedTitle = NSAttributedString(attachment: att)
            } else {
                let box = Self.makeActiveBoxImage(numberText: "\(currentNum)")
                let att = NSTextAttachment()
                att.image = box
                att.bounds = CGRect(x: 0, y: -3, width: box.size.width, height: box.size.height)
                let str = NSMutableAttributedString(attachment: att)
                str.append(NSAttributedString(string: " of \(totalNum)", attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .regular)
                ]))
                button.attributedTitle = str
            }

        case .hierarchical:
            if isFS {
                let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .bold)
                button.attributedTitle = NSAttributedString(string: "FS", attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor
                ])
            } else {
                let str = NSMutableAttributedString()
                str.append(NSAttributedString(string: "\(currentNum)", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .bold),
                    .foregroundColor: NSColor.labelColor
                ]))
                str.append(NSAttributedString(string: " of \(totalNum)", attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]))
                button.attributedTitle = str
            }
        }
    }

    // MARK: - Four-Finger Pre-Hide

    private var orderedIndicatorSections: [DesktopDisplaySection] {
        let active = desktopDisplaySections.firstIndex { $0.snapshot.displayID == pointerDisplayID() }
        return DisplayIndicatorGroup.orderedIndices(count: desktopDisplaySections.count, activeIndex: active,
            activeFirst: UserDefaults.standard.bool(forKey: "activeDisplayIndicatorFirst"))
            .map { desktopDisplaySections[$0] }
    }

    private func groupedDisplayIndicatorText() -> NSAttributedString? {
        guard desktopDisplaySections.count > 1 else { return nil }
        let externalIDs = desktopDisplaySections.filter { CGDisplayIsBuiltin($0.snapshot.displayID) == 0 }.map { $0.snapshot.displayID }
        let pointerID = pointerDisplayID()
        let active = orderedIndicatorSections.firstIndex { $0.snapshot.displayID == pointerID }
        let entries = orderedIndicatorSections.map { section in
            let snapshot = section.snapshot
            let index = snapshot.desktopIDs.firstIndex(of: snapshot.currentID)
            let appearance = displayTextStyle(indicatorDisplayKey(snapshot.displayID))
                .resolvedForDisplay(isActive: snapshot.displayID == pointerID)
            return DisplayIndicatorGroup.Entry(name: section.name,
                builtIn: CGDisplayIsBuiltin(snapshot.displayID) != 0,
                current: (index ?? 0) + 1, total: snapshot.desktopIDs.count, fullscreen: index == nil,
                appearance: appearance, monitorNumber: externalIDs.firstIndex(of: snapshot.displayID).map { $0 + 1 })
        }
        let height = max(1, floor(statusItem.button?.bounds.height ?? NSStatusBar.system.thickness))
        let stacked = UserDefaults.standard.object(forKey: "stackDisplayIndicators") as? Bool ?? true
        return DisplayIndicatorGroup.text(entries: entries, style: globalDesktopTextStyle,
            maximumHeight: height, stacked: stacked, accentedIndex: active)
    }

    private func pointerDisplayID() -> CGDirectDisplayID? {
        guard let point = CGEvent(source: nil)?.location else { return nil }
        return desktopDisplaySections.first { CGDisplayBounds($0.snapshot.displayID).contains(point) }?.snapshot.displayID
    }

    private func configureDisplayAccentTracking() {
        let enabled = desktopDisplaySections.count > 1 && (DisplayListOrder.current != .numerical || UserDefaults.standard.bool(forKey: "activeDisplayIndicatorFirst") || globalDesktopTextStyle.hierarchical || desktopDisplaySections.contains {
            let style = displayTextStyle(indicatorDisplayKey($0.snapshot.displayID))
            return style.hierarchical || style.accentOnlyWhenActive == true || style.fillOnlyWhenActive == true || style.pillOnlyWhenActive == true
        })
        guard enabled else {
            if let monitor = displayAccentGlobalMonitor { NSEvent.removeMonitor(monitor) }
            if let monitor = displayAccentLocalMonitor { NSEvent.removeMonitor(monitor) }
            displayAccentGlobalMonitor = nil
            displayAccentLocalMonitor = nil
            lastAccentDisplayID = nil
            return
        }
        guard displayAccentGlobalMonitor == nil else { return }
        lastAccentDisplayID = pointerDisplayID()
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        displayAccentGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            self?.refreshPointerDisplayAccent()
        }
        displayAccentLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.refreshPointerDisplayAccent()
            return event
        }
    }

    private func refreshPointerDisplayAccent() {
        let displayID = pointerDisplayID()
        guard displayID != lastAccentDisplayID else { return }
        lastAccentDisplayID = displayID
        if let displayID { recordDisplayUsage(displayID) }
        // Only repaint on a display boundary crossing. Never rebuild an open menu.
        if statusMenuIsOpen {
            pendingDisplayLayoutRefresh = true
            refreshDesktopIndicatorAppearanceMenu()
        } else if let text = groupedDisplayIndicatorText(), currentDesktopIndicatorAppearance != .none {
            statusItem.button?.attributedTitle = text
        }
    }

    private func startMultitouchPreHide() {
        guard
            monitoringShouldRun,
            !inputMonitoringPermissionMissing,
            dockWatcher?.isRunning == true
        else { return }

        multitouch.start(
            onFingerCountChange: { [weak self] fingers in
                guard let self, self.monitoringShouldRun else { return }
                self.dockWatcher?.missionControlTrackpadContactsChanged(fingers)
                self.desktopChangeTooltip.desktopGestureContactsChanged(fingers)
                if fingers < 3 {
                    // Refresh even when the gesture was cancelled and macOS
                    // didn't post a changed-Space notification.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.refreshDesktopTiles()
                    }
                }

                guard
                    self.hideOnFourFingerTouch,
                    let watcher = self.dockWatcher
                else { return }

                if fingers >= self.fourFingerThreshold {
                    guard !self.fourFingersDown else { return }
                    self.fourFingersDown = true
                    self.fourFingerStartedWithKnownState = false
                    // Do not guess which direction this gesture means while
                    // the initial/changed Mission Control state is unresolved.
                    // Keep the contact latched and skip its motion until lift.
                    guard let beganInMissionControl =
                        watcher.missionControlActiveAtGestureStart() else { return }
                    self.fourFingerStartedWithKnownState = true
                    self.fourFingerStartedInMissionControl = beganInMissionControl
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
                    self.fourFingerStartedWithKnownState = false
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
                    self.monitoringShouldRun
                else { return }

                self.dockWatcher?.missionControlTrackpadMotionDetected(motion)

                guard
                    self.hideOnFourFingerTouch,
                    self.fourFingersDown,
                    self.fourFingerStartedWithKnownState,
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
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.image = image
        updateMenuBarDesktopBadge()
    }

    private func buildMenu() {
        let menu = NSMenu()

        let statusMenuItem = NSMenuItem()
        let statusContainer = NSView(frame: NSRect(x: 0, y: 0, width: 190, height: 56))
        statusContainer.autoresizingMask = [.width]
        let statusView = DockAwayStatusView(frame: .zero)
        statusView.translatesAutoresizingMaskIntoConstraints = false
        statusView.pauseResumeButton.target = self
        statusView.pauseResumeButton.action = #selector(toggleDockAway)
        statusView.update(
            active: statusAppearsActive,
            status: activeStatusText,
            desktopStatus: activeDesktopStatusText,
            inactiveTitle: inactiveStatusTitle,
            inactiveDetail: dockAwayEnabled
                ? automaticSuspensionDetail
                : "App detection paused",
            inactiveActionTitle: permissionRecoveryRequired
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

        let tilesItem = NSMenuItem()
        tilesItem.title = "Desktop Manager"
        tilesItem.setAccessibilityLabel("Desktop Manager")
        let initialDesktopCount = dockWatcher?.desktopSelection(on: CGMainDisplayID())?.managerSpaceIDs.count ?? 0
        let canAddInitial = DockAwayDesktopCreationAvailable()
        let initialBoxes = initialDesktopCount + (canAddInitial ? 1 : 0)
        let initialTilesWidth: CGFloat = initialBoxes >= 5 ? 230 : 190
        let tiles = DesktopDisplaySectionsView(frame: NSRect(x: 0, y: 0, width: initialTilesWidth, height: 0))
        tiles.onSelect = { [weak self] identifier in self?.selectDesktop(identifier) }
        tiles.onAdd = { [weak self] displayID in self?.addDesktop(on: displayID) }
        tiles.onClose = { [weak self] in self?.closeDesktop($0) ?? false }
        tiles.onReorder = { [weak self] source, target in self?.reorderDesktop(source, onto: target) }
        tiles.onAppend = { [weak self] source, target in self?.reorderDesktop(source, onto: target, after: true) }
        tilesItem.view = tiles
        tilesItem.isHidden = true
        menu.addItem(tilesItem)
        desktopTilesView = tiles
        desktopTilesMenuItem = tilesItem

        let launchAtLogin = NSMenuItem()
        launchAtLogin.tag = 200
        let launchAtLoginRowView = DockSettingPersistenceRowView(
            title: "Launch at Login",
            isOn: isLaunchAtLoginEnabled(),
            width: 190,
            leadingInset: 12,
            titleLeadingAdjustment: 2
        ) { [weak self] _ in
            self?.toggleLaunchAtLogin()
        }
        launchAtLogin.view = launchAtLoginRowView
        self.launchAtLoginRowView = launchAtLoginRowView

        let blacklistItem = NSMenuItem(title: "Blacklist", action: nil, keyEquivalent: "")
        blacklistItem.view = DockAwayMenuRowView(
            title: "Blacklist",
            hasSubmenu: true,
            leadingInset: 12,
            titleLeadingAdjustment: 2
        )
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
        dockSettingsItem.view = DockAwayMenuRowView(
            title: "Dock Settings",
            icon: NSImage(
                systemSymbolName: "slider.horizontal.3",
                accessibilityDescription: "Dock Settings"
            ),
            hasSubmenu: true,
            leadingInset: 12,
            titleLeadingAdjustment: 2
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
        positionItem.view = DockSettingSectionHeaderView(title: "Dock Position")
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

        let animationSliderView = DockSettingSliderView(
            title: "Animation Speed",
            leadingTitle: "Slow",
            trailingTitle: "Instant",
            accessibilityLabel: "Dock animation speed",
            accessibilityHelp: "Adjust from zero percent slow to one hundred percent instant",
            helpHeading: "Animation Speed",
            helpTextProvider: {
                "Controls how fast the Dock slides onto your screen when you move your mouse to the edge, and how fast it glides away.\n\n• Slide right toward “Instant” to make the Dock appear and disappear without any animation delay.\n• Slide left toward “Slow” for a slower, more gradual sliding motion.\n• The center position restores the standard macOS animation speed.\n• Works whenever the Dock is set to automatically hide and show."
            }
        )
        animationSliderView.slider.target = self
        animationSliderView.slider.action = #selector(previewDockAnimationSlider(_:))
        animationSliderView.slider.commitHandler = { [weak self] percentage in
            self?.commitDockAnimationSlider(percentage)
        }
        let animationSliderItem = NSMenuItem()
        animationSliderItem.view = animationSliderView

        let revealDelaySliderView = DockSettingSliderView(
            title: "Reveal Delay",
            leadingTitle: "None",
            trailingTitle: "Long",
            accessibilityLabel: "Dock reveal delay",
            accessibilityHelp: "Adjust from zero percent no delay to one hundred percent long delay",
            helpHeading: "Reveal Delay",
            helpTextProvider: {
                "Controls how long your mouse must pause at the edge of the screen before a hidden Dock starts to appear.\n\n• Slide left toward “None” (0 sec) to make the Dock reveal itself the instant your pointer reaches the edge.\n• Slide right toward “Long” to require holding your pointer at the edge longer, preventing accidental triggers.\n• The center position restores the standard macOS reveal pause.\n• Helps keep your Dock out of the way while clicking buttons or scrollbars near the screen edge."
            }
        )
        revealDelaySliderView.slider.snapMarkerValues = [20, 40, 60, 80]
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
            title: "Restore Default macOS Dock",
            isOn: false,
            leadingControlStyle: .resetAction
        ) { [weak self] _ in
            self?.restoreDefaultDockSettings()
        }
        let restoreDockDefaultsItem = NSMenuItem()
        restoreDockDefaultsItem.view = restoreDockDefaultsRowView

        let dockIconActionsWidth: CGFloat = 360
        let dockIconActionsHeaderItem = NSMenuItem()
        dockIconActionsHeaderItem.view = DockSettingSectionHeaderView(
            title: "Dock Icon Actions:",
            width: dockIconActionsWidth
        )
        let dockIconClickMinimizeTitle = "Minimize/Expands App When Dock Icon Clicked"
        let dockIconClickMinimizeItem = NSMenuItem(
            title: dockIconClickMinimizeTitle,
            action: nil,
            keyEquivalent: ""
        )
        let dockIconClickMinimizeRow = DockSettingPersistenceRowView(
            title: dockIconClickMinimizeTitle,
            isOn: UserDefaults.standard.bool(
                forKey: DockIconClickMinimizeController.preferenceKey
            ),
            width: dockIconActionsWidth,
            leadingInset: 18,
            trailingInset: 12,
            helpHeading: dockIconClickMinimizeTitle,
            helpTextProvider: {
                "Click the Dock icon of the app you are using to minimize its open windows. Click it again to restore only the windows DockAway minimized.\n\n• Windows minimized another way stay minimized.\n• Dragging Dock icons and modifier-click actions keep their normal macOS behavior."
            }
        ) { [weak self] enabled in
            UserDefaults.standard.set(
                enabled,
                forKey: DockIconClickMinimizeController.preferenceKey
            )
            if enabled {
                UserDefaults.standard.set(
                    false,
                    forKey: DockIconClickMinimizeController.hidePreferenceKey
                )
                self?.dockIconClickHideRowView?.setOn(false)
            }
            self?.dockIconClickMinimizeRowView?.setOn(enabled)
            self?.refreshDockIconClickMinimizeController()
        }
        dockIconClickMinimizeRow.autoresizingMask = [.width]
        dockIconClickMinimizeItem.view = dockIconClickMinimizeRow

        let dockIconClickHideTitle = "Hides/Unhides App When Dock Icon Clicked"
        let dockIconClickHideItem = NSMenuItem(
            title: dockIconClickHideTitle,
            action: nil,
            keyEquivalent: ""
        )
        let dockIconClickHideRow = DockSettingPersistenceRowView(
            title: dockIconClickHideTitle,
            isOn: UserDefaults.standard.bool(
                forKey: DockIconClickMinimizeController.hidePreferenceKey
            ),
            width: dockIconActionsWidth,
            leadingInset: 18,
            trailingInset: 12,
            helpHeading: dockIconClickHideTitle,
            helpTextProvider: {
                "Click the Dock icon of the app you are using to hide the entire app. Click its Dock icon again to unhide and reactivate it.\n\n• Clicking an app that is not currently active keeps the normal macOS activation behavior.\n• Dragging Dock icons and modifier-click actions keep their normal macOS behavior."
            }
        ) { [weak self] enabled in
            UserDefaults.standard.set(
                enabled,
                forKey: DockIconClickMinimizeController.hidePreferenceKey
            )
            if enabled {
                UserDefaults.standard.set(
                    false,
                    forKey: DockIconClickMinimizeController.preferenceKey
                )
                self?.dockIconClickMinimizeRowView?.setOn(false)
            }
            self?.dockIconClickHideRowView?.setOn(enabled)
            self?.refreshDockIconClickMinimizeController()
        }
        dockIconClickHideRow.autoresizingMask = [.width]
        dockIconClickHideItem.view = dockIconClickHideRow

        dockSettingsItem.submenu = dockSettingsMenu
        self.dockSettingsMenu = dockSettingsMenu
        self.dockPositionRowView = positionRowView
        self.dockAnimationSliderView = animationSliderView
        self.dockRevealDelaySliderView = revealDelaySliderView
        self.dockSettingsPersistenceItems = dockSettingsPersistenceItems
        self.dockSettingsPersistenceNoneRowView = dockSettingsPersistenceNoneRowView
        self.restoreDockDefaultsRowView = restoreDockDefaultsRowView
        self.dockIconClickMinimizeRowView = dockIconClickMinimizeRow
        self.dockIconClickHideRowView = dockIconClickHideRow
        refreshDockSettingsMenu()
        dockSettingsMenu.addItem(positionItem)
        dockSettingsMenu.addItem(positionRowItem)
        dockSettingsMenu.addItem(wideMenuSeparator(width: 240, leadingInset: 18, trailingInset: 14))
        dockSettingsMenu.addItem(animationSliderItem)
        dockSettingsMenu.addItem(revealDelaySliderItem)
        let moreSettingsItem = NSMenuItem()
        moreSettingsItem.title = "More Dock Settings..."
        let moreSettingsView = MenuActionItemView(
            title: "More Dock Settings...",
            titleLeadingInset: 20
        ) { [weak self, weak dockSettingsMenu] in
            dockSettingsMenu?.cancelTracking()
            self?.openDesktopAndDockSettings()
        }
        moreSettingsItem.view = moreSettingsView
        moreSettingsItem.target = moreSettingsView
        moreSettingsItem.action = #selector(MenuActionItemView.performMenuAction(_:))
        dockSettingsMenu.addItem(moreSettingsItem)
        dockSettingsMenu.addItem(wideMenuSeparator(width: dockIconActionsWidth, leadingInset: 18, trailingInset: 14))
        dockSettingsMenu.addItem(dockIconActionsHeaderItem)
        dockSettingsMenu.addItem(dockIconClickMinimizeItem)
        dockSettingsMenu.addItem(dockIconClickHideItem)
        dockSettingsMenu.addItem(wideMenuSeparator(width: dockIconActionsWidth, leadingInset: 18, trailingInset: 14))
        dockSettingsMenu.addItem(keepDockSettingsAfterQuitItem)
        dockSettingsPersistenceItems.forEach { dockSettingsMenu.addItem($0) }
        dockSettingsMenu.addItem(dockSettingsPersistenceNoneItem)
        dockSettingsMenu.addItem(wideMenuSeparator(width: 240, leadingInset: 18, trailingInset: 14))
        dockSettingsMenu.addItem(restoreDockDefaultsItem)
        menu.addItem(wideMenuSeparator(width: 190, leadingInset: 14, trailingInset: 14))
        menu.addItem(blacklistItem)
        menu.addItem(dockSettingsItem)
        menu.addItem(wideMenuSeparator(width: 190, leadingInset: 14, trailingInset: 14))
        menu.addItem(launchAtLogin)

        // --- SPARKLE UPDATE MENU ITEM  ---
        let updateMenuItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        let updateRowView = DockAwayMenuRowView(
            title: "Check for Updates...",
            icon: NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath",
                accessibilityDescription: "Check for Updates"
            ),
            leadingInset: 12,
            titleLeadingAdjustment: 2,
            actionHandler: { [weak self] in
                self?.updaterController?.checkForUpdates(nil)
            }
        )
        updateMenuItem.view = updateRowView
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
        updateFrequencyItem.view = DockAwayMenuRowView(
            title: "Update Frequency",
            icon: NSImage(
                systemSymbolName: "clock.arrow.circlepath",
                accessibilityDescription: "Update Frequency"
            ),
            hasSubmenu: true,
            leadingInset: 12,
            titleLeadingAdjustment: 2
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
        updateFrequencyMenu.addItem(wideMenuSeparator(width: 170, leadingInset: 20, trailingInset: 14))
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

        // DockAway Settings
        menu.addItem(wideMenuSeparator(width: 190, leadingInset: 14, trailingInset: 14))
        let dockAwaySettingsItem = NSMenuItem(title: "DockAway Settings", action: nil, keyEquivalent: "")
        dockAwaySettingsItem.view = DockAwayMenuRowView(
            title: "DockAway Settings",
            icon: NSImage(
                systemSymbolName: "gearshape",
                accessibilityDescription: "DockAway Settings"
            ),
            hasSubmenu: true,
            leadingInset: 12,
            titleLeadingAdjustment: 2
        )
        dockAwaySettingsItem.state = .on
        dockAwaySettingsItem.onStateImage = menuIcon(from: NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: "DockAway Settings"
        ))
        let dockAwaySettingsMenu = NSMenu(title: "DockAway Settings")
        dockAwaySettingsMenu.autoenablesItems = false
        dockAwaySettingsMenu.delegate = self
        self.dockAwaySettingsMenu = dockAwaySettingsMenu

        let settingsRowTitles = [
            "DockAway Desktop Manager",
            "Teleport Pointer in Desktop Manager",
            "Teleport Pointer to Dock Icon's Window",
            "Teleport Pointer on “Move to Display”",
            "DockAway Keyboard Navigation"
        ]
        let maxSettingTitleWidth = settingsRowTitles.map {
            ceil(($0 as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 13)]).width)
        }.max() ?? 200
        // Keep the settings rows compact so help buttons and submenu chevrons
        // share the same right edge without crowding the longest title.
        let desktopManagerTitleWidth = ceil(("DockAway Desktop Manager" as NSString).size(
            withAttributes: [.font: NSFont.menuFont(ofSize: 13)]
        ).width)
        let settingsRowWidth = max(240, maxSettingTitleWidth + 76, desktopManagerTitleWidth + 90)

        let desktopManagerItem = NSMenuItem(title: "DockAway Desktop Manager", action: nil, keyEquivalent: "")
        let desktopManagerRow = DockSettingToggleRowView(
            title: "DockAway Desktop Manager",
            isOn: isDesktopManagerEnabled,
            width: settingsRowWidth,
            leadingInset: 34,
            trailingInset: 12
        ) { [weak self] enabled in
            self?.setDesktopManagerEnabled(enabled)
        }
        desktopManagerRow.autoresizingMask = [.width]
        desktopManagerItem.view = desktopManagerRow
        self.desktopManagerRowView = desktopManagerRow
        dockAwaySettingsMenu.addItem(desktopManagerItem)

        let managerPointerTitle = "Teleport Pointer in Desktop Manager"
        let managerPointerItem = NSMenuItem(title: managerPointerTitle, action: nil, keyEquivalent: "")
        let managerPointerRow = DockSettingPersistenceRowView(
            title: managerPointerTitle,
            isOn: UserDefaults.standard.bool(forKey: "moveCursorToSelectedDisplay"),
            width: settingsRowWidth,
            leadingInset: 12, trailingInset: 7, titleLeadingAdjustment: 2,
            indicatorSize: 14,
            helpHeading: managerPointerTitle,
            helpTextProvider: {
                "After a successful desktop selection on another display, moves your pointer to the center of that display.\n\n• Works with mouse and keyboard selection in Desktop Manager.\n• Selecting a desktop on the same display leaves the pointer where it is.\n• Does not change native macOS Mission Control."
            }
        ) { enabled in
            UserDefaults.standard.set(enabled, forKey: "moveCursorToSelectedDisplay")
        }
        managerPointerRow.autoresizingMask = [.width]
        managerPointerItem.view = managerPointerRow

        let keyboardNavItem = NSMenuItem(title: "DockAway Keyboard Navigation", action: nil, keyEquivalent: "")
        keyboardNavItem.view = SubmenuLabelView.keyboardNavigation()
        keyboardNavItem.state = .on
        keyboardNavItem.onStateImage = menuIcon(from: NSImage(
            systemSymbolName: "keyboard",
            accessibilityDescription: "DockAway Keyboard Navigation"
        ))

        let keyboardNavMenu = NSMenu(title: "DockAway Keyboard Navigation")
        keyboardNavMenu.autoenablesItems = false
        keyboardNavMenu.delegate = self
        self.keyboardNavigationMenu = keyboardNavMenu

        let navSubmenuWidth: CGFloat = 380

        let enableNavTitle = "Enable Keyboard Navigation"
        let enableNavItem = NSMenuItem(title: enableNavTitle, action: nil, keyEquivalent: "")
        let enableNavRow = DockSettingToggleRowView(
            title: enableNavTitle,
            isOn: KeyboardNavigationPreferences.isEnabled,
            width: navSubmenuWidth,
            leadingInset: 18,
            trailingInset: 12
        ) { [weak self] enabled in
            self?.setKeyboardNavigationEnabled(enabled)
        }
        enableNavRow.autoresizingMask = [.width]
        enableNavItem.view = enableNavRow
        self.keyboardNavigationEnabledRowView = enableNavRow
        keyboardNavMenu.addItem(enableNavItem)
        keyboardNavMenu.addItem(wideMenuSeparator(width: navSubmenuWidth, leadingInset: 18, trailingInset: 14))

        // Each hand can be disabled independently without changing its bindings.
        let rightHandHeaderItem = NSMenuItem(title: "Right Hand", action: nil, keyEquivalent: "")
        let rightHandToggleRow = DockSettingHandToggleHeaderView(
            title: "Right Hand:",
            isOn: KeyboardNavigationPreferences.isRightHandEnabled,
            width: navSubmenuWidth,
        ) { [weak self] enabled in
            self?.setKeyboardNavigationHandEnabled(.rightHand, enabled: enabled)
        }
        rightHandHeaderItem.view = rightHandToggleRow
        self.keyboardNavigationHandToggleRows[.rightHand] = rightHandToggleRow
        keyboardNavMenu.addItem(rightHandHeaderItem)

        var navRows: [DockSettingKeyRebindRowView] = []
        let currentSettings = KeyboardNavigationPreferences.current
        let isNavEnabled = KeyboardNavigationPreferences.isEnabled

        for action in NavigationAction.allCases {
            let item = NSMenuItem()
            let sc = currentSettings.shortcut(for: .rightHand, action: action, slot: 1)
            let isDual = (action == .close || action == .select)
            let secSc = isDual ? currentSettings.shortcut(for: .rightHand, action: action, slot: 2) : nil
            let row = DockSettingKeyRebindRowView(
                hand: .rightHand,
                action: action,
                keyCode: sc.keyCode,
                modifiers: sc.modifiers,
                secondaryKeyCode: secSc?.keyCode,
                secondaryModifiers: secSc?.modifiers ?? 0,
                width: navSubmenuWidth
            ) { [weak self] slot, newCode, newMods in
                var settings = KeyboardNavigationPreferences.current
                settings.setShortcut(keyCode: newCode, modifiers: newMods, for: .rightHand, action: action, slot: slot)
                KeyboardNavigationPreferences.current = settings
                self?.openShortcutHotKey?.reloadHotKeys()
                self?.refreshKeyboardNavigationMenu()
            }
            row.setControlEnabled(isNavEnabled && KeyboardNavigationPreferences.isRightHandEnabled)
            item.view = row
            keyboardNavMenu.addItem(item)
            navRows.append(row)
        }

        keyboardNavMenu.addItem(wideMenuSeparator(width: navSubmenuWidth, leadingInset: 18, trailingInset: 14))

        // Left Hand Section (Below)
        let leftHandHeaderItem = NSMenuItem(title: "Left Hand", action: nil, keyEquivalent: "")
        let leftHandToggleRow = DockSettingHandToggleHeaderView(
            title: "Left Hand:",
            isOn: KeyboardNavigationPreferences.isLeftHandEnabled,
            width: navSubmenuWidth,
        ) { [weak self] enabled in
            self?.setKeyboardNavigationHandEnabled(.leftHand, enabled: enabled)
        }
        leftHandHeaderItem.view = leftHandToggleRow
        self.keyboardNavigationHandToggleRows[.leftHand] = leftHandToggleRow
        keyboardNavMenu.addItem(leftHandHeaderItem)

        for action in NavigationAction.allCases {
            let item = NSMenuItem()
            let sc = currentSettings.shortcut(for: .leftHand, action: action, slot: 1)
            let row = DockSettingKeyRebindRowView(
                hand: .leftHand,
                action: action,
                keyCode: sc.keyCode,
                modifiers: sc.modifiers,
                width: navSubmenuWidth
            ) { [weak self] slot, newCode, newMods in
                var settings = KeyboardNavigationPreferences.current
                settings.setShortcut(keyCode: newCode, modifiers: newMods, for: .leftHand, action: action, slot: slot)
                KeyboardNavigationPreferences.current = settings
                self?.openShortcutHotKey?.reloadHotKeys()
                self?.refreshKeyboardNavigationMenu()
            }
            row.setControlEnabled(isNavEnabled && KeyboardNavigationPreferences.isLeftHandEnabled)
            item.view = row
            keyboardNavMenu.addItem(item)
            navRows.append(row)
        }

        self.keyboardNavigationRowViews = navRows

        keyboardNavMenu.addItem(wideMenuSeparator(width: navSubmenuWidth, leadingInset: 18, trailingInset: 14))

        // Reset Keyboard Binds to Default
        let resetControlsItem = NSMenuItem(title: "Reset Keyboard Binds to Default", action: nil, keyEquivalent: "")
        let resetControlsRow = DockSettingResetControlsRowView(
            leadingInset: 18,
            titleLeadingAdjustment: 1.5,
            width: navSubmenuWidth
        ) { [weak self] cascadeFinished in
            // Start beside Reset and travel upward through both hand sections.
            guard let self else {
                cascadeFinished()
                return
            }
            let rows = Array(self.keyboardNavigationRowViews.reversed())
            let defaults = KeyboardNavigationSettings()
            if rows.isEmpty {
                KeyboardNavigationPreferences.resetToDefaults()
                self.openShortcutHotKey?.reloadHotKeys()
                cascadeFinished()
                return
            }
            let rowCount = rows.count
            for (index, row) in rows.enumerated() {
                row.animateResetFeedback(
                    rowIndex: index,
                    onRedReached: { [weak self, weak row] in
                        guard let self, let row else { return }
                        self.resetKeyboardNavigationRowToDefault(
                            row,
                            defaults: defaults,
                            isFinalRow: index == rowCount - 1
                        )
                    },
                    onComplete: index == rowCount - 1 ? cascadeFinished : nil
                )
            }
        }
        resetControlsRow.setControlEnabled(isNavEnabled)
        resetControlsItem.view = resetControlsRow
        self.resetKeyboardControlsRowView = resetControlsRow
        keyboardNavMenu.addItem(resetControlsItem)

        keyboardNavItem.submenu = keyboardNavMenu
        dockAwaySettingsMenu.addItem(keyboardNavItem)
        dockAwaySettingsMenu.addItem(managerPointerItem)
        dockAwaySettingsMenu.addItem(wideMenuSeparator(width: settingsRowWidth, leadingInset: 14, trailingInset: 14))

        let teleportCursorItem = NSMenuItem(title: "Teleport Pointer to Dock Icon's Window", action: nil, keyEquivalent: "")
        let teleportCursorRow = DockSettingPersistenceRowView(
            title: "Teleport Pointer to Dock Icon's Window",
            isOn: isTeleportCursorEnabled,
            width: settingsRowWidth,
            leadingInset: 12,
            trailingInset: 7,
            titleLeadingAdjustment: 2,
            indicatorSize: 14,
            helpHeading: "Teleport Pointer to Dock Icon's Window",
            helpTextProvider: {
                "When switching to an application on another display, automatically moves the mouse pointer to that app's frontmost window.\n\n• Waits for the click to finish and the window to settle before moving your pointer.\n• Eliminates long pointer travel across multi-monitor workspaces.\n• Only teleports when switching to an app on a different display."
            }
        ) { [weak self] enabled in
            self?.setTeleportCursorEnabled(enabled)
        }
        teleportCursorRow.autoresizingMask = [.width]
        teleportCursorItem.view = teleportCursorRow
        self.teleportCursorRowView = teleportCursorRow
        dockAwaySettingsMenu.addItem(teleportCursorItem)

        let teleportWindowMoveTitle = "Teleport Pointer on “Move to Display”"
        let teleportWindowMoveItem = NSMenuItem(title: teleportWindowMoveTitle, action: nil, keyEquivalent: "")
        let teleportWindowMoveRow = DockSettingPersistenceRowView(
            title: teleportWindowMoveTitle,
            isOn: isTeleportWindowMoveEnabled,
            width: settingsRowWidth,
            leadingInset: 12,
            trailingInset: 7,
            titleLeadingAdjustment: 2,
            indicatorSize: 14,
            helpHeading: "Teleport Pointer on “Move to Display”",
            helpTextProvider: {
                "When moving a window to another monitor via macOS window controls, automatically teleports your mouse pointer along with the window.\n\n• Works when clicking “Move to [Display]” in the green window button options.\n• Keeps your focus immediately on the window in its new location.\n• Continues your workflow uninterrupted without searching for your pointer."
            }
        ) { [weak self] enabled in
            self?.setTeleportWindowMoveEnabled(enabled)
        }
        teleportWindowMoveRow.autoresizingMask = [.width]
        teleportWindowMoveItem.view = teleportWindowMoveRow
        self.teleportWindowMoveRowView = teleportWindowMoveRow
        dockAwaySettingsMenu.addItem(teleportWindowMoveItem)
        dockAwaySettingsMenu.addItem(wideMenuSeparator(width: settingsRowWidth, leadingInset: 14, trailingInset: 14))

        let hoverActivationTitle = "Activate on Hover"
        let hoverActivationItem = NSMenuItem(
            title: hoverActivationTitle,
            action: nil,
            keyEquivalent: ""
        )
        let hoverActivationIcon = NSImage(
            systemSymbolName: "cursorarrow.motionlines",
            accessibilityDescription: hoverActivationTitle
        ) ?? NSImage(
            systemSymbolName: "cursorarrow",
            accessibilityDescription: hoverActivationTitle
        )
        hoverActivationItem.view = DockAwayMenuRowView(
            title: hoverActivationTitle,
            icon: hoverActivationIcon,
            hasSubmenu: true,
            leadingInset: 12,
            titleLeadingAdjustment: 2,
            width: settingsRowWidth
        )
        hoverActivationItem.state = .on
        hoverActivationItem.onStateImage = menuIcon(from: hoverActivationIcon)

        let hoverActivationMenu = NSMenu(title: hoverActivationTitle)
        hoverActivationMenu.autoenablesItems = false
        hoverActivationMenu.delegate = self
        let hoverActivationRowWidth = max(settingsRowWidth, 330)

        let hoverEnabledTitle = "Activate Windows on Hover"
        let hoverEnabledItem = NSMenuItem(
            title: hoverEnabledTitle,
            action: nil,
            keyEquivalent: ""
        )
        let hoverEnabledRow = DockSettingToggleRowView(
            title: hoverEnabledTitle,
            isOn: HoverActivationController.isEnabled,
            width: hoverActivationRowWidth,
            leadingInset: 18,
            trailingInset: 12
        ) { [weak self] enabled in
            UserDefaults.standard.set(
                enabled,
                forKey: HoverActivationController.enabledPreferenceKey
            )
            self?.hoverActivationEnabledRowView?.setOn(enabled)
            self?.refreshHoverActivationController()
        }
        hoverEnabledItem.view = hoverEnabledRow
        self.hoverActivationEnabledRowView = hoverEnabledRow
        hoverActivationMenu.addItem(hoverEnabledItem)
        hoverActivationMenu.addItem(wideMenuSeparator(
            width: hoverActivationRowWidth,
            leadingInset: 18,
            trailingInset: 14
        ))

        let hoverDelayItem = NSMenuItem(title: "Hover Activation Delay", action: nil, keyEquivalent: "")
        let hoverDelayView = DockSettingSliderView(
            title: "Hover Activation Delay",
            leadingTitle: "Instant",
            trailingTitle: "2 sec",
            accessibilityLabel: "Hover activation delay",
            accessibilityHelp: "Set how long the pointer must remain over a window before it becomes active.",
            width: hoverActivationRowWidth,
            helpHeading: "Hover Activation Delay",
            helpTextProvider: {
                "Controls how long your pointer must remain over a window before DockAway activates it.\n\n• Slide left for immediate activation.\n• A short delay prevents windows from activating while you simply pass over them.\n• Changes apply immediately."
            }
        )
        hoverDelayView.slider.minValue = 0
        hoverDelayView.slider.maxValue = 2
        hoverDelayView.slider.snapMarkerValues = [0.05, 0.1, 0.25, 0.5, 1.0, 1.5]
        hoverDelayView.slider.target = self
        hoverDelayView.slider.action = #selector(previewHoverActivationDelay(_:))
        hoverDelayView.slider.commitHandler = { [weak self] delay in
            UserDefaults.standard.set(
                delay,
                forKey: HoverActivationController.delayPreferenceKey
            )
            self?.refreshHoverActivationMenu()
        }
        hoverDelayItem.view = hoverDelayView
        self.hoverActivationDelaySliderView = hoverDelayView
        hoverActivationMenu.addItem(hoverDelayItem)

        let pointerStopTitle = "Wait for Pointer to Stop"
        let pointerStopItem = NSMenuItem(
            title: pointerStopTitle,
            action: nil,
            keyEquivalent: ""
        )
        let pointerStopRow = DockSettingToggleRowView(
            title: pointerStopTitle,
            isOn: HoverActivationController.waitsForPointerToStop,
            width: hoverActivationRowWidth,
            leadingInset: 18,
            trailingInset: 12
        ) { [weak self] enabled in
            UserDefaults.standard.set(
                enabled,
                forKey: HoverActivationController.waitsForPointerToStopPreferenceKey
            )
            self?.hoverActivationPointerStopRowView?.setOn(enabled)
        }
        pointerStopRow.toggleControl.setAccessibilityHelp(
            "Waits until the pointer stops moving before focusing or bringing a window forward. The hover activation delay restarts whenever the pointer moves."
        )
        pointerStopItem.view = pointerStopRow
        self.hoverActivationPointerStopRowView = pointerStopRow
        hoverActivationMenu.addItem(pointerStopItem)

        let raiseTitle = "Bring Window to Front"
        let raiseItem = NSMenuItem(title: raiseTitle, action: nil, keyEquivalent: "")
        let raiseRow = DockSettingPersistenceRowView(
            title: raiseTitle,
            isOn: HoverActivationController.raisesWindow,
            width: hoverActivationRowWidth,
            leadingInset: 18,
            trailingInset: 12,
            titleLeadingAdjustment: 1,
            indicatorSize: 16,
            helpHeading: raiseTitle,
            helpTextProvider: {
                "Raises the exact hovered window above overlapping windows when it becomes active.\n\nTurn this off when you want keyboard focus to follow the pointer with the least possible change to window order."
            }
        ) { [weak self] enabled in
            UserDefaults.standard.set(
                enabled,
                forKey: HoverActivationController.raisesWindowPreferenceKey
            )
            self?.hoverActivationRaiseRowView?.setOn(enabled)
        }
        raiseItem.view = raiseRow
        self.hoverActivationRaiseRowView = raiseRow
        hoverActivationMenu.addItem(raiseItem)
        hoverActivationMenu.addItem(wideMenuSeparator(
            width: hoverActivationRowWidth,
            leadingInset: 18,
            trailingInset: 14
        ))

        let focusBlacklistItem = NSMenuItem(
            title: "Focus Prevention Blacklist",
            action: nil,
            keyEquivalent: ""
        )
        focusBlacklistItem.view = DockAwayMenuRowView(
            title: "Focus Prevention Blacklist",
            icon: NSImage(
                systemSymbolName: "hand.raised",
                accessibilityDescription: "Focus Prevention Blacklist"
            ),
            hasSubmenu: true,
            leadingInset: 18,
            titleLeadingAdjustment: 1,
            width: hoverActivationRowWidth
        )
        let focusBlacklistMenu = NSMenu(title: "Focus Prevention Blacklist")
        focusBlacklistMenu.autoenablesItems = false
        focusBlacklistMenu.delegate = self
        focusBlacklistItem.submenu = focusBlacklistMenu
        self.hoverActivationBlacklistMenu = focusBlacklistMenu
        rebuildHoverActivationBlacklistMenu()
        hoverActivationMenu.addItem(focusBlacklistItem)

        hoverActivationItem.submenu = hoverActivationMenu
        dockAwaySettingsMenu.addItem(hoverActivationItem)

        let displayOrderItem = NSMenuItem(title: "List Active Display on Top", action: nil, keyEquivalent: "")
        displayOrderItem.view = SubmenuLabelView.displayOrder()
        displayOrderItem.state = .on
        displayOrderItem.onStateImage = menuIcon(from: NSImage(
            systemSymbolName: "display",
            accessibilityDescription: "List Active Display on Top"
        ))
        let displayOrderMenu = NSMenu(title: displayOrderItem.title)
        displayOrderMenu.autoenablesItems = false
        displayOrderMenu.delegate = self

        let displayRowWidth: CGFloat = 210

        let numericalItem = NSMenuItem(title: DisplayListOrder.numerical.title, action: #selector(selectDisplayListOrder(_:)), keyEquivalent: "")
        numericalItem.representedObject = DisplayListOrder.numerical.rawValue
        let numericalRow = DockSettingPersistenceRowView(
            title: DisplayListOrder.numerical.title,
            isOn: DisplayListOrder.current == .numerical,
            width: displayRowWidth,
            leadingInset: 18,
            titleLeadingAdjustment: 1,
            font: .menuFont(ofSize: 13),
            indicatorSize: 16,
            multiline: false,
            helpHeading: DisplayListOrder.numerical.title,
            helpTextProvider: {
                "Maintains standard numerical order for all displays in Desktop Manager:\n[> Display 1 > Display 2 > Display 3]\n\n• Displays are always listed in ascending numerical order.\n• Keeps display order fixed and predictable regardless of pointer movement.\n• Turning this on turns off Active First ordering."
            }
        ) { [weak self] _ in
            self?.applyDisplayListOrderSelection(.numerical)
        }
        numericalItem.view = numericalRow
        displayOrderRows[.numerical] = numericalRow
        displayOrderMenu.addItem(numericalItem)

        let activeFirstItem = NSMenuItem(title: DisplayListOrder.activeFirst.title, action: #selector(selectDisplayListOrder(_:)), keyEquivalent: "")
        activeFirstItem.representedObject = DisplayListOrder.activeFirst.rawValue
        let activeFirstRow = DockSettingPersistenceRowView(
            title: DisplayListOrder.activeFirst.title,
            isOn: DisplayListOrder.current != .numerical,
            width: displayRowWidth,
            leadingInset: 18,
            titleLeadingAdjustment: 1,
            font: .menuFont(ofSize: 13),
            indicatorSize: 16,
            multiline: false,
            helpHeading: DisplayListOrder.activeFirst.title,
            helpTextProvider: {
                "Places the active display on top, with remaining displays in numerical order:\n[> Active Display > Display 1 > Display 2]\n\n• Positions the display containing your pointer at the top of Desktop Manager.\n• Remaining secondary displays follow in standard numerical sequence.\n• Automatically reorders as you move your pointer between monitors."
            }
        ) { [weak self] _ in
            self?.applyDisplayListOrderSelection(.activeFirst)
        }
        activeFirstItem.view = activeFirstRow
        displayOrderRows[.activeFirst] = activeFirstRow
        displayOrderMenu.addItem(activeFirstItem)

        displayOrderMenu.addItem(wideMenuSeparator(width: displayRowWidth, leadingInset: 18, trailingInset: 14))

        let lastUsedItem = NSMenuItem(title: DisplayListOrder.lastUsed.title, action: #selector(selectDisplayListOrder(_:)), keyEquivalent: "")
        lastUsedItem.representedObject = DisplayListOrder.lastUsed.rawValue
        let lastUsedRow = DockSettingPersistenceRowView(
            title: DisplayListOrder.lastUsed.title,
            isOn: DisplayListOrder.current == .lastUsed,
            width: displayRowWidth,
            leadingInset: 18,
            titleLeadingAdjustment: 1,
            font: .menuFont(ofSize: 13),
            indicatorSize: 16,
            multiline: false,
            helpHeading: DisplayListOrder.lastUsed.title,
            helpTextProvider: { [weak self] in
                guard let self else { return "" }
                let screenCount = max(NSScreen.screens.count, self.desktopDisplaySections.count)
                let hasThreeOrMore = screenCount >= 3
                let isActiveFirstOn = DisplayListOrder.current != .numerical
                if !isActiveFirstOn {
                    return "Orders remaining displays below the active display by recency:\n[> Active Display > Last Used (Display 2) > Last Used (Display 1)]\n\n• Currently disabled: Requires “Active First” to be enabled first.\n• With 3 or more displays connected, secondary displays sort by most recent focus."
                } else if !hasThreeOrMore {
                    return "Orders remaining displays below the active display by recency:\n[> Active Display > Last Used (Display 2) > Last Used (Display 1)]\n\n• Currently disabled: Requires 3 or more connected displays (currently \(screenCount)).\n• With 3 or more displays, secondary displays appear in order of last use."
                } else {
                    return "Orders remaining displays below the active display by recency:\n[> Active Display > Last Used (Display 2) > Last Used (Display 1)]\n\n• The most recently focused secondary display appears right below the active display.\n• Keeps your most relevant desktop spaces immediately accessible.\n• Automatically updates whenever you switch between displays."
                }
            }
        ) { [weak self] _ in
            self?.applyDisplayListOrderSelection(.lastUsed)
        }
        lastUsedItem.view = lastUsedRow
        displayOrderRows[.lastUsed] = lastUsedRow
        displayOrderMenu.addItem(lastUsedItem)

        self.displayOrderMenu = displayOrderMenu
        displayOrderItem.submenu = displayOrderMenu
        dockAwaySettingsMenu.addItem(displayOrderItem)
        refreshDisplayOrderMenu()

        let desktopIndicatorAppearanceItem = NSMenuItem(title: "Menubar Desktop Indicator", action: nil, keyEquivalent: "")
        desktopIndicatorAppearanceItem.view = SubmenuLabelView.desktopIndicatorAppearance()
        desktopIndicatorAppearanceItem.state = .on
        desktopIndicatorAppearanceItem.onStateImage = menuIcon(from: NSImage(
            systemSymbolName: "menubar.rectangle",
            accessibilityDescription: "Menubar Desktop Indicator"
        ))
        let desktopIndicatorAppearanceMenu = NSMenu(title: "Menubar Desktop Indicator")
        desktopIndicatorAppearanceMenu.autoenablesItems = false
        desktopIndicatorAppearanceMenu.delegate = self

        let tooltipSubmenuWidth: CGFloat = 280
        let desktopTooltipTitle = "Desktop Change Tooltip"
        let desktopChangeTooltipMenu = NSMenu(title: desktopTooltipTitle)
        desktopChangeTooltipMenu.autoenablesItems = false
        desktopChangeTooltipMenu.delegate = self
        self.desktopChangeTooltipMenu = desktopChangeTooltipMenu

        let tooltipDurationItem = NSMenuItem(title: "Display Duration", action: nil, keyEquivalent: "")
        let tooltipDurationView = DockSettingSliderView(
            title: "Display Duration",
            leadingTitle: "1 sec",
            trailingTitle: "10 sec",
            accessibilityLabel: "Tooltip display duration",
            accessibilityHelp: "Set how long the desktop change tooltip remains visible on screen.",
            width: tooltipSubmenuWidth,
            helpHeading: "Display Duration",
            helpTextProvider: {
                "Controls how long the desktop change tooltip stays on screen after switching desktops.\n\n• The tooltip appears centered below the menu bar on the active display.\n• Slide left for a shorter duration or right for a longer duration.\n• Default duration in DockAway is 4.0 seconds.\n• Changes apply immediately."
            }
        )
        tooltipDurationView.slider.minValue = DesktopChangeTooltip.minDuration
        tooltipDurationView.slider.maxValue = DesktopChangeTooltip.maxDuration
        tooltipDurationView.slider.snapMarkerValues = [DesktopChangeTooltip.defaultDuration]
        tooltipDurationView.slider.target = self
        tooltipDurationView.slider.action = #selector(previewDesktopChangeTooltipDuration(_:))
        tooltipDurationView.slider.commitHandler = { [weak self] val in
            let duration = (val * 10).rounded() / 10
            DesktopChangeTooltip.duration = duration
            self?.refreshDesktopChangeTooltipMenu()
        }
        tooltipDurationItem.view = tooltipDurationView
        self.desktopChangeTooltipDurationSliderView = tooltipDurationView
        desktopChangeTooltipMenu.addItem(tooltipDurationItem)

        desktopChangeTooltipMenu.addItem(wideMenuSeparator(
            width: tooltipSubmenuWidth,
            leadingInset: 18,
            trailingInset: 14
        ))

        let displayUnderneathTitle = "Place Display Name Underneath"
        let displayUnderneathItem = NSMenuItem(title: displayUnderneathTitle, action: nil, keyEquivalent: "")
        let displayUnderneathRow = DockSettingToggleRowView(
            title: displayUnderneathTitle,
            isOn: DesktopChangeTooltip.isDisplayUnderneath,
            width: tooltipSubmenuWidth,
            leadingInset: 18,
            trailingInset: 12
        ) { [weak self] enabled in
            DesktopChangeTooltip.isDisplayUnderneath = enabled
            self?.desktopChangeTooltip.resetPanel()
            self?.refreshDesktopChangeTooltipMenu()
        }
        displayUnderneathRow.autoresizingMask = [.width]
        displayUnderneathItem.view = displayUnderneathRow
        self.desktopChangeTooltipDisplayUnderneathRowView = displayUnderneathRow
        desktopChangeTooltipMenu.addItem(displayUnderneathItem)

        for appearance in [DesktopIndicatorAppearance.systemText] {
            let item = NSMenuItem()
            item.tag = -105
            let indicatorRow = DesktopIndicatorPreviewRow(title: "Menubar Desktop Indicator")
            indicatorRow.onPreviewClick = { [weak self] point in
                guard let self, !self.desktopDisplaySections.isEmpty else { return }
                let sections = self.orderedIndicatorSections
                let count = sections.count
                let stacked = UserDefaults.standard.object(forKey: "stackDisplayIndicators") as? Bool ?? true
                let rows = stacked && count > 1 ? DisplayIndicatorGroup.rowIndices(count: count) : [Array(0..<count)]
                let row = rows[min(rows.count - 1, max(0, Int(point.y * CGFloat(rows.count))))]
                var column = min(row.count - 1, max(0, Int(point.x * CGFloat(row.count))))
                if !stacked || count == 1 {
                    let widths = sections.map { section -> CGFloat in
                        let snapshot = section.snapshot
                        let number = snapshot.desktopIDs.firstIndex(of: snapshot.currentID)
                        let entry = DisplayIndicatorGroup.Entry(name: section.name,
                            builtIn: CGDisplayIsBuiltin(snapshot.displayID) != 0,
                            current: (number ?? 0) + 1, total: snapshot.desktopIDs.count, fullscreen: number == nil,
                            appearance: self.displayTextStyle(self.indicatorDisplayKey(snapshot.displayID)))
                        return DisplayIndicatorGroup.text(entries: [entry], style: self.globalDesktopTextStyle, stacked: false).size().width
                    }
                    let gap = (" " as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9)]).width
                    let total = widths.reduce(0, +) + gap * CGFloat(max(0, count - 1))
                    let x = point.x * (total + 16) - 8
                    var right: CGFloat = 0
                    for (index, width) in widths.enumerated() {
                        right += width + gap
                        if x < right { column = index; break }
                    }
                }
                let index = row[column]
                self.indicatorEditingDisplay = self.indicatorDisplayKey(sections[index].snapshot.displayID)
                self.refreshDesktopIndicatorAppearanceMenu()
            }
            indicatorRow.onToggle = { [weak self] enabled in
                guard let self else { return }
                self.saveCleanDesktopTextStyle(self.cleanDesktopTextStyle)
                DesktopIndicatorPreference.setEnabled(enabled)
                self.desktopChangeTooltip.dismiss(animated: true)
                self.pendingDisplayLayoutRefresh = true
                self.updateMenuBarDesktopBadge(liveCustomization: true)
            }
            item.view = indicatorRow
            desktopIndicatorAppearanceMenu.addItem(item)

            let desktopTooltipItem = NSMenuItem(title: desktopTooltipTitle, action: nil, keyEquivalent: "")
            desktopTooltipItem.tag = -108
            let desktopTooltipRow = DockSettingToggleRowView(
                title: desktopTooltipTitle,
                isOn: UserDefaults.standard.bool(forKey: DesktopChangeTooltip.preferenceKey),
                width: 280,
                leadingInset: 20,
                trailingInset: 12,
                hasSubmenu: true
            ) { [weak self] enabled in
                UserDefaults.standard.set(enabled, forKey: DesktopChangeTooltip.preferenceKey)
                if !enabled {
                    self?.desktopChangeTooltip.dismiss()
                }
                self?.refreshDesktopChangeTooltipMenu()
                self?.refreshDesktopIndicatorAppearanceMenu()
            }
            desktopTooltipRow.autoresizingMask = [.width]
            desktopTooltipItem.view = desktopTooltipRow
            self.desktopChangeTooltipRowView = desktopTooltipRow
            desktopTooltipItem.submenu = desktopChangeTooltipMenu
            desktopIndicatorAppearanceMenu.addItem(desktopTooltipItem)

            let targetItem = NSMenuItem(title: "Customize: All Displays", action: nil, keyEquivalent: "")
            targetItem.tag = -106
            targetItem.view = SubmenuLabelView.customizeDisplays()
            targetItem.submenu = NSMenu()
            targetItem.submenu?.autoenablesItems = false
            desktopIndicatorAppearanceMenu.addItem(targetItem)
            let targetSeparator = NSMenuItem.separator()
            targetSeparator.tag = -107
            desktopIndicatorAppearanceMenu.addItem(targetSeparator)
            if appearance == .systemText {
                let optionsItem = NSMenuItem()
                optionsItem.tag = -100
                let options = DesktopIndicatorStyleOptionsView(frame: .zero)
                let appearanceControlWidth = options.intrinsicContentSize.width
                options.onChange = { [weak self] option, enabled in
                    guard let self else { return }
                    var style = self.cleanDesktopTextStyle
                    if option == 11 {
                        UserDefaults.standard.set(enabled, forKey: "activeDisplayIndicatorFirst")
                        self.configureDisplayAccentTracking()
                        self.pendingDisplayLayoutRefresh = true
                        self.updateMenuBarDesktopBadge(liveCustomization: true)
                        return
                    }
                    if option == 12 {
                        style.pillOnlyWhenActive = enabled
                        if enabled {
                            style.encapsulatesDockIndicator = false
                        }
                        self.saveCleanDesktopTextStyle(style)
                        self.configureDisplayAccentTracking()
                        self.pendingDisplayLayoutRefresh = true
                        self.updateMenuBarDesktopBadge(liveCustomization: true)
                        return
                    }
                    if option == 7 {
                        style.encapsulatesDockIndicator = enabled
                        if enabled {
                            style.pillOnlyWhenActive = false
                        }
                        self.saveCleanDesktopTextStyle(style)
                        self.pendingDisplayLayoutRefresh = true
                        self.updateMenuBarDesktopBadge(liveCustomization: true)
                        return
                    }
                    if option == 8 {
                        guard !enabled || style.badge != .none else { return }
                        style.accentOnlyWhenActive = enabled
                        if enabled {
                            // Untoggle Accent Color: both can't be on at the same time
                            style.usesAccentColor = false
                        }
                        self.saveCleanDesktopTextStyle(style)
                        self.configureDisplayAccentTracking()
                        self.pendingDisplayLayoutRefresh = true
                        self.updateMenuBarDesktopBadge(liveCustomization: true)
                        return
                    }
                    if option == 9 {
                        UserDefaults.standard.set(enabled, forKey: "stackDisplayIndicators")
                        self.pendingDisplayLayoutRefresh = true
                        self.updateMenuBarDesktopBadge(liveCustomization: true)
                        return
                    }
                    if option == 3 && enabled {
                        // Accent Color turned ON -> untoggle Accented Active Display Count
                        style.accentOnlyWhenActive = false
                        self.pendingDisplayLayoutRefresh = true
                    }
                    style.setOption(option, enabled: enabled)
                    if option == 5 && enabled {
                        if self.desktopDisplaySections.count >= 2 && self.indicatorEditingDisplay == nil {
                            style.encapsulatesDockIndicator = true
                            style.pillOnlyWhenActive = false
                        }
                    }
                    if style.badge == .none { style.fillOnlyWhenActive = false }
                    if (option == 0 || option == 1) && style.badge == .none {
                        style.accentOnlyWhenActive = false
                    }
                    self.saveCleanDesktopTextStyle(style)
                    self.configureDisplayAccentTracking()
                    self.updateMenuBarDesktopBadge(liveCustomization: true)
                }
                let separatorMenu = DesktopIndicatorSeparatorMenu()
                separatorMenu.onChange = { [weak self] separator in
                    guard let self else { return }
                    var style = self.cleanDesktopTextStyle
                    style.separator = separator
                    self.saveCleanDesktopTextStyle(style)
                    self.updateMenuBarDesktopBadge(liveCustomization: true)
                }
                optionsItem.view = options
                desktopIndicatorAppearanceMenu.addItem(optionsItem)
                let opacityItem = NSMenuItem()
                opacityItem.tag = -102
                let opacityView = DockSettingSliderView(
                    title: "Pill Opacity", leadingTitle: "Transparent", trailingTitle: "Opaque",
                    accessibilityLabel: "Pill opacity",
                    accessibilityHelp: "Adjust the pill background opacity. The default is 8 percent.",
                    width: appearanceControlWidth,
                    helpHeading: "Pill Opacity",
                    helpTextProvider: {
                        "Adjusts the background opacity of the desktop indicator pill container.\n\n• Slide left for subtle translucent glass or right for solid tinting.\n• Integrates smoothly with both Light and Dark mode menu bars.\n• macOS default is 8% opacity."
                    }
                )
                opacityView.slider.target = self
                opacityView.slider.action = #selector(previewIndicatorPillOpacity(_:))
                opacityView.slider.commitHandler = { [weak self] percentage in
                    self?.setIndicatorPillOpacity(percentage)
                }
                opacityItem.view = opacityView
                opacityItem.isHidden = !cleanDesktopTextStyle.usesPill
                desktopIndicatorAppearanceMenu.addItem(opacityItem)

                let cornerRadiusItem = NSMenuItem()
                cornerRadiusItem.tag = -104
                let cornerRadiusView = DockSettingSliderView(
                    title: "Pill Corner Radius",
                    leadingTitle: "Square",
                    trailingTitle: "Round",
                    accessibilityLabel: "Pill corner radius",
                    accessibilityHelp: "Adjust the pill from square corners to fully rounded corners.",
                    width: appearanceControlWidth,
                    helpHeading: "Pill Corner Radius",
                    helpTextProvider: {
                        "Changes the curvature of the desktop indicator pill.\n\n• Slide left for square corners.\n• Slide right for a fully rounded capsule.\n• Every position between them updates smoothly in real time."
                    }
                )
                cornerRadiusView.slider.target = self
                cornerRadiusView.slider.action = #selector(previewIndicatorPillCornerRadius(_:))
                cornerRadiusView.slider.commitHandler = { [weak self] percentage in
                    self?.setIndicatorPillCornerRadius(percentage)
                }
                cornerRadiusItem.view = cornerRadiusView
                cornerRadiusItem.isHidden = !cleanDesktopTextStyle.usesPill
                desktopIndicatorAppearanceMenu.addItem(cornerRadiusItem)

                let paddingItem = NSMenuItem()
                paddingItem.tag = -103
                let paddingView = PillPaddingSlidersView(width: appearanceControlWidth)
                paddingView.horizontalSlider.target = self
                paddingView.horizontalSlider.action = #selector(previewIndicatorPillPaddingHorizontal(_:))
                paddingView.horizontalSlider.commitHandler = { [weak self] value in
                    self?.setIndicatorPillPadding(value)
                }
                paddingItem.view = paddingView
                paddingItem.isHidden = !cleanDesktopTextStyle.usesPill
                desktopIndicatorAppearanceMenu.addItem(paddingItem)
                desktopIndicatorAppearanceMenu.addItem(.separator())
                let separatorItem = NSMenuItem(title: "Indicator Separator", action: nil, keyEquivalent: "")
                separatorItem.tag = -101
                separatorItem.view = SubmenuLabelView.indicatorSeparator()
                separatorItem.submenu = separatorMenu
                desktopIndicatorAppearanceMenu.addItem(separatorItem)

                let numberStyleMenu = DesktopNumberIndicatorMenu()
                numberStyleMenu.onChange = { [weak self] in
                    guard let self else { return }
                    self.updateDockAwayMenuState()
                    self.updateMenuBarDesktopBadge(liveCustomization: true)
                }
                let numberStyleItem = NSMenuItem(title: "Desktop Manager Number Style", action: nil, keyEquivalent: "")
                numberStyleItem.tag = -109
                numberStyleItem.view = SubmenuLabelView.desktopNumberIndicator()
                numberStyleItem.submenu = numberStyleMenu
                desktopIndicatorAppearanceMenu.addItem(numberStyleItem)
            }
        }
        desktopIndicatorAppearanceItem.submenu = desktopIndicatorAppearanceMenu

        let missionControlItem = NSMenuItem(title: "macOS Mission Control Enhancements", action: nil, keyEquivalent: "")
        missionControlItem.view = SubmenuLabelView.missionControl()
        missionControlItem.state = .on
        missionControlItem.onStateImage = menuIcon(from: NSImage(
            systemSymbolName: "rectangle.3.group",
            accessibilityDescription: "macOS Mission Control Enhancements"
        ))
        let missionControlMenu = NSMenu(title: "macOS Mission Control Enhancements")
        missionControlMenu.delegate = self
        missionControlMenu.autoenablesItems = false

        let expandTitle = "Auto-expand Desktop Strip"
        let closeWindowsTitle = "Close Windows in Mission Control"
        let keyboardTitle = "Use Keyboard Shortcuts in MC"
        let expandItem = NSMenuItem(title: expandTitle, action: nil, keyEquivalent: "")
        let missionControlRowWidth = ceil([expandTitle, closeWindowsTitle, keyboardTitle].map {
            ($0 as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 13)]).width
        }.max() ?? 0) + 90 // Widen menu row so the help buttons and separator align cleanly with comfortable padding.
        expandItem.view = DockSettingPersistenceRowView(
            title: expandTitle,
            isOn: UserDefaults.standard.bool(forKey: MissionControlAutoExpand.preferenceKey),
            width: missionControlRowWidth, leadingInset: 18, titleLeadingAdjustment: 1,
            font: .menuFont(ofSize: 13), indicatorSize: 16, multiline: false,
            helpHeading: "Auto-expand Desktop Strip",
            helpTextProvider: {
                "Automatically expands the desktop thumbnail strip immediately upon entering Mission Control.\n\n• No need to move your pointer to the top edge to see spaces.\n• Smoothly centers your mouse pointer on the active display so you can click any desktop instantly.\n• Respects trackpad gesture direction and cancels cleanly when dismissed."
            }
        ) { enabled in
            UserDefaults.standard.set(enabled, forKey: MissionControlAutoExpand.preferenceKey)
        }
        missionControlMenu.addItem(expandItem)
        let closeWindowsItem = NSMenuItem()
        closeWindowsItem.view = DockSettingPersistenceRowView(
            title: closeWindowsTitle,
            isOn: UserDefaults.standard.bool(forKey: MissionControlWindowClose.preferenceKey),
            width: missionControlRowWidth, leadingInset: 18, titleLeadingAdjustment: 1,
            font: .menuFont(ofSize: 13), indicatorSize: 16, multiline: false,
            helpHeading: "Close Windows in Mission Control",
            helpTextProvider: {
                "Displays a native red close button on the hovered window while in Mission Control.\n\n• Hover over any window to reveal the close button in its upper-left corner.\n• Closes only that specific window, leaving the rest of the application open.\n• Stays hidden while dragging windows between desktops or spaces."
            }
        ) { [weak self] enabled in
            UserDefaults.standard.set(enabled, forKey: MissionControlWindowClose.preferenceKey)
            self?.dockWatcher?.refreshMissionControlClosePreference()
        }
        missionControlMenu.addItem(closeWindowsItem)
        missionControlMenu.addItem(wideMenuSeparator(width: missionControlRowWidth, leadingInset: 18, trailingInset: 14))
        let keyboardItem = NSMenuItem()
        keyboardItem.identifier = NSUserInterfaceItemIdentifier("missionControlKeyboardCommands")
        let keyboardRowView = DockSettingPersistenceRowView(
            title: keyboardTitle,
            isOn: UserDefaults.standard.bool(forKey: MissionControlWindowClose.keyboardPreferenceKey),
            width: missionControlRowWidth, leadingInset: 18, titleLeadingAdjustment: 1,
            font: .menuFont(ofSize: 13), indicatorSize: 16,
            helpHeading: "Use Keyboard Shortcuts in MC",
            helpTextProvider: { [weak self] in
                self?.dockWatcher?.missionControlKeyboardCommandsToolTip
                    ?? MissionControlWindowClose.shortcutHelp(appName: nil, shortcuts: [])
            }
        ) { [weak self] enabled in
            UserDefaults.standard.set(enabled, forKey: MissionControlWindowClose.keyboardPreferenceKey)
            self?.dockWatcher?.refreshMissionControlClosePreference()
        }
        keyboardItem.view = keyboardRowView
        missionControlMenu.addItem(keyboardItem)
        missionControlItem.submenu = missionControlMenu
        dockAwaySettingsMenu.addItem(desktopIndicatorAppearanceItem)
        dockAwaySettingsMenu.addItem(missionControlItem)

        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.view = SubmenuLabelView.theme()
        themeItem.state = .on
        themeItem.onStateImage = menuIcon(from: NSImage(
            systemSymbolName: "paintpalette",
            accessibilityDescription: "Theme"
        ))
        let themeMenu = NSMenu(title: "Theme")
        for theme in DockAwayTheme.allCases {
            let item = NSMenuItem(title: theme.title, action: #selector(selectDockAwayTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = theme.rawValue
            item.state = theme == DockAwayTheme.current ? .on : .off
            themeMenu.addItem(item)
        }
        themeItem.submenu = themeMenu
        dockAwaySettingsMenu.addItem(themeItem)

        let extrasItem = NSMenuItem(title: "Extras", action: nil, keyEquivalent: "")
        extrasItem.view = DockAwayMenuRowView(
            title: "Extras",
            icon: NSImage(
                systemSymbolName: "ellipsis.circle",
                accessibilityDescription: "Extras"
            ),
            hasSubmenu: true,
            leadingInset: 12,
            titleLeadingAdjustment: 2,
            width: settingsRowWidth
        )
        extrasItem.state = .on
        extrasItem.onStateImage = menuIcon(from: NSImage(
            systemSymbolName: "ellipsis.circle",
            accessibilityDescription: "Extras"
        ))
        let extrasMenu = NSMenu(title: "Extras")
        extrasMenu.autoenablesItems = false

        let mutedSoundTitle = "Show Sound Icon When Muted"
        let mutedSoundItem = NSMenuItem(title: mutedSoundTitle, action: nil, keyEquivalent: "")
        let mutedSoundRow = DockSettingPersistenceRowView(
            title: mutedSoundTitle,
            isOn: UserDefaults.standard.bool(forKey: MutedVolumeMenuBarController.preferenceKey),
            width: settingsRowWidth,
            leadingInset: 18,
            trailingInset: 12,
            titleLeadingAdjustment: 1,
            indicatorSize: 16,
            helpHeading: mutedSoundTitle,
            helpTextProvider: {
                "Uses the native macOS Sound menu bar icon. Set Sound to Show When Active in System Settings first.\n\nWhile muted or at zero volume, DockAway switches Sound to Always Show. When audible again, it restores Show When Active. macOS may still show the icon during audio activity.\n\nDisabling this option or quitting restores Show When Active. Changing the Sound visibility setting manually disables this option."
            }
        ) { [weak self] enabled in
            guard let self else { return }
            let accepted = self.mutedVolumeMenuBarController.setEnabled(enabled)
            self.mutedVolumeMenuBarRow?.setOn(enabled && accepted)
            if !accepted {
                let alert = NSAlert()
                alert.messageText = "Set Sound to Show When Active"
                alert.informativeText = "In System Settings, open Menu Bar (or Control Center on older macOS versions) and set Sound to Show When Active. Then enable this option again."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
        mutedSoundRow.autoresizingMask = [.width]
        mutedSoundItem.view = mutedSoundRow
        mutedVolumeMenuBarRow = mutedSoundRow
        extrasMenu.addItem(mutedSoundItem)

        let lockSoundTitle = "Lockscreen Lock Sound"
        let lockSoundItem = NSMenuItem(title: lockSoundTitle, action: nil, keyEquivalent: "")
        let lockSoundRow = DockSettingPersistenceRowView(
            title: lockSoundTitle,
            isOn: UserDefaults.standard.bool(forKey: LockscreenSoundPlayer.Event.lock.preferenceKey),
            width: settingsRowWidth,
            leadingInset: 18,
            trailingInset: 12,
            titleLeadingAdjustment: 1,
            indicatorSize: 16,
            helpHeading: lockSoundTitle,
            helpTextProvider: {
                "Plays a sound whenever you lock your Mac.\n\n• Uses your current sound output and volume.\n• Works while DockAway is running."
            }
        ) { [weak self] enabled in
            UserDefaults.standard.set(enabled, forKey: LockscreenSoundPlayer.Event.lock.preferenceKey)
            self?.lockSoundRowView?.setOn(enabled)
            if enabled {
                self?.lockscreenSoundPlayer.play(.lock)
            }
        }
        lockSoundRow.autoresizingMask = [.width]
        lockSoundItem.view = lockSoundRow
        self.lockSoundRowView = lockSoundRow
        extrasMenu.addItem(lockSoundItem)

        let unlockSoundTitle = "Lockscreen Unlock Sound"
        let unlockSoundItem = NSMenuItem(title: unlockSoundTitle, action: nil, keyEquivalent: "")
        let unlockSoundRow = DockSettingPersistenceRowView(
            title: unlockSoundTitle,
            isOn: UserDefaults.standard.bool(forKey: LockscreenSoundPlayer.Event.unlock.preferenceKey),
            width: settingsRowWidth,
            leadingInset: 18,
            trailingInset: 12,
            titleLeadingAdjustment: 1,
            indicatorSize: 16,
            helpHeading: unlockSoundTitle,
            helpTextProvider: {
                "Plays a sound whenever you unlock your Mac.\n\n• Uses your current sound output and volume.\n• Works while DockAway is running."
            }
        ) { [weak self] enabled in
            UserDefaults.standard.set(enabled, forKey: LockscreenSoundPlayer.Event.unlock.preferenceKey)
            self?.unlockSoundRowView?.setOn(enabled)
            if enabled {
                self?.lockscreenSoundPlayer.play(.unlock)
            }
        }
        unlockSoundRow.autoresizingMask = [.width]
        unlockSoundItem.view = unlockSoundRow
        self.unlockSoundRowView = unlockSoundRow
        extrasMenu.addItem(unlockSoundItem)

        extrasMenu.addItem(wideMenuSeparator(width: settingsRowWidth, leadingInset: 18, trailingInset: 14))

        let screenshotClipboardTitle = "Save Screenshots to Clipboard"
        let screenshotClipboardItem = NSMenuItem(title: screenshotClipboardTitle, action: nil, keyEquivalent: "")
        let screenshotClipboardRow = DockSettingPersistenceRowView(
            title: screenshotClipboardTitle,
            isOn: screenshotClipboardManager.isEnabled,
            width: settingsRowWidth,
            leadingInset: 18,
            trailingInset: 12,
            titleLeadingAdjustment: 1,
            indicatorSize: 16,
            helpHeading: screenshotClipboardTitle,
            helpTextProvider: {
                "Automatically copies newly captured screenshots to your clipboard.\n\n• Immediately paste (⌘V) your screenshot anywhere.\n• Screenshots are still saved to your folder as usual.\n• Works with standard macOS screenshot shortcuts.\n• macOS natively captures all displays, but DockAway clips the screenshot from the display your mouse is on."
            }
        ) { [weak self] enabled in
            self?.screenshotClipboardManager.isEnabled = enabled
            self?.screenshotClipboardRowView?.setOn(enabled)
        }
        screenshotClipboardRow.autoresizingMask = [.width]
        screenshotClipboardItem.view = screenshotClipboardRow
        self.screenshotClipboardRowView = screenshotClipboardRow
        extrasMenu.addItem(screenshotClipboardItem)

        let greenButtonFillTitle = "Green Button Fills Window"
        let greenButtonFillItem = NSMenuItem(title: greenButtonFillTitle, action: nil, keyEquivalent: "")
        let greenButtonFillRow = DockSettingPersistenceRowView(
            title: greenButtonFillTitle,
            isOn: UserDefaults.standard.bool(forKey: GreenButtonFillController.preferenceKey),
            width: settingsRowWidth,
            leadingInset: 18,
            trailingInset: 12,
            helpHeading: greenButtonFillTitle,
            helpTextProvider: {
                "Makes a normal click on the green macOS traffic-light button fill the window instead of entering full screen.\n\nHold Option while clicking the green button to enter full screen."
            }
        ) { [weak self] enabled in
            UserDefaults.standard.set(enabled, forKey: GreenButtonFillController.preferenceKey)
            self?.greenButtonFillRowView?.setOn(enabled)
            self?.refreshGreenButtonFillController()
        }
        greenButtonFillRow.autoresizingMask = [.width]
        greenButtonFillItem.view = greenButtonFillRow
        self.greenButtonFillRowView = greenButtonFillRow
        extrasMenu.addItem(greenButtonFillItem)

        let finderDeleteKeyTitle = "Delete Finder Items with Delete Key"
        let finderDeleteKeyItem = NSMenuItem(
            title: finderDeleteKeyTitle,
            action: nil,
            keyEquivalent: ""
        )
        let finderDeleteKeyRow = DockSettingPersistenceRowView(
            title: finderDeleteKeyTitle,
            isOn: UserDefaults.standard.bool(
                forKey: FinderDeleteKeyController.preferenceKey
            ),
            width: settingsRowWidth,
            leadingInset: 18,
            trailingInset: 12,
            titleLeadingAdjustment: 1,
            indicatorSize: 16,
            helpHeading: finderDeleteKeyTitle,
            helpTextProvider: {
                "Press Delete in Finder to move the selected files or folders to Trash, without holding Command.\n\n• Uses Finder's native Move to Trash command.\n• Rename fields, search fields, dialogs, and modified shortcuts keep their normal Delete-key behavior.\n• Holding Delete triggers the action only once per key press."
            }
        ) { [weak self] enabled in
            UserDefaults.standard.set(
                enabled,
                forKey: FinderDeleteKeyController.preferenceKey
            )
            self?.finderDeleteKeyRowView?.setOn(enabled)
            self?.refreshFinderDeleteKeyController()
        }
        finderDeleteKeyRow.autoresizingMask = [.width]
        finderDeleteKeyItem.view = finderDeleteKeyRow
        self.finderDeleteKeyRowView = finderDeleteKeyRow
        extrasMenu.addItem(finderDeleteKeyItem)

        let quickLookOrientationTitle = "Correct Quick Look Copy Orientation"
        let quickLookOrientationItem = NSMenuItem(
            title: quickLookOrientationTitle,
            action: nil,
            keyEquivalent: ""
        )
        let quickLookOrientationRow = DockSettingPersistenceRowView(
            title: quickLookOrientationTitle,
            isOn: UserDefaults.standard.bool(
                forKey: QuickLookCopyOrientationManager.preferenceKey
            ),
            width: settingsRowWidth,
            leadingInset: 18,
            trailingInset: 12,
            titleLeadingAdjustment: 1,
            indicatorSize: 16,
            helpHeading: quickLookOrientationTitle,
            helpTextProvider: {
                "Keeps images copied from Finder's Quick Look in their displayed orientation.\n\n• Applies the image's built-in orientation before placing it on the clipboard.\n• Prevents pasted images from turning sideways.\n• Regular Finder file copies and images copied from other apps are unchanged."
            }
        ) { [weak self] enabled in
            UserDefaults.standard.set(
                enabled,
                forKey: QuickLookCopyOrientationManager.preferenceKey
            )
            self?.quickLookCopyOrientationRowView?.setOn(enabled)
            self?.refreshQuickLookCopyOrientationManager()
        }
        quickLookOrientationRow.autoresizingMask = [.width]
        quickLookOrientationItem.view = quickLookOrientationRow
        self.quickLookCopyOrientationRowView = quickLookOrientationRow
        extrasMenu.addItem(quickLookOrientationItem)

        extrasItem.submenu = extrasMenu
        dockAwaySettingsMenu.addItem(extrasItem)

        let advancedItem = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        advancedItem.view = DockAwayMenuRowView(
            title: "Advanced",
            icon: NSImage(
                systemSymbolName: "gearshape.2",
                accessibilityDescription: "Advanced"
            ),
            hasSubmenu: true,
            leadingInset: 12,
            titleLeadingAdjustment: 2,
            width: settingsRowWidth
        )
        advancedItem.state = .on
        advancedItem.onStateImage = menuIcon(from: NSImage(
            systemSymbolName: "gearshape.2",
            accessibilityDescription: "Advanced"
        ))
        let advancedMenu = NSMenu(title: "Advanced")
        advancedMenu.autoenablesItems = false

        let webAppsTitle = "Open Web Apps & Finder on Active Desktop"
        let webAppsItem = NSMenuItem(title: webAppsTitle, action: nil, keyEquivalent: "")
        let advancedRowWidth = ceil(
            (webAppsTitle as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 13)]).width
        ) + 90
        let advancedMenuWidth = max(settingsRowWidth, advancedRowWidth)
        let webAppsRow = DockSettingPersistenceRowView(
            title: webAppsTitle,
            isOn: ChromiumWebAppPlacementController.isEnabled,
            width: advancedMenuWidth,
            leadingInset: 18,
            trailingInset: 12,
            titleLeadingAdjustment: 1,
            indicatorSize: 16,
            helpHeading: webAppsTitle,
            helpTextProvider: {
                "Opens Chromium web apps (Google Maps, Messages, etc.) and Finder/Trash windows on your current desktop and display instead of grouping or opening them on another monitor.\n\n• Prevents web apps and Finder from pulling you away to a different Space or monitor.\n• Automatically places newly opened windows where your mouse is.\n• Centers the window cleanly on your active display."
            }
        ) { [weak self] enabled in
            ChromiumWebAppPlacementController.isEnabled = enabled
            self?.chromiumWebAppPlacementRowView?.setOn(enabled)
            self?.refreshChromiumWebAppPlacementController()
        }
        webAppsRow.autoresizingMask = [.width]
        webAppsItem.view = webAppsRow
        self.chromiumWebAppPlacementRowView = webAppsRow
        advancedMenu.addItem(webAppsItem)

        advancedMenu.addItem(.separator())
        let restartItem = NSMenuItem(title: "Restart Dock", action: nil, keyEquivalent: "")
        let restartRow = DockAwayMenuRowView(
            title: "Restart Dock",
            icon: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Restart Dock"),
            leadingInset: 18,
            titleLeadingAdjustment: 1,
            width: advancedMenuWidth,
            helpHeading: "Restart Dock",
            helpTextProvider: {
                "Use this if the Dock stops appearing or responding. The Dock and Mission Control briefly disappear while macOS relaunches them.\n\n• Your Dock preferences, open apps, and desktops are preserved.\n• Only the Dock for your current login is restarted.\n• DockAway pauses its Dock monitoring and resumes when the replacement is ready."
            }
        ) { [weak self] in self?.restartDockFromAdvanced() }
        restartItem.view = restartRow
        restartItem.target = restartRow
        restartItem.action = #selector(DockAwayMenuRowView.performMenuAction(_:))
        advancedMenu.addItem(restartItem)
        restartDockMenuItem = restartItem
        restartDockRowView = restartRow
        advancedSettingsMenu = advancedMenu
        refreshRestartDockAction()

        advancedItem.submenu = advancedMenu
        dockAwaySettingsMenu.addItem(advancedItem)

        dockAwaySettingsItem.submenu = dockAwaySettingsMenu
        self.desktopIndicatorAppearanceMenu = desktopIndicatorAppearanceMenu
        refreshDesktopIndicatorAppearanceMenu()
        menu.addItem(dockAwaySettingsItem)

        let aboutMenuItem = NSMenuItem(title: "About DockAway", action: #selector(showAbout), keyEquivalent: "")
        aboutMenuItem.target = self
        aboutMenuItem.view = DockAwayMenuRowView(
            title: "About DockAway",
            leadingInset: 12,
            titleLeadingAdjustment: 2,
            actionHandler: { [weak self] in
                self?.showAbout()
            }
        )
        menu.addItem(aboutMenuItem)

        let quitMenuItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitMenuItem.target = self
        quitMenuItem.state = .on
        quitMenuItem.onStateImage = menuIcon(from: NSImage(
            systemSymbolName: "power",
            accessibilityDescription: "Quit DockAway"
        ))
        quitMenuItem.view = DockAwayMenuRowView(
            title: "Quit",
            icon: NSImage(
                systemSymbolName: "power",
                accessibilityDescription: "Quit DockAway"
            ),
            shortcut: "⌘Q",
            leadingInset: 12,
            titleLeadingAdjustment: 2,
            actionHandler: { [weak self] in
                self?.quit()
            }
        )
        menu.addItem(quitMenuItem)

        installDesktopMenuDelegates(in: menu)
        statusItem.menu = menu
        DockAwayTheme.current.apply(to: menu)
        statusItem.button?.appearance = DockAwayTheme.current.appearance
    }

    // MARK: - Desktop Manager Setting

    private func setDesktopManagerEnabled(_ enabled: Bool) {
        isDesktopManagerEnabled = enabled
        desktopManagerRowView?.setOn(enabled)
        permissionSetupDesktopManagerRowView?.setOn(enabled)

        let shouldAnimate = statusMenuIsOpen
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if enabled {
            desktopTilesView?.prepareForExpand()
            refreshDesktopTiles()
            desktopTilesMenuItem?.isHidden = false
            statusItem.menu?.update()
            desktopTilesView?.animateVisibility(expand: true, animated: shouldAnimate, onFrame: { [weak self] in
                self?.statusItem.menu?.update()
            }, completion: { [weak self] in
                self?.statusItem.menu?.update()
                if self?.statusMenuIsOpen == true {
                    self?.beginDesktopIconRefresh()
                }
            })
        } else {
            desktopIconRefreshTask?.cancel()
            desktopIconRefreshTask = nil
            desktopTilesView?.cancelActiveDrag(animated: false)

            desktopTilesView?.animateVisibility(expand: false, animated: shouldAnimate, onFrame: { [weak self] in
                self?.statusItem.menu?.update()
            }, completion: { [weak self] in
                self?.desktopTilesMenuItem?.isHidden = true
                self?.statusItem.menu?.update()
            })
        }
        if !shouldAnimate {
            statusItem.menu?.update()
        }
    }

    private func setupOpenShortcutHotKey() {
        let hotKey = DockAwayHotKey { [weak self] in
            self?.toggleStatusMenuFromShortcut()
        }
        openShortcutHotKey = hotKey
        if isOpenShortcutEnabled && KeyboardNavigationPreferences.isEnabled {
            hotKey.enable()
        }
    }

    private func toggleStatusMenuFromShortcut() {
        guard !isQuitting else { return }
        if statusMenuIsOpen {
            statusItem?.menu?.cancelTracking()
        } else {
            statusItem?.button?.performClick(nil)
        }
    }

    private func setTeleportCursorEnabled(_ enabled: Bool) {
        isTeleportCursorEnabled = enabled
        teleportCursorRowView?.setOn(enabled)
    }

    private func setTeleportWindowMoveEnabled(_ enabled: Bool) {
        isTeleportWindowMoveEnabled = enabled
        teleportWindowMoveRowView?.setOn(enabled)
    }

    private func setKeyboardNavigationEnabled(_ enabled: Bool) {
        KeyboardNavigationPreferences.isEnabled = enabled
        applyKeyboardNavigationEnabledState()
    }

    private func applyKeyboardNavigationEnabledState() {
        let enabled = KeyboardNavigationPreferences.isEnabled
        isOpenShortcutEnabled = enabled
        keyboardNavigationEnabledRowView?.setOn(enabled)
        if enabled {
            openShortcutHotKey?.enable()
        } else {
            openShortcutHotKey?.disable()
        }
        refreshKeyboardNavigationMenu()
    }

    private func setKeyboardNavigationHandEnabled(_ hand: NavigationHand, enabled: Bool) {
        let wasEnabled = KeyboardNavigationPreferences.isHandEnabled(hand)
        KeyboardNavigationPreferences.setHandEnabled(hand, enabled: enabled)

        if wasEnabled && !enabled {
            // A held delete/create key must not keep repeating after its hand is disabled.
            cancelContinuousDelete()
            cancelContinuousAdd()
        }

        applyKeyboardNavigationEnabledState()
        openShortcutHotKey?.reloadHotKeys()
        refreshKeyboardNavigationMenu()
    }

    private func refreshKeyboardNavigationMenu() {
        let isEnabled = KeyboardNavigationPreferences.isEnabled
        keyboardNavigationEnabledRowView?.setOn(isEnabled)
        let rightHandEnabled = KeyboardNavigationPreferences.isRightHandEnabled
        let leftHandEnabled = KeyboardNavigationPreferences.isLeftHandEnabled
        keyboardNavigationHandToggleRows[.rightHand]?.setOn(isEnabled && rightHandEnabled)
        keyboardNavigationHandToggleRows[.leftHand]?.setOn(isEnabled && leftHandEnabled)
        let settings = KeyboardNavigationPreferences.current
        for row in keyboardNavigationRowViews {
            let sc1 = settings.shortcut(for: row.hand, action: row.actionType, slot: 1)
            let sc2 = row.hasSecondary ? settings.shortcut(for: row.hand, action: row.actionType, slot: 2) : nil
            row.updateShortcuts(
                keyCode: sc1.keyCode,
                modifiers: sc1.modifiers,
                secondaryKeyCode: sc2?.keyCode,
                secondaryModifiers: sc2?.modifiers
            )
            let handEnabled = row.hand == .rightHand ? rightHandEnabled : leftHandEnabled
            row.setControlEnabled(isEnabled && handEnabled)
        }
        resetKeyboardControlsRowView?.setControlEnabled(isEnabled)
    }

    private func resetKeyboardNavigationRowToDefault(
        _ row: DockSettingKeyRebindRowView,
        defaults: KeyboardNavigationSettings,
        isFinalRow: Bool
    ) {
        let primary = defaults.shortcut(for: row.hand, action: row.actionType, slot: 1)
        let secondary = row.hasSecondary
            ? defaults.shortcut(for: row.hand, action: row.actionType, slot: 2)
            : nil

        var settings = KeyboardNavigationPreferences.current
        settings.setShortcut(
            keyCode: primary.keyCode,
            modifiers: primary.modifiers,
            for: row.hand,
            action: row.actionType,
            slot: 1
        )
        if let secondary {
            settings.setShortcut(
                keyCode: secondary.keyCode,
                modifiers: secondary.modifiers,
                for: row.hand,
                action: row.actionType,
                slot: 2
            )
        }
        KeyboardNavigationPreferences.current = settings

        row.updateShortcuts(
            keyCode: primary.keyCode,
            modifiers: primary.modifiers,
            secondaryKeyCode: secondary?.keyCode,
            secondaryModifiers: secondary?.modifiers
        )
        openShortcutHotKey?.reloadHotKeys()

        if isFinalRow {
            // The persisted result is now exactly the defaults, so remove the
            // override just as a conventional full reset would.
            KeyboardNavigationPreferences.resetToDefaults()
        }
    }

    private func refreshDisplayOrderMenu() {
        guard displayOrderMenu != nil else { return }
        let screenCount = max(NSScreen.screens.count, desktopDisplaySections.count)
        let hasThreeOrMore = screenCount >= 3
        let current = DisplayListOrder.current
        let isActiveFirstOn = (current != .numerical)
        let isLastUsedOn = (current == .lastUsed && hasThreeOrMore)

        displayOrderRows[.numerical]?.setOn(!isActiveFirstOn)
        displayOrderRows[.activeFirst]?.setOn(isActiveFirstOn)
        displayOrderRows[.lastUsed]?.setOn(isLastUsedOn)
        displayOrderRows[.lastUsed]?.setControlEnabled(isActiveFirstOn && hasThreeOrMore, updateMenuItem: false)
    }

    private func refreshDesktopChangeTooltipMenu() {
        let isEnabled = UserDefaults.standard.bool(forKey: DesktopChangeTooltip.preferenceKey)
        desktopChangeTooltipRowView?.setOn(isEnabled)
        desktopChangeTooltipDurationSliderView?.slider.isEnabled = isEnabled
        desktopChangeTooltipDisplayUnderneathRowView?.setOn(DesktopChangeTooltip.isDisplayUnderneath)
        desktopChangeTooltipDisplayUnderneathRowView?.setControlEnabled(isEnabled)
        let duration = DesktopChangeTooltip.duration
        let durationText = String(format: "%.1f sec", duration)
        desktopChangeTooltipDurationSliderView?.setValue(duration, displayText: durationText)
    }

    @objc private func previewDesktopChangeTooltipDuration(_ sender: NSSlider) {
        let duration = (sender.doubleValue * 10).rounded() / 10
        let durationText = String(format: "%.1f sec", duration)
        desktopChangeTooltipDurationSliderView?.setValue(duration, displayText: durationText)
    }

    private func refreshDockAwaySettingsMenu() {
        desktopManagerRowView?.setOn(isDesktopManagerEnabled)
        refreshDesktopChangeTooltipMenu()
        teleportCursorRowView?.setOn(isTeleportCursorEnabled)
        teleportWindowMoveRowView?.setOn(isTeleportWindowMoveEnabled)
        lockSoundRowView?.setOn(UserDefaults.standard.bool(forKey: LockscreenSoundPlayer.Event.lock.preferenceKey))
        unlockSoundRowView?.setOn(UserDefaults.standard.bool(forKey: LockscreenSoundPlayer.Event.unlock.preferenceKey))
        screenshotClipboardRowView?.setOn(screenshotClipboardManager.isEnabled)
        greenButtonFillRowView?.setOn(
            UserDefaults.standard.bool(forKey: GreenButtonFillController.preferenceKey)
        )
        finderDeleteKeyRowView?.setOn(
            UserDefaults.standard.bool(forKey: FinderDeleteKeyController.preferenceKey)
        )
        quickLookCopyOrientationRowView?.setOn(
            UserDefaults.standard.bool(forKey: QuickLookCopyOrientationManager.preferenceKey)
        )
        refreshHoverActivationMenu()
        chromiumWebAppPlacementRowView?.setOn(
            ChromiumWebAppPlacementController.isEnabled
        )
        screenshotClipboardManager.validateWatchedDirectory()
        refreshKeyboardNavigationMenu()
        refreshDisplayOrderMenu()
    }

    private func refreshChromiumWebAppPlacementController() {
        chromiumWebAppPlacementController.setEnabled(
            ChromiumWebAppPlacementController.isEnabled
                && accessibilityAccessGranted
        )
    }

    private func refreshGreenButtonFillController() {
        greenButtonFillController.setEnabled(
            UserDefaults.standard.bool(forKey: GreenButtonFillController.preferenceKey)
                && accessibilityAccessGranted
                && inputMonitoringAccessGranted
        )
    }

    private func refreshFinderDeleteKeyController() {
        finderDeleteKeyController.setEnabled(
            UserDefaults.standard.bool(
                forKey: FinderDeleteKeyController.preferenceKey
            )
                && accessibilityAccessGranted
                && inputMonitoringAccessGranted
        )
    }

    private func refreshQuickLookCopyOrientationManager() {
        quickLookCopyOrientationManager.setEnabled(
            UserDefaults.standard.bool(
                forKey: QuickLookCopyOrientationManager.preferenceKey
            )
        )
    }

    private func refreshHoverActivationController() {
        hoverActivationController.setEnabled(
            HoverActivationController.isEnabled
                && accessibilityAccessGranted
        )
        refreshHoverActivationMenu()
    }

    private func refreshHoverActivationMenu() {
        let enabled = HoverActivationController.isEnabled
        hoverActivationEnabledRowView?.setOn(enabled)
        hoverActivationPointerStopRowView?.setOn(
            HoverActivationController.waitsForPointerToStop
        )
        hoverActivationPointerStopRowView?.setControlEnabled(enabled)
        hoverActivationRaiseRowView?.setOn(HoverActivationController.raisesWindow)
        hoverActivationRaiseRowView?.setControlEnabled(enabled, updateMenuItem: false)
        hoverActivationDelaySliderView?.slider.isEnabled = enabled
        let delay = HoverActivationController.delay
        let delayText: String
        if delay < 0.005 {
            delayText = "Instant"
        } else if delay < 1 {
            delayText = "\(Int((delay * 1_000).rounded())) ms"
        } else {
            delayText = String(format: "%.1f sec", delay)
        }
        hoverActivationDelaySliderView?.setValue(delay, displayText: delayText)
    }

    @objc private func previewHoverActivationDelay(_ sender: NSSlider) {
        let delay = sender.doubleValue
        let text: String
        if delay < 0.005 {
            text = "Instant"
        } else if delay < 1 {
            text = "\(Int((delay * 1_000).rounded())) ms"
        } else {
            text = String(format: "%.1f sec", delay)
        }
        hoverActivationDelaySliderView?.setValue(delay, displayText: text)
    }

    private func refreshDockIconClickMinimizeController() {
        let hasRequiredPermissions = accessibilityAccessGranted
            && inputMonitoringAccessGranted
        let hideEnabled = UserDefaults.standard.bool(
            forKey: DockIconClickMinimizeController.hidePreferenceKey
        )
        var minimizeEnabled = UserDefaults.standard.bool(
            forKey: DockIconClickMinimizeController.preferenceKey
        )
        if hideEnabled && minimizeEnabled {
            minimizeEnabled = false
            UserDefaults.standard.set(
                false,
                forKey: DockIconClickMinimizeController.preferenceKey
            )
            dockIconClickMinimizeRowView?.setOn(false)
        }
        let mode = DockIconClickMinimizeController.mode(
            minimizeEnabled: hasRequiredPermissions && minimizeEnabled,
            hideEnabled: hasRequiredPermissions && hideEnabled
        )
        dockIconClickMinimizeController.setMode(mode)
    }

    // MARK: - Desktop Indicator Appearance

    func applyDisplayListOrderSelection(_ clickedOrder: DisplayListOrder) {
        let screenCount = max(NSScreen.screens.count, desktopDisplaySections.count)
        let current = DisplayListOrder.current

        let newOrder: DisplayListOrder
        switch clickedOrder {
        case .numerical:
            newOrder = .numerical

        case .activeFirst:
            if current != .numerical {
                newOrder = .numerical
            } else {
                newOrder = .activeFirst
            }

        case .lastUsed:
            guard screenCount >= 3, current != .numerical else { return }
            if current == .lastUsed {
                newOrder = .activeFirst
            } else {
                newOrder = .lastUsed
            }
        }

        UserDefaults.standard.set(newOrder.rawValue, forKey: DisplayListOrder.preferenceKey)
        refreshDisplayOrderMenu()
        if let id = pointerDisplayID() { recordDisplayUsage(id) }
        configureDisplayAccentTracking()
        pendingDisplayLayoutRefresh = true
        refreshDesktopTiles()
    }

    @objc private func selectDisplayListOrder(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let clickedOrder = DisplayListOrder(rawValue: raw) else { return }
        applyDisplayListOrderSelection(clickedOrder)
    }

    private func recordDisplayUsage(_ id: CGDirectDisplayID) {
        guard DisplayListOrder.current != .numerical else { return }
        let key = indicatorDisplayKey(id)
        var history = UserDefaults.standard.stringArray(forKey: DisplayListOrder.historyKey) ?? []
        guard history.first != key else { return }
        history.removeAll { $0 == key }
        history.insert(key, at: 0)
        UserDefaults.standard.set(Array(history.prefix(32)), forKey: DisplayListOrder.historyKey)
    }

    @objc private func selectDockAwayTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let theme = DockAwayTheme(rawValue: raw) else { return }
        UserDefaults.standard.set(raw, forKey: DockAwayTheme.preferenceKey)
        NSApp.appearance = theme.appearance
        desktopChangeTooltip.applyTheme(theme)
        statusItem.button?.appearance = theme.appearance
        if let menu = statusItem.menu { theme.apply(to: menu) }
        for item in sender.menu?.items ?? [] {
            item.state = (item.representedObject as? String) == raw ? .on : .off
        }
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            refreshDesktopIndicatorAppearanceMenu()
            updateMenuBarDesktopBadge()
        }
    }

    @objc private func reloadMissionControlKeyboardShortcuts() {
        dockWatcher?.reloadMissionControlKeyboardShortcuts()
    }

    @objc private func previewIndicatorPillOpacity(_ sender: NSSlider) {
        setIndicatorPillOpacity(sender.doubleValue)
    }

    private func setIndicatorPillOpacity(_ percentage: Double) {
        guard percentage.isFinite else { return }
        var editedStyle = cleanDesktopTextStyle
        editedStyle.pillOpacity = min(100, max(0, percentage)) / 100
        saveCleanDesktopTextStyle(editedStyle)
        // Slider tracking must not change menu-item visibility, titles, or row
        // geometry. Update only the existing content, including on mouse-up.
        let (current, total, isFS) = currentDesktopInfo()
        for item in desktopIndicatorAppearanceMenu?.items ?? [] {
            if let sliderView = item.view as? DockSettingSliderView, item.tag == -102 {
                sliderView.setPercentage(percentage, usesSystemDefault: false)
            } else if let paddingView = item.view as? PillPaddingSlidersView, item.tag == -103 {
                paddingView.update(
                    horizontal: editedStyle.pillPaddingHorizontal ?? 8.0
                )
            } else if item.tag == -105, let row = item.view as? DesktopIndicatorPreviewRow {
                row.preview = desktopIndicatorPreview(.systemText, current: current, total: total, isFS: isFS)
            } else if let row = item.view as? DesktopIndicatorPreviewRow,
                      let appearance = DesktopIndicatorAppearance(rawValue: item.tag) {
                row.preview = desktopIndicatorPreview(appearance, current: current, total: total, isFS: isFS)
            }
        }
        updateMenuBarDesktopBadge(liveCustomization: true, refreshMenu: false)
    }

    @objc private func previewIndicatorPillPaddingHorizontal(_ sender: NSSlider) {
        setIndicatorPillPadding(sender.doubleValue)
    }

    @objc private func previewIndicatorPillCornerRadius(_ sender: NSSlider) {
        setIndicatorPillCornerRadius(sender.doubleValue)
    }

    private func setIndicatorPillCornerRadius(_ percentage: Double) {
        guard percentage.isFinite else { return }
        let clamped = min(100, max(0, percentage))
        var editedStyle = cleanDesktopTextStyle
        editedStyle.pillCornerRadius = clamped / 100
        editedStyle.usesRoundPill = clamped >= 99.5
        saveCleanDesktopTextStyle(editedStyle)
        let (current, total, isFS) = currentDesktopInfo()
        for item in desktopIndicatorAppearanceMenu?.items ?? [] {
            if let sliderView = item.view as? DockSettingSliderView, item.tag == -104 {
                sliderView.setPercentage(clamped, usesSystemDefault: false)
            } else if item.tag == -105, let row = item.view as? DesktopIndicatorPreviewRow {
                row.preview = desktopIndicatorPreview(.systemText, current: current, total: total, isFS: isFS)
            } else if let row = item.view as? DesktopIndicatorPreviewRow,
                      let appearance = DesktopIndicatorAppearance(rawValue: item.tag) {
                row.preview = desktopIndicatorPreview(appearance, current: current, total: total, isFS: isFS)
            }
        }
        updateMenuBarDesktopBadge(liveCustomization: true, refreshMenu: false)
    }

    private func setIndicatorPillPadding(_ horizontal: Double) {
        var editedStyle = cleanDesktopTextStyle
        if horizontal.isFinite {
            editedStyle.pillPaddingHorizontal = min(24, max(0, horizontal))
        }
        saveCleanDesktopTextStyle(editedStyle)
        let (current, total, isFS) = currentDesktopInfo()
        for item in desktopIndicatorAppearanceMenu?.items ?? [] {
            if let paddingView = item.view as? PillPaddingSlidersView, item.tag == -103 {
                paddingView.update(
                    horizontal: editedStyle.pillPaddingHorizontal ?? 8.0
                )
            } else if item.tag == -105, let row = item.view as? DesktopIndicatorPreviewRow {
                row.preview = desktopIndicatorPreview(.systemText, current: current, total: total, isFS: isFS)
            } else if let row = item.view as? DesktopIndicatorPreviewRow,
                      let appearance = DesktopIndicatorAppearance(rawValue: item.tag) {
                row.preview = desktopIndicatorPreview(appearance, current: current, total: total, isFS: isFS)
            }
        }
        updateMenuBarDesktopBadge(liveCustomization: true, refreshMenu: false)
    }

    @objc private func selectDesktopIndicatorAppearance(_ sender: NSMenuItem) {
        guard let appearance = DesktopIndicatorAppearance(rawValue: sender.tag) else { return }
        saveCleanDesktopTextStyle(cleanDesktopTextStyle)
        DesktopIndicatorPreference.setEnabled(appearance != .none)
        refreshDesktopIndicatorAppearanceMenu()
        updateMenuBarDesktopBadge(liveCustomization: true)
    }

    private func refreshDesktopIndicatorAppearanceMenu() {
        guard let menu = desktopIndicatorAppearanceMenu else { return }
        if desktopDisplaySections.count == 1, let display = desktopDisplaySections.first {
            indicatorEditingDisplay = indicatorDisplayKey(display.snapshot.displayID)
        } else if let selected = indicatorEditingDisplay,
                  !desktopDisplaySections.contains(where: { indicatorDisplayKey($0.snapshot.displayID) == selected }) {
            indicatorEditingDisplay = nil
        }
        let current = currentDesktopIndicatorAppearance
        let (cur, tot, isFS) = currentDesktopInfo()
        let style = cleanDesktopTextStyle
        let context = "\(cur):\(tot):\(isFS):\(style.badge.rawValue):\(style.hierarchical):\(style.usesAccentColor):\(style.separator.rawValue):\(style.usesPill):\(style.usesRoundPill):\(style.encapsulatesDockIndicator):\(style.pillOnlyWhenActive ?? false):\(String(describing: glyphShowsDockVisible)):\(NSApp.effectiveAppearance.name.rawValue)"
        let opacityContext = context + ":\(style.pillOpacity):\(style.pillCornerRadius ?? (style.usesRoundPill ? 1.0 : 0.3)):\(style.pillPaddingHorizontal ?? 8.0):\(style.pillPaddingVertical ?? 3.0)"
        let needsPreview = desktopIndicatorPreviewContext != opacityContext
        desktopIndicatorPreviewContext = opacityContext
        for item in menu.items {
            if item.tag == -106, let targets = item.submenu {
                let hideSelector = desktopDisplaySections.isEmpty
                if item.isHidden != hideSelector { item.isHidden = hideSelector }
                if item.view == nil {
                    item.view = SubmenuLabelView.customizeDisplays()
                }
                let displays = desktopDisplaySections.map { (indicatorDisplayKey($0.snapshot.displayID), $0.name) }
                if let selected = indicatorEditingDisplay, !displays.contains(where: { $0.0 == selected }) {
                    indicatorEditingDisplay = nil
                }
                item.title = "Customize: " + (displays.first { $0.0 == indicatorEditingDisplay }?.1 ?? "All Displays")
                item.view?.needsDisplay = true
                let keys = [""] + displays.map { $0.0 }
                if targets.items.compactMap({ $0.representedObject as? String }) != keys {
                    targets.removeAllItems()
                    for (key, name) in [("", "All Displays")] + displays {
                        let choice = NSMenuItem(title: name, action: #selector(selectIndicatorEditingDisplay(_:)), keyEquivalent: "")
                        choice.target = self
                        choice.representedObject = key
                        let helpHeading = key.isEmpty ? "All Displays" : name
                        let helpText = key.isEmpty
                            ? "When All Displays is selected, appearance style changes (pills, fills, outlines, and accents) are applied globally across all connected monitors.\n\n• Changes update every display's menu bar indicator in unison.\n• Perfect for maintaining a consistent look across all screens."
                            : "When \(name) is selected, appearance style changes are isolated specifically to this monitor.\n\n• Customize pills, outlines, and badges independently per display.\n• Other displays retain their existing appearances."
                        let row = DockSettingPersistenceRowView(
                            title: name,
                            isOn: key == (indicatorEditingDisplay ?? ""),
                            width: 280,
                            leadingInset: 18,
                            helpHeading: helpHeading,
                            helpTextProvider: { helpText }
                        ) { [weak self] _ in
                            self?.indicatorEditingDisplay = key.isEmpty ? nil : key
                            self?.refreshDesktopIndicatorAppearanceMenu()
                        }
                        choice.view = row
                        targets.addItem(choice)
                    }
                }
                for choice in targets.items {
                    choice.state = (choice.representedObject as? String) == (indicatorEditingDisplay ?? "") ? .on : .off
                    (choice.view as? DockSettingPersistenceRowView)?.setOn(choice.state == .on)
                }
                continue
            }
            if item.isSeparatorItem {
                if item.tag == -107 {
                    let hideSelector = desktopDisplaySections.isEmpty
                    if item.isHidden != hideSelector { item.isHidden = hideSelector }
                }
                continue
            }
            if item.tag == -105, let row = item.view as? DesktopIndicatorPreviewRow {
                row.selected = current != .none
                row.preview = desktopIndicatorPreview(.systemText, current: cur, total: tot, isFS: isFS)
                continue
            }
            if item.tag == -102, let opacityView = item.view as? DockSettingSliderView {
                if item.isHidden != !style.usesPill {
                    item.isHidden = !style.usesPill
                }
                opacityView.setPercentage(style.pillOpacity * 100, usesSystemDefault: false)
                continue
            }
            if item.tag == -104, let radiusView = item.view as? DockSettingSliderView {
                if item.isHidden != !style.usesPill {
                    item.isHidden = !style.usesPill
                }
                let normalizedRadius = style.pillCornerRadius
                    ?? (style.usesRoundPill ? 1.0 : 0.3)
                radiusView.setPercentage(normalizedRadius * 100, usesSystemDefault: false)
                continue
            }
            if item.tag == -103, let paddingView = item.view as? PillPaddingSlidersView {
                if item.isHidden != !style.usesPill {
                    item.isHidden = !style.usesPill
                }
                paddingView.update(
                    horizontal: style.pillPaddingHorizontal ?? 8.0
                )
                continue
            }
            if let separatorMenu = item.submenu as? DesktopIndicatorSeparatorMenu {
                if item.view == nil {
                    item.view = SubmenuLabelView.indicatorSeparator()
                }
                separatorMenu.update(style.separator)
                continue
            }
            if let numberStyleMenu = item.submenu as? DesktopNumberIndicatorMenu {
                if item.view == nil {
                    item.view = SubmenuLabelView.desktopNumberIndicator()
                }
                numberStyleMenu.syncSelection()
                continue
            }
            if let options = item.view as? DesktopIndicatorStyleOptionsView {
                options.update(style)
                continue
            }
            if item.tag == -108, let tooltipRow = item.view as? DockSettingToggleRowView {
                tooltipRow.setOn(UserDefaults.standard.bool(forKey: DesktopChangeTooltip.preferenceKey))
                continue
            }
            guard let appearance = DesktopIndicatorAppearance(rawValue: item.tag) else { continue }
            item.state = (appearance == current) ? .on : .off
            item.title = appearance.title
            if let row = item.view as? DesktopIndicatorPreviewRow {
                row.selected = appearance == current
                if needsPreview || row.preview == nil {
                    row.preview = desktopIndicatorPreview(appearance, current: cur, total: tot, isFS: isFS)
                }
            }
        }
    }

    private func desktopIndicatorPreview(_ appearance: DesktopIndicatorAppearance, current: Int, total: Int, isFS: Bool) -> NSImage {
        let style = cleanDesktopTextStyle
        let targetAppearance = DockAwayTheme.current.appearance ?? NSApp.effectiveAppearance
        let isDark = targetAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if appearance == .systemText {
            // Render the prospective status-item content, not a separate mockup.
            // This deliberately reads current settings even while the status-item
            // resize is deferred until menu tracking ends.
            var grouped: NSAttributedString?
            var text: NSAttributedString!
            targetAppearance.performAsCurrentDrawingAppearance {
                grouped = self.groupedDisplayIndicatorText()
                text = grouped ?? style.text(current: current, total: total,
                    isFullscreen: isFS, dockIndicator: self.statusItem.button?.image)
            }
            let showsLogo = grouped == nil && !(style.usesPill && style.encapsulatesDockIndicator)
            let rawLogo = showsLogo ? (statusItem.button?.image ?? NSImage(named: isDockCurrentlyVisible() ? "DockAwayStatus-Up" : "DockAwayStatus-Down")) : nil
            let logoSize = rawLogo?.size ?? .zero
            let logoColor: NSColor = isDark ? .white : .black
            let logo: NSImage? = rawLogo.map { img in
                NSImage(size: logoSize, flipped: false) { rect in
                    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                    logoColor.setFill()
                    rect.fill(using: .sourceIn)
                    return true
                }
            }
            let textSize = text.size()
            let logoWidth = logo == nil ? 0 : logoSize.width + 4
            let height = max(32, ceil(max(textSize.height, logoSize.height)) + 4)
            let preview = NSImage(size: NSSize(width: ceil(logoWidth + textSize.width) + 16, height: height), flipped: false) { rect in
                targetAppearance.performAsCurrentDrawingAppearance {
                    logo?.draw(in: NSRect(x: 8, y: (rect.height - logoSize.height) / 2,
                                         width: logoSize.width, height: logoSize.height))
                    text.draw(at: NSPoint(x: 8 + logoWidth, y: (rect.height - textSize.height) / 2))
                }
                return true
            }
            preview.isTemplate = false
            preview.accessibilityDescription = text.string
            return preview
        }
        let encapsulated = appearance == .systemText && style.usesPill && style.encapsulatesDockIndicator
        var cleanText: NSAttributedString!
        targetAppearance.performAsCurrentDrawingAppearance {
            cleanText = style.text(current: current, total: total, isFullscreen: isFS, dockIndicator: self.statusItem.button?.image)
        }
        let sourceLogo = statusItem.button?.image ?? NSImage(named: isDockCurrentlyVisible() ? "DockAwayStatus-Up" : "DockAwayStatus-Down")
        let logoColor: NSColor = isDark ? .white : .black
        let logoSize = sourceLogo?.size ?? NSSize(width: 22, height: 16)
        let logo = NSImage(size: logoSize, flipped: false) { rect in
            sourceLogo?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            logoColor.setFill()
            rect.fill(using: .sourceIn)
            return true
        }
        // Both rows share a content-sized column. An encapsulated indicator
        // already contains the logo, so do not reserve a second logo column.
        let indicatorOrigin: CGFloat = style.usesPill && style.encapsulatesDockIndicator ? 8 : 42
        let noneWidth = 42 + ("None" as NSString).size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        ]).width
        let previewWidth = ceil(max(noneWidth, indicatorOrigin + cleanText.size().width) + 8)
        let preview = NSImage(size: NSSize(width: previewWidth, height: 32), flipped: false) { rect in
            targetAppearance.performAsCurrentDrawingAppearance {
                // The row supplies live native glass behind this transparent content.
                if !encapsulated {
                    logo.draw(in: NSRect(x: 8, y: (32 - logoSize.height) / 2, width: logoSize.width, height: logoSize.height), from: .zero, operation: .sourceOver, fraction: 1)
                }
                let text = isFS ? "FS" : "\(current) of \(total)"
                let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
                let textColor: NSColor = isDark ? .white : .labelColor
                func drawText(_ value: String, x: CGFloat = 42, font: NSFont = font, color: NSColor = textColor) {
                    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                    let size = (value as NSString).size(withAttributes: attributes)
                    (value as NSString).draw(at: NSPoint(x: x, y: (32 - size.height) / 2), withAttributes: attributes)
                }
                switch appearance {
                case .none:
                    drawText("None", color: .secondaryLabelColor)
                case .systemText:
                    let previewText = NSMutableAttributedString(attributedString: cleanText)
                    previewText.addAttribute(.foregroundColor, value: textColor, range: NSRange(location: 0, length: previewText.length))
                    let size = previewText.size()
                    previewText.draw(at: NSPoint(x: encapsulated ? 8 : 42, y: (32 - size.height) / 2))
                case .compactSlash:
                    drawText(isFS ? "FS" : "\(current)/\(total)")
                case .pillBadge:
                    let pill = Self.makePillBadgeImage(text: text)
                    pill.draw(in: NSRect(x: 42, y: 8, width: pill.size.width, height: 16), from: .zero, operation: .sourceOver, fraction: 1)
            case .activeBadge:
                let badge = Self.makeActiveBoxImage(numberText: isFS ? "FS" : "\(current)")
                badge.draw(in: NSRect(x: 42, y: 8, width: badge.size.width, height: 16), from: .zero, operation: .sourceOver, fraction: 1)
                if !isFS { drawText(" of \(total)", x: 42 + badge.size.width, color: .secondaryLabelColor) }
            case .hierarchical:
                let strong = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
                let number = isFS ? "FS" : "\(current)"
                drawText(number, font: strong)
                if !isFS {
                    let width = (number as NSString).size(withAttributes: [.font: strong]).width
                    drawText(" of \(total)", x: 42 + width, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
                }
            }
        }
        return true
    }
        preview.isTemplate = false
        preview.accessibilityDescription = appearance.title
        return preview
    }

    @objc private func selectIndicatorEditingDisplay(_ sender: NSMenuItem) {
        let key = sender.representedObject as? String ?? ""
        indicatorEditingDisplay = key.isEmpty ? nil : key
        refreshDesktopIndicatorAppearanceMenu()
    }

    // MARK: - Dock Settings

    @objc private func openDesktopAndDockSettings() {
        openSystemSettingsPane("com.apple.Desktop-Settings.extension")
    }

    private func openSystemSettingsPane(_ identifier: String) {
        statusItem.menu?.cancelTracking()
        guard let url = URL(string: "x-apple.systempreferences:\(identifier)") else { return }
        if !NSWorkspace.shared.open(url),
           let settingsURL = NSWorkspace.shared.urlForApplication(
               withBundleIdentifier: "com.apple.systempreferences"
           ) {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    private var dockSettingsCanRestartDock: Bool {
        guard !dockSettingsRestartInProgress, !fourFingersDown, !isQuitting,
              automaticSuspensionReasons.isEmpty, !desktopCreationInProgress else { return false }
        if let dockWatcher {
            return dockWatcher.canRestartDockSafely
        }
        return missionControlStateForDockSettings() == false
    }

    private func refreshRestartDockAction() {
        let title = dockSettingsRestartInProgress ? "Restarting Dock…" : "Restart Dock"
        restartDockMenuItem?.title = title
        restartDockMenuItem?.isEnabled = dockSettingsCanRestartDock
        restartDockRowView?.update(title: title)
        restartDockRowView?.setControlEnabled(dockSettingsCanRestartDock)
    }

    @objc private func restartDockFromAdvanced() {
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.dockSettingsCanRestartDock else {
                NSSound.beep()
                self.refreshRestartDockAction()
                return
            }
            let generation = self.beginDockRestart(manual: true)
            self.restartDock(generation: generation)
        }
    }

    private func beginDockRestart(manual: Bool) -> Int {
        dockRestartIsManual = manual
        dockSettingsRestartInProgress = true
        dockRestartGeneration += 1
        fourFingersDown = false
        fourFingerStartedInMissionControl = false
        dockWatcher?.stop()
        multitouch.stop()
        refreshRestartDockAction()
        updateDockAwayMenuState()
        dockAwayStatusView?.pauseResumeButton.isEnabled = false
        return dockRestartGeneration
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
        refreshRestartDockAction()
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
        dockIconClickMinimizeRowView?.setOn(
            UserDefaults.standard.bool(
                forKey: DockIconClickMinimizeController.preferenceKey
            )
        )
        dockIconClickHideRowView?.setOn(
            UserDefaults.standard.bool(
                forKey: DockIconClickMinimizeController.hidePreferenceKey
            )
        )

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
            restoreDockDefaultsRowView?.setTitle("Restore Default macOS Dock")
            restoreDockDefaultsRowView?.setControlEnabled(false)
            restoreDockDefaultsRowView?.setOn(true)
        } else {
            restoreDockDefaultsRowView?.setTitle("Restore Default macOS Dock")
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
        // An explicit choice always takes precedence over first-run setup.
        UserDefaults.standard.set(true, forKey: Self.initialRevealDelayHandledKey)
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

    private func removeInitialDockRevealDelayIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.initialRevealDelayHandledKey) else { return }

        // Do not override managed preferences or introduce a preference where
        // none exists. This is a one-time adjustment, not a settings watchdog.
        guard !dockPreferenceIsForced(Self.dockRevealDelayKey),
              let delay = dockPreferenceDouble(forKey: Self.dockRevealDelayKey),
              delay.isFinite, delay > 0 else {
            defaults.set(true, forKey: Self.initialRevealDelayHandledKey)
            return
        }
        guard dockSettingsCanRestartDock else { return }
        if applyDockPreferenceChanges([
            DockPreferenceChange(key: Self.dockRevealDelayKey, value: NSNumber(value: 0))
        ]) {
            defaults.set(true, forKey: Self.initialRevealDelayHandledKey)
        }
    }

    @discardableResult
    private func applyDockPreferenceChanges(_ requestedChanges: [DockPreferenceChange]) -> Bool {
        guard dockSettingsCanRestartDock else {
            NSSound.beep()
            return false
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
            return true
        }

        let restartGeneration = beginDockRestart(manual: false)

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
            return false
        }

        restartDock(
            generation: restartGeneration
        )
        return true
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
        dockAwayDebugLog("Restarting native Dock; manual=\(dockRestartIsManual)")
        dockRestartController.restart { [weak self] error in
            guard let self, !self.isQuitting, self.dockRestartGeneration == generation else { return }
            // Let the replacement establish its preference observers before
            // DockAway resumes. Failures report directly instead of stalling UI.
            DispatchQueue.main.asyncAfter(deadline: .now() + (error == nil ? 0.10 : 0)) { [weak self] in
                self?.finishDockSettingsChange(generation: generation, errorMessage: error)
            }
        }
    }

    private func finishDockSettingsChange(
        generation: Int,
        errorMessage: String?
    ) {
        guard generation == dockRestartGeneration else { return }

        let wasManual = dockRestartIsManual
        dockRestartIsManual = false
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
            alert.messageText = wasManual ? "Restart Dock" : "Dock Settings"
            alert.informativeText = errorMessage
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func refreshUpdateMenuItem() {
        guard let updateMenuItem else { return }
        let updateIsAvailable = availableUpdateVersion != nil
        let title: String
        if let version = availableUpdateVersion {
            title = "Update Available v\(version)"
        } else {
            title = "Check for Updates..."
        }
        updateMenuItem.title = title

        let symbolName = updateIsAvailable
            ? "arrow.down"
            : "arrow.triangle.2.circlepath"
        let icon = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: updateIsAvailable
                ? "Update Available"
                : "Check for Updates"
        )
        updateMenuItem.state = .on
        updateMenuItem.onStateImage = menuIcon(from: icon)
        (updateMenuItem.view as? DockAwayMenuRowView)?.update(
            title: title,
            icon: icon
        )
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
            guard !item.isSeparatorItem, !(item.view is WideMenuSeparatorView) else { continue }
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

    // MARK: - Hover Activation Focus Prevention

    private func rebuildHoverActivationBlacklistMenu() {
        guard let menu = hoverActivationBlacklistMenu else { return }
        menu.removeAllItems()

        let protectedIdentifiers = HoverActivationController.protectedBundleIdentifiers
        var applicationsByIdentifier = [String: BlacklistApplication]()
        var currentApplication: BlacklistApplication?

        let previouslyActiveApplication = settingsMenuPreviousApplication
            ?? NSWorkspace.shared.frontmostApplication
        if let application = previouslyActiveApplication,
           !application.isTerminated,
           let bundleIdentifier = application.bundleIdentifier,
           bundleIdentifier != Bundle.main.bundleIdentifier {
            currentApplication = BlacklistApplication(
                bundleIdentifier: bundleIdentifier,
                name: application.localizedName ?? bundleIdentifier,
                icon: application.icon
            )
        }

        for application in NSWorkspace.shared.runningApplications {
            guard isHoverProtectionCandidate(application),
                  let bundleIdentifier = application.bundleIdentifier,
                  bundleIdentifier != Bundle.main.bundleIdentifier,
                  bundleIdentifier != currentApplication?.bundleIdentifier else { continue }
            applicationsByIdentifier[bundleIdentifier] = BlacklistApplication(
                bundleIdentifier: bundleIdentifier,
                name: application.localizedName ?? bundleIdentifier,
                icon: application.icon
            )
        }

        for bundleIdentifier in protectedIdentifiers
        where applicationsByIdentifier[bundleIdentifier] == nil
            && bundleIdentifier != currentApplication?.bundleIdentifier {
            applicationsByIdentifier[bundleIdentifier] = applicationInfo(
                forBundleIdentifier: bundleIdentifier
            )
        }

        let applications = applicationsByIdentifier.values.filter {
            $0.bundleIdentifier != currentApplication?.bundleIdentifier
        }.sorted {
            let firstProtected = protectedIdentifiers.contains($0.bundleIdentifier)
            let secondProtected = protectedIdentifiers.contains($1.bundleIdentifier)
            if firstProtected != secondProtected { return firstProtected }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        if let currentApplication {
            menu.addItem(blacklistSectionHeader("Current Application", width: 280))
            let currentItem = hoverProtectionMenuItem(
                for: currentApplication,
                protectedIdentifiers: protectedIdentifiers
            )
            currentItem.toolTip = "Current application"
            currentItem.view?.toolTip = "Current application"
            menu.addItem(currentItem)
            menu.addItem(wideMenuSeparator(width: 280, leadingInset: 18, trailingInset: 14))
        }

        let protectedApplications = applications.filter {
            protectedIdentifiers.contains($0.bundleIdentifier)
        }
        let otherApplications = applications.filter {
            !protectedIdentifiers.contains($0.bundleIdentifier)
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
            menu.addItem(emptyItem)
        } else {
            if !protectedApplications.isEmpty {
                menu.addItem(blacklistSectionHeader("Blacklisted Applications", width: 280))
                for application in protectedApplications {
                    menu.addItem(hoverProtectionMenuItem(
                        for: application,
                        protectedIdentifiers: protectedIdentifiers
                    ))
                }
            }

            if !otherApplications.isEmpty {
                if !protectedApplications.isEmpty {
                    menu.addItem(blacklistGroupSeparator())
                }
                menu.addItem(blacklistSectionHeader("Other Applications", width: 280))
                for application in otherApplications {
                    menu.addItem(hoverProtectionMenuItem(
                        for: application,
                        protectedIdentifiers: protectedIdentifiers
                    ))
                }
            }
        }

        menu.addItem(wideMenuSeparator(width: 280, leadingInset: 18, trailingInset: 14))

        let chooseItem = NSMenuItem(title: "Choose Application…", action: nil, keyEquivalent: "")
        let chooseView = BlacklistActionMenuItemView(
            title: "Choose Application…",
            width: 280,
            titleLeadingInset: 18
        ) { [weak self, weak menu] in
            menu?.cancelTracking()
            DispatchQueue.main.async {
                self?.chooseHoverActivationProtectedApplications()
            }
        }
        chooseItem.view = chooseView
        chooseItem.target = chooseView
        chooseItem.action = #selector(BlacklistActionMenuItemView.performMenuAction(_:))
        menu.addItem(chooseItem)

        let clearItem = NSMenuItem(title: "Remove All", action: nil, keyEquivalent: "")
        let clearView = BlacklistActionMenuItemView(
            title: "Remove All",
            isEnabled: !protectedIdentifiers.isEmpty,
            width: 280,
            titleLeadingInset: 18
        ) { [weak self] in
            self?.clearHoverActivationProtectedApplications()
        }
        clearItem.view = clearView
        clearItem.isEnabled = !protectedIdentifiers.isEmpty
        clearItem.target = clearView
        clearItem.action = #selector(BlacklistActionMenuItemView.performMenuAction(_:))
        hoverActivationBlacklistClearActionView = clearView
        menu.addItem(clearItem)

        menu.addItem(wideMenuSeparator(width: 280, leadingInset: 18, trailingInset: 14))
        let helpItem = NSMenuItem(title: "About Focus Prevention Blacklist", action: nil, keyEquivalent: "")
        let helpView = BlacklistHelpMenuItemView(
            title: "About Focus Prevention Blacklist",
            heading: "Focus Prevention Blacklist",
            width: 280,
            titleLeadingInset: 18,
            iconTrailingInset: 14,
            text: {
                """
                Prevents Hover Activation from activating blacklisted applications or switching focus away when they are active.

                • Keeps keyboard and window focus locked to the frontmost app even when your cursor hovers over background windows.
                • Excludes blacklisted apps from being auto-activated or brought forward on hover.
                • Ideal for launchers, quick-search tools, and floating panels (e.g., Spotlight, Raycast, Alfred, rcmd, or SuperCmd) so their popups do not disappear accidentally.
                • Clicking another application or window with your mouse still switches focus immediately.
                • Select any running application from the list above or click “Choose Application…” to add any installed app.
                """
            }
        )
        helpItem.view = helpView
        helpItem.target = helpView
        helpItem.action = #selector(BlacklistHelpMenuItemView.performMenuAction(_:))
        menu.addItem(helpItem)
    }

    private func hoverProtectionMenuItem(
        for application: BlacklistApplication,
        protectedIdentifiers: Set<String>
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: application.name,
            action: nil,
            keyEquivalent: ""
        )
        item.representedObject = application.bundleIdentifier
        item.view = DockSettingPersistenceRowView(
            title: application.name,
            isOn: protectedIdentifiers.contains(application.bundleIdentifier),
            width: 280,
            leadingInset: 18,
            icon: application.icon ?? NSImage(
                systemSymbolName: "app",
                accessibilityDescription: "Application"
            )
        ) { [weak self] isProtected in
            self?.setHoverActivationProtectedApplication(
                application.bundleIdentifier,
                isProtected: isProtected
            )
        }
        return item
    }

    private func isHoverProtectionCandidate(
        _ application: NSRunningApplication
    ) -> Bool {
        if application.activationPolicy == .regular {
            return true
        }

        if HoverActivationDecision.isInteractiveAccessoryApp(bundleIdentifier: application.bundleIdentifier) {
            return true
        }

        // Launchers and menu-bar utilities commonly use accessory activation.
        // Include top-level third-party apps while excluding embedded helpers,
        // XPC services, and macOS agents from the picker.
        guard application.activationPolicy == .accessory,
              let bundleURL = application.bundleURL?.standardizedFileURL,
              bundleURL.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame,
              isTopLevelApplicationBundle(bundleURL) else { return false }

        let path = bundleURL.path
        let userApplicationsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .path
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(userApplicationsPath + "/")
    }

    private func isTopLevelApplicationBundle(_ url: URL) -> Bool {
        var parent = url.deletingLastPathComponent()
        while parent.path != "/" {
            if parent.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame {
                return false
            }
            let next = parent.deletingLastPathComponent()
            if next == parent { break }
            parent = next
        }
        return true
    }

    private func setHoverActivationProtectedApplication(
        _ bundleIdentifier: String,
        isProtected: Bool
    ) {
        var identifiers = HoverActivationController.protectedBundleIdentifiers
        if isProtected {
            identifiers.insert(bundleIdentifier)
        } else {
            identifiers.remove(bundleIdentifier)
        }
        saveHoverActivationProtectedBundleIdentifiers(identifiers)
    }

    private func saveHoverActivationProtectedBundleIdentifiers(
        _ identifiers: Set<String>
    ) {
        UserDefaults.standard.set(
            identifiers.sorted(),
            forKey: HoverActivationController.protectedBundleIdentifiersPreferenceKey
        )
        hoverActivationBlacklistClearActionView?.setControlEnabled(!identifiers.isEmpty)
    }

    private func chooseHoverActivationProtectedApplications() {
        let panel = NSOpenPanel()
        panel.title = "Choose Applications to Blacklist"
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
            var identifiers = HoverActivationController.protectedBundleIdentifiers
            for url in panel.urls {
                if let bundleIdentifier = Bundle(url: url)?.bundleIdentifier,
                   bundleIdentifier != Bundle.main.bundleIdentifier {
                    identifiers.insert(bundleIdentifier)
                }
            }
            self.saveHoverActivationProtectedBundleIdentifiers(identifiers)
            self.rebuildHoverActivationBlacklistMenu()
        }
    }

    private func clearHoverActivationProtectedApplications() {
        saveHoverActivationProtectedBundleIdentifiers([])
        rebuildHoverActivationBlacklistMenu()
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

        let previouslyActiveApplication = settingsMenuPreviousApplication
            ?? NSWorkspace.shared.frontmostApplication
        if let application = previouslyActiveApplication,
           !application.isTerminated,
           application.activationPolicy == .regular,
           let bundleIdentifier = application.bundleIdentifier,
           bundleIdentifier != Bundle.main.bundleIdentifier {
            currentApplication = BlacklistApplication(
                bundleIdentifier: bundleIdentifier,
                name: application.localizedName ?? bundleIdentifier,
                icon: application.icon
            )
        }
        currentBlacklistBundleIdentifier = currentApplication?.bundleIdentifier

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

        // Keep previously blacklisted apps visible even when they are not running.
        // Running and current apps already have live metadata, so avoid looking
        // up bundle metadata and file icons that would immediately be replaced.
        for bundleIdentifier in ignoredIdentifiers
        where applicationsByIdentifier[bundleIdentifier] == nil
            && bundleIdentifier != currentApplication?.bundleIdentifier {
            applicationsByIdentifier[bundleIdentifier] = applicationInfo(
                forBundleIdentifier: bundleIdentifier
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
            blacklistMenu.addItem(blacklistSectionHeader("Current Application"))
            let currentItem = blacklistMenuItem(
                for: currentApplication,
                ignoredIdentifiers: ignoredIdentifiers
            )
            currentItem.toolTip = "Current application"
            currentItem.view?.toolTip = "Current application"
            blacklistMenu.addItem(currentItem)
            blacklistMenu.addItem(.separator())
        }

        let selectedApplications = applications.filter {
            ignoredIdentifiers.contains($0.bundleIdentifier)
        }
        let otherApplications = applications.filter {
            !ignoredIdentifiers.contains($0.bundleIdentifier)
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
            if !selectedApplications.isEmpty {
                blacklistMenu.addItem(blacklistSectionHeader("Selected Applications"))
                for application in selectedApplications {
                    blacklistMenu.addItem(blacklistMenuItem(
                        for: application,
                        ignoredIdentifiers: ignoredIdentifiers
                    ))
                }
            }

            if !otherApplications.isEmpty {
                if !selectedApplications.isEmpty {
                    blacklistMenu.addItem(blacklistGroupSeparator())
                }
                blacklistMenu.addItem(blacklistSectionHeader("Other Applications"))
                for application in otherApplications {
                    blacklistMenu.addItem(blacklistMenuItem(
                        for: application,
                        ignoredIdentifiers: ignoredIdentifiers
                    ))
                }
            }
        }

        blacklistMenu.addItem(.separator())

        let chooseItem = NSMenuItem()
        chooseItem.title = "Choose Application…"
        chooseItem.view = BlacklistActionMenuItemView(
            title: "Choose Application…"
        ) { [weak self, weak blacklistMenu] in
            blacklistMenu?.cancelTracking()
            DispatchQueue.main.async {
                self?.chooseBlacklistApplication()
            }
        }
        chooseItem.target = chooseItem.view
        chooseItem.action = #selector(BlacklistActionMenuItemView.performMenuAction(_:))
        blacklistMenu.addItem(chooseItem)

        let clearItem = NSMenuItem()
        clearItem.title = "Remove All"
        let clearActionView = BlacklistActionMenuItemView(
            title: "Remove All",
            isEnabled: !ignoredIdentifiers.isEmpty
        ) { [weak self] in
            self?.clearBlacklist()
        }
        clearItem.view = clearActionView
        clearItem.isEnabled = !ignoredIdentifiers.isEmpty
        clearItem.target = clearActionView
        clearItem.action = #selector(BlacklistActionMenuItemView.performMenuAction(_:))
        blacklistClearActionView = clearActionView
        blacklistMenu.addItem(clearItem)

        blacklistMenu.addItem(.separator())

        let helpItem = NSMenuItem()
        helpItem.title = "About Blacklist"
        helpItem.view = BlacklistHelpMenuItemView()
        helpItem.target = helpItem.view
        helpItem.action = #selector(BlacklistHelpMenuItemView.performMenuAction(_:))
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

    private func blacklistSectionHeader(_ title: String, width: CGFloat = 190) -> NSMenuItem {
        let item = NSMenuItem()
        item.title = title
        item.isEnabled = false
        item.view = DockSettingSectionHeaderView(
            title: title,
            width: width,
            leadingInset: 18,
            font: .systemFont(ofSize: 11.5, weight: .semibold),
            centered: true
        )
        return item
    }

    private func blacklistGroupSeparator() -> NSMenuItem {
        let separator = NSMenuItem()
        separator.isEnabled = false
        separator.view = BlacklistGroupSeparatorView(frame: .zero)
        return separator
    }

    private func wideMenuSeparator(
        width: CGFloat = 190,
        leadingInset: CGFloat = 14,
        trailingInset: CGFloat = 14
    ) -> NSMenuItem {
        .wideSeparator(width: width, leadingInset: leadingInset, trailingInset: trailingInset)
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
            alert.informativeText = "Are you sure you want to:\nRemove \(applicationCount) apps from the blacklist?"
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

    func updateStatus(_ text: String, desktopText: String? = nil) {
        let applyUpdate = { [weak self] in
            guard let self, self.monitoringShouldRun else { return }
            guard self.activeStatusText != text || self.activeDesktopStatusText != desktopText else { return }
            self.activeStatusText = text
            self.activeDesktopStatusText = desktopText
            self.updateDockAwayMenuState()
            self.updateMenuBarDesktopBadge()
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

        if dockShortcutWarningVisible {
            statusItem.menu?.cancelTracking()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let alert = NSAlert()
                alert.messageText = "Enable the Dock Keyboard Shortcut"
                alert.informativeText = "In System Settings, open Keyboard > Keyboard Shortcuts > Mission Control and enable ‘Turn Dock hiding on/off’. DockAway uses your chosen key combination and will resume Dock changes once it is enabled."
                alert.addButton(withTitle: "Open Keyboard Settings")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    self.openSystemSettingsPane("com.apple.Keyboard-Settings.extension")
                }
            }
            return
        }

        if dockAwayEnabled, multitouchWarningVisible {
            retryMultitouchSupport()
            return
        }

        if dockAwayEnabled,
           !accessibilityAccessGranted || !inputMonitoringAccessGranted {
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
            updateDockAwayMenuState()
            restoreDockState()
            applyStatusIcon(dockVisible: isDockCurrentlyVisible())
            dockAwayDebugLog("🔴 DockAway inactive")
        } else {
            dockAwayEnabled = true
            requestAccessibilityPermission()
            updateDockAwayMenuState()
        }
    }

    private func updateDockAwayMenuState() {
        refreshDesktopTiles()
        dockAwayStatusView?.update(
            active: statusAppearsActive,
            status: activeStatusText,
            desktopStatus: desktopMenuStatus,
            inactiveTitle: inactiveStatusTitle,
            inactiveDetail: dockAwayEnabled
                ? automaticSuspensionDetail
                : "App detection paused",
            inactiveActionTitle: permissionRecoveryRequired
                && dockAwayEnabled
                ? permissionActionTitle
                : "Resume DockAway",
            warning: dockShortcutWarningVisible || multitouchWarningVisible,
            warningTitle: dockShortcutWarningVisible ? "Dock Shortcut Required" : "No Multitouch Support:",
            warningDetail: dockShortcutWarningVisible ? (dockShortcutWarning ?? "") : "4-finger gestures off",
            warningActionTitle: dockShortcutWarningVisible ? "Open Keyboard Settings" : "Retry Gesture Support"
        )
        dockAwayStatusView?.pauseResumeButton.isEnabled = !dockSettingsRestartInProgress
    }

    private func desktopTileIcon(for app: NSRunningApplication) -> NSImage? {
        // Use the bundle's Finder icon, then flatten its representations once
        // before miniature drawing. Avoid scaling a live application icon surface.
        guard let source = app.bundleURL.map({ NSWorkspace.shared.icon(forFile: $0.path) }) ?? app.icon,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill(using: .copy)
        source.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64), from: .zero,
                    operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.addRepresentation(bitmap)
        image.isTemplate = false
        return image
    }

    private func desktopApplicationSpaceIDs() -> [UInt64] {
        desktopDisplaySections.flatMap { section in
            let snapshot = section.snapshot
            let fullscreenContentIDs = snapshot.fullscreenSpaceIDs.flatMap {
                snapshot.fullscreenContentSpaceIDs[$0] ?? []
            }
            return snapshot.desktopIDs + snapshot.fullscreenSpaceIDs + fullscreenContentIDs
        }
    }

    private func beginDesktopIconRefresh() {
        desktopIconRefreshTask?.cancel()
        guard isDesktopManagerEnabled else { return }
        desktopIconRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.isQuitting else { return }
                let ids = self.desktopApplicationSpaceIDs()
                let owners: [UInt64: [Int32]]? = await Task.detached(priority: .utility) {
                    guard let raw = DockAwayCopyDesktopApplicationPIDs(ids.map { NSNumber(value: $0) }) else { return nil }
                    return Dictionary(uniqueKeysWithValues: raw.map { ($0.key.uint64Value, $0.value.map(\.int32Value)) })
                }.value
                guard !Task.isCancelled else { return }
                if let owners, self.desktopApplicationSpaceIDs() == ids {
                    var icons: [UInt64: [DesktopApplicationIcon]] = [:]
                    var appCache: [Int32: NSRunningApplication] = [:]
                    for pid in Set(owners.values.flatMap { $0 }) {
                        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                            appCache[pid] = app
                        }
                    }
                    for (sid, pids) in owners {
                        var seen = Set<String>()
                        icons[sid] = pids.compactMap { pid -> DesktopApplicationIcon? in
                            guard let app = appCache[pid], let image = self.desktopTileIcon(for: app) else { return nil }
                            let identity = app.bundleIdentifier ?? app.bundleURL?.path ?? "pid:\(pid)"
                            guard seen.insert(identity).inserted else { return nil }
                            return DesktopApplicationIcon(name: app.localizedName ?? "App", image: image, bundleIdentifier: app.bundleIdentifier)
                        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    }
                    if self.desktopTilesView?.hasActiveDesktopGesture != true {
                        self.desktopTilesView?.updateApplicationIcons(icons)
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func refreshDesktopTiles() {
        let displayID = statusItem.button?.window?.screen?.displayID ?? CGMainDisplayID()
        desktopTileSnapshot = dockWatcher?.desktopSelection(on: displayID)
        let screens = NSScreen.screens.sorted { lhs, rhs in
            func priority(_ screen: NSScreen) -> Int {
                let id = screen.displayID ?? 0
                return id == CGMainDisplayID() ? 0 : (CGDisplayIsBuiltin(id) != 0 ? 1 : 2)
            }
            if priority(lhs) != priority(rhs) { return priority(lhs) < priority(rhs) }
            return lhs.frame.minX == rhs.frame.minX ? lhs.frame.minY < rhs.frame.minY : lhs.frame.minX < rhs.frame.minX
        }
        var seenSpaces = Set<UInt64>()
        desktopDisplaySections = screens.enumerated().compactMap { index, screen in
            guard let id = screen.displayID,
                  let snapshot = dockWatcher?.desktopSelection(on: id),
                  !snapshot.desktopIDs.isEmpty,
                  seenSpaces.isDisjoint(with: snapshot.desktopIDs) else { return nil }
            seenSpaces.formUnion(snapshot.desktopIDs)
            let prefix = id == CGMainDisplayID() ? "Main" : "Display \(index + 1)"
            let rawName = screen.localizedName
            let screenName: String
            if CGDisplayIsBuiltin(id) != 0, rawName.contains("Built-in") {
                screenName = "Built-in Display"
            } else {
                screenName = rawName.replacingOccurrences(of: "Built-in Retina Display", with: "Built-in Display")
            }
            return DesktopDisplaySection(name: "\(prefix): \(screenName)", snapshot: snapshot)
        }
        if screens.count > 1, desktopDisplaySections.count == 1,
           !NSScreen.screensHaveSeparateSpaces, let shared = desktopDisplaySections.first {
            desktopDisplaySections = [DesktopDisplaySection(name: "All Displays", snapshot: shared.snapshot)]
        }
        let pointer = CGEvent(source: nil)?.location
        let activeDisplayID = desktopDisplaySections.first { section in
            pointer.map { CGDisplayBounds(section.snapshot.displayID).contains($0) } ?? false
        }?.snapshot.displayID ?? displayID
        let destinations = desktopDisplaySections.compactMap { section -> DesktopChangeDestination? in
            let snapshot = section.snapshot
            if let index = snapshot.desktopIDs.firstIndex(of: snapshot.currentID) {
                return DesktopChangeDestination(displayID: snapshot.displayID, spaceID: snapshot.currentID,
                    title: "Desktop \(index + 1) of \(snapshot.desktopIDs.count)",
                    displayName: section.name, isFullscreen: false)
            }
            guard snapshot.fullscreenSpaceIDs.contains(snapshot.currentID) else { return nil }
            return DesktopChangeDestination(displayID: snapshot.displayID, spaceID: snapshot.currentID,
                title: snapshot.fullscreenApplicationNames[snapshot.currentID] ?? "Fullscreen",
                displayName: section.name, isFullscreen: true)
        }
        desktopChangeTooltip.update(
            destinations,
            preferredDisplayID: activeDisplayID
        ) { [weak self] in
            guard let self else { return false }
            return !self.isQuitting && self.monitoringShouldRun && !self.statusMenuIsOpen
                && !self.permissionSetupInProgress && self.startedPopover == nil
                && self.dockWatcher?.isMissionControlActive != true
                && !self.desktopSwitcher.isSwitching
        }
        recordDisplayUsage(activeDisplayID)
        let keys = desktopDisplaySections.map { indicatorDisplayKey($0.snapshot.displayID) }
        let order = DisplayListOrder.current.indices(keys: keys, active: indicatorDisplayKey(activeDisplayID),
            recent: UserDefaults.standard.stringArray(forKey: DisplayListOrder.historyKey) ?? [])
        let orderedSections = order.map { desktopDisplaySections[$0] }
        if isDesktopManagerEnabled {
            if desktopTilesView?.hasActiveDesktopGesture != true {
                desktopTilesView?.update(orderedSections, showLabels: screens.count > 1,
                    enabled: !desktopSwitcher.isSwitching && !desktopCreationInProgress,
                    canAdd: DockAwayDesktopCreationAvailable(),
                    canClose: DockAwayDesktopRemovalAvailable(), activeDisplayID: activeDisplayID)
            }
        }
        configureDisplayAccentTracking()
        let isCollapsing = desktopTilesView?.isAnimatingVisibility == true && !isDesktopManagerEnabled
        let shouldHideTiles = (!isDesktopManagerEnabled && !isCollapsing) || desktopDisplaySections.isEmpty
        if desktopTilesMenuItem?.isHidden != shouldHideTiles {
            desktopTilesMenuItem?.isHidden = shouldHideTiles
        }
        updateMenuBarDesktopBadge()
    }

    private func reorderDesktop(_ source: UInt64, onto target: UInt64, after: Bool = false) {
        desktopInteractionTrace("reorder requested")
        guard isDesktopManagerEnabled, !desktopCreationInProgress, !desktopSwitcher.isSwitching,
              let before = desktopDisplaySections.first(where: { $0.snapshot.managerSpaceIDs.contains(source) })?.snapshot,
              let destination = desktopDisplaySections.first(where: { $0.snapshot.managerSpaceIDs.contains(target) })?.snapshot,
              dockWatcher?.desktopSelection(on: before.displayID)?.orderedSpaceIDs == before.orderedSpaceIDs else { return }
        let crossesDisplays = before.displayID != destination.displayID
        let movesLastRegularDesktop = before.desktopIDs.contains(source) && before.desktopIDs.count <= 1
        guard !crossesDisplays || !movesLastRegularDesktop,
              dockWatcher?.desktopSelection(on: destination.displayID)?.orderedSpaceIDs == destination.orderedSpaceIDs else { return }
        let expected: [UInt64]
        var expectedDestination = destination.orderedSpaceIDs
        if crossesDisplays {
            guard let insertion = expectedDestination.firstIndex(of: target) else { return }
            expected = before.orderedSpaceIDs.filter { $0 != source }
            expectedDestination.insert(source, at: insertion + (after ? 1 : 0))
        } else {
            guard let order = before.reorderedSpaceIDs(moving: source, onto: target) else { return }
            expected = order
        }
        if statusMenuIsOpen { pendingDisplayLayoutRefresh = true }
        desktopCreationInProgress = true
        refreshDesktopTiles()
        Task { [weak self] in
            let sent = await Task.detached(priority: .userInitiated) {
                after ? DockAwayAppendDesktop(source, target) : DockAwayReorderDesktop(source, target)
            }.value
            guard let self, !self.isQuitting else { return }
            var confirmed = false
            if sent {
                for _ in 0..<20 {
                    if self.dockWatcher?.desktopSelection(on: before.displayID)?.orderedSpaceIDs == expected,
                       !crossesDisplays || self.dockWatcher?.desktopSelection(on: destination.displayID)?.orderedSpaceIDs == expectedDestination {
                        confirmed = true
                        break
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            self.desktopCreationInProgress = false
            desktopInteractionTrace("reorder finished confirmed=\(confirmed)")
            self.dockWatcher?.refreshStatus()
            self.updateDockAwayMenuState()
            if !confirmed {
                self.statusItem.menu?.cancelTracking()
                let alert = NSAlert()
                alert.messageText = crossesDisplays ? "Desktop move wasn't confirmed" : "Desktop reorder wasn't confirmed"
                alert.informativeText = "macOS did not confirm the requested order. Check Mission Control before trying again. No automatic retries were made."
                alert.runModal()
            }
        }
    }

    private func selectDesktop(_ identifier: UInt64) {
        guard isDesktopManagerEnabled, !desktopCreationInProgress else { return }
        guard let initial = desktopDisplaySections.first(where: {
            $0.snapshot.managerSpaceIDs.contains(identifier)
        })?.snapshot else { return }
        let pointerAtSelection = CGEvent(source: nil)?.location
        let crossesDisplays = pointerAtSelection.map { !CGDisplayBounds(initial.displayID).contains($0) }
            ?? (initial.displayID != desktopTileSnapshot?.displayID)
        if initial.currentID == identifier && !crossesDisplays {
            statusItem.menu?.cancelTracking()
            return
        }
        let shouldMoveCursor = crossesDisplays && (UserDefaults.standard.object(forKey: "moveCursorToSelectedDisplay") as? Bool ?? true)
        // Prevent menuDidClose from reactivating the previous application on the old desktop,
        // which triggers an incomplete macOS slide animation back to the origin space.
        settingsMenuPreviousApplication = nil
        hoverActivationController.beginSpaceTransition()
        statusItem.menu?.cancelTracking()
        desktopSwitcher.switchTo(identifier, initial: initial,
            forceDirectJump: true, snapshot: { [weak self] in
            guard let self, !self.isQuitting else { return nil }
            return self.dockWatcher?.desktopSelection(on: initial.displayID)
        }, teleport: { target, current in
            await Task.detached(priority: .userInitiated) {
                DockAwayJumpToDesktop(target, current)
            }.value
        }, completion: { [weak self] message in
            guard let self else { return }
            if message == nil {
                if shouldMoveCursor,
                   CGDisplayIsActive(initial.displayID) != 0,
                   NSEvent.pressedMouseButtons == 0 {
                    let currentPointer = CGEvent(source: nil)?.location
                    let bounds = CGDisplayBounds(initial.displayID)
                    if currentPointer == nil || !bounds.contains(currentPointer!) {
                        CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY))
                    }
                }
                DockAwayActivateSpace(identifier)
            }
            self.dockWatcher?.refreshStatus()
            self.refreshDesktopTiles()
            if let message {
                let alert = NSAlert()
                alert.messageText = "Desktop switching stopped"
                alert.informativeText = message
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        })
    }

    private func restoreMenuAfterDesktopRemoval(_ requested: Bool) {
        guard requested else { return }
        desktopMenuRestoreGeneration &+= 1
        let generation = desktopMenuRestoreGeneration
        pendingDesktopMenuRestoreGeneration = generation
        attemptDesktopMenuRestore(generation: generation, attemptsRemaining: 12)
    }

    private func attemptDesktopMenuRestore(generation: UInt, attemptsRemaining: Int) {
        guard attemptsRemaining > 0 else {
            if pendingDesktopMenuRestoreGeneration == generation {
                pendingDesktopMenuRestoreGeneration = nil
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self, !self.isQuitting,
                  self.pendingDesktopMenuRestoreGeneration == generation,
                  self.statusItem?.menu != nil else { return }
            if self.statusMenuIsOpen {
                self.attemptDesktopMenuRestore(
                    generation: generation,
                    attemptsRemaining: attemptsRemaining - 1
                )
                return
            }

            self.statusItem?.button?.performClick(nil)
            // menuWillOpen clears the token before native menu tracking begins.
            // Reaching here with the token intact means AppKit ignored the click.
            if self.pendingDesktopMenuRestoreGeneration == generation {
                self.attemptDesktopMenuRestore(
                    generation: generation,
                    attemptsRemaining: attemptsRemaining - 1
                )
            }
        }
    }

    @discardableResult
    private func closeDesktop(_ identifier: UInt64, restoreMenu: Bool = false, didSwitchAway: Bool = false) -> Bool {
        guard isDesktopManagerEnabled, !desktopCreationInProgress, !desktopSwitcher.isSwitching else {
            restoreMenuAfterDesktopRemoval(restoreMenu)
            return false
        }
        let display = desktopDisplaySections.first(where: {
            $0.snapshot.desktopIDs.contains(identifier) || $0.snapshot.fullscreenSpaceIDs.contains(identifier)
        })?.snapshot.displayID ?? NSScreen.screens.compactMap(\.displayID).first(where: { screenID in
            guard let snap = self.dockWatcher?.desktopSelection(on: screenID) else { return false }
            return snap.desktopIDs.contains(identifier) || snap.fullscreenSpaceIDs.contains(identifier)
        })
        guard let display, let before = dockWatcher?.desktopSelection(on: display) else {
            restoreMenuAfterDesktopRemoval(restoreMenu)
            return false
        }

        let isFullscreen = before.fullscreenSpaceIDs.contains(identifier)
        let isRegular = before.desktopIDs.contains(identifier)

        guard isFullscreen || (isRegular && before.desktopIDs.count > 1 && DockAwayDesktopRemovalAvailable()) else {
            restoreMenuAfterDesktopRemoval(restoreMenu)
            return false
        }

        if !isFullscreen && before.currentID == identifier {
            if didSwitchAway {
                restoreMenuAfterDesktopRemoval(restoreMenu)
                return false
            }
            guard let index = before.desktopIDs.firstIndex(of: identifier) else {
                restoreMenuAfterDesktopRemoval(restoreMenu)
                return false
            }
            let neighbor = before.desktopIDs[index + 1 < before.desktopIDs.count ? index + 1 : index - 1]

            guard neighbor != 0, neighbor != identifier else {
                restoreMenuAfterDesktopRemoval(restoreMenu)
                return false
            }

            let shouldRestoreMenu = restoreMenu || statusMenuIsOpen
            if statusMenuIsOpen || restoreMenu {
                pendingRestoredKeyboardSpaceID = neighbor
            }
            // The switch needs to end native menu tracking. Restore that menu
            // once removal finishes, rather than leaving it permanently closed.
            settingsMenuPreviousApplication = nil
            hoverActivationController.beginSpaceTransition()
            statusItem.menu?.cancelTracking()
            desktopSwitcher.switchTo(neighbor, initial: before,
                forceDirectJump: true, snapshot: { [weak self] in
                self?.dockWatcher?.desktopSelection(on: display)
            }, teleport: { target, current in
                await Task.detached(priority: .userInitiated) {
                    DockAwayJumpToDesktop(target, current)
                }.value
            }, completion: { [weak self] message in
                guard let self, !self.isQuitting else { return }
                self.refreshDesktopTiles()
                if message == nil {
                    DockAwayActivateSpace(neighbor)
                    self.closeDesktop(identifier, restoreMenu: shouldRestoreMenu, didSwitchAway: true)
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Desktop wasn't closed"
                    alert.informativeText = message ?? "Unable to switch away from the current desktop."
                    alert.runModal()
                    self.restoreMenuAfterDesktopRemoval(shouldRestoreMenu)
                }
            })
            return true
        }

        if isFullscreen && (statusMenuIsOpen || before.currentID == identifier) {
            statusItem.menu?.cancelTracking()
        }
        desktopCreationInProgress = true
        refreshDesktopTiles()
        DesktopMenuOperation.run(work: {
            isFullscreen ? DockAwayCloseFullscreenSpace(identifier) : DockAwayRemoveDesktop(identifier)
        }, attempts: 40, confirmed: { [weak self] sent in
            guard sent, let current = self?.dockWatcher?.desktopSelection(on: display) else { return false }
            return !current.orderedSpaceIDs.contains(identifier)
        }) { [weak self] _, confirmed in
            guard let self, !self.isQuitting else { return }
            self.desktopCreationInProgress = false
            self.dockWatcher?.refreshStatus()
            self.updateDockAwayMenuState()
            if !confirmed {
                self.cancelContinuousDelete()
                self.statusItem.menu?.cancelTracking()
                let alert = NSAlert()
                alert.messageText = isFullscreen ? "Fullscreen desktop wasn't closed" : "Desktop removal wasn't confirmed"
                alert.informativeText = isFullscreen
                    ? "DockAway couldn't confirm that the selected window closed or left fullscreen. The app may be waiting for you to save a document, or may not support this action. No app-wide Quit was sent. Check the window before trying again."
                    : "macOS did not confirm that the desktop was closed. Some windows may already have moved to another desktop. Check Mission Control before trying again."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            } else {
                self.restoreMenuAfterDesktopRemoval(restoreMenu)
                self.scheduleContinuousDeleteIfNeeded()
            }
        }
        return true
    }

    /// When the latest held-key add or delete began. Repeat pauses count from
    /// here, so the time macOS takes to finish an action is part of the pause.
    private var continuousActionStart: CFTimeInterval = 0

    private func progressiveActionDelay(count: Int) -> TimeInterval {
        // 0.75 s before the first repeat, then 0.1 s shorter each time, down to 0.25 s.
        let pause = max(0.25, 0.75 - Double(max(1, count) - 1) * 0.1)
        return max(0, pause - (CACurrentMediaTime() - continuousActionStart))
    }

    private var continuousDeleteTimer: DispatchWorkItem?
    private var continuousDeleteCount: Int = 0
    private var closePressOnlyMovesFocus = false

    private func cancelContinuousDelete() {
        closePressOnlyMovesFocus = false
        continuousDeleteTimer?.cancel()
        continuousDeleteTimer = nil
        continuousDeleteCount = 0
    }

    private func handleRepeatCloseKey() {
        guard !closePressOnlyMovesFocus,
              continuousDeleteTimer == nil,
              !desktopCreationInProgress,
              !desktopSwitcher.isSwitching,
              DockAwayDesktopRemovalAvailable() else { return }
        let hasDeletableDesktop = desktopDisplaySections.contains {
            $0.snapshot.desktopIDs.count > 1 || !$0.snapshot.fullscreenSpaceIDs.isEmpty
        }
        guard hasDeletableDesktop else { return }
        scheduleContinuousDeleteIfNeeded()
    }

    private func scheduleContinuousDeleteIfNeeded() {
        continuousDeleteTimer?.cancel()
        continuousDeleteTimer = nil
        guard isDesktopManagerEnabled,
              statusMenuIsOpen,
              !closePressOnlyMovesFocus,
              !desktopCreationInProgress,
              !desktopSwitcher.isSwitching,
              desktopKeyboardCapture.isCloseKeyHeld,
              let key = desktopKeyboardCapture.heldCloseKey else {
            continuousDeleteCount = 0
            return
        }

        let delay = progressiveActionDelay(count: continuousDeleteCount)
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isDesktopManagerEnabled,
                  self.statusMenuIsOpen,
                  !self.desktopCreationInProgress,
                  !self.desktopSwitcher.isSwitching,
                  self.desktopKeyboardCapture.isCloseKeyHeld else {
                self?.cancelContinuousDelete()
                return
            }
            self.continuousDeleteTimer = nil
            self.continuousDeleteCount += 1
            self.continuousActionStart = CACurrentMediaTime()
            let handled = self.desktopTilesView?.handleNavigationKey(key) ?? false
            if !handled {
                self.cancelContinuousDelete()
            }
        }
        continuousDeleteTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private var continuousAddTimer: DispatchWorkItem?
    private var continuousAddCount: Int = 0

    private func cancelContinuousAdd() {
        continuousAddTimer?.cancel()
        continuousAddTimer = nil
        continuousAddCount = 0
    }

    private func handleRepeatSelectKey() {
        guard continuousAddTimer == nil,
              !desktopCreationInProgress,
              !desktopSwitcher.isSwitching,
              DockAwayDesktopCreationAvailable(),
              case .add = desktopTilesView?.currentKeyboardTarget else { return }
        scheduleContinuousAddIfNeeded()
    }

    private func scheduleContinuousAddIfNeeded() {
        continuousAddTimer?.cancel()
        continuousAddTimer = nil
        guard isDesktopManagerEnabled,
              statusMenuIsOpen,
              !desktopCreationInProgress,
              !desktopSwitcher.isSwitching,
              desktopKeyboardCapture.isSelectKeyHeld,
              let key = desktopKeyboardCapture.heldSelectKey else {
            continuousAddCount = 0
            return
        }

        guard case .add = desktopTilesView?.currentKeyboardTarget else {
            cancelContinuousAdd()
            return
        }

        let delay = progressiveActionDelay(count: continuousAddCount)
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isDesktopManagerEnabled,
                  self.statusMenuIsOpen,
                  !self.desktopCreationInProgress,
                  !self.desktopSwitcher.isSwitching,
                  self.desktopKeyboardCapture.isSelectKeyHeld,
                  case .add = self.desktopTilesView?.currentKeyboardTarget else {
                self?.cancelContinuousAdd()
                return
            }
            self.continuousAddTimer = nil
            self.continuousAddCount += 1
            self.continuousActionStart = CACurrentMediaTime()
            let handled = self.desktopTilesView?.handleNavigationKey(key) ?? false
            if !handled {
                self.cancelContinuousAdd()
            }
        }
        continuousAddTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    @discardableResult
    private func addDesktop(on displayID: CGDirectDisplayID) -> Bool {
        guard isDesktopManagerEnabled, !desktopCreationInProgress, !desktopSwitcher.isSwitching,
              DockAwayDesktopCreationAvailable(),
              let before = dockWatcher?.desktopSelection(on: displayID),
              let anchor = before.desktopIDs.last else { return false }
        desktopCreationInProgress = true
        refreshDesktopTiles()
        DesktopMenuOperation.run(work: {
            DockAwayCreateDesktopOnDisplay(displayID, anchor)
        }, attempts: 20, confirmed: { [weak self] created in
            created != 0 && !before.orderedSpaceIDs.contains(created)
                && self?.dockWatcher?.desktopSelection(on: displayID)?.desktopIDs.contains(created) == true
        }) { [weak self] created, confirmed in
            guard let self, !self.isQuitting else { return }
            self.desktopCreationInProgress = false
            self.updateDockAwayMenuState()
            if !confirmed {
                self.statusItem.menu?.cancelTracking()
                let alert = NSAlert()
                alert.messageText = "Desktop creation wasn't confirmed"
                if created != 0, let actual = self.desktopDisplaySections.first(where: { $0.snapshot.desktopIDs.contains(created) }) {
                    alert.informativeText = "The new desktop was found on \(actual.name), but its placement on the requested display wasn't confirmed. No second desktop was created. Check Mission Control before trying again."
                } else {
                    alert.informativeText = "A new desktop could not be confirmed on the requested display. No automatic retry was made. Check Mission Control before trying again."
                }
                alert.addButton(withTitle: "OK")
                alert.runModal()
            } else {
                self.scheduleContinuousAddIfNeeded()
            }
        }
        return true
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

        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        NSApp.orderFrontStandardAboutPanel(options: [
            NSApplication.AboutPanelOptionKey.applicationName: "DockAway",
            NSApplication.AboutPanelOptionKey.credits: attributedCredits
        ])

        // Keep AppKit's standard About panel, using the avatar's sky blue.
        // A light appearance keeps its native text legible on this fixed color.
        // Accessory apps do not necessarily have a key window immediately after
        // opening this panel. Track the newly created panel and reuse it later.
        if aboutPanelWindow == nil {
            aboutPanelWindow = NSApp.windows.first {
                $0 is NSPanel && !existingWindows.contains(ObjectIdentifier($0))
            }
        }
        if let aboutPanel = aboutPanelWindow {
            aboutPanel.appearance = NSAppearance(named: .aqua)
            aboutPanel.backgroundColor = NSColor(
                srgbRed: 84.0 / 255.0,
                green: 172.0 / 255.0,
                blue: 1,
                alpha: 1
            )
            if let content = aboutPanel.contentView,
               !content.subviews.contains(where: { $0.identifier?.rawValue == "aboutSkyBackground" }) {
                let sky = NonHitTestingImageView(frame: content.bounds)
                sky.identifier = NSUserInterfaceItemIdentifier("aboutSkyBackground")
                sky.image = NSImage(named: "AboutSky")
                sky.imageScaling = .scaleAxesIndependently
                sky.autoresizingMask = [.width, .height]
                sky.setAccessibilityElement(false)
                content.addSubview(sky, positioned: .below, relativeTo: nil)
            }
        }
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
        guard !isQuitting, !permissionContinuePending, !permissionRelaunchScheduled else { return }
        if permissionSetupInProgress {
            permissionSetupWindow?.makeKeyAndOrderFront(nil)
            permissionMonitor.refresh(force: true)
            return
        }
        permissionSetupRequested = true
        permissionMonitor.refresh(force: true)
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
        permissionSetupView = setupView

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
        renderPermissionSetupState()

        let refreshTimer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            // This timer is registered exclusively on the main run loop.
            MainActor.assumeIsolated {
                guard let self, !self.permissionContinuePending,
                      self.automaticSuspensionReasons.isEmpty, !self.isQuitting else { return }
                self.permissionMonitor.refresh()
            }
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
        permissionMonitor.refresh()
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
        let windowSize = NSSize(width: 540, height: 665)
        let panelCornerRadius: CGFloat = 28
        let panel = PermissionSetupPanel(
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

        let iconView = DraggableAppIconButton(
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
        iconView.setAccessibilityHelp("Drag DockAway into a permission list in System Settings. Click to play the icon shine animation.")
        iconView.toolTip = "Drag into System Settings to add DockAway to a permission list."
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
            wrappingLabelWithString: "Let’s get DockAway ready. Enable Accessibility first. DockAway will then check whether any additional input access is needed."
        )
        introductionLabel.font = .systemFont(ofSize: 13)
        introductionLabel.textColor = .labelColor
        introductionLabel.maximumNumberOfLines = 2
        introductionLabel.alignment = .center

        let permissionHeading = NSTextField(labelWithString: "Here’s what DockAway checks:")
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
        continueButton.keyEquivalent = ""

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

        let desktopManagerHeading = NSTextField(labelWithString: "Included Features:")
        desktopManagerHeading.font = .systemFont(ofSize: 13, weight: .medium)
        desktopManagerHeading.textColor = .labelColor
        desktopManagerHeading.translatesAutoresizingMaskIntoConstraints = false

        let desktopManagerRow = OnboardingDesktopManagerRowView(
            isOn: isDesktopManagerEnabled
        ) { [weak self] enabled in
            self?.setDesktopManagerEnabled(enabled)
        }
        desktopManagerRow.translatesAutoresizingMaskIntoConstraints = false
        permissionSetupDesktopManagerRowView = desktopManagerRow

        let contentStack = NSStackView(
            views: [
                iconContainer,
                titleContainer,
                introductionLabel,
                permissionHeading,
                setupView,
                desktopManagerHeading,
                desktopManagerRow,
                bottomControlsRow
            ]
        )
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 13
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setCustomSpacing(16, after: iconContainer)
        contentStack.setCustomSpacing(12, after: titleContainer)
        contentStack.setCustomSpacing(14, after: introductionLabel)
        contentStack.setCustomSpacing(8, after: permissionHeading)
        contentStack.setCustomSpacing(14, after: setupView)
        contentStack.setCustomSpacing(8, after: desktopManagerHeading)
        contentStack.setCustomSpacing(14, after: desktopManagerRow)
        buttonStack.setHuggingPriority(.required, for: .horizontal)

        contentView.addSubview(contentStack)
        if let closeButton = NSWindow.standardWindowButton(.closeButton, for: [.titled, .closable]) {
            closeButton.target = self
            closeButton.action = #selector(closePermissionSetup)
            closeButton.keyEquivalent = "w"
            closeButton.keyEquivalentModifierMask = [.command]
            closeButton.toolTip = "Close setup. DockAway keeps running in the menu bar."
            closeButton.setAccessibilityLabel("Close onboarding")
            closeButton.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(closeButton)
            NSLayoutConstraint.activate([
                closeButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
                closeButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18)
            ])
        }
        setupView.instructionView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(setupView.instructionView)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 34),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -34),
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            iconContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            titleContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            introductionLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            setupView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            desktopManagerRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
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

        let keyboardSettingsView = OnboardingKeyboardSettingsView(
            onBack: { [weak self] in
                self?.transitionFromOnboardingStep2ToStep1()
            },
            onGetStarted: { [weak self] in
                self?.finishOnboardingFromKeyboardSettings()
            }
        )
        keyboardSettingsView.translatesAutoresizingMaskIntoConstraints = false
        keyboardSettingsView.isHidden = true
        keyboardSettingsView.alphaValue = 0
        keyboardSettingsView.onToggle = { [weak self] enabled in
            self?.setKeyboardNavigationEnabled(enabled)
        }
        keyboardSettingsView.onShortcutChanged = { [weak self] in
            self?.applyKeyboardNavigationEnabledState()
            self?.openShortcutHotKey?.reloadHotKeys()
            self?.refreshKeyboardNavigationMenu()
        }
        contentView.addSubview(keyboardSettingsView)
        permissionSetupKeyboardSettingsView = keyboardSettingsView
        permissionSetupContentStack = contentStack
        onboardingCurrentStep = 1

        NSLayoutConstraint.activate([
            keyboardSettingsView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 34),
            keyboardSettingsView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -34),
            keyboardSettingsView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            keyboardSettingsView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])

        let entranceViews: [NSView] = [
            iconContainer,
            titleContainer,
            introductionLabel,
            permissionHeading,
            setupView,
            desktopManagerHeading,
            desktopManagerRow,
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

        let armReturnKeyDelay = reduceMotion ? 0.3 : windowAnimationDuration + 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + armReturnKeyDelay) { [weak self] in
            guard let self, self.onboardingCurrentStep == 1 else { return }
            self.permissionSetupContinueButton?.keyEquivalent = "\r"
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
        guard permissionSetupInProgress, !permissionContinuePending,
              !permissionRelaunchScheduled, !isQuitting,
              automaticSuspensionReasons.isEmpty else { return }
        permissionContinueGeneration += 1
        let generation = permissionContinueGeneration
        permissionContinuePending = true
        renderPermissionSetupState()
        // Check authorization first, then actual access in this running process.
        permissionMonitor.refresh(force: true) { [weak self] snapshot in
            guard let self, self.isPermissionCompletionCurrent(generation) else { return }
            guard snapshot?.allGranted == true else {
                self.finishPermissionCompletionAttempt()
                return
            }
            self.permissionContinuePending = false
            self.renderPermissionSetupState()
            self.transitionToOnboardingStep2()
            self.runtimePermissionAccess.refresh {}
        }
    }

    private func transitionToOnboardingStep2() {
        guard onboardingCurrentStep == 1,
              let step1 = permissionSetupContentStack,
              let step2 = permissionSetupKeyboardSettingsView else { return }
        onboardingCurrentStep = 2
        permissionSetupContinueButton?.keyEquivalent = ""
        step2.prepareForOnboarding(
            applyDefaults: !UserDefaults.standard.bool(forKey: Self.permissionSetupCompletedKey)
        )

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let instructionView = permissionSetupView?.instructionView

        if reduceMotion {
            step1.isHidden = true
            instructionView?.isHidden = true
            step2.isHidden = false
            step2.alphaValue = 1
        } else {
            step1.wantsLayer = true
            step2.wantsLayer = true
            instructionView?.wantsLayer = true

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                step1.animator().alphaValue = 0
                step1.layer?.transform = CATransform3DMakeTranslation(-20, 0, 0)
                instructionView?.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self, self.onboardingCurrentStep == 2 else { return }
                step1.isHidden = true
                instructionView?.isHidden = true

                step2.isHidden = false
                step2.alphaValue = 0
                step2.layer?.transform = CATransform3DMakeTranslation(20, 0, 0)

                NSAnimationContext.runAnimationGroup { ctx2 in
                    ctx2.duration = 0.24
                    ctx2.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    step2.animator().alphaValue = 1
                    step2.layer?.transform = CATransform3DIdentity
                }
            }
        }
    }

    private func transitionFromOnboardingStep2ToStep1() {
        guard onboardingCurrentStep == 2,
              let step1 = permissionSetupContentStack,
              let step2 = permissionSetupKeyboardSettingsView else { return }
        onboardingCurrentStep = 1
        permissionSetupContinueButton?.keyEquivalent = "\r"

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let instructionView = permissionSetupView?.instructionView

        if reduceMotion {
            step2.isHidden = true
            step1.isHidden = false
            step1.alphaValue = 1
            instructionView?.isHidden = false
            instructionView?.alphaValue = 1
        } else {
            step1.wantsLayer = true
            step2.wantsLayer = true
            instructionView?.wantsLayer = true

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                step2.animator().alphaValue = 0
                step2.layer?.transform = CATransform3DMakeTranslation(20, 0, 0)
            } completionHandler: { [weak self] in
                guard let self, self.onboardingCurrentStep == 1 else { return }
                step2.isHidden = true

                step1.isHidden = false
                step1.alphaValue = 0
                step1.layer?.transform = CATransform3DMakeTranslation(-20, 0, 0)

                instructionView?.isHidden = false
                instructionView?.alphaValue = 0

                NSAnimationContext.runAnimationGroup { ctx2 in
                    ctx2.duration = 0.24
                    ctx2.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    step1.animator().alphaValue = 1
                    step1.layer?.transform = CATransform3DIdentity
                    instructionView?.animator().alphaValue = 1
                }
            }
        }
    }

    private func finishOnboardingFromKeyboardSettings() {
        guard permissionSetupInProgress, !permissionContinuePending,
              !permissionRelaunchScheduled, !isQuitting,
              automaticSuspensionReasons.isEmpty else { return }
        permissionContinueGeneration += 1
        let generation = permissionContinueGeneration
        permissionContinuePending = true

        permissionMonitor.refresh(force: true) { [weak self] snapshot in
            guard let self, self.isPermissionCompletionCurrent(generation) else { return }
            guard snapshot?.allGranted == true else {
                self.finishPermissionCompletionAttempt()
                self.transitionFromOnboardingStep2ToStep1()
                return
            }
            self.runtimePermissionAccess.refresh { [weak self] in
                guard let self, self.isPermissionCompletionCurrent(generation) else { return }
                self.confirmPermissionCompletion(generation: generation)
            }
        }
    }

    private func isPermissionCompletionCurrent(_ generation: Int) -> Bool {
        permissionContinueGeneration == generation && permissionContinuePending
            && permissionSetupInProgress && !permissionRelaunchScheduled
            && !isQuitting && automaticSuspensionReasons.isEmpty
    }

    private func finishPermissionCompletionAttempt() {
        permissionContinuePending = false
        permissionContinueGeneration += 1
        renderPermissionSetupState()
        updateDockAwayMenuState()
    }

    private func confirmPermissionCompletion(generation: Int, initializationFailed: Bool = false) {
        permissionMonitor.refresh(force: true) { [weak self] snapshot in
            guard let self, self.isPermissionCompletionCurrent(generation) else { return }
            let decision = PermissionCompletionDecision.decide(
                authorization: snapshot,
                runtime: initializationFailed ? nil : self.runtimePermissionAccess.snapshot
            )
            switch decision {
            case .remainInSetup:
                self.finishPermissionCompletionAttempt()
            case .continueInPlace:
                self.finishPermissionSetupInPlace(generation: generation)
            case .restart:
                MajorReleaseOnboarding.markCompleted()
                UserDefaults.standard.set(true, forKey: Self.permissionSetupCompletedKey)
                UserDefaults.standard.set(true, forKey: Self.showStartedPopoverAfterRelaunchKey)
                self.dismissPermissionSetup()
                self.scheduleRelaunchAfterPermissionSetup()
            }
        }
    }

    private func finishPermissionSetupInPlace(generation: Int) {
        guard isPermissionCompletionCurrent(generation) else { return }
        // Allow initialization only during this synchronous, user-approved
        // handoff. Keep the window available until monitoring has started.
        permissionSetupInProgress = false
        startMonitoringIfAllowed(resetState: true)
        permissionSetupInProgress = true
        guard dockWatcher?.isRunning == true,
              accessibilityAccessGranted, inputMonitoringAccessGranted else {
            dockWatcher?.stop()
            multitouch.stop()
            // Initialization failure is not evidence of a permission grant.
            // Reconfirm before falling back, rather than blindly restarting.
            confirmPermissionCompletion(generation: generation, initializationFailed: true)
            return
        }
        MajorReleaseOnboarding.markCompleted()
        dismissPermissionSetup(preservingPermissionState: true)
        completePermissionSetup(forceStartedPopover: true)
    }

    @objc private func cancelPermissionSetup() {
        dismissPermissionSetup()
        NSApp.terminate(self)
    }

    @objc private func closePermissionSetup() {
        permissionSetupRequested = false
        // Closing is not completion or quitting. Keep permission monitoring alive
        // and leave unfinished setup available from the menu-bar recovery action.
        dismissPermissionSetup(preservingPermissionState: true)
        updateDockAwayMenuState()
    }

    private func dismissPermissionSetup(preservingPermissionState: Bool = false) {
        permissionSetupTimer?.invalidate()
        permissionSetupTimer = nil
        permissionSetupWindow?.orderOut(nil)
        permissionSetupWindow = nil
        permissionSetupView = nil
        permissionSetupContinueButton = nil
        permissionSetupLaunchAtLoginRowView = nil
        permissionSetupDesktopManagerRowView = nil
        permissionSetupKeyboardSettingsView = nil
        permissionSetupContentStack = nil
        onboardingCurrentStep = 1
        permissionSetupInProgress = false
        permissionContinuePending = false
        permissionContinueGeneration += 1
        if !preservingPermissionState {
            permissionMonitor.stop()
            runtimePermissionAccess.invalidate()
        }
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
                self.presentPermissionSetup()
                self.permissionMonitor.refresh(force: true)
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

    private func completePermissionSetup(allowStartedPopover: Bool = true, forceStartedPopover: Bool = false) {
        guard permissionMonitor.snapshot?.allGranted == true,
              accessibilityAccessGranted, inputMonitoringAccessGranted else { return }
        let defaults = UserDefaults.standard
        let isFirstCompletedSetup = !defaults.bool(
            forKey: Self.permissionSetupCompletedKey
        )
        let shouldShowAfterRelaunch = defaults.bool(
            forKey: Self.showStartedPopoverAfterRelaunchKey
        )
        let shouldShowStartedPopover = allowStartedPopover
            && (isFirstCompletedSetup || shouldShowAfterRelaunch || forceStartedPopover)
        defaults.set(true, forKey: Self.permissionSetupCompletedKey)
        if shouldShowStartedPopover {
            defaults.set(false, forKey: Self.showStartedPopoverAfterRelaunchKey)
        }

        if dockWatcher == nil {
            dockWatcher = DockWatcher()
        }
        // Apply only after this process has usable access, whether onboarding
        // completed in place or a fallback relaunch was needed.
        if allowStartedPopover {
            removeInitialDockRevealDelayIfNeeded()
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
            title: "DockAway has successfully started ",
            detail: "You can manage it here from the menu bar.",
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
            detail = "Restore Accessibility and Input Monitoring from the menu bar by pressing the resume button."
        } else if accessibilityPermissionMissing {
            title = "Accessibility permission was revoked"
            detail = "Restore Accessibility from the menu bar by pressing the resume button to restore access."
        } else if inputMonitoringPermissionMissing {
            title = "Input Monitoring permission was revoked"
            detail = "Gesture detection is paused. Click the menu bar icon and press the resume button to restore access."
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
            // Keep Apple Color Emoji out of the vibrant button-title rendering
            // path. A non-template image preserves its colors on bright backdrops.
            let emojiText = NSAttributedString(
                string: celebrationEmoji,
                attributes: [.font: NSFont.systemFont(ofSize: 14)]
            )
            let emojiSize = emojiText.size()
            let emojiImage = NSImage(
                size: NSSize(width: ceil(emojiSize.width), height: ceil(emojiSize.height)),
                flipped: false
            ) { rect in
                emojiText.draw(at: NSPoint(
                    x: (rect.width - emojiSize.width) / 2,
                    y: (rect.height - emojiSize.height) / 2
                ))
                return true
            }
            emojiImage.isTemplate = false
            let emojiButton = NSButton(
                image: emojiImage,
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

    // MARK: - Live Permission Observation

    private func renderPermissionSetupState() {
        let snapshot = permissionMonitor.snapshot
        permissionSetupView?.update(
            accessibilityGranted: snapshot?.accessibilityGranted == true,
            inputMonitoringGranted: inputMonitoringAccessGranted,
            inputMonitoringRestartPending: inputMonitoringRestartPending,
            inputMonitoringSettingsOpen: inputMonitoringSettingsVisitInProgress,
            checkingPermissions: snapshot == nil || permissionContinuePending
        )
        permissionSetupContinueButton?.isEnabled = snapshot?.allGranted == true
            && !permissionContinuePending && !permissionRelaunchScheduled

        if onboardingCurrentStep == 2 && snapshot?.allGranted != true {
            transitionFromOnboardingStep2ToStep1()
        }
    }

    private func applyPermissionSnapshot(_ snapshot: PermissionSnapshot?) {
        guard !isQuitting else { return }
        let previouslyGranted = !accessibilityPermissionMissing && !inputMonitoringPermissionMissing
        // A failed or timed-out check is unknown, never a cached grant.
        accessibilityPermissionMissing = snapshot?.accessibilityGranted != true
        inputMonitoringPermissionMissing = snapshot?.inputMonitoringGranted != true
        refreshGreenButtonFillController()
        refreshDockIconClickMinimizeController()
        refreshChromiumWebAppPlacementController()
        refreshFinderDeleteKeyController()
        refreshHoverActivationController()
        if let snapshot, !snapshot.allGranted {
            // Drop obsolete runtime grants. Continue can reacquire them with
            // a new serialized local check, or use a restart as a fallback.
            runtimePermissionAccess.invalidate()
        }

        if !accessibilityAccessGranted || !inputMonitoringAccessGranted {
            fourFingersDown = false
            fourFingerStartedInMissionControl = false
            dockWatcher?.stop()
            multitouch.stop()
        }
        renderPermissionSetupState()
        updateDockAwayMenuState()

        if permissionSetupRequested {
            if snapshot?.allGranted == true, runtimePermissionAccess.isChecking {
                return
            }
            permissionSetupRequested = false
            let setupCompleted = UserDefaults.standard.bool(forKey: Self.permissionSetupCompletedKey)
            if setupCompleted, !MajorReleaseOnboarding.needsPresentation(),
               snapshot?.allGranted == true,
               accessibilityAccessGranted, inputMonitoringAccessGranted {
                completePermissionSetup()
            } else {
                presentPermissionSetup()
            }
            return
        }
        guard !permissionSetupInProgress, !permissionContinuePending,
              !permissionRelaunchScheduled else { return }
        if monitoringShouldRun, dockWatcher?.isRunning != true {
            startMonitoringIfAllowed(resetState: true)
        }
        if previouslyGranted, let snapshot, !snapshot.allGranted {
            showPermissionRevokedPopover()
        }
    }

    private func startPermissionHealthMonitoring() {
        permissionMonitor.onChange = { [weak self] snapshot in
            self?.applyPermissionSnapshot(snapshot)
        }
        permissionHealthTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isQuitting, !self.permissionRelaunchScheduled,
                      !self.permissionContinuePending,
                      self.automaticSuspensionReasons.isEmpty else { return }

                let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                let settingsIsFrontmost = frontmost == "com.apple.systempreferences"
                    || frontmost == "com.apple.SystemSettings"
                // Remain responsive in onboarding and Settings, even if Settings
                // was opened independently. Quiet background operation polls less.
                self.permissionMonitor.refresh(
                    minimumInterval: self.permissionSetupInProgress || settingsIsFrontmost ? 0.4 : 3
                )
            }
        }
        // Allow system timer coalescing without changing the polling interval.
        timer.tolerance = 0.05
        permissionHealthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func accessibilityPermissionWasRevoked() {
        guard !isQuitting else { return }
        // A failed protected operation is a reason to revalidate, not permission
        // to publish a cached API result as the System Settings switch state.
        runtimePermissionAccess.invalidate()
        fourFingersDown = false
        fourFingerStartedInMissionControl = false
        dockWatcher?.stop()
        multitouch.stop()
        if !permissionContinuePending {
            permissionMonitor.refresh(force: true)
            renderPermissionSetupState()
        }
        updateDockAwayMenuState()
    }

    @objc private func openAccessibilitySettings() {
        if !permissionContinuePending {
            permissionMonitor.refresh()
        }
        if let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    @objc private func openInputMonitoringSettings() {
        // Open the native pane without an additional permission request alert.
        // This flag controls instructions only, never permission observations.
        inputMonitoringSettingsVisitInProgress = true
        renderPermissionSetupState()
        if !permissionContinuePending {
            permissionMonitor.refresh()
        }
        if let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ) {
            NSWorkspace.shared.open(settingsURL)
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
            self?.permissionMonitor.stop()
            self?.runtimePermissionAccess.invalidate()
            self?.permissionSetupTimer?.invalidate()
            self?.permissionHealthTimer?.invalidate()
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
        mutedVolumeMenuBarController.stop()
        isQuitting = true
        desktopChangeTooltip.dismiss()
        DockSettingKeyRebindRowView.stopRecording()
        screenshotClipboardManager.stopMonitoring()
        greenButtonFillController.stop()
        finderDeleteKeyController.stop()
        quickLookCopyOrientationManager.stop()
        hoverActivationController.stop()
        dockIconClickMinimizeController.stop()
        chromiumWebAppPlacementController.stop()
        cursorTeleportManager?.stop()
        cursorTeleportManager = nil
        openShortcutHotKey?.disable()
        openShortcutHotKey = nil
        desktopSwitcher.cancel()
        closeStartedPopover()
        permissionHealthTimer?.invalidate()
        permissionHealthTimer = nil
        permissionSetupTimer?.invalidate()
        permissionSetupTimer = nil
        permissionContinuePending = false
        permissionMonitor.stop()
        runtimePermissionAccess.invalidate()
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

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate item: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        switch choice {
        case .skip:
            clearAvailableUpdateIndicator()
        case .dismiss, .install:
            showAvailableUpdate(item)
        @unknown default:
            showAvailableUpdate(item)
        }
    }
}

// MARK: - Sparkle Gentle Reminders

extension AppDelegate: SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    // Let Sparkle present its native update window when a scheduled or
    // launch-time check finds an update. DockAway still mirrors the available
    // version in its menu so the update remains easy to return to later.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        true
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !state.userInitiated, !handleShowingUpdate else { return }
        showAvailableUpdate(update)
    }

}

extension AppDelegate: NSMenuDelegate {
    private func installDesktopMenuDelegates(in menu: NSMenu) {
        menu.delegate = self
        for item in menu.items {
            if let submenu = item.submenu { installDesktopMenuDelegates(in: submenu) }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if statusMenuIsOpen && menu !== statusItem.menu {
            desktopKeyboardCapture.setSubmenu(menu, isOpen: true)
            cancelContinuousDelete()
            cancelContinuousAdd()
        }
        desktopChangeTooltip.dismiss()
        // Native switches use the system accent while their application is active.
        // Match a native settings panel without replacing or recoloring the control.
        if menu === statusItem.menu,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() {
            settingsMenuPreviousApplication = NSWorkspace.shared.frontmostApplication
            RunLoop.main.perform(inModes: [.common, .eventTracking]) {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        if menu === blacklistMenu {
            rebuildBlacklistMenu()
        } else if menu === hoverActivationBlacklistMenu {
            rebuildHoverActivationBlacklistMenu()
        } else if menu === dockSettingsMenu {
            refreshDockSettingsMenu()
        } else if menu === advancedSettingsMenu {
            refreshRestartDockAction()
        } else if menu === desktopIndicatorAppearanceMenu {
            refreshDesktopIndicatorAppearanceMenu()
        } else if menu === dockAwaySettingsMenu {
            refreshDockAwaySettingsMenu()
        } else if menu === desktopChangeTooltipMenu {
            refreshDesktopChangeTooltipMenu()
        } else if menu === displayOrderMenu {
            refreshDisplayOrderMenu()
        } else if menu === keyboardNavigationMenu {
            refreshKeyboardNavigationMenu()
        } else if menu === statusItem.menu {
            pendingDesktopMenuRestoreGeneration = nil
#if DEBUG
            DesktopReleaseDiagnostics.start()
#endif
            desktopInteractionTrace("status menu opening")
            statusMenuIsOpen = true
            if KeyboardNavigationPreferences.isEnabled && isDesktopManagerEnabled {
                let captured = desktopKeyboardCapture.start(action: { [weak self] key in
                    guard let self, self.statusMenuIsOpen else { return }
                    if key == 53 {
                        self.statusItem.menu?.cancelTracking()
                    } else {
                        if KeyboardNavigationPreferences.current.closeKeyCodes.contains(Int64(key)) {
                            // A press starting on + is navigation only, including
                            // autorepeats. A fresh press may delete the desktop.
                            self.closePressOnlyMovesFocus = false
                            if case .add = self.desktopTilesView?.currentKeyboardTarget {
                                self.closePressOnlyMovesFocus = true
                            }
                            self.continuousDeleteCount = 1
                            self.continuousActionStart = CACurrentMediaTime()
                        }
                        if KeyboardNavigationPreferences.current.selectKeyCodes.contains(Int64(key)) {
                            self.continuousAddCount = 1
                            self.continuousActionStart = CACurrentMediaTime()
                        }
                        _ = self.desktopTilesView?.handleNavigationKey(key)
                    }
                }, closeAction: { [weak self] in
                    guard let self, self.statusMenuIsOpen else { return }
                    self.statusItem.menu?.cancelTracking()
                }, onCloseKeyUp: { [weak self] _ in
                    self?.cancelContinuousDelete()
                }, onSelectKeyUp: { [weak self] _ in
                    self?.cancelContinuousAdd()
                }, onRepeatCloseKey: { [weak self] _ in
                    self?.handleRepeatCloseKey()
                }, onRepeatSelectKey: { [weak self] _ in
                    self?.handleRepeatSelectKey()
                })
                if !captured { dockAwayDebugLog("Desktop Manager keyboard capture unavailable; check Accessibility access") }
            }
            refreshDesktopTiles()
            if let restoreID = pendingRestoredKeyboardSpaceID {
                desktopTilesView?.restoreKeyboardFocus(to: restoreID)
                pendingRestoredKeyboardSpaceID = nil
                if desktopKeyboardCapture.isCloseKeyHeld {
                    scheduleContinuousDeleteIfNeeded()
                }
            }
            closeStartedPopover()
            dockWatcher?.refreshStatus()
            updateDockAwayMenuState()
            if isDesktopManagerEnabled {
                beginDesktopIconRefresh()
            }
            // The menu opening is an event-driven opportunity to reflect a
            // manual Dock shortcut or a permission changed in System Settings.
            applyStatusIcon(dockVisible: isDockCurrentlyVisible())
            if !permissionContinuePending {
                // Reopening the menu must not cancel a healthy in-flight probe.
                permissionMonitor.refresh()
            }
            if dockShortcutWarning != nil, DockShortcut.current() != nil {
                updateDockShortcutWarning(nil)
            }
            refreshDockSettingsMenu()
            refreshUpdateFrequencyMenu()
            refreshDesktopIndicatorAppearanceMenu()
        }
        // Include dynamically rebuilt menus so nested submenus retain native
        // arrow/Return handling for their entire tracking lifetime.
        installDesktopMenuDelegates(in: menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu !== statusItem.menu {
            desktopKeyboardCapture.setSubmenu(menu, isOpen: false)
        }
        if menu === keyboardNavigationMenu || menu === statusItem.menu {
            DockSettingKeyRebindRowView.stopRecording()
        }
        if menu === statusItem.menu {
            desktopInteractionTrace("status menu closed")
#if DEBUG
            DesktopReleaseDiagnostics.finish()
#endif
            desktopTilesView?.cancelActiveDrag()
            desktopTilesView?.finishVisibilityTransition(enabled: isDesktopManagerEnabled)
            desktopTilesMenuItem?.isHidden = !isDesktopManagerEnabled
            statusMenuIsOpen = false
            let previousApplication = settingsMenuPreviousApplication
            settingsMenuPreviousApplication = nil
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.statusMenuIsOpen, !self.desktopSwitcher.isSwitching,
                      NSApp.isActive,
                      NSApp.keyWindow == nil,
                      let previousApplication, !previousApplication.isTerminated else { return }
                // Do not steal focus from a window opened by a menu command or
                // from another application selected while dismissing the menu.
                previousApplication.activate(options: [])
            }
            desktopKeyboardCapture.stop()
            cancelContinuousDelete()
            cancelContinuousAdd()
            if pendingDesktopMenuRestoreGeneration == nil && pendingRestoredKeyboardSpaceID == nil {
                desktopTilesView?.endKeyboardNavigation()
            }
            if pendingDisplayLayoutRefresh {
                pendingDisplayLayoutRefresh = false
                DispatchQueue.main.async { [weak self] in self?.updateMenuBarDesktopBadge() }
            }
            desktopIconRefreshTask?.cancel()
            desktopIconRefreshTask = nil
        }
    }
}
