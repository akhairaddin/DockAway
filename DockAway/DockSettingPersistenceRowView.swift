import Cocoa
import QuartzCore

final class DockSettingHelpButton: NSButton {
    var heading: String
    var textProvider: () -> String
    private var helpPopover: NSPopover?
    private var hoverWorkItem: DispatchWorkItem?
    private var trackingAreaRef: NSTrackingArea?
    private var openedByClick = false

    init(heading: String, textProvider: @escaping () -> String) {
        self.heading = heading
        self.textProvider = textProvider
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        isBordered = false
        setButtonType(.momentaryChange)
        image = NSImage(
            systemSymbolName: "questionmark.circle",
            accessibilityDescription: "\(heading) Help"
        )
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        contentTintColor = .secondaryLabelColor
        target = self
        action = #selector(performHelpAction(_:))
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(heading) Help")
        setAccessibilityHelp(textProvider())
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        contentTintColor = .labelColor
        beginHover()
    }

    override func mouseExited(with event: NSEvent) {
        contentTintColor = .secondaryLabelColor
        endHover()
    }

    func beginHover() {
        guard isEnabled else { return }
        schedulePopover()
    }

    func endHover() {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        if !openedByClick {
            helpPopover?.performClose(nil)
            helpPopover = nil
        }
    }

    @objc func performHelpAction(_ sender: Any?) {
        guard isEnabled else { return }
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        if let existing = helpPopover, existing.isShown {
            if openedByClick {
                existing.performClose(nil)
                helpPopover = nil
                openedByClick = false
            } else {
                openedByClick = true
            }
        } else {
            openedByClick = true
            showPopover()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performHelpAction(nil)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        performHelpAction(nil)
    }

    func closePopover() {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        helpPopover?.performClose(nil)
        helpPopover = nil
        openedByClick = false
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            closePopover()
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
        guard isEnabled, window != nil, !(helpPopover?.isShown ?? false) else { return }
        let popover = makeHelpPopover()
        helpPopover = popover
        setAccessibilityHelp(textProvider())
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxX)
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

final class DockSettingPersistenceRowView: NSView {
    enum LeadingControlStyle {
        case checkbox
        case resetAction
    }

    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let changeHandler: (Bool) -> Void
    private let itemIcon: NSImage?
    private let centeredTitle: Bool
    private let fullRowHitTarget: Bool
    private let leadingControlStyle: LeadingControlStyle
    private var rowTitle: String
    private var isShowingResetActionSuccess = false
    private var resetActionSuccessTimer: Timer?
    private var displayedIsOn: Bool?
    private var controlEnabled = true
    private(set) var helpButton: DockSettingHelpButton?
    private(set) var hierarchyArrowView: NSImageView?
    var helpControl: NSButton? { helpButton }

    init(
        title: String,
        isOn: Bool,
        width: CGFloat = 190,
        shortcut: String? = nil,
        leadingInset: CGFloat = 18,
        hierarchyParentLeadingInset: CGFloat? = nil,
        trailingInset: CGFloat = 12,
        titleLeadingAdjustment: CGFloat = 0,
        fullRowHitTarget: Bool = true,
        icon: NSImage? = nil,
        font: NSFont? = nil,
        indicatorSize: CGFloat = 16,
        multiline: Bool = false,
        centeredTitle: Bool = false,
        checkboxOnFirstLine: Bool = false,
        leadingControlStyle: LeadingControlStyle = .checkbox,
        helpHeading: String? = nil,
        helpTextProvider: (() -> String)? = nil,
        changeHandler: @escaping (Bool) -> Void
    ) {
        self.itemIcon = icon?.copy() as? NSImage
        self.changeHandler = changeHandler
        self.centeredTitle = centeredTitle
        self.fullRowHitTarget = fullRowHitTarget
        self.leadingControlStyle = leadingControlStyle
        self.rowTitle = title
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: multiline ? 40 : 26))
        autoresizingMask = [.width]

        if leadingControlStyle == .resetAction {
            checkbox.setButtonType(.momentaryChange)
            checkbox.image = NSImage(
                systemSymbolName: "arrow.counterclockwise",
                accessibilityDescription: "Restore Default macOS Dock Settings"
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            )
            checkbox.imagePosition = .imageOnly
            checkbox.isBordered = false
            checkbox.contentTintColor = .labelColor
        } else {
            checkbox.setButtonType(.switch)
        }
        checkbox.title = ""
        checkbox.state = leadingControlStyle == .checkbox && isOn ? .on : .off
        checkbox.target = self
        checkbox.action = #selector(toggleCheckbox(_:))
        checkbox.focusRingType = .none
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.controlSize = (indicatorSize <= 14) ? .small : .regular
        checkbox.setContentHuggingPriority(.required, for: .horizontal)
        checkbox.setContentCompressionResistancePriority(.required, for: .horizontal)

        if let font { checkbox.font = font }
        titleLabel.font = checkbox.font
        titleLabel.alignment = centeredTitle ? .center : .left
        titleLabel.lineBreakMode = .byTruncatingTail
        if multiline {
            titleLabel.maximumNumberOfLines = 2
            titleLabel.lineBreakMode = .byClipping
            titleLabel.cell?.wraps = true
            titleLabel.cell?.isScrollable = false
        }
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setAccessibilityElement(false)
        updateTitle(title)

        addSubview(checkbox)
        addSubview(titleLabel)

        var rowConstraints: [NSLayoutConstraint] = [
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            multiline && checkboxOnFirstLine
                ? checkbox.centerYAnchor.constraint(equalTo: titleLabel.topAnchor, constant: 6)
                : checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(
                equalTo: checkbox.trailingAnchor,
                constant: 6 + titleLeadingAdjustment
            ),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ]

        if let hierarchyParentLeadingInset {
            let arrow = NSImageView()
            arrow.image = NSImage(systemSymbolName: "arrow.turn.down.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
            arrow.contentTintColor = .secondaryLabelColor
            arrow.imageScaling = .scaleProportionallyDown
            arrow.translatesAutoresizingMaskIntoConstraints = false
            arrow.setAccessibilityElement(false)
            hierarchyArrowView = arrow
            addSubview(arrow)
            // Align the symbol's vertical stem beneath the parent checkbox.
            // Its right-facing end points toward the indented child control.
            rowConstraints += [
                arrow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hierarchyParentLeadingInset + 5),
                arrow.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 2),
                arrow.widthAnchor.constraint(equalToConstant: 18),
                arrow.heightAnchor.constraint(equalToConstant: 18),
                arrow.trailingAnchor.constraint(lessThanOrEqualTo: checkbox.leadingAnchor, constant: -5)
            ]
        }

        if let helpTextProvider {
            let button = DockSettingHelpButton(
                heading: helpHeading ?? title,
                textProvider: helpTextProvider
            )
            self.helpButton = button
            super.toolTip = nil
            checkbox.toolTip = nil
            addSubview(button)
            rowConstraints.append(contentsOf: [
                button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailingInset),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 16),
                button.heightAnchor.constraint(equalToConstant: 16),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8)
            ])
        } else if let shortcut {
            shortcutLabel.font = NSFont.menuFont(ofSize: 13)
            shortcutLabel.textColor = .secondaryLabelColor
            shortcutLabel.stringValue = shortcut
            shortcutLabel.alignment = .right
            shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
            shortcutLabel.setAccessibilityElement(false)
            addSubview(shortcutLabel)
            rowConstraints.append(contentsOf: [
                shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailingInset),
                shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -8)
            ])
        } else {
            rowConstraints.append(
                titleLabel.trailingAnchor.constraint(
                    lessThanOrEqualTo: trailingAnchor,
                    constant: -trailingInset
                )
            )
        }

        if (multiline || centeredTitle) && helpTextProvider == nil {
            rowConstraints.append(titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12))
        }
        if multiline {
            rowConstraints.append(titleLabel.heightAnchor.constraint(equalToConstant: 34))
        }
        NSLayoutConstraint.activate(rowConstraints)

        setIndicatorState(isOn)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        resetActionSuccessTimer?.invalidate()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: frame.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = superview != nil ? convert(point, from: superview) : point
        guard bounds.contains(localPoint) else { return nil }
        if let helpButton, helpButton.frame.insetBy(dx: -4, dy: -4).contains(localPoint) {
            return helpButton
        }
        guard controlEnabled else { return nil }
        if checkbox.frame.contains(localPoint) {
            return checkbox.hitTest(localPoint) ?? checkbox
        }
        if fullRowHitTarget {
            return self
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        if let helpButton, helpButton.frame.insetBy(dx: -4, dy: -4).contains(localPoint) {
            helpButton.performHelpAction(self)
            return
        }
        guard controlEnabled else { return }
        helpButton?.closePopover()
        checkbox.performClick(nil)
    }

    var checkboxControl: NSButton { checkbox }

    override var toolTip: String? {
        get {
            if helpButton != nil { return nil }
            return super.toolTip
        }
        set {
            if helpButton != nil {
                super.toolTip = nil
                checkbox.toolTip = nil
            } else {
                super.toolTip = newValue
            }
        }
    }

    func setOn(_ isOn: Bool) {
        setIndicatorState(isOn)
    }

    func setTitle(_ title: String) {
        rowTitle = title
        if !isShowingResetActionSuccess {
            updateTitle(title)
        }
    }

    func setControlEnabled(_ enabled: Bool, updateMenuItem: Bool = true) {
        controlEnabled = enabled
        if updateMenuItem { enclosingMenuItem?.isEnabled = enabled }
        checkbox.isEnabled = enabled
        titleLabel.alphaValue = enabled || isShowingResetActionSuccess ? 1 : 0.45
        shortcutLabel.alphaValue = enabled ? 1 : 0.45
        hierarchyArrowView?.alphaValue = enabled ? 1 : 0.45
        helpButton?.isEnabled = true
        helpButton?.alphaValue = enabled ? 1 : 0.65
    }

    @objc private func toggleCheckbox(_ sender: NSButton) {
        if leadingControlStyle == .resetAction {
            sender.state = .off
            changeHandler(true)
            showResetActionSuccess()
            return
        }

        let requestedState = sender.state == .on
        let previousDisplayedState = displayedIsOn
        changeHandler(requestedState)

        if displayedIsOn == previousDisplayedState,
           (checkbox.state == .on) == requestedState {
            setIndicatorState(requestedState)
        }
    }

    private func setIndicatorState(_ isOn: Bool) {
        checkbox.state = leadingControlStyle == .checkbox && isOn ? .on : .off
        displayedIsOn = isOn
    }

    private func showResetActionSuccess() {
        resetActionSuccessTimer?.invalidate()
        addResetActionTransition(duration: 0.24)
        isShowingResetActionSuccess = true
        checkbox.isEnabled = true
        checkbox.image = NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: "Dock Settings Reset to Default"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        )
        checkbox.contentTintColor = .systemGreen
        checkbox.setAccessibilityLabel("Dock Settings Reset to Default")
        titleLabel.stringValue = "Dock Settings Reset to Default"
        titleLabel.alphaValue = 1

        let timer = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finishResetActionSuccess()
            }
        }
        resetActionSuccessTimer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishResetActionSuccess() {
        guard isShowingResetActionSuccess else { return }
        resetActionSuccessTimer?.invalidate()
        resetActionSuccessTimer = nil
        addResetActionTransition(duration: 0.5)
        isShowingResetActionSuccess = false
        checkbox.image = NSImage(
            systemSymbolName: "arrow.counterclockwise",
            accessibilityDescription: rowTitle
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        )
        checkbox.contentTintColor = .labelColor
        checkbox.isEnabled = controlEnabled
        updateTitle(rowTitle)
        titleLabel.alphaValue = controlEnabled ? 1 : 0.45
    }

    private func addResetActionTransition(duration: TimeInterval) {
        wantsLayer = true
        layer?.removeAnimation(forKey: "resetActionTransition")
        guard window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = duration
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(transition, forKey: "resetActionTransition")
    }

    private func updateTitle(_ title: String) {
        checkbox.setAccessibilityLabel(title)

        guard let icon = itemIcon?.copy() as? NSImage else {
            if titleLabel.maximumNumberOfLines == 2 {
                let text = NSMutableAttributedString(string: title, attributes: [
                    .font: titleLabel.font ?? NSFont.menuFont(ofSize: 13),
                    .foregroundColor: NSColor.labelColor
                ])
                let style = NSMutableParagraphStyle()
                style.alignment = centeredTitle ? .center : .left
                style.lineBreakMode = .byClipping
                text.addAttribute(.paragraphStyle, value: style,
                                  range: NSRange(location: 0, length: text.length))
                titleLabel.attributedStringValue = text
            } else {
                titleLabel.stringValue = title
            }
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
}

final class DockSettingToggleRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let toggle = DockMenuSwitch()
    private let changeHandler: (Bool) -> Void
    private var displayedIsOn: Bool
    private var controlEnabled = true
    private let hasSubmenu: Bool
    private var hoverArea: NSTrackingArea?
    private var hovered = false

    init(
        title: String,
        isOn: Bool,
        width: CGFloat = 190,
        leadingInset: CGFloat = 18,
        trailingInset: CGFloat = 12,
        hasSubmenu: Bool = false,
        changeHandler: @escaping (Bool) -> Void
    ) {
        self.changeHandler = changeHandler
        self.hasSubmenu = hasSubmenu
        displayedIsOn = isOn
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        autoresizingMask = [.width]

        titleLabel.stringValue = title
        titleLabel.font = NSFont.menuFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setAccessibilityElement(false)
        addSubview(titleLabel)

        toggle.controlSize = .small
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggleChanged(_:))
        toggle.setAccessibilityLabel(title)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(toggle)

        let toggleTrailing = hasSubmenu ? -36 : -trailingInset
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -12),

            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: toggleTrailing),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: frame.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hasSubmenu else { return }
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        hoverArea = area
        addTrackingArea(area)
        hovered = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        guard hasSubmenu else { return }
        hovered = true
        updateLabelColor()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hasSubmenu else { return }
        hovered = false
        updateLabelColor()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard hasSubmenu else { return }
        hovered = false
        needsDisplay = true
    }

    private func updateLabelColor() {
        let highlighted = hovered || (enclosingMenuItem?.isHighlighted ?? false)
        titleLabel.textColor = highlighted ? .selectedMenuItemTextColor : (controlEnabled ? .labelColor : .tertiaryLabelColor)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard hasSubmenu else { return }
        let highlighted = hovered || (enclosingMenuItem?.isHighlighted ?? false)
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        updateLabelColor()
        let chevronColor: NSColor = highlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
        let chevronConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [chevronColor]))
        NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(chevronConfig)?
            .draw(in: NSRect(x: bounds.maxX - 23, y: bounds.midY - 5, width: 6, height: 10))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = superview != nil ? convert(point, from: superview) : point
        guard controlEnabled, bounds.contains(localPoint) else { return nil }
        if toggle.frame.contains(localPoint) {
            return toggle.hitTest(localPoint) ?? toggle
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard controlEnabled else { return }
        if !hasSubmenu {
            toggle.performClick(nil)
        }
    }

    func setOn(_ isOn: Bool) {
        displayedIsOn = isOn
        toggle.state = isOn ? .on : .off
    }

    func setControlEnabled(_ enabled: Bool) {
        controlEnabled = enabled
        enclosingMenuItem?.isEnabled = enabled
        toggle.isEnabled = enabled
        titleLabel.alphaValue = enabled ? 1 : 0.45
        updateLabelColor()
        needsDisplay = true
    }

    var toggleControl: DockMenuSwitch { toggle }

    @objc private func toggleChanged(_ sender: DockMenuSwitch) {
        let requestedState = sender.state == .on
        let previousDisplayedState = displayedIsOn
        changeHandler(requestedState)
        if displayedIsOn == previousDisplayedState {
            setOn(requestedState)
        }
    }
}

final class DockAwayMenuRowView: NSView {
    private var hoverArea: NSTrackingArea?
    private var hovered = false

    var title: String {
        didSet {
            setAccessibilityLabel(title)
            needsDisplay = true
        }
    }

    var icon: NSImage? {
        didSet { needsDisplay = true }
    }

    var customToolTip: String? {
        didSet { toolTip = customToolTip }
    }

    private let hasSubmenu: Bool
    private let shortcut: String?
    private let leadingInset: CGFloat
    private let titleLeadingAdjustment: CGFloat
    private let actionHandler: (() -> Void)?
    private var controlEnabled = true
    private(set) var helpButton: DockSettingHelpButton?

    init(
        title: String,
        icon: NSImage? = nil,
        hasSubmenu: Bool = false,
        shortcut: String? = nil,
        leadingInset: CGFloat = 12,
        titleLeadingAdjustment: CGFloat = 2,
        width: CGFloat = 190,
        height: CGFloat = 26,
        toolTip: String? = nil,
        helpHeading: String? = nil,
        helpTextProvider: (() -> String)? = nil,
        actionHandler: (() -> Void)? = nil
    ) {
        self.title = title
        self.icon = icon
        self.hasSubmenu = hasSubmenu
        self.shortcut = shortcut
        self.leadingInset = leadingInset
        self.titleLeadingAdjustment = titleLeadingAdjustment
        self.actionHandler = actionHandler
        self.customToolTip = toolTip
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        // Give transparent redraws their own backing surface so a previous
        // selection fill cannot remain in the menu's cached contents.
        wantsLayer = true
        self.toolTip = toolTip
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityLabel(title)
        if actionHandler != nil {
            setAccessibilityRole(.button)
        }
        if let helpTextProvider {
            let button = DockSettingHelpButton(heading: helpHeading ?? title, textProvider: helpTextProvider)
            helpButton = button
            self.toolTip = nil
            addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 16),
                button.heightAnchor.constraint(equalToConstant: 16)
            ])
            setAccessibilityHelp(helpTextProvider())
            setAccessibilityChildren([button])
        }
    }

    required init?(coder: NSCoder) { nil }

    func update(title: String? = nil, icon: NSImage? = nil, toolTip: String? = nil) {
        if let title { self.title = title }
        if let icon { self.icon = icon }
        if let toolTip { self.customToolTip = toolTip }
        needsDisplay = true
    }

    func setControlEnabled(_ enabled: Bool) {
        controlEnabled = enabled
        setAccessibilityEnabled(enabled)
        helpButton?.isEnabled = enabled
        if !enabled { helpButton?.closePopover() }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        let highlighted: Bool
        if let selected = enclosingMenuItem?.menu?.highlightedItem {
            highlighted = controlEnabled && selected === enclosingMenuItem
        } else {
            highlighted = controlEnabled && hovered
        }
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let color: NSColor
        if highlighted {
            color = .selectedMenuItemTextColor
        } else if controlEnabled {
            color = .labelColor
        } else {
            color = .tertiaryLabelColor
        }

        let text = NSMutableAttributedString(
            string: title,
            attributes: [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: color]
        )
        let leftAligned = NSMutableParagraphStyle()
        leftAligned.alignment = .left
        leftAligned.lineBreakMode = .byTruncatingTail
        text.addAttribute(.paragraphStyle, value: leftAligned, range: NSRange(location: 0, length: text.length))
        let textHeight = ceil(text.size().height)

        let textX: CGFloat = leadingInset + 16 + 6 + titleLeadingAdjustment
        let rightMargin: CGFloat = helpButton != nil ? 36 : hasSubmenu ? 26 : (shortcut != nil ? 44 : 12)
        let textWidth = max(0, bounds.width - textX - rightMargin)
        text.draw(in: NSRect(x: textX, y: (bounds.height - textHeight) / 2, width: textWidth, height: textHeight))

        if let icon {
            let config = NSImage.SymbolConfiguration(paletteColors: [color])
            let drawnIcon = icon.withSymbolConfiguration(config) ?? icon
            let iconRect = NSRect(x: leadingInset, y: (bounds.height - 16) / 2, width: 16, height: 16)
            drawnIcon.draw(in: iconRect)
        }
        helpButton?.contentTintColor = highlighted ? .selectedMenuItemTextColor : .secondaryLabelColor

        if hasSubmenu {
            let chevronColor: NSColor = highlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
            let chevronConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [chevronColor]))
            NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(chevronConfig)?
                .draw(in: NSRect(x: bounds.maxX - 18, y: bounds.midY - 5, width: 6, height: 10))
        }

        if let shortcut {
            let sColor: NSColor = highlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
            let sText = NSAttributedString(
                string: shortcut,
                attributes: [
                    .font: NSFont.menuFont(ofSize: 13),
                    .foregroundColor: sColor
                ]
            )
            let sSize = sText.size()
            sText.draw(at: NSPoint(x: bounds.maxX - 18 - sSize.width, y: (bounds.height - sSize.height) / 2))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        hoverArea = area
        addTrackingArea(area)
        hovered = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        // Menu tracking can omit an exit when opening a submenu or relaying
        // events to a custom view. Retire sibling hover state explicitly.
        for item in enclosingMenuItem?.menu?.items ?? [] {
            guard let row = item.view as? DockAwayMenuRowView, row !== self else { continue }
            row.hovered = false
            row.helpButton?.endHover()
            row.needsDisplay = true
        }
        hovered = true
        if controlEnabled { helpButton?.beginHover() }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        helpButton?.endHover()
        needsDisplay = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { helpButton?.closePopover() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard controlEnabled else { return }
        if let actionHandler {
            helpButton?.closePopover()
            enclosingMenuItem?.menu?.cancelTracking()
            actionHandler()
        } else {
            super.mouseDown(with: event)
        }
    }

    @objc func performMenuAction(_ sender: Any?) {
        guard controlEnabled else { return }
        helpButton?.closePopover()
        actionHandler?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard controlEnabled else { return false }
        helpButton?.closePopover()
        actionHandler?()
        return true
    }
}

final class DockDestructiveButton: NSButton {
    private var pressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        isBordered = false
        setButtonType(.momentaryPushIn)
        alignment = .center
        contentTintColor = .white
        focusRingType = .default
        updateDestructiveAppearance()
    }

    override var intrinsicContentSize: NSSize {
        let native = super.intrinsicContentSize
        return NSSize(width: max(56, native.width + 16), height: 20)
    }

    override var isEnabled: Bool {
        didSet { updateDestructiveAppearance() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDestructiveAppearance()
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        updateDestructiveAppearance()
        super.mouseDown(with: event)
        pressed = false
        updateDestructiveAppearance()
    }

    private func updateDestructiveAppearance() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let red = pressed
                ? NSColor.systemRed.blended(withFraction: 0.18, of: .black) ?? .systemRed
                : .systemRed
            layer.backgroundColor = red.withAlphaComponent(isEnabled ? 1 : 0.45).cgColor
            layer.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        }
        layer.borderWidth = 0.5
        contentTintColor = NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.65)
    }
}

final class DockSettingResetControlsRowView: NSView {
    private(set) var isConfirming = false
    private(set) var isShowingSuccess = false
    var title: String = "Reset Keyboard Binds to Default" {
        didSet {
            if !isShowingSuccess { normalTitleLabel.stringValue = title }
            updateAccessibility()
        }
    }
    var icon: NSImage? = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset Keyboard Binds to Default") {
        didSet {
            let iconConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            if !isShowingSuccess {
                normalIcon.image = (icon ?? NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset Keyboard Binds to Default"))?
                    .withSymbolConfiguration(iconConfig)
            }
        }
    }

    private let leadingInset: CGFloat
    private let titleLeadingAdjustment: CGFloat
    private let successHoldDuration: TimeInterval
    private let onReset: (@escaping () -> Void) -> Void
    private var controlEnabled = true
    private var hovered = false
    private var hoverArea: NSTrackingArea?
    private var menuEndObserver: NSObjectProtocol?
    private var successHoldTimer: Timer?

    private let normalContainer = NSView()
    private let highlightBackground = NSView()
    private let normalIcon = NSImageView()
    private let normalTitleLabel = NSTextField(labelWithString: "Reset Keyboard Binds to Default")

    private let confirmContainer = NSView()
    private let confirmationIcon = NSImageView()
    private let promptLabel = NSTextField(labelWithString: "Reset all shortcuts?")
    private let cancelBtn = NSButton(title: "Cancel", target: nil, action: nil)
    private let resetBtn = DockDestructiveButton(title: "Reset", target: nil, action: nil)

    private let successContainer = NSView()
    private let successContent = NSStackView()
    private let successLabel = NSTextField(labelWithString: "Shortcuts Reset")
    private let successIcon = NSImageView()

    init(
        leadingInset: CGFloat = 18,
        titleLeadingAdjustment: CGFloat = 1.5,
        width: CGFloat = 380,
        height: CGFloat = 26,
        successHoldDuration: TimeInterval = 1,
        onReset: @escaping (@escaping () -> Void) -> Void
    ) {
        self.leadingInset = leadingInset
        self.titleLeadingAdjustment = titleLeadingAdjustment
        self.successHoldDuration = successHoldDuration
        self.onReset = onReset
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)

        setupNormalContainer()
        setupConfirmContainer()
        setupSuccessContainer()
        updateAccessibility()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        successHoldTimer?.invalidate()
        if let menuEndObserver { NotificationCenter.default.removeObserver(menuEndObserver) }
    }

    private func setupNormalContainer() {
        normalContainer.wantsLayer = true
        normalContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(normalContainer)

        highlightBackground.wantsLayer = true
        highlightBackground.layer?.cornerRadius = 5
        highlightBackground.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.cgColor
        highlightBackground.alphaValue = 0
        highlightBackground.translatesAutoresizingMaskIntoConstraints = false
        normalContainer.addSubview(highlightBackground)

        let iconConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        normalIcon.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset Keyboard Binds to Default")?
            .withSymbolConfiguration(iconConfig)
        normalIcon.contentTintColor = .labelColor
        normalIcon.translatesAutoresizingMaskIntoConstraints = false
        normalContainer.addSubview(normalIcon)

        normalTitleLabel.font = NSFont.menuFont(ofSize: 13)
        normalTitleLabel.textColor = .labelColor
        normalTitleLabel.lineBreakMode = .byTruncatingTail
        normalTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        normalContainer.addSubview(normalTitleLabel)

        NSLayoutConstraint.activate([
            normalContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            normalContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            normalContainer.topAnchor.constraint(equalTo: topAnchor),
            normalContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            highlightBackground.leadingAnchor.constraint(equalTo: normalContainer.leadingAnchor, constant: 4),
            highlightBackground.trailingAnchor.constraint(equalTo: normalContainer.trailingAnchor, constant: -4),
            highlightBackground.topAnchor.constraint(equalTo: normalContainer.topAnchor, constant: 1),
            highlightBackground.bottomAnchor.constraint(equalTo: normalContainer.bottomAnchor, constant: -1),

            normalIcon.leadingAnchor.constraint(equalTo: normalContainer.leadingAnchor, constant: leadingInset),
            normalIcon.centerYAnchor.constraint(equalTo: normalContainer.centerYAnchor),
            normalIcon.widthAnchor.constraint(equalToConstant: 16),
            normalIcon.heightAnchor.constraint(equalToConstant: 16),

            normalTitleLabel.leadingAnchor.constraint(
                equalTo: normalIcon.trailingAnchor,
                constant: 6 + titleLeadingAdjustment
            ),
            normalTitleLabel.centerYAnchor.constraint(equalTo: normalContainer.centerYAnchor),
            normalTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: normalContainer.trailingAnchor, constant: -12)
        ])
    }

    private func setupConfirmContainer() {
        confirmContainer.wantsLayer = true
        confirmContainer.translatesAutoresizingMaskIntoConstraints = false
        confirmContainer.isHidden = true
        confirmContainer.alphaValue = 0
        addSubview(confirmContainer)

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        confirmationIcon.contentTintColor = .secondaryLabelColor
        confirmationIcon.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        confirmationIcon.translatesAutoresizingMaskIntoConstraints = false
        confirmContainer.addSubview(confirmationIcon)

        promptLabel.font = .menuFont(ofSize: 13)
        promptLabel.textColor = .labelColor
        promptLabel.lineBreakMode = .byTruncatingTail
        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        confirmContainer.addSubview(promptLabel)

        cancelBtn.bezelStyle = .rounded
        cancelBtn.controlSize = .small
        cancelBtn.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        cancelBtn.target = self
        cancelBtn.action = #selector(cancelClicked)
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false
        confirmContainer.addSubview(cancelBtn)

        resetBtn.controlSize = .small
        resetBtn.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        resetBtn.hasDestructiveAction = true
        resetBtn.target = self
        resetBtn.action = #selector(resetClicked)
        resetBtn.translatesAutoresizingMaskIntoConstraints = false
        confirmContainer.addSubview(resetBtn)

        NSLayoutConstraint.activate([
            confirmContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            confirmContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            confirmContainer.topAnchor.constraint(equalTo: topAnchor),
            confirmContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            confirmationIcon.leadingAnchor.constraint(equalTo: confirmContainer.leadingAnchor, constant: leadingInset),
            confirmationIcon.centerYAnchor.constraint(equalTo: confirmContainer.centerYAnchor),
            confirmationIcon.widthAnchor.constraint(equalToConstant: 16),
            confirmationIcon.heightAnchor.constraint(equalToConstant: 16),

            promptLabel.leadingAnchor.constraint(equalTo: confirmationIcon.trailingAnchor, constant: 6),
            promptLabel.centerYAnchor.constraint(equalTo: confirmContainer.centerYAnchor),
            promptLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelBtn.leadingAnchor, constant: -8),

            resetBtn.trailingAnchor.constraint(equalTo: confirmContainer.trailingAnchor, constant: -12),
            resetBtn.centerYAnchor.constraint(equalTo: confirmContainer.centerYAnchor),
            resetBtn.heightAnchor.constraint(equalToConstant: 20),

            cancelBtn.trailingAnchor.constraint(equalTo: resetBtn.leadingAnchor, constant: -6),
            cancelBtn.centerYAnchor.constraint(equalTo: confirmContainer.centerYAnchor),
            cancelBtn.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    private func setupSuccessContainer() {
        successContainer.wantsLayer = true
        successContainer.translatesAutoresizingMaskIntoConstraints = false
        successContainer.isHidden = true
        successContainer.alphaValue = 0
        addSubview(successContainer)

        successLabel.font = NSFont.menuFont(ofSize: 13)
        successLabel.textColor = .labelColor
        successLabel.translatesAutoresizingMaskIntoConstraints = false

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .systemGreen]))
        successIcon.image = NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: "Shortcuts Reset"
        )?.withSymbolConfiguration(config)
        successIcon.translatesAutoresizingMaskIntoConstraints = false

        successContent.orientation = .horizontal
        successContent.alignment = .centerY
        successContent.spacing = 6
        successContent.addArrangedSubview(successLabel)
        successContent.addArrangedSubview(successIcon)
        successContent.translatesAutoresizingMaskIntoConstraints = false
        successContainer.addSubview(successContent)

        NSLayoutConstraint.activate([
            successContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            successContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            successContainer.topAnchor.constraint(equalTo: topAnchor),
            successContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            successContent.centerXAnchor.constraint(equalTo: successContainer.centerXAnchor),
            successContent.centerYAnchor.constraint(equalTo: successContainer.centerYAnchor),
            successContent.leadingAnchor.constraint(greaterThanOrEqualTo: successContainer.leadingAnchor, constant: 12),
            successContent.trailingAnchor.constraint(lessThanOrEqualTo: successContainer.trailingAnchor, constant: -12),

            successIcon.widthAnchor.constraint(equalToConstant: 16),
            successIcon.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    func setControlEnabled(_ enabled: Bool) {
        controlEnabled = enabled
        cancelBtn.isEnabled = enabled
        resetBtn.isEnabled = enabled
        if !enabled { restoreNormalState(animated: false) }
        setAccessibilityEnabled(enabled)
        updateHoverState()
    }

    func setConfirming(_ confirming: Bool, animated: Bool = true) {
        guard !confirming || controlEnabled else { return }
        guard !confirming || !isShowingSuccess else { return }
        guard isConfirming != confirming else { return }
        addStateTransition(animated: animated)
        isConfirming = confirming
        normalContainer.isHidden = confirming
        normalContainer.alphaValue = confirming ? 0 : 1
        confirmContainer.isHidden = !confirming
        confirmContainer.alphaValue = confirming ? 1 : 0
        successContainer.isHidden = true
        successContainer.alphaValue = 0
        updateHoverState()
        updateAccessibility()
    }

    private func showResetSuccess() {
        successHoldTimer?.invalidate()
        successHoldTimer = nil
        isConfirming = false
        isShowingSuccess = true
        normalContainer.isHidden = true
        normalContainer.alphaValue = 0
        successContainer.isHidden = false
        successContainer.alphaValue = 1

        confirmContainer.layer?.removeAnimation(forKey: "confirmationFadeOut")
        successContainer.layer?.removeAnimation(forKey: "successFadeIn")
        if window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Keep the old confirmation visible in the presentation layer while
            // the success state fades over it, then leave both model layers in
            // their final state for the remainder of the cascade.
            confirmContainer.isHidden = false
            confirmContainer.alphaValue = 0
            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = 1
            fadeOut.toValue = 0
            fadeOut.duration = 0.24
            fadeOut.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            confirmContainer.layer?.add(fadeOut, forKey: "confirmationFadeOut")

            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.duration = 0.24
            fadeIn.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            successContainer.layer?.add(fadeIn, forKey: "successFadeIn")
        } else {
            confirmContainer.isHidden = true
            confirmContainer.alphaValue = 0
        }
        updateHoverState()
        updateAccessibility()
    }

    private func finishResetSuccess(animated: Bool = true) {
        guard isShowingSuccess else { return }
        addStateTransition(animated: animated, duration: 0.5)
        isShowingSuccess = false
        confirmContainer.isHidden = true
        confirmContainer.alphaValue = 0
        successContainer.isHidden = true
        successContainer.alphaValue = 0
        normalContainer.isHidden = false
        normalContainer.alphaValue = 1
        restoreNormalContent()
        updateHoverState()
        updateAccessibility()
    }

    private func holdResetSuccessAfterCascade() {
        guard isShowingSuccess else { return }
        successHoldTimer?.invalidate()
        let timer = Timer(timeInterval: successHoldDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.successHoldTimer = nil
                self.finishResetSuccess()
            }
        }
        successHoldTimer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
    }

    private func restoreNormalState(animated: Bool) {
        successHoldTimer?.invalidate()
        successHoldTimer = nil
        confirmContainer.layer?.removeAnimation(forKey: "confirmationFadeOut")
        successContainer.layer?.removeAnimation(forKey: "successFadeIn")
        let stateChanged = isConfirming || isShowingSuccess
        if stateChanged { addStateTransition(animated: animated) }
        isConfirming = false
        isShowingSuccess = false
        normalContainer.isHidden = false
        normalContainer.alphaValue = 1
        confirmContainer.isHidden = true
        confirmContainer.alphaValue = 0
        successContainer.isHidden = true
        successContainer.alphaValue = 0
        restoreNormalContent()
        updateHoverState()
        updateAccessibility()
    }

    private func restoreNormalContent() {
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        normalIcon.image = (icon ?? NSImage(
            systemSymbolName: "arrow.counterclockwise",
            accessibilityDescription: "Reset Keyboard Binds to Default"
        ))?.withSymbolConfiguration(iconConfig)
        normalTitleLabel.stringValue = title
    }

    private func addStateTransition(animated: Bool, duration: TimeInterval = 0.16) {
        // One replaceable fade keeps all three states inside the same fixed row.
        layer?.removeAnimation(forKey: "transition")
        guard animated, window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = duration
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(transition, forKey: "transition")
    }

    private func updateAccessibility() {
        // Expose the real confirmation buttons, rather than making a second
        // VoiceOver press on the row silently confirm the reset.
        setAccessibilityRole(isConfirming ? .group : .button)
        setAccessibilityLabel(
            isConfirming ? "Reset all shortcuts to defaults?"
                : (isShowingSuccess ? "Shortcuts Reset" : title)
        )
        setAccessibilityChildren(isConfirming ? [promptLabel, cancelBtn, resetBtn] : [])
    }

    @objc private func cancelClicked() {
        setConfirming(false)
    }

    @objc private func resetClicked() {
        guard controlEnabled && isConfirming else { return }
        showResetSuccess()
        onReset { [weak self] in
            self?.holdResetSuccessAfterCascade()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard controlEnabled && !isShowingSuccess else { return }
        if !isConfirming {
            setConfirming(true, animated: true)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        updateHoverState()
    }

    private func updateHoverState() {
        let isHighlighted = controlEnabled && !isConfirming && !isShowingSuccess
            && (hovered || (enclosingMenuItem?.isHighlighted ?? false))
        // Menu highlighting follows the pointer immediately, like other rows.
        highlightBackground.alphaValue = isHighlighted ? 1 : 0
        let color: NSColor = isHighlighted ? .selectedMenuItemTextColor
            : (controlEnabled ? .labelColor : .tertiaryLabelColor)
        normalTitleLabel.textColor = color
        normalIcon.contentTintColor = color
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        hoverArea = area
        addTrackingArea(area)
        hovered = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        updateHoverState()
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateHoverState()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateHoverState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hovered = false
        if let menuEndObserver {
            NotificationCenter.default.removeObserver(menuEndObserver)
            self.menuEndObserver = nil
        }
        if window != nil, let menu = enclosingMenuItem?.menu {
            menuEndObserver = NotificationCenter.default.addObserver(
                forName: NSMenu.didEndTrackingNotification, object: menu, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.layer?.removeAnimation(forKey: "transition")
                    self?.restoreNormalState(animated: false)
                }
            }
        }
        if window == nil {
            layer?.removeAnimation(forKey: "transition")
            restoreNormalState(animated: false)
        }
        updateHoverState()
    }

    @objc func performMenuAction(_ sender: Any?) {
        guard controlEnabled && !isShowingSuccess else { return }
        setConfirming(true, animated: true)
    }

    override func accessibilityPerformPress() -> Bool {
        guard controlEnabled && !isConfirming && !isShowingSuccess else { return false }
        setConfirming(true)
        return true
    }
}

final class WideMenuSeparatorView: NSView {
    private let leadingInset: CGFloat
    private let trailingInset: CGFloat

    init(width: CGFloat = 190, leadingInset: CGFloat = 14, trailingInset: CGFloat = 14) {
        self.leadingInset = leadingInset
        self.trailingInset = trailingInset
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 9))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 9)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let lineY = floor(bounds.midY)
        let rect = NSRect(
            x: leadingInset,
            y: lineY,
            width: max(0, bounds.width - leadingInset - trailingInset),
            height: 1
        )
        NSColor.separatorColor.setFill()
        rect.fill()
    }
}

extension NSMenuItem {
    static func wideSeparator(
        width: CGFloat = 190,
        leadingInset: CGFloat = 14,
        trailingInset: CGFloat = 14
    ) -> NSMenuItem {
        let separator = NSMenuItem()
        separator.tag = -999
        separator.isEnabled = false
        separator.view = WideMenuSeparatorView(width: width, leadingInset: leadingInset, trailingInset: trailingInset)
        return separator
    }
}
