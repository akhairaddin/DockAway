import Cocoa
import QuartzCore

/// An invisible, non-interactive view for positioning the enlarged preview.
private final class PreviewAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

final class OnboardingDesktopManagerRowView: NSView, NSPopoverDelegate {
    /// The menu with a section for each display, and with one shared section.
    private static let separatePreviewName = "DesktopManagerPreview"
    private static let sharedPreviewName = "DesktopManagerPreviewShared"

    private let previewContainerView = NSView()
    private let previewClipView = NSView()
    /// Where the enlarged preview points. Fixed while it is open, so resizing
    /// the thumbnail never moves the popover.
    private let previewAnchorView = PreviewAnchorView()
    private let separatePreviewView = NSImageView()
    private let sharedPreviewView = NSImageView()
    private let previewWidth: CGFloat
    private var previewHeightConstraint: NSLayoutConstraint?
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private let textStack: NSStackView
    private let toggle = NSSwitch()
    private let toggleAction: (Bool) -> Void
    private var previewPopover: NSPopover?
    private weak var separateSpacesRow: OnboardingSeparateSpacesRowView?

    // The open enlarged preview, which follows the same layout changes.
    private static let enlargedWidth: CGFloat = 220
    private var enlargedSeparateView: NSImageView?
    private var enlargedSharedView: NSImageView?
    private var enlargedResizeAnimation: EasedAnimation?
    private var enlargedCaptionLabel: NSTextField?
    private var enlargedSubcaptionLabel: NSTextField?
    private var enlargedPreviewEventMonitor: Any?
    private var enlargedPreviewResignObserver: NSObjectProtocol?

    var isOn: Bool {
        toggle.state == .on
    }

    var toggleControl: NSSwitch {
        toggle
    }

    /// Whether the preview shows a section for each display.
    private(set) var showsSeparateSpacesPreview = true

    /// - Parameter separateSpacesRow: Shown inside this card below a divider.
    ///   The preview follows its switch.
    init(
        isOn: Bool,
        compact: Bool = false,
        separateSpacesRow: OnboardingSeparateSpacesRowView? = nil,
        toggleAction: @escaping (Bool) -> Void
    ) {
        self.toggleAction = toggleAction
        previewWidth = compact ? 52 : 92
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

        // Both previews hang from the top of a clipping frame. Switching
        // layouts crossfades them while the frame takes the new height, so the
        // shared header stays put and only the display sections change.
        previewClipView.translatesAutoresizingMaskIntoConstraints = false
        previewClipView.wantsLayer = true
        previewClipView.layer?.cornerRadius = 8
        previewClipView.layer?.cornerCurve = .continuous
        previewClipView.layer?.masksToBounds = true
        previewClipView.layer?.borderWidth = 1.0
        previewClipView.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        previewContainerView.addSubview(previewClipView)
        NSLayoutConstraint.activate([
            previewClipView.leadingAnchor.constraint(equalTo: previewContainerView.leadingAnchor),
            previewClipView.trailingAnchor.constraint(equalTo: previewContainerView.trailingAnchor),
            previewClipView.topAnchor.constraint(equalTo: previewContainerView.topAnchor),
            previewClipView.bottomAnchor.constraint(equalTo: previewContainerView.bottomAnchor)
        ])
        for (imageView, name) in [(separatePreviewView, Self.separatePreviewName),
                                  (sharedPreviewView, Self.sharedPreviewName)] {
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.wantsLayer = true
            imageView.imageScaling = .scaleAxesIndependently
            imageView.image = NSImage(named: name)
            imageView.setAccessibilityElement(false)
            previewClipView.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: previewClipView.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: previewClipView.trailingAnchor),
                imageView.topAnchor.constraint(equalTo: previewClipView.topAnchor),
                imageView.heightAnchor.constraint(equalToConstant: Self.previewHeight(named: name, width: previewWidth))
            ])
        }

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

        addSubview(previewAnchorView)
        addSubview(previewContainerView)
        addSubview(textStack)
        addSubview(toggle)

        // The Desktop Manager itself fills a fixed-height area at the top. A
        // shorter preview leaves more space below it, so the separate Spaces
        // setting never moves out from under the pointer.
        let topHeight: CGFloat = compact ? 88 : 126
        let featureArea = NSLayoutGuide()
        addLayoutGuide(featureArea)
        let separateHeight = Self.previewHeight(named: Self.separatePreviewName, width: previewWidth)
        let previewHeight = previewContainerView.heightAnchor.constraint(equalToConstant: separateHeight)
        previewHeightConstraint = previewHeight
        let previewTopInset = ((topHeight - separateHeight) / 2).rounded()

        var constraints: [NSLayoutConstraint] = []
        if separateSpacesRow == nil {
            constraints.append(heightAnchor.constraint(equalToConstant: topHeight))
        }
        constraints += [
            featureArea.topAnchor.constraint(equalTo: topAnchor),
            featureArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            featureArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            featureArea.heightAnchor.constraint(equalToConstant: topHeight),

            // The preview keeps its top edge and grows or shrinks at the bottom;
            // the text and switch beside it stay centered on it.
            previewContainerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            previewContainerView.topAnchor.constraint(equalTo: featureArea.topAnchor, constant: previewTopInset),
            previewContainerView.widthAnchor.constraint(equalToConstant: previewWidth),
            previewHeight,

            textStack.leadingAnchor.constraint(equalTo: previewContainerView.trailingAnchor, constant: 14),
            textStack.centerYAnchor.constraint(equalTo: previewContainerView.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -14),

            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            toggle.centerYAnchor.constraint(equalTo: previewContainerView.centerYAnchor)
        ]

        if let separateSpacesRow {
            let divider = NSBox()
            divider.boxType = .separator
            divider.translatesAutoresizingMaskIntoConstraints = false
            separateSpacesRow.translatesAutoresizingMaskIntoConstraints = false
            addSubview(divider)
            addSubview(separateSpacesRow)
            constraints += [
                divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                divider.topAnchor.constraint(equalTo: featureArea.bottomAnchor),
                separateSpacesRow.leadingAnchor.constraint(equalTo: leadingAnchor),
                separateSpacesRow.trailingAnchor.constraint(equalTo: trailingAnchor),
                separateSpacesRow.topAnchor.constraint(equalTo: divider.bottomAnchor),
                separateSpacesRow.bottomAnchor.constraint(equalTo: bottomAnchor)
            ]
        }
        NSLayoutConstraint.activate(constraints)

        if let separateSpacesRow {
            self.separateSpacesRow = separateSpacesRow
            setShowsSeparateSpacesPreview(separateSpacesRow.showsSeparateSpaces, animated: false)
            separateSpacesRow.onSelectionChange = { [weak self] separateSpaces, animated in
                self?.setShowsSeparateSpacesPreview(separateSpaces, animated: animated)
            }
        }
        sharedPreviewView.alphaValue = showsSeparateSpacesPreview ? 0 : 1
        updateVisualAppearance(isOn: isOn, animated: false)
    }

    /// Whole points, so a popover anchored to the preview never lands half a point off.
    private static func previewHeight(named name: String, width: CGFloat) -> CGFloat {
        let fallbackAspect: CGFloat = name == sharedPreviewName ? 768.0 / 880.0 : 1024.0 / 880.0
        guard let size = NSImage(named: name)?.size, size.width > 0 else { return (width * fallbackAspect).rounded() }
        return (width * size.height / size.width).rounded()
    }

    /// Shows the menu with a section for each display, or with one shared
    /// section for all displays.
    func setShowsSeparateSpacesPreview(_ separateSpaces: Bool, animated: Bool = true) {
        guard separateSpaces != showsSeparateSpacesPreview else { return }
        showsSeparateSpacesPreview = separateSpaces

        let name = separateSpaces ? Self.separatePreviewName : Self.sharedPreviewName
        let height = Self.previewHeight(named: name, width: previewWidth)
        let enlargedHeight = Self.previewHeight(named: name, width: Self.enlargedWidth).rounded()
        let separateAlpha: CGFloat = separateSpaces ? 1 : 0
        let animate = animated && window?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        enlargedSubcaptionLabel?.stringValue = Self.enlargedSubcaption(separateSpaces: separateSpaces)
        if animate {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                previewHeightConstraint?.animator().constant = height
                separatePreviewView.animator().alphaValue = separateAlpha
                sharedPreviewView.animator().alphaValue = 1 - separateAlpha
                enlargedSeparateView?.animator().alphaValue = separateAlpha
                enlargedSharedView?.animator().alphaValue = 1 - separateAlpha
            }, completionHandler: { [weak self] in
                guard let self else { return }
                self.window?.invalidateCursorRects(for: self)
            })
        } else {
            previewHeightConstraint?.constant = height
            separatePreviewView.alphaValue = separateAlpha
            sharedPreviewView.alphaValue = 1 - separateAlpha
            enlargedSeparateView?.alphaValue = separateAlpha
            enlargedSharedView?.alphaValue = 1 - separateAlpha
            window?.invalidateCursorRects(for: self)
        }
        if let popover = previewPopover, popover.isShown {
            resizeEnlargedPreview(popover, to: enlargedContentSize(imageHeight: enlargedHeight), animated: animate)
        }
    }

    /// Resizes the open enlarged preview from its arrow upward. Its captions
    /// are pinned to the bottom, so they stay put while the image grows or
    /// shrinks above them. Each frame sets the size directly: NSPopover's own
    /// resize animation runs on a separate clock and makes the layout drift.
    /// Its animation stays off until it closes; turning it back on right after
    /// a resize repositions the popover by a point.
    private func resizeEnlargedPreview(_ popover: NSPopover, to size: NSSize, animated: Bool) {
        enlargedResizeAnimation?.invalidate()
        enlargedResizeAnimation = nil
        popover.animates = false
        guard animated, let contentView = popover.contentViewController?.view else {
            popover.contentSize = size
            return
        }
        let startHeight = popover.contentSize.height
        enlargedResizeAnimation = EasedAnimation(view: contentView, duration: 0.32) { [weak self, weak popover] progress, finished in
            guard let popover else { return }
            popover.contentSize = NSSize(width: size.width,
                                         height: (startHeight + (size.height - startHeight) * progress).rounded())
            if finished { self?.enlargedResizeAnimation = nil }
        }
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
        previewClipView.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
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

    /// One line in both layouts, so the captions never change height.
    private static func enlargedSubcaption(separateSpaces: Bool) -> String {
        separateSpaces
            ? "Separate Spaces, thumbnails & switcher"
            : "Shared Spaces, thumbnails & switcher"
    }

    /// The enlarged image plus its captions and margins.
    private func enlargedContentSize(imageHeight: CGFloat) -> NSSize {
        let captionHeight = enlargedCaptionLabel?.intrinsicContentSize.height ?? 15
        let subcaptionHeight = enlargedSubcaptionLabel?.intrinsicContentSize.height ?? 13
        return NSSize(width: Self.enlargedWidth + 30,
                      height: (14 + imageHeight + 9 + captionHeight + 6 + subcaptionHeight + 14).rounded(.up))
    }

    private func showEnlargedPreview() {
        if previewPopover?.isShown == true {
            closeEnlargedPreview()
            return
        }

        let popover = NSPopover()
        // This view closes the popover itself, so changing the separate Spaces
        // setting updates the open preview instead of dismissing it.
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self

        // Like the thumbnail, both layouts hang from the top of a clipping
        // frame. Here the frame fills the space above the captions, so it
        // grows and shrinks with the popover.
        let clipView = NSView()
        clipView.translatesAutoresizingMaskIntoConstraints = false
        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = 10
        clipView.layer?.cornerCurve = .continuous
        clipView.layer?.masksToBounds = true
        clipView.layer?.borderWidth = 1.0
        clipView.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        var imageViews: [NSImageView] = []
        for name in [Self.separatePreviewName, Self.sharedPreviewName] {
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.wantsLayer = true
            imageView.imageScaling = .scaleAxesIndependently
            imageView.image = NSImage(named: name)
            clipView.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
                imageView.topAnchor.constraint(equalTo: clipView.topAnchor),
                imageView.heightAnchor.constraint(
                    equalToConstant: Self.previewHeight(named: name, width: Self.enlargedWidth).rounded())
            ])
            imageViews.append(imageView)
        }
        let separateAlpha: CGFloat = showsSeparateSpacesPreview ? 1 : 0
        imageViews[0].alphaValue = separateAlpha
        imageViews[1].alphaValue = 1 - separateAlpha
        imageViews[showsSeparateSpacesPreview ? 0 : 1].setAccessibilityLabel("Desktop Manager menu preview")
        imageViews[showsSeparateSpacesPreview ? 1 : 0].setAccessibilityElement(false)

        let captionLabel = NSTextField(labelWithString: "Desktop Manager Menu")
        captionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        captionLabel.textColor = .labelColor
        captionLabel.alignment = .center
        captionLabel.translatesAutoresizingMaskIntoConstraints = false

        let subcaptionLabel = NSTextField(
            labelWithString: Self.enlargedSubcaption(separateSpaces: showsSeparateSpacesPreview)
        )
        subcaptionLabel.lineBreakMode = .byTruncatingTail
        subcaptionLabel.font = .systemFont(ofSize: 10.5)
        subcaptionLabel.textColor = .secondaryLabelColor
        subcaptionLabel.alignment = .center
        subcaptionLabel.translatesAutoresizingMaskIntoConstraints = false

        let previewName = showsSeparateSpacesPreview ? Self.separatePreviewName : Self.sharedPreviewName
        let imageHeight = Self.previewHeight(named: previewName, width: Self.enlargedWidth).rounded()
        enlargedSeparateView = imageViews[0]
        enlargedSharedView = imageViews[1]
        enlargedCaptionLabel = captionLabel
        enlargedSubcaptionLabel = subcaptionLabel
        let contentSize = enlargedContentSize(imageHeight: imageHeight)

        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
        container.addSubview(clipView)
        container.addSubview(captionLabel)
        container.addSubview(subcaptionLabel)
        // Laid out from the bottom: the arrow edge stays fixed while the
        // popover resizes, so the captions do too.
        NSLayoutConstraint.activate([
            subcaptionLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            subcaptionLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            subcaptionLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            captionLabel.bottomAnchor.constraint(equalTo: subcaptionLabel.topAnchor, constant: -6),
            captionLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            captionLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            clipView.bottomAnchor.constraint(equalTo: captionLabel.topAnchor, constant: -9),
            clipView.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            clipView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            clipView.widthAnchor.constraint(equalToConstant: Self.enlargedWidth)
        ])

        let contentController = NSViewController()
        contentController.view = container
        popover.contentViewController = contentController
        popover.contentSize = contentSize
        previewPopover = popover

        // Above the thumbnail, clear of the settings below it.
        layoutSubtreeIfNeeded()
        previewAnchorView.frame = previewContainerView.frame.integral
        popover.show(relativeTo: previewAnchorView.bounds, of: previewAnchorView, preferredEdge: .maxY)
        installEnlargedPreviewDismissal()
    }

    /// Closes the enlarged preview on Escape, on leaving the app, or on a
    /// click anywhere except the preview, its thumbnail, and the separate
    /// Spaces setting it illustrates.
    private func installEnlargedPreviewDismissal() {
        enlargedPreviewEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleEnlargedPreviewEvent(event) ?? false }
            return consumed ? nil : event
        }
        enlargedPreviewResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeEnlargedPreview() }
        }
    }

    /// Returns whether the event was used to close the preview.
    private func handleEnlargedPreviewEvent(_ event: NSEvent) -> Bool {
        guard previewPopover?.isShown == true else { return false }
        if event.type == .keyDown {
            guard event.keyCode == 53 else { return false }
            closeEnlargedPreview()
            return true
        }
        if !keepsEnlargedPreviewOpen(for: event) {
            closeEnlargedPreview()
        }
        return false
    }

    private func keepsEnlargedPreviewOpen(for event: NSEvent) -> Bool {
        if let popoverWindow = previewPopover?.contentViewController?.view.window,
           event.window === popoverWindow {
            return true
        }
        guard let window, event.window === window else { return false }
        return [previewContainerView, separateSpacesRow].compactMap { $0 }.contains {
            $0.convert($0.bounds, to: nil).contains(event.locationInWindow)
        }
    }

    private func closeEnlargedPreview() {
        let popover = previewPopover
        tearDownEnlargedPreview()
        popover?.animates = true
        popover?.close()
    }

    private func tearDownEnlargedPreview() {
        enlargedResizeAnimation?.invalidate()
        enlargedResizeAnimation = nil
        if let enlargedPreviewEventMonitor {
            NSEvent.removeMonitor(enlargedPreviewEventMonitor)
        }
        enlargedPreviewEventMonitor = nil
        if let enlargedPreviewResignObserver {
            NotificationCenter.default.removeObserver(enlargedPreviewResignObserver)
        }
        enlargedPreviewResignObserver = nil
        previewPopover = nil
        enlargedSeparateView = nil
        enlargedSharedView = nil
        enlargedCaptionLabel = nil
        enlargedSubcaptionLabel = nil
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover, popover === previewPopover else { return }
        tearDownEnlargedPreview()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { closeEnlargedPreview() }
    }

    /// Also sent when an ancestor hides, such as onboarding moving to its
    /// next page, which Return can do while the enlarged preview is open.
    override func viewDidHide() {
        super.viewDidHide()
        closeEnlargedPreview()
    }
}
