import Cocoa
import CoreText

/// One native status item containing independently rendered display counters.
enum DisplayIndicatorGroup {
    struct Entry {
        let name: String
        let builtIn: Bool
        let current: Int
        let total: Int
        let fullscreen: Bool
        var appearance: DesktopIndicatorTextStyle? = nil
        var monitorNumber: Int? = nil
    }

    static func glyph(builtIn: Bool, number: Int, ink: NSColor? = nil, alpha: CGFloat = 1.0) -> NSImage {
        let activeAppearance = NSAppearance.currentDrawing()
        let isDark = activeAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let baseInk = ink ?? (isDark ? .white : .black)
        let effectiveInk = alpha < 1.0 ? baseInk.withAlphaComponent(baseInk.alphaComponent * alpha) : baseInk
        let image = NSImage(size: NSSize(width: 24, height: 18), flipped: false) { rect in
            let symbol = NSImage(systemSymbolName: builtIn ? "laptopcomputer" : "display",
                                 accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
            symbol?.draw(in: rect.insetBy(dx: 1, dy: 1), from: .zero, operation: .sourceOver, fraction: alpha)
            effectiveInk.setFill()
            rect.fill(using: .sourceIn)
            if !builtIn && number > 0 {
                let text = String(number) as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: number < 10 ? 10 : 8, weight: .heavy),
                    .foregroundColor: effectiveInk
                ]
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: (rect.width - size.width) / 2,
                                     y: (rect.height - size.height) / 2 + 2), withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    static func text(entries: [Entry], style: DesktopIndicatorTextStyle,
                     maximumHeight: CGFloat = 22, stacked: Bool = true,
                     accentedIndex: Int? = nil) -> NSAttributedString {
        guard !entries.isEmpty else { return NSAttributedString() }
        if entries.count > 1 && stacked {
            return stackedText(entries: entries, style: style, maximumHeight: maximumHeight, accentedIndex: accentedIndex)
        }
        var rows: [NSAttributedString] = []
        var externalNumber = 0
        let numbered = entries.filter { !$0.builtIn }.count >= 2
        for (index, entry) in entries.enumerated() {
            let isActive = accentedIndex == nil || index == accentedIndex
            let style = displayStyle(entry.appearance ?? style, index: index, accentedIndex: accentedIndex)
            let displayAlpha: CGFloat = (style.hierarchical && !isActive) ? 0.55 : 1.0
            let result = NSMutableAttributedString()
            if !entry.builtIn { externalNumber += 1 }
            let icon = glyph(builtIn: entry.builtIn,
                             number: numbered ? (entry.monitorNumber ?? externalNumber) : 0,
                             alpha: displayAlpha)
            if !(style.usesPill && style.encapsulatesDockIndicator) {
                let attachment = NSTextAttachment()
                attachment.image = icon
                attachment.bounds = NSRect(x: 0, y: -4, width: 24, height: 18)
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 8)]))
            }
            result.append(style.text(current: entry.current, total: entry.total,
                                     isFullscreen: entry.fullscreen, dockIndicator: icon,
                                     compactPillLayout: true, isActive: isActive))
            rows.append(result)
        }
        let result = NSMutableAttributedString()
        for (index, row) in rows.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 9)])) }
            result.append(row)
        }
        return result
    }

    static func displayStyle(_ base: DesktopIndicatorTextStyle, index: Int, accentedIndex: Int?) -> DesktopIndicatorTextStyle {
        guard let accentedIndex else { return base }
        var style = base
        if base.accentOnlyWhenActive == true {
            style.usesAccentColor = index == accentedIndex
        }
        style.accentsPlainNumber = false
        return style
    }

    static func rowIndices(count: Int) -> [[Int]] {
        guard count > 0 else { return [] }
        if count.isMultiple(of: 2) { return (0..<count).map { [$0] } }
        var rows: [[Int]] = [[0]]
        for start in stride(from: 1, to: count, by: 2) {
            rows.append(Array(start..<min(start + 2, count)))
        }
        return rows
    }

    static func orderedIndices(count: Int, activeIndex: Int?, activeFirst: Bool) -> [Int] {
        var indices = Array(0..<count)
        if activeFirst, let activeIndex, indices.contains(activeIndex) {
            indices.removeAll { $0 == activeIndex }
            indices.insert(activeIndex, at: 0)
        }
        return indices
    }

    // Lay out actual text at the final size. Never shrink an already padded
    // badge/pill image, which wastes most of each row on miniature padding.
    private static func stackedText(entries: [Entry], style: DesktopIndicatorTextStyle,
                                    maximumHeight: CGFloat, accentedIndex: Int?) -> NSAttributedString {
        let height = maximumHeight
        let layout = rowIndices(count: entries.count)
        let rowHeight = height / CGFloat(layout.count)
        let currentStrings = entries.map { $0.fullscreen ? "FS" : "\($0.current)" }
        let suffixStrings = entries.map { entry in
            let style = entry.appearance ?? style
            return entry.fullscreen ? "" : style.separator.suffix(total: entry.total)
        }
        // Fit visible glyph bounds, not the font's em square or line spacing.
        // Keep one point clear of row edges, plus the badge's stroke if present.
        let fonts = entries.enumerated().map { index, entry in
            let choice = entry.appearance ?? style
            return largestFont(strings: [currentStrings[index]], weight: .bold,
                               inkHeight: rowHeight - (choice.badge == .none ? 1 : 3))
        }
        let suffixFonts = entries.enumerated().map { index, entry in
            largestFont(strings: [suffixStrings[index]], weight: (entry.appearance ?? style).hierarchical ? .medium : .semibold,
                        inkHeight: rowHeight - 1)
        }
        let glyphWidth: CGFloat = 20
        let rows = entries.enumerated().map { index, entry -> (String, String, CGFloat, CGFloat) in
            let font = fonts[index]
            let suffixFont = suffixFonts[index]
            let style = entry.appearance ?? style
            let current = entry.fullscreen ? "FS" : "\(entry.current)"
            let suffix = entry.fullscreen ? "" : style.separator.suffix(total: entry.total)
            let currentWidth = ceil((current as NSString).size(withAttributes: [.font: font]).width) + (style.badge == .none ? 0 : 4)
            let suffixWidth = ceil((suffix as NSString).size(withAttributes: [.font: suffixFont]).width)
            return (current, suffix, currentWidth, suffixWidth)
        }
        let cellWidths = rows.map { ceil(glyphWidth + 6 + $0.2 + $0.3) }
        let gap: CGFloat = 3
        let rowWidths = layout.map { indices in indices.reduce(CGFloat(0)) { $0 + cellWidths[$1] } + CGFloat(indices.count - 1) * gap }
        let width = rowWidths.max() ?? 50
        let sharedPill = style.usesPill && style.encapsulatesDockIndicator && (style.pillOnlyWhenActive != true)
        let pillPadding: CGFloat = sharedPill ? max(1, CGFloat((style.pillPaddingHorizontal ?? 8.0) * 0.5)) : 0
        let totalWidth = width + pillPadding * 2
        let numbered = entries.filter { !$0.builtIn }.count >= 2
        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { rect in
            if sharedPill {
                let opacity = style.pillOpacity.isFinite ? min(1, max(0, style.pillOpacity)) : 0.08
                NSColor.labelColor.withAlphaComponent(opacity).setFill()
                let vPad = CGFloat((style.pillPaddingVertical ?? 3.0) * 0.3)
                let pillRect = NSRect(x: 0.5, y: max(0, 1 - vPad), width: totalWidth - 1, height: min(height, height - 2 + vPad * 2))
                let radius = style.usesRoundPill ? pillRect.height / 2 : pillRect.height * 0.15
                NSBezierPath(roundedRect: pillRect, xRadius: radius, yRadius: radius).fill()
            }
            var externalNumber = 0
            for (index, entry) in entries.enumerated() {
                let font = fonts[index]
                let suffixFont = suffixFonts[index]
                let isActive = accentedIndex == nil || index == accentedIndex
                let style = displayStyle(entry.appearance ?? style, index: index, accentedIndex: accentedIndex)
                let isInactiveDisplay = style.hierarchical && !isActive
                let displayAlpha: CGFloat = isInactiveDisplay ? 0.55 : 1.0
                let opacity = style.pillOpacity.isFinite ? min(1, max(0, style.pillOpacity)) : 0.08
                let ink: NSColor = (style.usesPill || sharedPill) && opacity >= 0.5 ? .textBackgroundColor : .labelColor
                if !entry.builtIn { externalNumber += 1 }
                let row = rows[index]
                let rowIndex = layout.firstIndex { $0.contains(index) }!
                let indices = layout[rowIndex]
                let column = indices.firstIndex(of: index)!
                let left = pillPadding + (width - rowWidths[rowIndex]) / 2
                    + indices.prefix(column).reduce(CGFloat(0)) { $0 + cellWidths[$1] + gap }
                let bottom = rect.height - CGFloat(rowIndex + 1) * rowHeight
                let rowRect = NSRect(x: left, y: bottom + 0.5, width: cellWidths[index], height: rowHeight - 1)
                if style.usesPill && !sharedPill {
                    NSColor.labelColor.withAlphaComponent(opacity * displayAlpha).setFill()
                    let radius = style.usesRoundPill ? rowRect.height / 2 : rowRect.height * 0.15
                    NSBezierPath(roundedRect: rowRect, xRadius: radius, yRadius: radius).fill()
                }
                glyph(builtIn: entry.builtIn, number: numbered ? (entry.monitorNumber ?? externalNumber) : 0, ink: ink).draw(
                    in: NSRect(x: left + 1, y: bottom, width: glyphWidth, height: rowHeight),
                    from: .zero, operation: .sourceOver, fraction: displayAlpha)
                let x = left + glyphWidth + 4
                let badgeRect = NSRect(x: x, y: bottom + 0.5, width: row.2, height: rowHeight - 1)
                let baseBadgeColor: NSColor = style.usesAccentColor ? .systemBlue : ink
                let badgeColor = baseBadgeColor.withAlphaComponent(baseBadgeColor.alphaComponent * displayAlpha)
                if style.badge != .none {
                    badgeColor.set()
                    let path = NSBezierPath(roundedRect: badgeRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
                    if style.hasFill { path.fill() }
                    if style.hasOutline {
                        if style.hasFill {
                            let baseBorder: NSColor = style.usesAccentColor ? ink
                                : ((style.usesPill || sharedPill) && opacity >= 0.5 ? .labelColor : .textBackgroundColor)
                            baseBorder.withAlphaComponent(baseBorder.alphaComponent * displayAlpha).setStroke()
                        }
                        path.lineWidth = 1
                        path.stroke()
                    }
                }
                let rawCurrentInk: NSColor = style.hasFill
                    ? (style.usesAccentColor ? .white : ((style.usesPill || sharedPill) && opacity >= 0.5 ? .labelColor : .textBackgroundColor))
                    : ink
                let currentInk = rawCurrentInk.withAlphaComponent(rawCurrentInk.alphaComponent * displayAlpha)
                drawLine(row.0, font: font, color: currentInk,
                         x: x + (style.badge == .none ? 0 : 2), bottom: bottom, height: rowHeight)
                let suffixAlpha = (style.hierarchical ? 0.55 : 1.0) * displayAlpha
                let suffixInk = ink.withAlphaComponent(ink.alphaComponent * suffixAlpha)
                drawLine(row.1, font: suffixFont, color: suffixInk,
                         x: x + row.2, bottom: bottom, height: rowHeight)
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = entries.map { "\($0.name): \($0.current) of \($0.total)" }.joined(separator: ", ")
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: (14 - height) / 2 - 3, width: totalWidth, height: height)
        return NSAttributedString(attachment: attachment)
    }

    static func largestFont(strings: [String], weight: NSFont.Weight, inkHeight: CGFloat) -> NSFont {
        let available = max(1, inkHeight)
        var low: CGFloat = 1
        var high = available * 4
        for _ in 0..<18 {
            let size = (low + high) / 2
            let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            let fits = strings.filter { !$0.isEmpty }.allSatisfy {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: [.font: font]))
                return CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).height <= available
            }
            if fits { low = size } else { high = size }
        }
        return .monospacedDigitSystemFont(ofSize: floor(low * 4) / 4, weight: weight)
    }

    private static func drawLine(_ text: String, font: NSFont, color: NSColor,
                                 x: CGFloat, bottom: CGFloat, height: CGFloat, outline: NSColor? = nil) {
        guard !text.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let outline { attributes[.strokeColor] = outline; attributes[.strokeWidth] = -3.0 }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: bottom + (height - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
