import Cocoa


/// A custom-drawn row that opens a submenu. `.icon` rows lead with an SF
/// Symbol; `.plain` rows are indented titles with a secondary chevron.
final class SubmenuLabelView: NSView {
    enum Style {
        case icon(symbolName: String, symbolHeight: CGFloat = 12, clearsSecondaryLayer: Bool = false)
        case plain
    }

    private let title: String?
    private let style: Style
    private let highlightsWithMenuItem: Bool
    private var hoverArea: NSTrackingArea?
    private var hovered = false

    /// A `nil` title draws the enclosing menu item's title.
    init(title: String?, accessibilityLabel: String? = nil, style: Style,
         highlightsWithMenuItem: Bool = true, width fixedWidth: CGFloat? = nil) {
        self.title = title
        self.style = style
        self.highlightsWithMenuItem = highlightsWithMenuItem
        let textWidth = ceil(((title ?? "") as NSString).size(
            withAttributes: [.font: NSFont.menuFont(ofSize: 13)]).width)
        let frame: NSRect
        switch style {
        case .icon: frame = NSRect(x: 0, y: 0, width: fixedWidth ?? textWidth + 60, height: 24)
        case .plain: frame = NSRect(x: 0, y: 0, width: fixedWidth ?? textWidth + 70, height: 26)
        }
        super.init(frame: frame)
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityLabel(accessibilityLabel ?? title)
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = hovered || (highlightsWithMenuItem && enclosingMenuItem?.isHighlighted == true)
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let color: NSColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        let text = NSMutableAttributedString(string: title ?? enclosingMenuItem?.title ?? "Customize: All Displays",
            attributes: [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: color])
        let leftAligned = NSMutableParagraphStyle()
        leftAligned.alignment = .left
        text.addAttribute(.paragraphStyle, value: leftAligned,
                          range: NSRange(location: 0, length: text.length))
        let textHeight = ceil(text.size().height)
        let chevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)

        switch style {
        case let .icon(symbolName, symbolHeight, clearsSecondaryLayer):
            text.draw(in: NSRect(x: 34.0, y: (bounds.height - textHeight) / 2,
                                 width: bounds.width - 54, height: textHeight))
            let iconConfiguration = NSImage.SymbolConfiguration(
                paletteColors: clearsSecondaryLayer ? [color, .clear] : [color])
            NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(iconConfiguration)?
                .draw(in: NSRect(x: 12, y: bounds.midY - symbolHeight / 2, width: 14, height: symbolHeight))
            chevron?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))?
                .draw(in: NSRect(x: bounds.maxX - 18, y: bounds.midY - 5, width: 6, height: 10))
        case .plain:
            text.draw(in: NSRect(x: 20, y: (bounds.height - textHeight) / 2,
                                 width: bounds.width - 20 - 24, height: textHeight))
            let chevronColor: NSColor = highlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
            let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [chevronColor]))
            chevron?.withSymbolConfiguration(configuration)?
                .draw(in: NSRect(x: bounds.maxX - 23, y: bounds.midY - 5, width: 6, height: 10))
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
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hovered = false; needsDisplay = true }
}

extension SubmenuLabelView {
    static func displayOrder() -> SubmenuLabelView {
        SubmenuLabelView(title: "List Active Display on Top",
                         style: .icon(symbolName: "display", clearsSecondaryLayer: true))
    }

    static func desktopIndicatorAppearance() -> SubmenuLabelView {
        SubmenuLabelView(title: "Menubar Desktop Indicator",
                         style: .icon(symbolName: "menubar.rectangle", symbolHeight: 10),
                         highlightsWithMenuItem: false)
    }

    static func keyboardNavigation() -> SubmenuLabelView {
        SubmenuLabelView(title: "DockAway Keyboard Navigation", style: .icon(symbolName: "keyboard"))
    }

    static func missionControl() -> SubmenuLabelView {
        SubmenuLabelView(title: "macOS Mission Control Enhancements",
                         style: .icon(symbolName: "rectangle.3.group"), highlightsWithMenuItem: false)
    }

    static func theme() -> SubmenuLabelView {
        SubmenuLabelView(title: "Theme", style: .icon(symbolName: "paintpalette"), highlightsWithMenuItem: false)
    }

    static func indicatorSeparator() -> SubmenuLabelView {
        SubmenuLabelView(title: "Indicator Separator", style: .plain)
    }

    static func desktopNumberIndicator() -> SubmenuLabelView {
        SubmenuLabelView(title: "Desktop Manager Number Style", style: .plain)
    }

    /// Titled by its menu item, which names the display being customized.
    static func customizeDisplays() -> SubmenuLabelView {
        SubmenuLabelView(title: nil, accessibilityLabel: "Customize", style: .plain, width: 250)
    }
}

// The preview has its own explicit drawing area instead of relying on NSMenu's
// small icon column. This stays inside the existing native submenu.
final class DesktopIndicatorPreviewRow: NSButton {
    private let indicatorSwitch = DockMenuSwitch()
    private var helpButton: DockSettingHelpButton?
    var onPreviewClick: ((NSPoint) -> Void)?
    var onToggle: ((Bool) -> Void)? {
        didSet {
            indicatorSwitch.isHidden = onToggle == nil
            helpButton?.isHidden = onToggle == nil
            frame.size.height = onToggle != nil ? 76 : 42
            needsLayout = true
        }
    }
    private var previewLeading: CGFloat { onToggle == nil ? 24 : 20 }
    private let previewImageView = NSImageView()
    private var previewBackground: NSView!
    var preview: NSImage? {
        didSet {
            let targetAppearance = DockAwayTheme.current.appearance ?? NSApp.effectiveAppearance
            previewImageView.appearance = targetAppearance
            previewBackground?.appearance = targetAppearance
            if onToggle == nil, oldValue?.size != preview?.size {
                let titleWidth = (title as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 13)]).width
                frame.size.width = ceil(previewLeading + (preview?.size.width ?? 96) + 12 + titleWidth + 10)
            }
            previewImageView.image = preview
            needsLayout = true
            needsDisplay = true
        }
    }
    var selected = false {
        didSet {
            let state: NSControl.StateValue = selected ? .on : .off
            if indicatorSwitch.state != state { indicatorSwitch.state = state }
            needsDisplay = true
        }
    }
    private var hovered = false
    private var hoverArea: NSTrackingArea?

    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 42))
        self.title = title
        autoresizingMask = [.width]
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryChange)
        if let buttonCell = cell as? NSButtonCell {
            buttonCell.highlightsBy = []
            buttonCell.showsStateBy = []
        }
        setAccessibilityLabel(title)
        previewImageView.imageScaling = .scaleNone
        previewImageView.setAccessibilityElement(false)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 8
            // Darken only the preview glass, not the actual menu-bar indicator.
            glass.tintColor = NSColor.black.withAlphaComponent(0.22)
            glass.contentView = previewImageView
            // This glass is a preview background, not a standalone control.
            // Interactive glass draws an accent hover ring that can escape the
            // custom NSMenu row as two full-width horizontal lines.
            if #available(macOS 27.0, *) { glass.effectIsInteractive = false }
            previewBackground = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 8
            effect.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
            effect.layer?.masksToBounds = true
            effect.layer?.borderWidth = 0.5
            effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
            effect.addSubview(previewImageView)
            previewImageView.autoresizingMask = [.width, .height]
            previewBackground = effect
        }
        let targetAppearance = DockAwayTheme.current.appearance ?? NSApp.effectiveAppearance
        previewImageView.appearance = targetAppearance
        previewBackground.appearance = targetAppearance
        previewBackground.setAccessibilityElement(false)
        addSubview(previewBackground)
        indicatorSwitch.controlSize = .small
        indicatorSwitch.sizeToFit()
        indicatorSwitch.target = self
        indicatorSwitch.action = #selector(toggleIndicator(_:))
        indicatorSwitch.isHidden = true
        indicatorSwitch.setAccessibilityLabel("Menubar Desktop Indicator")
        addSubview(indicatorSwitch)

        let help = DockSettingHelpButton(
            heading: "Menubar Desktop Indicator",
            textProvider: {
                "Displays the active macOS desktop space number for each connected display directly in your menu bar.\n\n• Keeps track of your active space without opening Mission Control.\n• Supports multi-display setups with stacked or horizontal layouts.\n• Fully customizable with pills, fills, outlines, and DockAway blue.\n• Click any display in the preview above to customize its appearance individually."
            }
        )
        help.isHidden = true
        self.helpButton = help
        addSubview(help)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    @objc private func toggleIndicator(_ sender: DockMenuSwitch) {
        selected = sender.state == .on
        onToggle?(selected)
    }


    override func layout() {
        super.layout()
        if onToggle != nil {
            let switchSize = indicatorSwitch.intrinsicContentSize
            helpButton?.frame = NSRect(
                x: bounds.width - 12 - 16,
                y: 21 - 8,
                width: 16,
                height: 16
            )
            indicatorSwitch.frame = NSRect(
                x: (helpButton?.frame.minX ?? bounds.width - 28) - 8 - switchSize.width,
                y: 21 - switchSize.height / 2,
                width: switchSize.width,
                height: switchSize.height
            )
            helpButton?.isHidden = false
            previewBackground.frame = NSRect(
                x: (bounds.width - (preview?.size.width ?? 96)) / 2,
                y: 38,
                width: preview?.size.width ?? 96,
                height: 30
            )
        } else {
            helpButton?.isHidden = true
            previewBackground.frame = NSRect(x: previewLeading, y: 5, width: preview?.size.width ?? 96, height: 32)
        }
        if #available(macOS 26.0, *) {
            // NSGlassEffectView lays out its content view.
        } else {
            previewImageView.frame = previewBackground.bounds
        }
    }

    // Only the native switch toggles. Consume other row clicks without letting
    // NSMenu treat them as item selection; the preview has its own edit action.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        let local = convert(point, from: superview)
        if let helpButton, !helpButton.isHidden, helpButton.frame.insetBy(dx: -4, dy: -4).contains(local) {
            return helpButton
        }
        if onToggle != nil, indicatorSwitch.frame.contains(local) {
            return indicatorSwitch.hitTest(local)
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard onToggle != nil else { super.mouseDown(with: event); return }
        guard let window else { return }
        let loc = convert(event.locationInWindow, from: nil)
        if let helpButton, !helpButton.isHidden, helpButton.frame.insetBy(dx: -4, dy: -4).contains(loc) {
            helpButton.performHelpAction(self)
            return
        }
        helpButton?.closePopover()
        let beganInPreview = previewBackground.frame.contains(loc)
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged],
                                          until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp {
                let point = convert(next.locationInWindow, from: nil)
                if beganInPreview, let onPreviewClick, previewBackground.frame.contains(point) {
                    let frame = previewBackground.frame
                    onPreviewClick(NSPoint(x: (point.x - frame.minX) / frame.width,
                                           y: (point.y - frame.minY) / frame.height))
                    return
                }
                return
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if onToggle == nil { super.mouseUp(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = hovered || isHighlighted
        if highlighted && onToggle == nil {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let color: NSColor = (highlighted && onToggle == nil) ? .selectedMenuItemTextColor : .labelColor
        if onToggle != nil {
            let titleFont = NSFont.systemFont(ofSize: 15, weight: .regular)
            let titleRightLimit = indicatorSwitch.frame.minX
            let titleRect = NSRect(x: 20, y: 10, width: max(0, titleRightLimit - 26), height: 22)
            (title as NSString).draw(
                in: titleRect,
                withAttributes: [
                    .font: titleFont,
                    .foregroundColor: NSColor.labelColor
                ]
            )
        } else {
            let previewWidth = preview?.size.width ?? 96
            let titleX = previewLeading + previewWidth + 12
            (title as NSString).draw(in: NSRect(x: titleX, y: 12, width: bounds.width - titleX - 10, height: 20),
                withAttributes: [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: color])
            if selected {
                ("✓" as NSString).draw(at: NSPoint(x: 8, y: 12),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: color])
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        hoverArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
}
