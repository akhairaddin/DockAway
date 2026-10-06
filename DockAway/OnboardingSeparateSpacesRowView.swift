import AppKit

/// A real AppKit switch. No row gesture or background drag intercepts its input.
private final class OnboardingSeparateSpacesSwitch: NSSwitch {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

@MainActor
final class OnboardingSeparateSpacesRowView: NSView {
    static let title = "Displays have separate Spaces"

    let toggleControl: NSSwitch
    private let titleLabel = NSTextField(labelWithString: OnboardingSeparateSpacesRowView.title)
    private let noticeLabel = NSTextField(labelWithString: "")
    private let captionLabel = NSTextField(labelWithString: "")
    /// Explains "Requires log out" while that notice is shown.
    let logoutHelpButton = DockSettingHelpButton(
        heading: "Log out, then log back in to apply",
        textProvider: {
            "'Displays have separate Spaces' is a native macOS setting, not a DockAway one. "
                + "It's found in the bottom of 'Desktop and Dock' and both toggles are linked. macOS applies a change to it only after you log out and back in.\n\n"
                + "Until then, your displays keep their current Spaces. When you're ready, "
                + "save your work and select the  Apple menu > Log Out then log back in."
        }
    )
    private let toggleAction: (Bool) -> Void
    private let embedded: Bool

    var notice: String { noticeLabel.stringValue }
    var caption: String { captionLabel.stringValue }

    /// Whether the switch shows separate Spaces, including a choice that
    /// takes effect only after logging out.
    var showsSeparateSpaces: Bool { toggleControl.state == .on }

    /// Called with the switch's new choice and whether to animate the change.
    var onSelectionChange: ((_ separateSpaces: Bool, _ animated: Bool) -> Void)?

    /// - Parameter embedded: Draws no background of its own, for a row placed
    ///   inside another card.
    init(snapshot: SeparateSpacesPreferenceController.Snapshot,
         compact: Bool = false,
         embedded: Bool = false,
         switchControl: NSSwitch? = nil,
         toggleAction: @escaping (Bool) -> Void) {
        toggleControl = switchControl ?? OnboardingSeparateSpacesSwitch()
        self.toggleAction = toggleAction
        self.embedded = embedded
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        updateBackground()

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.lineBreakMode = .byTruncatingTail
        noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        logoutHelpButton.isHidden = true

        let text = NSStackView(views: [titleLabel, noticeLabel, logoutHelpButton])
        text.orientation = .horizontal
        text.alignment = .centerY
        text.spacing = 10
        text.setCustomSpacing(4, after: noticeLabel)
        text.detachesHiddenViews = true
        text.translatesAutoresizingMaskIntoConstraints = false

        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        captionLabel.translatesAutoresizingMaskIntoConstraints = false

        toggleControl.controlSize = .regular
        toggleControl.target = self
        toggleControl.action = #selector(toggleChanged(_:))
        toggleControl.translatesAutoresizingMaskIntoConstraints = false
        toggleControl.setAccessibilityLabel(Self.title)
        toggleControl.setContentHuggingPriority(.required, for: .horizontal)
        toggleControl.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(text)
        addSubview(captionLabel)
        addSubview(toggleControl)
        // The title line and the caption below it are centered as one block.
        let textBlock = NSLayoutGuide()
        addLayoutGuide(textBlock)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: compact ? 44 : 56),
            logoutHelpButton.widthAnchor.constraint(equalToConstant: 16),
            logoutHelpButton.heightAnchor.constraint(equalToConstant: 16),
            textBlock.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.topAnchor.constraint(equalTo: textBlock.topAnchor),
            captionLabel.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 1),
            captionLabel.bottomAnchor.constraint(equalTo: textBlock.bottomAnchor),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: embedded ? 16 : 20),
            captionLabel.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: toggleControl.leadingAnchor, constant: -14),
            captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggleControl.leadingAnchor, constant: -14),
            toggleControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            toggleControl.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        update(snapshot, animated: false)
    }

    required init?(coder: NSCoder) { nil }
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    func update(_ snapshot: SeparateSpacesPreferenceController.Snapshot, animated: Bool = true) {
        let state: NSControl.StateValue = snapshot.configuredEnabled ? .on : .off
        // Leave an already-correct state alone, especially while a native
        // click or an external preference update is still animating.
        if toggleControl.isEnabled != snapshot.canEdit {
            toggleControl.isEnabled = snapshot.canEdit
        }
        if toggleControl.state != state {
            if animated, window?.isVisible == true,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    // NSSwitch's animator proxy owns the knob and track
                    // animation. Do not simulate a click or send an action.
                    toggleControl.animator().state = state
                }
            } else {
                toggleControl.state = state
            }
        }
        showSelection(separateSpaces: snapshot.configuredEnabled, animated: animated)
        let requiresLogout = snapshot.canEdit && snapshot.requiresLogon
        if snapshot.isManaged {
            noticeLabel.stringValue = "Managed by your organization"
        } else if !snapshot.isAvailable {
            noticeLabel.stringValue = "Unable to read macOS setting"
        } else {
            noticeLabel.stringValue = snapshot.requiresLogon ? "Requires log out" : ""
        }
        noticeLabel.isHidden = noticeLabel.stringValue.isEmpty
        logoutHelpButton.isHidden = !requiresLogout
        if !requiresLogout { logoutHelpButton.closePopover() }
        noticeLabel.font = .systemFont(ofSize: requiresLogout ? 12 : 11,
                                      weight: requiresLogout ? .semibold : .regular)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.setContentCompressionResistancePriority(
            requiresLogout ? .required : .defaultLow, for: .horizontal
        )
        titleLabel.textColor = snapshot.canEdit ? .labelColor : .secondaryLabelColor
        // Keep the notice visible to VoiceOver without replacing the switch's
        // stable, system-setting label or its native on/off accessibility value.
        noticeLabel.setAccessibilityLabel(noticeLabel.stringValue)
    }

    @objc private func toggleChanged(_ sender: NSSwitch) {
        guard sender.isEnabled else { return }
        showSelection(separateSpaces: sender.state == .on, animated: true)
        toggleAction(sender.state == .on)
    }

    private func showSelection(separateSpaces: Bool, animated: Bool) {
        captionLabel.stringValue = separateSpaces
            ? "Each display gets its own row of desktops."
            : "All displays share one row of desktops."
        onSelectionChange?(separateSpaces, animated)
    }

    private func updateBackground() {
        guard !embedded else { return }
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.38).cgColor
    }
}
