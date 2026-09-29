import Cocoa
import QuartzCore

final class OnboardingDesktopManagerRowView: NSView {
    private let previewContainerView = NSView()
    private let previewImageView = NSImageView()
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private let textStack: NSStackView
    private let toggle = NSSwitch()
    private let toggleAction: (Bool) -> Void
    private var previewPopover: NSPopover?

    var isOn: Bool {
        toggle.state == .on
    }

    var toggleControl: NSSwitch {
        toggle
    }

    init(
        isOn: Bool,
        toggleAction: @escaping (Bool) -> Void
    ) {
        self.toggleAction = toggleAction
        titleLabel = NSTextField(labelWithString: "Desktop Manager")
        detailLabel = NSTextField(
            wrappingLabelWithString: "Preview, switch, reorder, create, and close Spaces right from your menu bar with live app thumbnails and keyboard navigation."
        )
        textStack = NSStackView(views: [titleLabel, detailLabel])
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.38).cgColor

        // Preview thumbnail container
        previewContainerView.translatesAutoresizingMaskIntoConstraints = false
        previewContainerView.wantsLayer = true
        previewContainerView.layer?.cornerRadius = 8
        previewContainerView.layer?.cornerCurve = .continuous
        previewContainerView.layer?.masksToBounds = false
        previewContainerView.layer?.shadowColor = NSColor.black.withAlphaComponent(0.22).cgColor
        previewContainerView.layer?.shadowOffset = CGSize(width: 0, height: -1.5)
        previewContainerView.layer?.shadowRadius = 3.5
        previewContainerView.layer?.shadowOpacity = 1.0
        previewContainerView.toolTip = "Click to enlarge Desktop Manager preview"

        // Preview image view
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewImageView.wantsLayer = true
        previewImageView.layer?.cornerRadius = 8
        previewImageView.layer?.cornerCurve = .continuous
        previewImageView.layer?.masksToBounds = true
        previewImageView.layer?.borderWidth = 1.0
        previewImageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.image = NSImage(named: "DesktopManagerPreview")

        previewContainerView.addSubview(previewImageView)
        NSLayoutConstraint.activate([
            previewImageView.leadingAnchor.constraint(equalTo: previewContainerView.leadingAnchor),
            previewImageView.trailingAnchor.constraint(equalTo: previewContainerView.trailingAnchor),
            previewImageView.topAnchor.constraint(equalTo: previewContainerView.topAnchor),
            previewImageView.bottomAnchor.constraint(equalTo: previewContainerView.bottomAnchor)
        ])

        // Add click gesture to enlarge preview
        let clickRecognizer = NSClickGestureRecognizer(target: self, action: #selector(handlePreviewClicked(_:)))
        previewContainerView.addGestureRecognizer(clickRecognizer)

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor

        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 3

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false

        toggle.controlSize = .regular
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = #selector(handleToggleChanged(_:))
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.setAccessibilityLabel("Desktop Manager")
        toggle.setAccessibilityHelp("Enables or disables the DockAway Desktop Manager.")
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(previewContainerView)
        addSubview(textStack)
        addSubview(toggle)

        // The preview screenshot has aspect ratio 441 x 512 (approx 0.861).
        // At width 92, height is ~107.
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 126),

            previewContainerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            previewContainerView.centerYAnchor.constraint(equalTo: centerYAnchor),
            previewContainerView.widthAnchor.constraint(equalToConstant: 92),
            previewContainerView.heightAnchor.constraint(equalToConstant: 107),

            textStack.leadingAnchor.constraint(equalTo: previewContainerView.trailingAnchor, constant: 14),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -14),

            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        updateVisualAppearance(isOn: isOn, animated: false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(previewContainerView.frame, cursor: .pointingHand)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.38).cgColor
        previewImageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        previewContainerView.layer?.shadowColor = NSColor.black.withAlphaComponent(0.22).cgColor
        updateVisualAppearance(isOn: toggle.state == .on, animated: false)
    }

    @objc private func handleToggleChanged(_ sender: NSSwitch) {
        let isNowOn = sender.state == .on
        updateVisualAppearance(isOn: isNowOn, animated: true)
        toggleAction(isNowOn)
    }

    func setOn(_ isOn: Bool, animated: Bool = true) {
        let targetState: NSControl.StateValue = isOn ? .on : .off
        toggle.state = targetState
        updateVisualAppearance(isOn: isOn, animated: animated)
    }

    private func updateVisualAppearance(isOn: Bool, animated: Bool) {
        let targetPreviewAlpha: CGFloat = isOn ? 1.0 : 0.42
        let targetTextAlpha: CGFloat = isOn ? 1.0 : 0.55

        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                previewContainerView.animator().alphaValue = targetPreviewAlpha
                textStack.animator().alphaValue = targetTextAlpha
            }
        } else {
            previewContainerView.alphaValue = targetPreviewAlpha
            textStack.alphaValue = targetTextAlpha
        }
    }

    @objc private func handlePreviewClicked(_ gesture: NSClickGestureRecognizer) {
        guard gesture.state == .ended else { return }
        showEnlargedPreview()
    }

    private func showEnlargedPreview() {
        if let existing = previewPopover, existing.isShown {
            existing.close()
            previewPopover = nil
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        let popoverContentVC = NSViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 348))

        let enlargedImageView = NSImageView()
        enlargedImageView.translatesAutoresizingMaskIntoConstraints = false
        enlargedImageView.wantsLayer = true
        enlargedImageView.layer?.cornerRadius = 10
        enlargedImageView.layer?.cornerCurve = .continuous
        enlargedImageView.layer?.masksToBounds = true
        enlargedImageView.layer?.borderWidth = 1.0
        enlargedImageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        enlargedImageView.imageScaling = .scaleProportionallyUpOrDown
        enlargedImageView.image = NSImage(named: "DesktopManagerPreview")

        let captionLabel = NSTextField(labelWithString: "Desktop Manager Menu")
        captionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        captionLabel.textColor = .labelColor
        captionLabel.alignment = .center
        captionLabel.translatesAutoresizingMaskIntoConstraints = false

        let subCaptionLabel = NSTextField(
            wrappingLabelWithString: "Multi-display Spaces, app thumbnails & switcher"
        )
        subCaptionLabel.font = .systemFont(ofSize: 10.5)
        subCaptionLabel.textColor = .secondaryLabelColor
        subCaptionLabel.alignment = .center
        subCaptionLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(enlargedImageView)
        container.addSubview(captionLabel)
        container.addSubview(subCaptionLabel)

        NSLayoutConstraint.activate([
            enlargedImageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            enlargedImageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            enlargedImageView.widthAnchor.constraint(equalToConstant: 220),
            enlargedImageView.heightAnchor.constraint(equalToConstant: 256),

            captionLabel.topAnchor.constraint(equalTo: enlargedImageView.bottomAnchor, constant: 9),
            captionLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            captionLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            subCaptionLabel.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 6),
            subCaptionLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            subCaptionLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            subCaptionLabel.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -14)
        ])

        popoverContentVC.view = container
        popover.contentViewController = popoverContentVC
        popover.contentSize = container.frame.size
        previewPopover = popover

        popover.show(
            relativeTo: previewContainerView.bounds,
            of: previewContainerView,
            preferredEdge: .maxX
        )
    }
}
