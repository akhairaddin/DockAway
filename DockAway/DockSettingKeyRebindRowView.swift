import Cocoa
import Carbon
import QuartzCore

struct ShortcutRecordingDraft {
    var heldKeys: Set<UInt16> = []
    var candidate: (keyCode: UInt16, modifiers: UInt32)?

    mutating func press(_ keyCode: UInt16, modifiers: UInt32, accepted: Bool) {
        heldKeys.insert(keyCode)
        candidate = accepted ? (keyCode, modifiers) : nil
    }

    mutating func release(_ keyCode: UInt16?, modifiers: UInt32) -> (keyCode: UInt16, modifiers: UInt32)? {
        if let keyCode { heldKeys.remove(keyCode) }
        guard heldKeys.isEmpty, modifiers == 0 else { return nil }
        defer { candidate = nil }
        return candidate
    }
}

// A translucent wash preserves the native bezel and readable keycaps.
private final class ShortcutResetFeedbackButton: NSButton, CAAnimationDelegate {
    private let resetWash = CALayer()
    private var redReachedAction: (() -> Void)?
    private var pulseCompletion: (() -> Void)?
    private var hoverTrackingArea: NSTrackingArea?
    private var hovered = false

    override var isEnabled: Bool {
        didSet {
            if !isEnabled { hovered = false }
            updateHoverScale(animated: false)
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        resetWash.frame = bounds.insetBy(dx: 1, dy: 1)
        resetWash.cornerRadius = 5
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        hoverTrackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateHoverScale(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateHoverScale(animated: true)
    }

    private func updateHoverScale(animated: Bool) {
        guard let layer else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let targetScale: CGFloat = isEnabled && hovered && !reduceMotion ? 1.035 : 1
        let presentationScale = layer.presentation()?.value(forKeyPath: "transform.scale") as? NSNumber
        let currentScale = presentationScale.map { CGFloat(truncating: $0) } ?? layer.transform.m11

        layer.removeAnimation(forKey: "shortcutHoverScale")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeScale(targetScale, targetScale, 1)
        layer.zPosition = targetScale > 1 ? 1 : 0
        CATransaction.commit()

        guard animated, !reduceMotion, abs(currentScale - targetScale) > 0.001 else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = currentScale
        scale.toValue = targetScale
        scale.duration = targetScale > 1 ? 0.13 : 0.18
        scale.timingFunction = CAMediaTimingFunction(
            name: targetScale > 1 ? .easeOut : .easeInEaseOut
        )
        layer.add(scale, forKey: "shortcutHoverScale")
    }

    func pulseReset(
        after delay: TimeInterval,
        onRedReached: (() -> Void)? = nil,
        onComplete: (() -> Void)? = nil
    ) {
        guard window != nil else {
            onRedReached?()
            onComplete?()
            return
        }
        resetWash.removeAnimation(forKey: "resetPulse")
        resetWash.removeAnimation(forKey: "resetPulseTrigger")
        redReachedAction = onRedReached
        pulseCompletion = onComplete
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            redReachedAction = nil
            pulseCompletion = nil
            onRedReached?()
            onComplete?()
            return
        }
        if resetWash.superlayer == nil {
            resetWash.opacity = 0
            layer?.addSublayer(resetWash)
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resetWash.backgroundColor = NSColor.systemRed.cgColor
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        // Keep the pulse visibly red while still allowing the shortcut keycaps
        // and native button bezel to remain readable underneath it.
        pulse.values = [0, 0.82, 0.82, 0]
        pulse.keyTimes = [0, 0.22, 0.42, 1]
        pulse.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        pulse.duration = 0.48
        pulse.beginTime = resetWash.convertTime(CACurrentMediaTime(), from: nil) + delay
        if onComplete != nil {
            pulse.delegate = self
            pulse.setValue(true, forKey: "resetPulseCompletion")
        }
        // The model stays transparent, so cancellation and completion restore it
        // without timers or delayed mutations of the shortcut's actual value.
        resetWash.add(pulse, forKey: "resetPulse")

        if onRedReached != nil {
            // Fire as the wash reaches its red plateau, so the binding changes
            // at the same visual instant the wave reaches this box.
            let trigger = CABasicAnimation(keyPath: "transform.scale")
            trigger.fromValue = 1
            trigger.toValue = 1
            trigger.duration = 0.001
            trigger.beginTime = pulse.beginTime + (pulse.duration * 0.22)
            trigger.delegate = self
            trigger.setValue(true, forKey: "resetPulseTrigger")
            resetWash.add(trigger, forKey: "resetPulseTrigger")
        }
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        guard flag else { return }
        if anim.value(forKey: "resetPulseTrigger") as? Bool == true {
            let action = redReachedAction
            redReachedAction = nil
            action?()
        } else if anim.value(forKey: "resetPulseCompletion") as? Bool == true {
            let completion = pulseCompletion
            pulseCompletion = nil
            completion?()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resetWash.removeAnimation(forKey: "resetPulse")
        resetWash.removeAnimation(forKey: "resetPulseTrigger")
        if window == nil {
            hovered = false
            updateHoverScale(animated: false)
            let action = redReachedAction
            redReachedAction = nil
            action?()
            let completion = pulseCompletion
            pulseCompletion = nil
            completion?()
        }
    }
}

// The native recorder stays attached to the selected shortcut inside the open menu.
final class DockSettingKeyRebindRowView: NSView, NSPopoverDelegate {
    let hand: NavigationHand
    let actionType: NavigationAction
    private(set) var currentKeyCode1: UInt16
    private(set) var currentModifiers1: UInt32
    private(set) var currentKeyCode2: UInt16 = KeyboardNavigationPreferences.unboundKeyCode
    private(set) var currentModifiers2: UInt32 = 0
    let hasSecondary: Bool
    private let onChange: (Int, UInt16, UInt32) -> Void
    private let settingsProvider: () -> KeyboardNavigationSettings
    private let titleLabel = NSTextField(labelWithString: "")
    private let primaryButton = ShortcutResetFeedbackButton()
    private let secondaryButton = ShortcutResetFeedbackButton()
    private var controlEnabled = true
    private var activeSlot = 1
    private var draft = ShortcutRecordingDraft()
    private var popover: NSPopover?
    private var recorderContent: ShortcutRecorderContentController?
    private var finishTimer: Timer?
    private var isFinishing = false
    private var resignObserver: NSObjectProtocol?

    private static var activeRecorder: DockSettingKeyRebindRowView?
    private static var recordingTap: EventTap?
    static var isRecording: Bool { activeRecorder != nil }

    init(hand: NavigationHand, action: NavigationAction, keyCode: UInt16,
         modifiers: UInt32 = 0, secondaryKeyCode: UInt16? = nil,
         secondaryModifiers: UInt32 = 0, width: CGFloat = 350,
         settingsProvider: @escaping () -> KeyboardNavigationSettings = { KeyboardNavigationPreferences.current },
         onChange: @escaping (Int, UInt16, UInt32) -> Void) {
        self.hand = hand
        actionType = action
        currentKeyCode1 = keyCode
        currentModifiers1 = modifiers
        hasSecondary = secondaryKeyCode != nil
        currentKeyCode2 = secondaryKeyCode ?? KeyboardNavigationPreferences.unboundKeyCode
        currentModifiers2 = secondaryModifiers
        self.onChange = onChange
        self.settingsProvider = settingsProvider
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 34))
        autoresizingMask = [.width]
        titleLabel.stringValue = action.title
        titleLabel.font = .menuFont(ofSize: 13)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        for (index, button) in [primaryButton, secondaryButton].enumerated() {
            button.tag = index + 1
            button.wantsLayer = true
            button.bezelStyle = .roundRect
            button.setButtonType(.momentaryPushIn)
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.action = #selector(beginRecording(_:))
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        let buttons = NSStackView(views: hasSecondary ? [primaryButton, secondaryButton] : [primaryButton])
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -12),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
            primaryButton.widthAnchor.constraint(equalToConstant: hasSecondary ? 86 : 122),
            primaryButton.heightAnchor.constraint(equalToConstant: 26)
        ])
        if hasSecondary {
            NSLayoutConstraint.activate([
                secondaryButton.widthAnchor.constraint(equalTo: primaryButton.widthAnchor),
                secondaryButton.heightAnchor.constraint(equalTo: primaryButton.heightAnchor)
            ])
        }
        updateBadges()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 34)
    }

    required init?(coder: NSCoder) { nil }

    func updateShortcut(keyCode: UInt16, modifiers: UInt32, slot: Int = 1) {
        if slot == 1 {
            currentKeyCode1 = keyCode
            currentModifiers1 = modifiers
        } else if slot == 2 && hasSecondary {
            currentKeyCode2 = keyCode
            currentModifiers2 = modifiers
        }
        updateBadges()
    }

    func updateShortcuts(keyCode: UInt16, modifiers: UInt32, secondaryKeyCode: UInt16? = nil,
                         secondaryModifiers: UInt32? = nil) {
        updateShortcut(keyCode: keyCode, modifiers: modifiers)
        if let secondaryKeyCode {
            updateShortcut(keyCode: secondaryKeyCode, modifiers: secondaryModifiers ?? 0, slot: 2)
        }
    }

    func animateResetFeedback(
        rowIndex: Int,
        onRedReached: (() -> Void)? = nil,
        onComplete: (() -> Void)? = nil
    ) {
        let delay = Double(rowIndex) * 0.075
        primaryButton.pulseReset(
            after: delay,
            onRedReached: onRedReached,
            onComplete: onComplete
        )
        if hasSecondary { secondaryButton.pulseReset(after: delay) }
    }

    func setControlEnabled(_ enabled: Bool) {
        controlEnabled = enabled
        if !enabled && Self.activeRecorder === self { Self.stopRecording() }
        titleLabel.textColor = enabled ? .labelColor : .secondaryLabelColor
        primaryButton.isEnabled = enabled
        secondaryButton.isEnabled = enabled
    }

    private func shortcut(slot: Int) -> (keyCode: UInt16, modifiers: UInt32) {
        slot == 1 ? (currentKeyCode1, currentModifiers1) : (currentKeyCode2, currentModifiers2)
    }

    private func updateBadges() {
        for button in [primaryButton, secondaryButton] {
            let binding = shortcut(slot: button.tag)
            let empty = binding.keyCode == KeyboardNavigationPreferences.unboundKeyCode
            let newTitle = empty ? "None"
                : KeyboardNavigationPreferences.displayName(for: binding.keyCode, modifiers: binding.modifiers)
            if button.title != newTitle {
                if window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    let transition = CATransition()
                    transition.type = .fade
                    transition.duration = 0.16
                    transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    button.layer?.add(transition, forKey: "badgeFade")
                }
                button.title = newTitle
            }
            let slotName = hasSecondary ? (button.tag == 1 ? "primary" : "alternate") : "shortcut"
            button.setAccessibilityLabel("\(hand.title), \(actionType.title), \(slotName)")
            button.setAccessibilityValue(empty ? "None" : button.title)
            button.toolTip = "Record, clear, or reset this shortcut"
        }
    }

    @objc private func beginRecording(_ sender: NSButton) {
        guard controlEnabled else { return }
        if Self.activeRecorder === self && activeSlot == sender.tag {
            Self.stopRecording()
            return
        }
        Self.stopRecording()
        Self.activeRecorder = self
        activeSlot = sender.tag
        draft = ShortcutRecordingDraft()
        isFinishing = false
        guard sender.window != nil else {
            Self.activeRecorder = nil
            return
        }
        presentRecorder(relativeTo: sender)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, Self.activeRecorder === self { Self.stopRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func presentRecorder(relativeTo anchor: NSView) {
        let current = shortcut(slot: activeSlot)
        let defaultBinding = KeyboardNavigationSettings().shortcut(for: hand, action: actionType, slot: activeSlot)
        let content = ShortcutRecorderContentController(
            title: actionType.title,
            subtitle: hand.title + (hasSecondary ? (activeSlot == 1 ? " · Primary shortcut" : " · Alternate shortcut") : ""),
            canClear: current.keyCode != KeyboardNavigationPreferences.unboundKeyCode,
            canReset: current != defaultBinding
        )
        content.onClear = { [weak self] in
            guard let self else { return }
            self.unbindSlot(self.activeSlot)
        }
        content.onReset = { [weak self] in
            guard let self else { return }
            self.resetShortcut(slot: self.activeSlot)
        }
        content.onCancel = { Self.stopRecording() }
        recorderContent = content
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = content
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        if installRecordingTap() {
            content.showKeys(keyCode: nil, modifiers: 0, message: instruction, tint: .secondaryLabelColor)
        } else {
            content.showKeys(keyCode: nil, modifiers: 0,
                message: "Allow DockAway in Accessibility settings to record a shortcut.", tint: .systemRed)
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            Self.stopRecording()
        }
    }

    private var instruction: String {
        actionType == .openMenu
            ? "Press a shortcut. Release the keys to save."
            : "Press a single key. Option can be used by itself."
    }

    func popoverDidClose(_ notification: Notification) {
        if Self.activeRecorder === self { Self.stopRecording() }
    }

    @discardableResult
    func resetShortcut(slot: Int) -> Bool {
        guard slot == 1 || (slot == 2 && hasSecondary) else { return false }
        let binding = KeyboardNavigationSettings().shortcut(for: hand, action: actionType, slot: slot)
        guard commitKey(slot: slot, newKey: binding.keyCode, modifiers: binding.modifiers) else { return false }
        if Self.activeRecorder === self { Self.stopRecording() }
        return true
    }

    func unbindSlot(_ slot: Int) {
        guard slot == 1 || (slot == 2 && hasSecondary) else { return }
        commitKey(slot: slot, newKey: KeyboardNavigationPreferences.unboundKeyCode, modifiers: 0)
        if Self.activeRecorder === self { Self.stopRecording() }
    }

    @discardableResult
    private func commitKey(slot: Int, newKey: UInt16, modifiers: UInt32) -> Bool {
        // Recording and resetting share the same final validation, including
        // changes made after a chord was first pressed.
        if let reason = Self.refusal(keyCode: newKey, modifiers: modifiers, hand: hand,
                                     action: actionType, slot: slot, settings: settingsProvider()) {
            draft = ShortcutRecordingDraft()
            recorderContent?.showKeys(keyCode: newKey, modifiers: modifiers,
                message: reason + " Change or clear that binding first.", tint: .systemRed)
            return false
        }
        updateShortcut(keyCode: newKey, modifiers: modifiers, slot: slot)
        onChange(slot, newKey, modifiers)
        return true
    }

    static func refusal(keyCode: UInt16, modifiers: UInt32, hand: NavigationHand,
                        action: NavigationAction, slot: Int, settings: KeyboardNavigationSettings) -> String? {
        if keyCode == KeyboardNavigationPreferences.unboundKeyCode { return nil }
        if action == .openMenu {
            if modifiers & UInt32(cmdKey | optionKey | controlKey) == 0 {
                return "Include ⌘, ⌥, or ⌃ to open DockAway from any app."
            }
        } else if modifiers != 0 {
            // Navigation dispatch currently matches key codes, not modifier chords.
            return "Use a single key for desktop navigation."
        }
        for otherHand in NavigationHand.allCases {
            for otherAction in NavigationAction.allCases {
                for otherSlot in 1...((otherHand == .rightHand && (otherAction == .close || otherAction == .select)) ? 2 : 1) {
                    if otherHand == hand && otherAction == action && otherSlot == slot { continue }
                    let binding = settings.shortcut(for: otherHand, action: otherAction, slot: otherSlot)
                    if binding.keyCode == keyCode && binding.modifiers == modifiers && otherAction != action {
                        return "Already used for \(otherAction.title.lowercased())."
                    }
                }
            }
        }
        return nil
    }

    static func isStandaloneOptionKey(_ keyCode: UInt16) -> Bool {
        keyCode == 58 || keyCode == 61
    }

    private func installRecordingTap() -> Bool {
        // A disabled tap ends recording in handleRecordedEvent instead of re-enabling.
        Self.recordingTap = EventTap(
            events: [.keyDown, .keyUp, .flagsChanged],
            includeEventTracking: true,
            reenablesWhenDisabled: false
        ) { type, event in
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            var modifiers: UInt32 = 0
            if event.flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
            if event.flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
            if event.flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
            if event.flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
            let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            Self.handleRecordedEvent(type, keyCode: keyCode, modifiers: modifiers, repeated: repeated)
            return type == .keyDown || type == .keyUp
        }
        return Self.recordingTap != nil
    }

    static func handleRecordedEvent(_ type: CGEventType, keyCode: UInt16, modifiers: UInt32, repeated: Bool) {
        guard let recorder = activeRecorder else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stopRecording()
            return
        }
        guard !recorder.isFinishing else { return }
        if type == .flagsChanged, isStandaloneOptionKey(keyCode) {
            let isPressed = modifiers & UInt32(optionKey) != 0
            if isPressed {
                let refusal = refusal(
                    keyCode: keyCode,
                    modifiers: 0,
                    hand: recorder.hand,
                    action: recorder.actionType,
                    slot: recorder.activeSlot,
                    settings: recorder.settingsProvider()
                )
                recorder.draft.press(keyCode, modifiers: 0, accepted: refusal == nil)
                recorder.recorderContent?.showKeys(
                    keyCode: keyCode,
                    modifiers: 0,
                    message: refusal ?? "Release to save",
                    tint: refusal == nil ? .controlAccentColor : .systemRed
                )
            } else if let binding = recorder.draft.release(keyCode, modifiers: 0) {
                recorder.finish(binding)
            }
        } else if type == .keyDown {
            guard !repeated else { return }
            if keyCode == 53 && modifiers == 0 { stopRecording(); return }
            let refusal = refusal(keyCode: keyCode, modifiers: modifiers, hand: recorder.hand,
                action: recorder.actionType, slot: recorder.activeSlot, settings: recorder.settingsProvider())
            recorder.draft.press(keyCode, modifiers: modifiers, accepted: refusal == nil)
            recorder.recorderContent?.showKeys(keyCode: keyCode, modifiers: modifiers,
                message: refusal ?? "Release to save", tint: refusal == nil ? .controlAccentColor : .systemRed)
        } else if type == .keyUp || type == .flagsChanged {
            if let binding = recorder.draft.release(type == .keyUp ? keyCode : nil, modifiers: modifiers) {
                recorder.finish(binding)
            } else if type == .flagsChanged && recorder.draft.heldKeys.isEmpty && recorder.draft.candidate == nil {
                recorder.recorderContent?.showKeys(keyCode: nil, modifiers: modifiers,
                    message: recorder.instruction, tint: .secondaryLabelColor)
            }
        }
    }

    private func finish(_ binding: (keyCode: UInt16, modifiers: UInt32)) {
        guard commitKey(slot: activeSlot, newKey: binding.keyCode, modifiers: binding.modifiers) else { return }
        isFinishing = true
        recorderContent?.showKeys(keyCode: binding.keyCode, modifiers: binding.modifiers,
            message: "Shortcut saved", tint: .systemGreen)
        // Keep the confirmation visible briefly; swallow the end of the chord.
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let self, Self.activeRecorder === self else { return }
            Self.stopRecording()
        }
        finishTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    static func stopRecording() {
        recordingTap?.invalidate()
        recordingTap = nil
        let recorder = activeRecorder
        activeRecorder = nil
        recorder?.finishTimer?.invalidate()
        recorder?.finishTimer = nil
        if let observer = recorder?.resignObserver { NotificationCenter.default.removeObserver(observer) }
        recorder?.resignObserver = nil
        recorder?.popover?.close()
        recorder?.popover = nil
        recorder?.recorderContent = nil
        recorder?.draft = ShortcutRecordingDraft()
        recorder?.isFinishing = false
    }
}

final class ShortcutRecorderContentController: NSViewController {
    var onClear: (() -> Void)?
    var onReset: (() -> Void)?
    var onCancel: (() -> Void)?
    private let keycaps = NSStackView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let heading: String
    private let subtitle: String
    private let canClear: Bool
    private let canReset: Bool

    init(title: String, subtitle: String, canClear: Bool, canReset: Bool) {
        heading = title
        self.subtitle = subtitle
        self.canClear = canClear
        self.canReset = canReset
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 230))
        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let detail = NSTextField(labelWithString: subtitle)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        keycaps.wantsLayer = true
        keycaps.orientation = .horizontal
        keycaps.spacing = 6
        keycaps.alignment = .centerY
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 2
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearShortcut))
        clear.isEnabled = canClear
        let reset = NSButton(title: "Reset to Default", target: self, action: #selector(resetShortcut))
        reset.isEnabled = canReset
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelRecording))
        let actions = NSStackView(views: [clear, reset, cancel])
        actions.spacing = 8
        for button in [clear, reset, cancel] { button.bezelStyle = .rounded }
        let hint = NSTextField(labelWithString: "Esc to cancel")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor

        for child in [title, detail, keycaps, messageLabel, actions, hint] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
            child.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            keycaps.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 18),
            keycaps.heightAnchor.constraint(equalToConstant: 48),
            messageLabel.topAnchor.constraint(equalTo: keycaps.bottomAnchor, constant: 12),
            messageLabel.widthAnchor.constraint(equalToConstant: 320),
            messageLabel.heightAnchor.constraint(equalToConstant: 32),
            actions.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 10),
            hint.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 10)
        ])
    }

    func showKeys(keyCode: UInt16?, modifiers: UInt32, message: String, tint: NSColor) {
        loadViewIfNeeded()
        keycaps.arrangedSubviews.forEach { keycaps.removeArrangedSubview($0); $0.removeFromSuperview() }
        var symbols: [String] = []
        for (flag, symbol) in [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")] {
            if modifiers & UInt32(flag) != 0 { symbols.append(symbol) }
        }
        if let keyCode { symbols.append(KeyboardNavigationPreferences.displayName(for: keyCode)) }
        if symbols.isEmpty { symbols = ["Press a key"] }
        for symbol in symbols {
            let cap = NSTextField(labelWithString: symbol)
            cap.font = .systemFont(ofSize: 18, weight: .medium)
            cap.alignment = .center
            cap.textColor = keyCode == nil && modifiers == 0 ? .tertiaryLabelColor : .labelColor
            let box = NSBox()
            box.boxType = .custom
            box.cornerRadius = 7
            box.borderColor = keyCode == nil ? .separatorColor : tint.withAlphaComponent(0.55)
            box.fillColor = .controlBackgroundColor
            box.contentViewMargins = .zero
            box.contentView?.addSubview(cap)
            cap.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                box.widthAnchor.constraint(equalToConstant: max(44, cap.intrinsicContentSize.width + 22)),
                box.heightAnchor.constraint(equalToConstant: 44),
                cap.centerXAnchor.constraint(equalTo: box.contentView!.centerXAnchor),
                cap.centerYAnchor.constraint(equalTo: box.contentView!.centerYAnchor)
            ])
            keycaps.addArrangedSubview(box)
        }
        if view.window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.12
            keycaps.layer?.add(transition, forKey: "recordedKeys")
        }
        messageLabel.stringValue = message
        messageLabel.textColor = tint
        view.layoutSubtreeIfNeeded()
        NSAccessibility.post(element: messageLabel, notification: .valueChanged)
    }

    @objc private func clearShortcut() { onClear?() }
    @objc private func resetShortcut() { onReset?() }
    @objc private func cancelRecording() { onCancel?() }
}
