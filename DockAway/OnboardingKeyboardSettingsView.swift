import Cocoa
import Carbon
import QuartzCore
import SwiftUI

final class OnboardingKeyboardSettingsView: NSView {
    // Callbacks
    private let onBack: () -> Void
    private let onGetStarted: () -> Void
    var onShortcutChanged: (() -> Void)?
    var onToggle: ((Bool) -> Void)?

    // Header Views
    private let iconContainer = NSView()
    private let iconImageView = NSImageView()
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private let headerStack: NSStackView

    // One grouped card for the master switch and its hand-specific options.
    private let keyboardNavigationCard = NSView()
    private let masterToggle = DockMenuSwitch()
    private let controlsSeparator = NSView()

    // Each hand option combines layout selection with its independent enable switch.
    private let handOptionStack = NSStackView()
    private let leftHandOption = KeyboardHandOptionCardView(
        title: "Left Hand",
        detail: "WASD keys",
        accessibilityLabel: "Enable Left Hand keyboard navigation"
    )
    private let rightHandOption = KeyboardHandOptionCardView(
        title: "Right Hand",
        detail: "Arrow keys",
        accessibilityLabel: "Enable Right Hand keyboard navigation"
    )
    private var selectedHand: NavigationHand = .rightHand
    private var hasPreparedOnboarding = false

    // Shortcuts Card
    private let shortcutsCard = NSView()
    private let rightHandStack = NSStackView()
    private let leftHandStack = NSStackView()
    private var rightHandRows: [DockSettingKeyRebindRowView] = []
    private var leftHandRows: [DockSettingKeyRebindRowView] = []
    private let resetButton = NSButton()
    private var isResetting = false
    private var resetSuccessTimer: Timer?

    // Bottom Controls
    private let backButton = NSButton()
    private let getStartedButton: OnboardingPrimaryButton
    private let bottomControlsStack = NSStackView()
    private let shortcutRowHeight: CGFloat

    init(
        compact: Bool = false,
        onBack: @escaping () -> Void,
        onGetStarted: @escaping () -> Void
    ) {
        self.onBack = onBack
        self.onGetStarted = onGetStarted
        shortcutRowHeight = compact ? 32 : 34

        // Header
        titleLabel = NSTextField(labelWithString: "Desktop Manager Keyboard Navigation")
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center

        subtitleLabel = NSTextField(
            wrappingLabelWithString: "Switch, create, and close desktops across displays from your keyboard."
        )
        subtitleLabel.font = .systemFont(ofSize: 12.5)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 2

        // Icon
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.wantsLayer = true
        iconContainer.layer?.cornerRadius = 12
        iconContainer.layer?.cornerCurve = .continuous
        iconContainer.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.image = NSImage(
            systemSymbolName: "keyboard",
            accessibilityDescription: "Keyboard Navigation"
        )
        iconImageView.contentTintColor = .systemBlue
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconContainer.addSubview(iconImageView)

        NSLayoutConstraint.activate([
            iconContainer.widthAnchor.constraint(equalToConstant: compact ? 32 : 44),
            iconContainer.heightAnchor.constraint(equalToConstant: compact ? 32 : 44),
            iconImageView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 24),
            iconImageView.heightAnchor.constraint(equalToConstant: 24)
        ])

        headerStack = NSStackView(views: [iconContainer, titleLabel, subtitleLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .centerX
        headerStack.spacing = compact ? 4 : 6
        headerStack.setCustomSpacing(compact ? 6 : 8, after: iconContainer)
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        // Keep the master switch, hand switches, and binding selector together
        // so they read as one keyboard-navigation setup instead of separate cards.
        keyboardNavigationCard.translatesAutoresizingMaskIntoConstraints = false
        keyboardNavigationCard.wantsLayer = true
        keyboardNavigationCard.layer?.cornerRadius = 10
        keyboardNavigationCard.layer?.borderWidth = 0.5
        keyboardNavigationCard.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        keyboardNavigationCard.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.38).cgColor

        masterToggle.translatesAutoresizingMaskIntoConstraints = false
        masterToggle.swiftUIControlSize = .regular
        masterToggle.showsLabel = true
        masterToggle.detailLabel = "Control Spaces and switch desktops using hotkeys"
        masterToggle.state = KeyboardNavigationPreferences.isEnabled ? .on : .off
        masterToggle.setAccessibilityLabel("Enable Keyboard Navigation")

        controlsSeparator.translatesAutoresizingMaskIntoConstraints = false
        controlsSeparator.wantsLayer = true
        controlsSeparator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor

        // Hand cards combine choosing a shortcut set with toggling that set on
        // or off. Their switches remain usable while the master toggle is off.
        leftHandOption.handToggle.state = KeyboardNavigationPreferences.isLeftHandEnabled ? .on : .off
        rightHandOption.handToggle.state = KeyboardNavigationPreferences.isRightHandEnabled ? .on : .off
        handOptionStack.orientation = .horizontal
        handOptionStack.alignment = .centerY
        handOptionStack.distribution = .fillEqually
        handOptionStack.spacing = 8
        handOptionStack.translatesAutoresizingMaskIntoConstraints = false
        handOptionStack.addArrangedSubview(leftHandOption)
        handOptionStack.addArrangedSubview(rightHandOption)

        keyboardNavigationCard.addSubview(masterToggle)
        keyboardNavigationCard.addSubview(controlsSeparator)
        keyboardNavigationCard.addSubview(handOptionStack)

        NSLayoutConstraint.activate([
            masterToggle.leadingAnchor.constraint(equalTo: keyboardNavigationCard.leadingAnchor, constant: 14),
            masterToggle.trailingAnchor.constraint(equalTo: keyboardNavigationCard.trailingAnchor, constant: -14),
            masterToggle.topAnchor.constraint(equalTo: keyboardNavigationCard.topAnchor, constant: compact ? 6 : 8),

            controlsSeparator.topAnchor.constraint(equalTo: masterToggle.bottomAnchor, constant: compact ? 6 : 10),
            controlsSeparator.leadingAnchor.constraint(equalTo: keyboardNavigationCard.leadingAnchor, constant: 14),
            controlsSeparator.trailingAnchor.constraint(equalTo: keyboardNavigationCard.trailingAnchor, constant: -14),
            controlsSeparator.heightAnchor.constraint(equalToConstant: 1),

            handOptionStack.topAnchor.constraint(equalTo: controlsSeparator.bottomAnchor, constant: compact ? 6 : 8),
            handOptionStack.leadingAnchor.constraint(equalTo: keyboardNavigationCard.leadingAnchor, constant: 10),
            handOptionStack.trailingAnchor.constraint(equalTo: keyboardNavigationCard.trailingAnchor, constant: -10),
            handOptionStack.heightAnchor.constraint(equalToConstant: compact ? 48 : 56),
            handOptionStack.bottomAnchor.constraint(equalTo: keyboardNavigationCard.bottomAnchor, constant: -6)
        ])

        // Shortcuts Card
        shortcutsCard.translatesAutoresizingMaskIntoConstraints = false
        shortcutsCard.wantsLayer = true
        shortcutsCard.layer?.cornerRadius = 10
        shortcutsCard.layer?.borderWidth = 0.5
        shortcutsCard.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        shortcutsCard.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.38).cgColor

        let rowsContainer = NSView()
        rowsContainer.translatesAutoresizingMaskIntoConstraints = false

        rightHandStack.orientation = .vertical
        rightHandStack.alignment = .width
        rightHandStack.spacing = 1
        rightHandStack.translatesAutoresizingMaskIntoConstraints = false

        leftHandStack.orientation = .vertical
        leftHandStack.alignment = .width
        leftHandStack.spacing = 1
        leftHandStack.translatesAutoresizingMaskIntoConstraints = false
        leftHandStack.isHidden = true

        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .regular
        resetButton.wantsLayer = true
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        if let icon = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset to Defaults")?.withSymbolConfiguration(config) {
            resetButton.image = icon
            resetButton.imagePosition = .imageLeading
        }
        resetButton.attributedTitle = NSAttributedString(
            string: "Reset to Defaults",
            attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 13, weight: .regular)
            ]
        )
        resetButton.translatesAutoresizingMaskIntoConstraints = false

        shortcutsCard.addSubview(rowsContainer)
        shortcutsCard.addSubview(resetButton)

        rowsContainer.addSubview(rightHandStack)
        rowsContainer.addSubview(leftHandStack)

        NSLayoutConstraint.activate([
            rowsContainer.topAnchor.constraint(equalTo: shortcutsCard.topAnchor, constant: 6),
            rowsContainer.leadingAnchor.constraint(equalTo: shortcutsCard.leadingAnchor, constant: 8),
            rowsContainer.trailingAnchor.constraint(equalTo: shortcutsCard.trailingAnchor, constant: -8),

            rightHandStack.topAnchor.constraint(equalTo: rowsContainer.topAnchor),
            rightHandStack.leadingAnchor.constraint(equalTo: rowsContainer.leadingAnchor),
            rightHandStack.trailingAnchor.constraint(equalTo: rowsContainer.trailingAnchor),
            rightHandStack.bottomAnchor.constraint(equalTo: rowsContainer.bottomAnchor),

            leftHandStack.topAnchor.constraint(equalTo: rowsContainer.topAnchor),
            leftHandStack.leadingAnchor.constraint(equalTo: rowsContainer.leadingAnchor),
            leftHandStack.trailingAnchor.constraint(equalTo: rowsContainer.trailingAnchor),
            leftHandStack.bottomAnchor.constraint(equalTo: rowsContainer.bottomAnchor),

            resetButton.topAnchor.constraint(equalTo: rowsContainer.bottomAnchor, constant: compact ? 6 : 8),
            resetButton.centerXAnchor.constraint(equalTo: shortcutsCard.centerXAnchor),
            resetButton.bottomAnchor.constraint(equalTo: shortcutsCard.bottomAnchor, constant: compact ? -6 : -9)
        ])

        // Bottom Controls
        backButton.title = "Back"
        backButton.bezelStyle = .automatic
        backButton.controlSize = .large
        backButton.keyEquivalent = "\u{1b}"
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.widthAnchor.constraint(equalToConstant: 88).isActive = true
        if #available(macOS 26.0, *) {
            backButton.borderShape = .capsule
        }

        getStartedButton = OnboardingPrimaryButton(title: "Get Started", target: nil, action: nil)
        getStartedButton.controlSize = .large
        getStartedButton.keyEquivalent = "\r"
        getStartedButton.translatesAutoresizingMaskIntoConstraints = false
        getStartedButton.widthAnchor.constraint(equalToConstant: 114).isActive = true

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        bottomControlsStack.orientation = .horizontal
        bottomControlsStack.alignment = .centerY
        bottomControlsStack.translatesAutoresizingMaskIntoConstraints = false
        bottomControlsStack.heightAnchor.constraint(equalToConstant: 32).isActive = true
        bottomControlsStack.addArrangedSubview(backButton)
        bottomControlsStack.addArrangedSubview(spacer)
        bottomControlsStack.addArrangedSubview(getStartedButton)

        super.init(frame: .zero)

        // Add subviews to main view
        addSubview(headerStack)
        addSubview(keyboardNavigationCard)
        addSubview(shortcutsCard)
        addSubview(bottomControlsStack)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: topAnchor),
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: trailingAnchor),

            keyboardNavigationCard.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: compact ? 8 : 12),
            keyboardNavigationCard.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyboardNavigationCard.trailingAnchor.constraint(equalTo: trailingAnchor),

            shortcutsCard.topAnchor.constraint(equalTo: keyboardNavigationCard.bottomAnchor, constant: compact ? 8 : 10),
            shortcutsCard.leadingAnchor.constraint(equalTo: leadingAnchor),
            shortcutsCard.trailingAnchor.constraint(equalTo: trailingAnchor),

            bottomControlsStack.topAnchor.constraint(greaterThanOrEqualTo: shortcutsCard.bottomAnchor, constant: compact ? 10 : 16),
            bottomControlsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomControlsStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomControlsStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // Wire actions
        masterToggle.target = self
        masterToggle.action = #selector(handleMasterToggleChanged(_:))

        leftHandOption.onSelect = { [weak self] in self?.selectHand(.leftHand) }
        rightHandOption.onSelect = { [weak self] in self?.selectHand(.rightHand) }
        leftHandOption.handToggle.target = self
        leftHandOption.handToggle.action = #selector(handleHandToggleChanged(_:))
        rightHandOption.handToggle.target = self
        rightHandOption.handToggle.action = #selector(handleHandToggleChanged(_:))
        selectHand(.rightHand)

        resetButton.target = self
        resetButton.action = #selector(handleResetClicked(_:))

        backButton.target = self
        backButton.action = #selector(handleBackClicked(_:))

        getStartedButton.target = self
        getStartedButton.action = #selector(handleGetStartedClicked(_:))

        buildRows()
        updateVisualState(isOn: KeyboardNavigationPreferences.isEnabled, animated: false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        resetSuccessTimer?.invalidate()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            resetSuccessTimer?.invalidate()
            resetSuccessTimer = nil
            if isResetting {
                restoreResetButton(animated: false)
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        keyboardNavigationCard.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        keyboardNavigationCard.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.38).cgColor
        controlsSeparator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        shortcutsCard.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        shortcutsCard.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.38).cgColor
        iconContainer.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor
    }

    private func buildRows() {
        let rowWidth: CGFloat = 456
        let settings = KeyboardNavigationPreferences.current
        let isNavEnabled = KeyboardNavigationPreferences.isEnabled

        // Right Hand Rows
        rightHandRows.removeAll()
        for subview in rightHandStack.arrangedSubviews {
            subview.removeFromSuperview()
        }
        for action in NavigationAction.allCases {
            let sc = settings.shortcut(for: .rightHand, action: action, slot: 1)
            let isDual = (action == .close || action == .select)
            let secSc = isDual ? settings.shortcut(for: .rightHand, action: action, slot: 2) : nil
            let row = DockSettingKeyRebindRowView(
                hand: .rightHand,
                action: action,
                keyCode: sc.keyCode,
                modifiers: sc.modifiers,
                secondaryKeyCode: secSc?.keyCode,
                secondaryModifiers: secSc?.modifiers ?? 0,
                width: rowWidth
            ) { [weak self] slot, newCode, newMods in
                guard let self else { return }
                var s = KeyboardNavigationPreferences.current
                s.setShortcut(keyCode: newCode, modifiers: newMods, for: .rightHand, action: action, slot: slot)
                KeyboardNavigationPreferences.current = s
                self.onShortcutChanged?()
            }
            row.setControlEnabled(isNavEnabled && KeyboardNavigationPreferences.isRightHandEnabled)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: shortcutRowHeight).isActive = true
            rightHandStack.addArrangedSubview(row)
            rightHandRows.append(row)
        }

        // Left Hand Rows
        leftHandRows.removeAll()
        for subview in leftHandStack.arrangedSubviews {
            subview.removeFromSuperview()
        }
        for action in NavigationAction.allCases {
            let sc = settings.shortcut(for: .leftHand, action: action, slot: 1)
            let row = DockSettingKeyRebindRowView(
                hand: .leftHand,
                action: action,
                keyCode: sc.keyCode,
                modifiers: sc.modifiers,
                width: rowWidth
            ) { [weak self] slot, newCode, newMods in
                guard let self else { return }
                var s = KeyboardNavigationPreferences.current
                s.setShortcut(keyCode: newCode, modifiers: newMods, for: .leftHand, action: action, slot: slot)
                KeyboardNavigationPreferences.current = s
                self.onShortcutChanged?()
            }
            row.setControlEnabled(isNavEnabled && KeyboardNavigationPreferences.isLeftHandEnabled)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: shortcutRowHeight).isActive = true
            leftHandStack.addArrangedSubview(row)
            leftHandRows.append(row)
        }
    }

    func prepareForOnboarding(applyDefaults: Bool = true) {
        if !hasPreparedOnboarding && applyDefaults {
            hasPreparedOnboarding = true
            KeyboardNavigationPreferences.isRightHandEnabled = true
            KeyboardNavigationPreferences.isLeftHandEnabled = true
            KeyboardNavigationPreferences.isEnabled = true
            onToggle?(true)
            onShortcutChanged?()
        }
        refreshRows()
    }

    func refreshRows() {
        let settings = KeyboardNavigationPreferences.current
        let isNavEnabled = KeyboardNavigationPreferences.isEnabled
        masterToggle.state = isNavEnabled ? .on : .off
        leftHandOption.handToggle.state = KeyboardNavigationPreferences.isLeftHandEnabled ? .on : .off
        rightHandOption.handToggle.state = KeyboardNavigationPreferences.isRightHandEnabled ? .on : .off
        updateVisualState(isOn: isNavEnabled, animated: false)

        for row in rightHandRows {
            let sc1 = settings.shortcut(for: .rightHand, action: row.actionType, slot: 1)
            let sc2 = row.hasSecondary ? settings.shortcut(for: .rightHand, action: row.actionType, slot: 2) : nil
            row.updateShortcuts(
                keyCode: sc1.keyCode,
                modifiers: sc1.modifiers,
                secondaryKeyCode: sc2?.keyCode,
                secondaryModifiers: sc2?.modifiers
            )
            row.setControlEnabled(isNavEnabled && KeyboardNavigationPreferences.isRightHandEnabled)
        }
        for row in leftHandRows {
            let sc1 = settings.shortcut(for: .leftHand, action: row.actionType, slot: 1)
            row.updateShortcuts(
                keyCode: sc1.keyCode,
                modifiers: sc1.modifiers
            )
            row.setControlEnabled(isNavEnabled && KeyboardNavigationPreferences.isLeftHandEnabled)
        }
    }

    private func selectHand(_ hand: NavigationHand) {
        selectedHand = hand
        leftHandOption.isSelected = hand == .leftHand
        rightHandOption.isSelected = hand == .rightHand
        rightHandStack.isHidden = hand != .rightHand
        leftHandStack.isHidden = hand != .leftHand
    }

    @objc private func handleMasterToggleChanged(_ sender: DockMenuSwitch) {
        KeyboardNavigationPreferences.isEnabled = sender.state == .on
        let isEnabled = KeyboardNavigationPreferences.isEnabled
        sender.state = isEnabled ? .on : .off
        updateVisualState(isOn: isEnabled, animated: true)
        for row in rightHandRows {
            row.setControlEnabled(isEnabled && KeyboardNavigationPreferences.isRightHandEnabled)
        }
        for row in leftHandRows {
            row.setControlEnabled(isEnabled && KeyboardNavigationPreferences.isLeftHandEnabled)
        }
        onToggle?(isEnabled)
        onShortcutChanged?()
    }

    @objc private func handleHandToggleChanged(_ sender: DockMenuSwitch) {
        let hand: NavigationHand = sender === leftHandOption.handToggle ? .leftHand : .rightHand
        KeyboardNavigationPreferences.setHandEnabled(hand, enabled: sender.state == .on)
        refreshRows()
        onShortcutChanged?()
    }

    private func updateVisualState(isOn: Bool, animated: Bool) {
        let targetAlpha: CGFloat = isOn ? 1.0 : 0.45
        leftHandOption.handToggle.state = isOn && KeyboardNavigationPreferences.isLeftHandEnabled ? .on : .off
        rightHandOption.handToggle.state = isOn && KeyboardNavigationPreferences.isRightHandEnabled ? .on : .off
        leftHandOption.selectionEnabled = isOn
        rightHandOption.selectionEnabled = isOn
        resetButton.isEnabled = isOn && !isResetting

        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                shortcutsCard.animator().alphaValue = targetAlpha
            }
        } else {
            shortcutsCard.alphaValue = targetAlpha
        }
    }

    @objc private func handleResetClicked(_ sender: NSButton) {
        guard !isResetting else { return }
        isResetting = true
        resetButton.isEnabled = false

        let isRightHand = selectedHand == .rightHand
        let visibleRows = isRightHand ? Array(rightHandRows.reversed()) : Array(leftHandRows.reversed())
        let otherRows = isRightHand ? leftHandRows : rightHandRows
        let defaults = KeyboardNavigationSettings()

        // 1. Reset all persistent settings to defaults
        KeyboardNavigationPreferences.resetToDefaults()

        // 2. Immediately update the non-visible hand's rows so switching hands reflects defaults
        for row in otherRows {
            let sc1 = defaults.shortcut(for: row.hand, action: row.actionType, slot: 1)
            let sc2: (keyCode: UInt16, modifiers: UInt32)? = row.hasSecondary ? defaults.shortcut(for: row.hand, action: row.actionType, slot: 2) : nil
            row.updateShortcuts(
                keyCode: sc1.keyCode,
                modifiers: sc1.modifiers,
                secondaryKeyCode: sc2?.keyCode,
                secondaryModifiers: sc2?.modifiers
            )
        }

        if visibleRows.isEmpty {
            refreshRows()
            onShortcutChanged?()
            showResetSuccess()
            return
        }

        let rowCount = visibleRows.count
        for (index, row) in visibleRows.enumerated() {
            let isFinal = (index == rowCount - 1)
            row.animateResetFeedback(
                rowIndex: index,
                onRedReached: { [weak self, weak row] in
                    guard let self, let row else { return }
                    let sc1 = defaults.shortcut(for: row.hand, action: row.actionType, slot: 1)
                    let sc2: (keyCode: UInt16, modifiers: UInt32)? = row.hasSecondary ? defaults.shortcut(for: row.hand, action: row.actionType, slot: 2) : nil
                    row.updateShortcuts(
                        keyCode: sc1.keyCode,
                        modifiers: sc1.modifiers,
                        secondaryKeyCode: sc2?.keyCode,
                        secondaryModifiers: sc2?.modifiers
                    )
                    if isFinal {
                        self.onShortcutChanged?()
                    }
                },
                onComplete: isFinal ? { [weak self] in
                    self?.showResetSuccess()
                } : nil
            )
        }
    }

    private func showResetSuccess() {
        resetSuccessTimer?.invalidate()
        resetSuccessTimer = nil

        let checkmarkConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .systemGreen]))
        let checkmarkImage = NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: "Shortcuts Reset"
        )?.withSymbolConfiguration(checkmarkConfig)

        applyResetButtonTransition()
        resetButton.attributedTitle = NSAttributedString(
            string: "Shortcuts Reset",
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 13, weight: .regular)
            ]
        )
        resetButton.image = checkmarkImage
        resetButton.imagePosition = .imageTrailing
        resetButton.isEnabled = true

        let timer = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restoreResetButton()
            }
        }
        resetSuccessTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func restoreResetButton(animated: Bool = true) {
        resetSuccessTimer?.invalidate()
        resetSuccessTimer = nil

        let normalConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        let normalImage = NSImage(
            systemSymbolName: "arrow.counterclockwise",
            accessibilityDescription: "Reset to Defaults"
        )?.withSymbolConfiguration(normalConfig)

        if animated {
            applyResetButtonTransition()
        }
        resetButton.attributedTitle = NSAttributedString(
            string: "Reset to Defaults",
            attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 13, weight: .regular)
            ]
        )
        resetButton.image = normalImage
        resetButton.imagePosition = .imageLeading

        isResetting = false
        resetButton.isEnabled = masterToggle.state == .on
    }

    private func applyResetButtonTransition() {
        guard window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.2
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        resetButton.layer?.add(transition, forKey: "resetButtonFade")
    }

    @objc private func handleBackClicked(_ sender: NSButton) {
        onBack()
    }

    @objc private func handleGetStartedClicked(_ sender: NSButton) {
        onGetStarted()
    }
}

private final class KeyboardHandOptionCardView: NSView {
    private let title: String
    private let detail: String
    private let selectionButton = NSButton()
    private let detailLabel = NSTextField(labelWithString: "")
    let handToggle = DockMenuSwitch()
    var onSelect: (() -> Void)?

    var isSelected = false {
        didSet { updateSelectionAppearance() }
    }

    var selectionEnabled = true {
        didSet { updateSelectionAppearance() }
    }

    init(title: String, detail: String, accessibilityLabel: String) {
        self.title = title
        self.detail = detail
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        selectionButton.setButtonType(.radio)
        selectionButton.bezelStyle = .regularSquare
        selectionButton.isBordered = false
        selectionButton.controlSize = .small
        selectionButton.translatesAutoresizingMaskIntoConstraints = false
        selectionButton.target = self
        selectionButton.action = #selector(selectOption(_:))
        selectionButton.setAccessibilityLabel("Select \(title) shortcuts")
        selectionButton.setAccessibilityHelp("Show the \(detail) shortcut layout for editing")

        detailLabel.stringValue = detail
        detailLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        detailLabel.maximumNumberOfLines = 1
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        handToggle.swiftUIControlSize = .small
        handToggle.showsLabel = false
        handToggle.setAccessibilityLabel(accessibilityLabel)
        handToggle.translatesAutoresizingMaskIntoConstraints = false

        addSubview(selectionButton)
        addSubview(detailLabel)
        addSubview(handToggle)

        NSLayoutConstraint.activate([
            selectionButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            selectionButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            selectionButton.trailingAnchor.constraint(lessThanOrEqualTo: handToggle.leadingAnchor, constant: -6),
            selectionButton.heightAnchor.constraint(equalToConstant: 20),

            detailLabel.leadingAnchor.constraint(equalTo: selectionButton.leadingAnchor, constant: 19),
            detailLabel.topAnchor.constraint(equalTo: selectionButton.bottomAnchor, constant: 1),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: handToggle.leadingAnchor, constant: -6),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),

            handToggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            handToggle.centerYAnchor.constraint(equalTo: selectionButton.centerYAnchor)
        ])

        updateSelectionAppearance()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelectionAppearance()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }

        // Keep the native switch independently clickable while making every
        // other part of the card select its shortcut layout.
        if handToggle.frame.contains(localPoint) {
            return handToggle.hitTest(localPoint) ?? handToggle
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard selectionEnabled else { return }
        onSelect?()
    }

    @objc private func selectOption(_ sender: NSButton) {
        guard selectionEnabled else { return }
        onSelect?()
    }

    private func updateSelectionAppearance() {
        let titleColor: NSColor = selectionEnabled
            ? (isSelected ? .systemBlue : .labelColor)
            : .secondaryLabelColor
        selectionButton.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                .foregroundColor: titleColor
            ]
        )
        selectionButton.state = isSelected ? .on : .off
        selectionButton.isEnabled = selectionEnabled
        selectionButton.setAccessibilityValue(isSelected ? 1 : 0)

        detailLabel.stringValue = isSelected ? "\(detail)  ·  Editing" : detail
        detailLabel.textColor = selectionEnabled && isSelected ? .systemBlue : .secondaryLabelColor

        layer?.borderColor = isSelected
            ? NSColor.systemBlue.withAlphaComponent(0.72).cgColor
            : NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.backgroundColor = isSelected
            ? NSColor.systemBlue.withAlphaComponent(0.12).cgColor
            : NSColor.white.withAlphaComponent(0.035).cgColor
    }
}
