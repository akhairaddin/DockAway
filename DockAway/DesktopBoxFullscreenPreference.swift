import Cocoa

enum DesktopBoxFullscreenStyle: String, CaseIterable {
    case trafficLight = "trafficLight"
    case pillBadge = "pillBadge"
    case parenthetical = "parenthetical"
    case none = "none"

    var title: String {
        switch self {
        case .trafficLight: return "Traffic Light Icon (1 🟢)"
        case .pillBadge: return "Green Pill Badge (1 [FS])"
        case .parenthetical: return "Text Tag (1 (FS))"
        case .none: return "None (Standard Number)"
        }
    }
}

enum DesktopBoxFullscreenPreference {
    static let styleKey = "fullscreenBoxStyle"
    static let greenOutlineKey = "fullscreenBoxGreenOutline"

    static var currentStyle: DesktopBoxFullscreenStyle {
        get {
            guard let raw = UserDefaults.standard.string(forKey: styleKey),
                  let style = DesktopBoxFullscreenStyle(rawValue: raw) else {
                return .trafficLight
            }
            return style
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: styleKey)
        }
    }

    static var greenOutlineEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: greenOutlineKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: greenOutlineKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: greenOutlineKey)
        }
    }

    private static var cachedTrafficLightIcon: NSImage?

    static func trafficLightIcon(size: CGFloat = 9) -> NSImage {
        if let cachedTrafficLightIcon, cachedTrafficLightIcon.size.width == size {
            return cachedTrafficLightIcon
        }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let circlePath = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            let greenColor = NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1.0)
            greenColor.setFill()
            circlePath.fill()

            let strokeColor = NSColor(srgbRed: 0.11, green: 0.62, blue: 0.18, alpha: 1.0)
            strokeColor.setStroke()
            circlePath.lineWidth = 0.5
            circlePath.stroke()

            let darkGreen = NSColor(srgbRed: 0.04, green: 0.35, blue: 0.08, alpha: 0.85)
            darkGreen.setFill()

            let scale = size / 12.0
            let p1 = NSBezierPath()
            p1.move(to: NSPoint(x: 3.2 * scale, y: size - 3.2 * scale))
            p1.line(to: NSPoint(x: 6.2 * scale, y: size - 3.2 * scale))
            p1.line(to: NSPoint(x: 3.2 * scale, y: size - 6.2 * scale))
            p1.close()
            p1.fill()

            let p2 = NSBezierPath()
            p2.move(to: NSPoint(x: size - 3.2 * scale, y: 3.2 * scale))
            p2.line(to: NSPoint(x: size - 6.2 * scale, y: 3.2 * scale))
            p2.line(to: NSPoint(x: size - 3.2 * scale, y: 6.2 * scale))
            p2.close()
            p2.fill()
            return true
        }
        cachedTrafficLightIcon = image
        return image
    }

    static func pillBadgeIcon(height: CGFloat = 11) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .bold)
        let text = "FS" as NSString
        let textSize = text.size(withAttributes: [.font: font])
        let width = ceil(textSize.width + 5)
        let size = NSSize(width: width, height: height)

        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5)
            NSColor.systemGreen.withAlphaComponent(0.22).setFill()
            path.fill()

            let pStyle = NSMutableParagraphStyle()
            pStyle.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(srgbRed: 0.157, green: 0.85, blue: 0.3, alpha: 1.0),
                .paragraphStyle: pStyle
            ]
            text.draw(in: NSRect(x: 0, y: (height - textSize.height) / 2 - 0.5, width: width, height: textSize.height), withAttributes: attrs)
            return true
        }
        return image
    }

    static func formattedLabel(
        desktopNumber: Int,
        isFullscreen: Bool,
        style: DesktopBoxFullscreenStyle = currentStyle,
        textColor: NSColor
    ) -> NSAttributedString {
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        let pStyle = NSMutableParagraphStyle()
        pStyle.alignment = .center

        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: textColor,
            .paragraphStyle: pStyle
        ]

        guard isFullscreen else {
            return NSAttributedString(string: "\(desktopNumber)", attributes: baseAttrs)
        }

        switch style {
        case .none:
            return NSAttributedString(string: "\(desktopNumber)", attributes: baseAttrs)

        case .parenthetical:
            let text = "\(desktopNumber) (FS)"
            let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
            var attrs = baseAttrs
            attrs[.font] = font
            return NSAttributedString(string: text, attributes: attrs)

        case .trafficLight:
            let result = NSMutableAttributedString(string: "\(desktopNumber) ", attributes: baseAttrs)
            let icon = trafficLightIcon(size: 9)
            let attachment = NSTextAttachment()
            attachment.image = icon
            attachment.bounds = CGRect(x: 0, y: -0.5, width: icon.size.width, height: icon.size.height)
            result.append(NSAttributedString(attachment: attachment))
            return result

        case .pillBadge:
            let result = NSMutableAttributedString(string: "\(desktopNumber) ", attributes: baseAttrs)
            let badge = pillBadgeIcon(height: 11)
            let attachment = NSTextAttachment()
            attachment.image = badge
            attachment.bounds = CGRect(x: 0, y: -1, width: badge.size.width, height: badge.size.height)
            result.append(NSAttributedString(attachment: attachment))
            return result
        }
    }

    private static let knownBrandPrefixRegex = try? NSRegularExpression(
        pattern: "^(?:google|microsoft|adobe|mozilla|autodesk|affinity|wondershare|oracle|vmware|jetbrains)\\s+",
        options: [.caseInsensitive]
    )

    private static let trailingYearRegex = try? NSRegularExpression(
        pattern: "\\s+(?:20\\d\\d(?:\\.\\d+)?|CC)$",
        options: [.caseInsensitive]
    )

    /// Sanitizes application names for display in Desktop Manager titles.
    /// Strips leading corporate suite brands (e.g. "Google Chrome" -> "Chrome", "Microsoft Word" -> "Word",
    /// "Adobe Photoshop 2024" -> "Photoshop"), matches bundle identifier company prefixes,
    /// removes release years, and simplifies common product names.
    static func displayFullscreenName(_ name: String, bundleIdentifier: String? = nil) -> String {
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return name }

        // 1. Check known suite brands
        if let regex = knownBrandPrefixRegex {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            let stripped = regex.stringByReplacingMatches(
                in: trimmed,
                options: [],
                range: range,
                withTemplate: ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty {
                trimmed = stripped
            }
        }

        // 2. Check bundle identifier company segment (e.g. "com.company.AppName")
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            let parts = bundleIdentifier.split(separator: ".")
            if parts.count >= 2 {
                let company = String(parts[1])
                if company.count > 2,
                   let companyRegex = try? NSRegularExpression(
                    pattern: "^\(NSRegularExpression.escapedPattern(for: company))\\s+",
                    options: [.caseInsensitive]
                   ) {
                    let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
                    let stripped = companyRegex.stringByReplacingMatches(
                        in: trimmed,
                        options: [],
                        range: range,
                        withTemplate: ""
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !stripped.isEmpty {
                        trimmed = stripped
                    }
                }
            }
        }

        // 3. Strip trailing release years/versions (e.g. "Photoshop 2024" -> "Photoshop", "Illustrator CC" -> "Illustrator")
        if let yearRegex = trailingYearRegex {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            let stripped = yearRegex.stringByReplacingMatches(
                in: trimmed,
                options: [],
                range: range,
                withTemplate: ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty {
                trimmed = stripped
            }
        }

        // 4. Common product aliases for compact display
        if trimmed.caseInsensitiveCompare("Visual Studio Code") == .orderedSame {
            return "VS Code"
        }

        return trimmed.isEmpty ? name : trimmed
    }

    static func formattedFullscreenName(
        _ name: String,
        style: DesktopBoxFullscreenStyle = currentStyle,
        textColor: NSColor,
        availableWidth: CGFloat = 44.0
    ) -> NSAttributedString {
        let displayName = displayFullscreenName(name)
        let labelText: String
        switch style {
        case .parenthetical:
            labelText = "\(displayName) (FS)"
        case .none, .trafficLight, .pillBadge:
            labelText = displayName
        }

        // Dynamic font sizing (from 8.0 down to 7.0) so long single words (e.g. Photoshop, Illustrator)
        // fit neatly on one line without awkward character-splitting.
        var fontSize: CGFloat = 8.0
        let words = labelText.split(separator: " ").map(String.init)
        for word in words {
            while fontSize > 6.5 {
                let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
                let w = (word as NSString).size(withAttributes: [.font: font]).width
                if w <= availableWidth { break }
                fontSize -= 0.5
            }
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = -1.5

        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]
        return NSAttributedString(string: labelText, attributes: attributes)
    }
}

enum DesktopNumberIndicatorStyle: String, CaseIterable {
    case accentPill = "accentPill"
    case subtleShadow = "subtleShadow"

    var title: String {
        switch self {
        case .accentPill: return "Accent Pill Badge"
        case .subtleShadow: return "Bold Text with Shadow"
        }
    }

    var labelYOffset: CGFloat {
        // Switching indicator styles must not move the numbers below the tiles.
        4.5
    }
}

enum DesktopNumberStylePreference {
    static let styleKey = "desktopNumberIndicatorStyle"

    static var labelYOffset: CGFloat {
        currentStyle.labelYOffset
    }

    static var currentStyle: DesktopNumberIndicatorStyle {
        get {
            guard let raw = UserDefaults.standard.string(forKey: styleKey),
                  let style = DesktopNumberIndicatorStyle(rawValue: raw) else {
                return .subtleShadow
            }
            return style
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: styleKey)
        }
    }
}
