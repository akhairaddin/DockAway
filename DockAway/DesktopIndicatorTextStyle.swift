import Cocoa

enum DesktopIndicatorPreference {
    static let enabledKey = "desktopIndicatorEnabled"
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        if let saved = defaults.object(forKey: enabledKey) as? Bool { return saved }
        // Preserve the former None choice when migrating to the explicit toggle.
        return (defaults.object(forKey: "DesktopIndicatorAppearance") as? Int) != 0
    }
    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
        defaults.set(enabled ? 1 : 0, forKey: "DesktopIndicatorAppearance")
    }
}

struct DesktopIndicatorTextStyle: Codable {
    enum Badge: Int, Codable { case none, filled, outline, filledOutline }
    var hasFill: Bool { badge == .filled || badge == .filledOutline }
    var hasOutline: Bool { badge == .outline || badge == .filledOutline }
    enum Separator: RawRepresentable, Equatable, Hashable, Codable {
        case none, of, slash, backslash, dash, emDash
        case bullet, hollowBullet, heart, hollowHeart
        case star, hollowStar, diamond, hollowDiamond, flower, hollowFlower
        case custom(String)

        var rawValue: String {
            switch self {
            case .none: return "none"
            case .of: return "of"
            case .slash: return "slash"
            case .backslash: return "backslash"
            case .dash: return "dash"
            case .emDash: return "emDash"
            case .bullet: return "bullet"
            case .hollowBullet: return "hollowBullet"
            case .heart: return "heart"
            case .hollowHeart: return "hollowHeart"
            case .star: return "star"
            case .hollowStar: return "hollowStar"
            case .diamond: return "diamond"
            case .hollowDiamond: return "hollowDiamond"
            case .flower: return "flower"
            case .hollowFlower: return "hollowFlower"
            case .custom(let str): return "custom:" + str
            }
        }

        nonisolated init?(rawValue: String) {
            switch rawValue {
            case "none": self = .none
            case "of", "verticalLine": self = .of
            case "slash": self = .slash
            case "backslash": self = .backslash
            case "dash": self = .dash
            case "emDash": self = .emDash
            case "bullet": self = .bullet
            case "hollowBullet": self = .hollowBullet
            case "heart": self = .heart
            case "hollowHeart": self = .hollowHeart
            case "star": self = .star
            case "hollowStar": self = .hollowStar
            case "diamond": self = .diamond
            case "hollowDiamond": self = .hollowDiamond
            case "flower": self = .flower
            case "hollowFlower": self = .hollowFlower
            default:
                if rawValue.hasPrefix("custom:") {
                    let text = String(rawValue.dropFirst("custom:".count))
                    self = .custom(text)
                } else {
                    return nil
                }
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if raw == "verticalLine" {
                self = .of
            } else if let val = Separator(rawValue: raw) {
                self = val
            } else {
                self = .of
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        var title: String {
            switch self {
            case .none: return "None"
            case .of: return "of"
            case .slash: return "/"
            case .backslash: return "\\"
            case .dash: return "-"
            case .emDash: return "\u{2014}"
            case .bullet: return "•"
            case .hollowBullet: return "◦"
            case .heart: return "♥"
            case .hollowHeart: return "♡"
            case .star: return "★"
            case .hollowStar: return "☆"
            case .diamond: return "◆"
            case .hollowDiamond: return "◇"
            case .flower: return "✿"
            case .hollowFlower: return "❀"
            case .custom(let str):
                let trimmed = str.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? "" : trimmed
            }
        }
        var accessibilityLabel: String {
            switch self {
            case .none: return "None"
            case .of: return "of"
            case .slash: return "Slash"
            case .backslash: return "Backslash"
            case .dash: return "Dash"
            case .emDash: return "Em dash"
            case .bullet: return "Filled bullet"
            case .hollowBullet: return "Unfilled bullet"
            case .heart: return "Filled heart"
            case .hollowHeart: return "Unfilled heart"
            case .star: return "Filled star"
            case .hollowStar: return "Unfilled star"
            case .diamond: return "Filled diamond"
            case .hollowDiamond: return "Unfilled diamond"
            case .flower: return "Filled flower"
            case .hollowFlower: return "Unfilled flower"
            case .custom(let str): return "Custom (\(str))"
            }
        }
        func suffix(total: Int) -> String {
            switch self {
            case .none:
                return ""
            case .custom(let str):
                let trimmed = str.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? " \(total)" : " \(trimmed) \(total)"
            default:
                return " \(title) \(total)"
            }
        }
    }
    var badge: Badge = .none
    var hierarchical = false
    var usesAccentColor = true
    var separator: Separator = .of
    var usesPill = false
    var pillOpacity: Double = 0.08
    var encapsulatesDockIndicator = false
    // Nil preserves the shape selected by older builds. New values are a
    // normalized 0...1 radius controlled by the native corner-radius slider.
    var pillCornerRadius: Double? = nil
    var usesRoundPill = false
    var accentsPlainNumber = false
    var accentOnlyWhenActive: Bool? = nil
    var fillOnlyWhenActive: Bool? = nil
    var pillOnlyWhenActive: Bool? = nil
    var pillPaddingHorizontal: Double? = 8.0
    var pillPaddingVertical: Double? = 3.0

    func resolvedForDisplay(isActive: Bool) -> Self {
        var result = self
        if accentOnlyWhenActive == true { result.usesAccentColor = isActive && badge != .none }
        if fillOnlyWhenActive == true && badge != .none {
            result.badge = isActive ? (hasOutline ? .filledOutline : .filled) : .outline
        }
        if pillOnlyWhenActive == true {
            result.usesPill = isActive && usesPill
        }
        return result
    }

    mutating func setOption(_ option: Int, enabled: Bool) {
        switch option {
        case 0:
            if enabled && hasOutline && fillOnlyWhenActive == true && accentOnlyWhenActive == true {
                badge = .filled
            } else {
                badge = enabled ? (hasOutline ? .filledOutline : .filled) : (hasOutline ? .outline : .none)
            }
        case 1:
            badge = enabled ? (hasFill ? .filledOutline : .outline)
                : (hasFill || fillOnlyWhenActive == true ? .filled : .none)
        case 2: hierarchical = enabled
        case 3: usesAccentColor = enabled
        case 5:
            usesPill = enabled
        case 7:
            encapsulatesDockIndicator = enabled
            if enabled { pillOnlyWhenActive = false }
        case 10:
            guard !enabled || badge != .none else { return }
            fillOnlyWhenActive = enabled
        case 12:
            pillOnlyWhenActive = enabled
            if enabled { encapsulatesDockIndicator = false }
        default: break
        }
    }

    func text(current: Int, total: Int, isFullscreen: Bool, dockIndicator: NSImage? = nil,
              compactPillLayout: Bool = false, isActive: Bool = true) -> NSAttributedString {
        let opacity = pillOpacity.isFinite ? min(1, max(0, pillOpacity)) : 0.08
        let activeAppearance = NSAppearance.currentDrawing()
        let isDark = activeAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let pillInk: NSColor = usesPill && opacity >= 0.5
            ? (isDark ? .black : .white)
            : (isDark ? .white : .black)
        let displayAlpha: CGFloat = (hierarchical && !isActive) ? 0.55 : 1.0
        let effectivePillInk = pillInk.withAlphaComponent(pillInk.alphaComponent * displayAlpha)
        let suffixInk = hierarchical
            ? pillInk.withAlphaComponent(0.55 * displayAlpha)
            : effectivePillInk
        let number = isFullscreen ? "FS" : "\(current)"
        let result = NSMutableAttributedString()
        if badge == .none {
            result.append(NSAttributedString(string: number, attributes: [
                .foregroundColor: effectivePillInk,
                .font: NSFont.monospacedDigitSystemFont(ofSize: hierarchical ? 12.5 : 12, weight: hierarchical ? .bold : .medium)
            ]))
        } else {
            let compact = !hierarchical
            let height: CGFloat = hierarchical ? 18 : 14
            let font = NSFont.monospacedDigitSystemFont(
                ofSize: hierarchical ? 12.5 : 10,
                weight: hierarchical ? .bold : .medium
            )
            let size = (number as NSString).size(withAttributes: [.font: font])
            let image = NSImage(size: NSSize(width: max(height, size.width + (compact ? 5 : 6)), height: height), flipped: false) { rect in
                let radius: CGFloat = compact ? 3 : 3.5
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.6, dy: 0.6), xRadius: radius, yRadius: radius)
                let baseBadgeColor = usesAccentColor ? NSColor.systemBlue : pillInk
                let badgeColor = baseBadgeColor.withAlphaComponent(baseBadgeColor.alphaComponent * displayAlpha)
                let baseNumberColor = hasFill
                    ? (usesAccentColor ? NSColor.white : (usesPill && opacity >= 0.5 ? (isDark ? NSColor.white : NSColor.black) : (isDark ? NSColor.black : NSColor.white)))
                    : pillInk
                let numberColor = baseNumberColor.withAlphaComponent(baseNumberColor.alphaComponent * displayAlpha)
                badgeColor.set()
                if hasFill { path.fill() }
                if hasOutline {
                    if hasFill {
                        // Keep the border neutral, even when the fill is accented.
                        let baseBorder = (usesAccentColor ? pillInk : baseNumberColor)
                        baseBorder.withAlphaComponent(baseBorder.alphaComponent * displayAlpha).setStroke()
                    }
                    path.lineWidth = 1.2
                    path.stroke()
                }
                (number as NSString).draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (height - size.height) / 2 - 0.5),
                    withAttributes: [.font: font, .foregroundColor: numberColor])
                return true
            }
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: hierarchical ? -4 : -2, width: image.size.width, height: height)
            result.append(NSAttributedString(attachment: attachment))
        }
        if !isFullscreen {
            result.append(NSAttributedString(string: separator.suffix(total: total), attributes: [
                .foregroundColor: suffixInk,
                .font: hierarchical ? NSFont.systemFont(ofSize: 11.5, weight: .regular)
                    : NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            ]))
        }
        guard usesPill else { return result }
        // The pill surrounds the complete indicator, so other options still combine.
        let content = NSMutableAttributedString(attributedString: result)
        let contentSize = content.size()
        let includedIcon = encapsulatesDockIndicator ? dockIndicator : nil
        let hPad = CGFloat(pillPaddingHorizontal ?? (compactPillLayout ? 4 : 8))
        let vPad = CGFloat(pillPaddingVertical ?? (compactPillLayout ? 1 : 3))
        let padding: CGFloat = compactPillLayout ? max(1, round(hPad * 0.5)) : hPad
        let verticalPad: CGFloat = compactPillLayout ? max(0, round(vPad * 0.6)) : vPad
        let iconWidth: CGFloat = includedIcon == nil ? 0 : (compactPillLayout ? 24 : 28)
        let minHeight = max(includedIcon != nil ? 16 : 0, ceil(contentSize.height))
        let height = max(compactPillLayout ? (12 + verticalPad * 2) : (14 + verticalPad * 2), minHeight + verticalPad * 2)
        let minWidth: CGFloat = compactPillLayout ? (10 + padding * 2) : (18 + padding * 2)
        let totalWidth = max(minWidth, ceil(contentSize.width) + padding * 2 + iconWidth)
        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { rect in
            (isDark ? NSColor.white : NSColor.black).withAlphaComponent(opacity * displayAlpha).setFill()
            let maximumRadius = height / 2
            let legacyRadius = usesRoundPill ? maximumRadius : height * 0.15
            let radius = pillCornerRadius.map {
                maximumRadius * CGFloat(min(1, max(0, $0)))
            } ?? legacyRadius
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            if let includedIcon {
                let iconRect = NSRect(x: padding, y: (height - 16) / 2, width: 22, height: 16)
                let tinted = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { tintRect in
                    includedIcon.draw(in: tintRect, from: .zero, operation: .sourceOver, fraction: displayAlpha)
                    effectivePillInk.setFill()
                    tintRect.fill(using: .sourceIn)
                    return true
                }
                tinted.draw(in: iconRect)
            }
            content.draw(at: NSPoint(x: (rect.width - contentSize.width + iconWidth) / 2,
                                     y: (rect.height - contentSize.height) / 2))
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: -3 - (height - 16) / 2, width: image.size.width, height: height)
        return NSAttributedString(attachment: attachment)
    }
}

final class CustomSeparatorEditButton: NSButton {
    private var trackingAreaRef: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = "Edit"
        font = .systemFont(ofSize: 11, weight: .regular)
        contentTintColor = .secondaryLabelColor
        setButtonType(.momentaryChange)
        setAccessibilityLabel("Edit Custom Separator")
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
    }

    override func mouseExited(with event: NSEvent) {
        contentTintColor = .secondaryLabelColor
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

final class DesktopIndicatorSeparatorOptionsView: NSView {
    static let customSeparatorDefaultsKey = "desktopIndicatorCustomSeparator"

    var onChange: ((DesktopIndicatorTextStyle.Separator) -> Void)?
    private var controls: [DesktopIndicatorTextStyle.Separator: DockSettingPersistenceRowView] = [:]
    private var selectedSeparator: DesktopIndicatorTextStyle.Separator = .of
    private var customRow: DockSettingPersistenceRowView?
    private var customEditButton: CustomSeparatorEditButton?

    static let pairs: [(col0: DesktopIndicatorTextStyle.Separator, col1: DesktopIndicatorTextStyle.Separator)] = [
        (.none, .of),
        (.slash, .backslash),
        (.dash, .emDash),
        (.hollowBullet, .bullet),
        (.hollowHeart, .heart),
        (.hollowStar, .star),
        (.hollowDiamond, .diamond),
        (.hollowFlower, .flower)
    ]

    override var intrinsicContentSize: NSSize { frame.size }

    override init(frame: NSRect) {
        super.init(frame: frame)

        let rowHeight: CGFloat = 20.0
        let numRows = Self.pairs.count
        let columnWidth: CGFloat = 56.0
        let gap: CGFloat = 6.0
        let padX: CGFloat = 8.0
        let padY: CGFloat = 4.0
        let colX = [padX, padX + columnWidth + gap]
        let totalWidth: CGFloat = colX[1] + columnWidth + padX
        let customRowHeight: CGFloat = 22.0
        let separatorGap: CGFloat = 8.0
        let customY = padY
        let presetsBaseY = customY + customRowHeight + separatorGap
        let totalHeight: CGFloat = presetsBaseY + CGFloat(numRows) * rowHeight + padY

        for (rowIndex, pair) in Self.pairs.enumerated() {
            let y = presetsBaseY + CGFloat(numRows - 1 - rowIndex) * rowHeight

            let items: [(col: Int, sep: DesktopIndicatorTextStyle.Separator)] = [(0, pair.col0), (1, pair.col1)]
            for item in items {
                let x = colX[item.col]
                let row = DockSettingPersistenceRowView(
                    title: item.sep.title,
                    isOn: false,
                    width: columnWidth,
                    leadingInset: 0,
                    trailingInset: 0,
                    titleLeadingAdjustment: -1,
                    font: .systemFont(ofSize: 13),
                    indicatorSize: 14,
                    multiline: false,
                    centeredTitle: false,
                    checkboxOnFirstLine: true
                ) { [weak self] _ in
                    self?.selectSeparator(item.sep)
                }
                row.checkboxControl.setAccessibilityLabel(item.sep.accessibilityLabel)
                let sepToolTip: String
                if item.sep == .none {
                    sepToolTip = "Show only the current desktop number without displaying the total count."
                } else {
                    sepToolTip = "Use '\(item.sep.title)' (\(item.sep.accessibilityLabel)) as the separator between current desktop and total desktop count (e.g. 1 \(item.sep.title) 3)."
                }
                row.toolTip = sepToolTip
                row.checkboxControl.toolTip = sepToolTip
                row.frame = NSRect(x: x, y: y, width: columnWidth, height: rowHeight)
                controls[item.sep] = row
                addSubview(row)
            }
        }

        // Custom Separator Row
        let customRowWidth = totalWidth - padX * 2 - 32.0
        let row = DockSettingPersistenceRowView(
            title: "Custom...",
            isOn: false,
            width: customRowWidth,
            leadingInset: 0,
            trailingInset: 0,
            titleLeadingAdjustment: -1,
            font: .systemFont(ofSize: 12),
            indicatorSize: 14,
            multiline: false,
            centeredTitle: false,
            checkboxOnFirstLine: true
        ) { [weak self] _ in
            guard let self else { return }
            let saved = UserDefaults.standard.string(forKey: Self.customSeparatorDefaultsKey)
            if let saved, !saved.isEmpty {
                self.selectSeparator(.custom(saved))
            } else {
                self.handleEditClick()
            }
        }
        row.frame = NSRect(x: padX, y: customY, width: customRowWidth, height: customRowHeight)
        addSubview(row)
        self.customRow = row

        let editButton = CustomSeparatorEditButton()
        editButton.frame = NSRect(x: totalWidth - padX - 30.0, y: customY + 1, width: 30.0, height: customRowHeight - 2)
        editButton.target = self
        editButton.action = #selector(handleEditClick)
        addSubview(editButton)
        self.customEditButton = editButton

        self.frame.size = NSSize(width: totalWidth, height: totalHeight)
        refreshCustomRowAppearance()
    }

    required init?(coder: NSCoder) { nil }
    override func mouseDown(with event: NSEvent) {} // Keep the native menu open.

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        NSRect(x: 8.0, y: 30.0, width: bounds.width - 16.0, height: 1.0).fill()
    }

    @objc private func handleEditClick() {
        var menu = enclosingMenuItem?.menu
        while let supermenu = menu?.supermenu {
            menu = supermenu
        }
        menu?.cancelTracking()
        let currentVal: String?
        if case .custom(let str) = selectedSeparator {
            currentVal = str
        } else {
            currentVal = UserDefaults.standard.string(forKey: Self.customSeparatorDefaultsKey)
        }
        DispatchQueue.main.async { [weak self] in
            self?.presentCustomSeparatorPrompt(currentValue: currentVal)
        }
    }

    private func presentCustomSeparatorPrompt(currentValue: String?) {
        let alert = NSAlert()
        alert.messageText = "Custom Indicator Separator"
        alert.informativeText = "Enter a custom symbol, text, or emoji to use between desktop numbers (e.g., “|”, “~”, “to”):"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        inputField.font = .systemFont(ofSize: 13)
        inputField.placeholderString = "e.g. | or to"
        if let currentValue, !currentValue.isEmpty {
            inputField.stringValue = currentValue
        }
        alert.accessoryView = inputField
        alert.window.initialFirstResponder = inputField

        NSApp.activate(ignoringOtherApps: true)
        inputField.selectText(nil)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let clean = inputField.stringValue
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty {
                let customVal = String(clean.prefix(12))
                UserDefaults.standard.set(customVal, forKey: Self.customSeparatorDefaultsKey)
                self.selectSeparator(.custom(customVal))
            }
        }
    }

    func selectSeparator(_ separator: DesktopIndicatorTextStyle.Separator) {
        selectedSeparator = separator
        update(separator)
        onChange?(separator)
    }

    func update(_ selected: DesktopIndicatorTextStyle.Separator) {
        selectedSeparator = selected
        for (sep, control) in controls {
            control.setOn(sep == selected)
        }
        let isCustom: Bool
        switch selected {
        case .custom: isCustom = true
        default: isCustom = false
        }
        customRow?.setOn(isCustom)
        refreshCustomRowAppearance()
    }

    private func refreshCustomRowAppearance() {
        let saved = UserDefaults.standard.string(forKey: Self.customSeparatorDefaultsKey)
        let displayStr: String?
        if case .custom(let str) = selectedSeparator {
            displayStr = str
            if saved != str {
                UserDefaults.standard.set(str, forKey: Self.customSeparatorDefaultsKey)
            }
        } else {
            displayStr = saved
        }
        if let displayStr, !displayStr.isEmpty {
            customRow?.setTitle("Custom: \(displayStr)")
            customEditButton?.isHidden = false
            let tip = "Use '\(displayStr)' as the separator between current desktop and total desktop count (e.g. 1 \(displayStr) 3)."
            customRow?.toolTip = tip
            customRow?.checkboxControl.toolTip = tip
        } else {
            customRow?.setTitle("Custom...")
            customEditButton?.isHidden = true
            let tip = "Type a custom separator symbol, text, or emoji."
            customRow?.toolTip = tip
            customRow?.checkboxControl.toolTip = tip
        }
    }
}

final class DesktopIndicatorSeparatorMenu: NSMenu {
    var onChange: ((DesktopIndicatorTextStyle.Separator) -> Void)?
    private let optionsView = DesktopIndicatorSeparatorOptionsView(frame: .zero)

    init() {
        super.init(title: "Indicator Separator")
        autoenablesItems = false
        let item = NSMenuItem()
        item.view = optionsView
        addItem(item)
        optionsView.onChange = { [weak self] selected in
            self?.onChange?(selected)
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ selected: DesktopIndicatorTextStyle.Separator) {
        optionsView.update(selected)
    }
}

final class DesktopIndicatorStyleOptionsView: NSView {
    var onChange: ((Int, Bool) -> Void)?
    private var controls: [Int: DockSettingPersistenceRowView] = [:]
    private var col0Width: CGFloat = 0
    private var col1Width: CGFloat = 0
    private var colX: [CGFloat] = []
    private let rowHeight: CGFloat = 26.0
    private var currentUsesPill: Bool? = nil

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]

        let items: [(index: Int, title: String)] = [
            (0, "Filled"),
            (1, "Outline"),
            (2, "Hierarchical"),
            (3, "Accent Color"),
            (5, "Pill"),
            (7, "Encapsulate Both Indicators"),
            (9, "Stack Display Indicators"),
            (8, "Accented Active Display Count"),
            (10, "Fill Active Display Count"),
            (11, "Active Display First"),
            (12, "Pill around Active Display")
        ]

        let helpHeadings: [Int: String] = [
            0: "Filled",
            1: "Outline",
            2: "Hierarchical",
            3: "Accent Color",
            5: "Pill",
            7: "Encapsulate Both Indicators",
            8: "Accented Active Display Count",
            9: "Stack Display Indicators",
            10: "Fill Active Display Count",
            11: "Active Display First",
            12: "Pill around Active Display"
        ]

        let helpTexts: [Int: String] = [
            0: "Fills the desktop indicator background with solid color, creating a high-contrast badge for the desktop count.\n\n• In monochrome mode, uses solid black or white based on menu bar appearance.\n• With Accent Color enabled, uses DockAway blue.\n• Ideal for maximum legibility in busy menu bars.",
            1: "Draws a refined 1 pt border outline around the desktop indicator count.\n\n• Provides a crisp, lightweight container around the numbers.\n• Matches dark or light mode menu bar styling dynamically.\n• Can be paired with Accent Color for tinted borders.",
            2: "Applies native macOS hierarchical opacity rendering to the desktop indicators.\n\n• Subtly dims inactive indicators while keeping active ones clear and prominent.\n• Reduces visual clutter in multi-display setups.\n• Blends seamlessly with macOS Sonoma and Sequoia menu bars.",
            3: "Tints Filled and Outline styles with DockAway blue.\n\n• Replaces default monochrome black and white with a consistent blue tint.\n• Applies across both status icons and indicator backgrounds.\n• Keeps the indicator appearance consistent across Macs.",
            5: "Encloses the desktop indicator in a customizable pill.\n\n• Use Pill Corner Radius to move smoothly from square to fully rounded.\n• Customize background translucency with Pill Opacity.\n• Adjust internal margins with Pill Padding.",
            7: "Groups both the Dock status arrow and the desktop count together inside a single unified pill container.\n\n• Creates a seamless combined status badge in your menu bar.\n• Dock visibility state and desktop space remain visible together at a glance.\n• Automatically scales to fit both icons with balanced inner spacing.",
            8: "Highlights only the desktop count of the display containing your pointer with DockAway blue.\n\n• Inactive display counts remain subtle and monochrome.\n• Instantly shows which display currently has mouse and keyboard focus.\n• Updates smoothly in real time as your cursor moves between screens.",
            9: "Arranges multi-display indicators vertically in stacked pairs to conserve menu bar space.\n\n• Displays the main display on top and secondary display below.\n• Saves significant horizontal space across multi-monitor setups.\n• When turned off, indicators are placed side-by-side in a single row.",
            10: "Fills the indicator background with solid color only on the display currently containing your pointer.\n\n• Other display indicators remain outlined or plain.\n• Gives immediate visual feedback for which monitor is active.\n• Works in tandem with Outline and Accent Color preferences.",
            11: "Reorders the menu bar indicators so the display containing your pointer is always positioned first on the left.\n\n• Active display is always in the primary leading position.\n• Remaining displays follow in numerical order.\n• Especially convenient when working primarily on external monitors.",
            12: "Draws the enclosing pill capsule only around the indicator for the active display containing your pointer.\n\n• Other display indicators remain unencapsulated.\n• Creates a distinctive focal spotlight on your current screen.\n• Automatically moves to the target display as your pointer crosses screens."
        ]

        col0Width = 212
        col1Width = 212
        colX = [18.0, 18.0 + col0Width + 14]
        self.frame.size.width = max(colX[1] + col1Width + 10, 280)

        for item in items {
            let width: CGFloat = col0Width
            let row = DockSettingPersistenceRowView(
                title: item.title,
                isOn: false,
                width: width,
                leadingInset: 0,
                trailingInset: 2,
                font: .systemFont(ofSize: 11),
                indicatorSize: 16,
                multiline: false,
                centeredTitle: false,
                checkboxOnFirstLine: true,
                helpHeading: helpHeadings[item.index] ?? item.title,
                helpTextProvider: { helpTexts[item.index] ?? "" }
            ) { [weak self] enabled in
                self?.onChange?(item.index, enabled)
            }
            let button = row.checkboxControl
            button.tag = item.index

            controls[item.index] = row
            addSubview(row)
        }

        applyLayout(usesPill: false)
    }

    override var intrinsicContentSize: NSSize { frame.size }

    required init?(coder: NSCoder) { nil }
    override func mouseDown(with event: NSEvent) {} // Keep the native menu open.

    private func applyLayout(usesPill: Bool) {
        currentUsesPill = usesPill
        let totalRows: Int
        let layoutItems: [(index: Int, col: Int, row: Int)]

        if usesPill {
            totalRows = 6
            layoutItems = [
                (0, 0, 0), (1, 1, 0),
                (2, 0, 1), (3, 1, 1),
                (5, 0, 2), (7, 1, 2),
                (9, 0, 3), (8, 1, 3),
                (10, 0, 4), (11, 1, 4),
                (12, 0, 5)
            ]
            if let row7 = controls[7] {
                if row7.superview == nil {
                    if let next = controls[9] {
                        addSubview(row7, positioned: .below, relativeTo: next)
                    } else {
                        addSubview(row7)
                    }
                }
                row7.isHidden = false
                row7.setControlEnabled(true, updateMenuItem: false)
            }
            if let row12 = controls[12] {
                if row12.superview == nil {
                    addSubview(row12)
                }
                row12.isHidden = false
                row12.setControlEnabled(true, updateMenuItem: false)
            }
        } else {
            totalRows = 5
            layoutItems = [
                (0, 0, 0), (1, 1, 0),
                (2, 0, 1), (3, 1, 1),
                (5, 0, 2), (9, 1, 2),
                (8, 0, 3), (10, 1, 3),
                (11, 0, 4)
            ]
            controls[7]?.isHidden = true
            controls[7]?.removeFromSuperview()
            controls[12]?.isHidden = true
            controls[12]?.removeFromSuperview()
        }

        let rowY: [CGFloat] = (0..<totalRows).map { row in
            2 + CGFloat(totalRows - 1 - row) * rowHeight
        }

        for item in layoutItems {
            guard let control = controls[item.index] else { continue }
            let x = colX[item.col]
            let y = rowY[item.row]
            let width: CGFloat = item.col == 0 ? col0Width : max(col1Width, bounds.width - colX[1] - 10)
            control.frame = NSRect(x: x, y: y, width: width, height: rowHeight)
            control.layoutSubtreeIfNeeded()
        }

        self.frame.size.height = CGFloat(totalRows) * rowHeight + 4
        invalidateIntrinsicContentSize()
        enclosingMenuItem?.menu?.update()
    }

    override func layout() {
        super.layout()
        if let currentUsesPill {
            applyLayout(usesPill: currentUsesPill)
        }
    }

    func update(_ style: DesktopIndicatorTextStyle) {
        if currentUsesPill != style.usesPill {
            applyLayout(usesPill: style.usesPill)
        }
        controls[0]?.setOn(style.hasFill)
        controls[1]?.setOn(style.hasOutline)
        controls[2]?.setOn(style.hierarchical)
        let accentedActive = style.accentOnlyWhenActive ?? false
        controls[3]?.setOn(style.usesAccentColor && !accentedActive)
        controls[5]?.setOn(style.usesPill)
        controls[7]?.setOn(style.encapsulatesDockIndicator)
        controls[8]?.setOn(accentedActive && style.badge != .none)
        controls[8]?.setControlEnabled(style.badge != .none, updateMenuItem: false)
        let stacked = UserDefaults.standard.object(forKey: "stackDisplayIndicators") as? Bool ?? true
        controls[9]?.setOn(stacked)
        controls[11]?.setOn(UserDefaults.standard.bool(forKey: "activeDisplayIndicatorFirst"))
        controls[12]?.setOn(style.pillOnlyWhenActive == true)
        controls[12]?.setControlEnabled(style.usesPill, updateMenuItem: false)
        controls[10]?.setOn(style.badge != .none && style.fillOnlyWhenActive == true)
        controls[10]?.setControlEnabled(style.badge != .none, updateMenuItem: false)
    }
}

final class DesktopNumberIndicatorMenu: NSMenu {
    var onChange: (() -> Void)?
    private var styleRows: [DesktopNumberIndicatorStyle: DockSettingPersistenceRowView] = [:]

    init() {
        super.init(title: "Desktop Manager Number Style")
        autoenablesItems = false

        let rowWidth: CGFloat = 240
        for style in DesktopNumberIndicatorStyle.allCases {
            let item = NSMenuItem()
            let helpHeading = style.title
            let helpText: String
            switch style {
            case .accentPill:
                helpText = "Renders the desktop number inside a blue pill badge for high visibility.\n\n• Applies DockAway blue directly behind the desktop number.\n• Creates a prominent, rounded capsule around each individual digit.\n• Excellent readability across both bright and dark wallpapers."
            case .subtleShadow:
                helpText = "Renders the desktop number as bold typography with a subtle drop shadow.\n\n• Matches native macOS menu bar status item aesthetics.\n• Crisp drop shadow ensures high legibility against varied desktop backgrounds.\n• Sleek and non-intrusive."
            }
            let row = DockSettingPersistenceRowView(
                title: style.title,
                isOn: DesktopNumberStylePreference.currentStyle == style,
                width: rowWidth,
                leadingInset: 18,
                titleLeadingAdjustment: 1,
                font: .menuFont(ofSize: 13),
                indicatorSize: 16,
                multiline: false,
                helpHeading: helpHeading,
                helpTextProvider: { helpText }
            ) { [weak self] _ in
                self?.selectStyle(style)
            }
            item.view = row
            styleRows[style] = row
            addItem(item)
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func selectStyle(_ style: DesktopNumberIndicatorStyle) {
        DesktopNumberStylePreference.currentStyle = style
        syncSelection()
        onChange?()
    }

    override func update() {
        super.update()
        syncSelection()
    }

    func syncSelection() {
        let current = DesktopNumberStylePreference.currentStyle
        for (style, row) in styleRows {
            row.setOn(style == current)
        }
    }
}
