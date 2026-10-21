import AppKit
import IOKit.ps
import QuartzCore

struct DesktopChangeDestination: Equatable {
    let displayID: CGDirectDisplayID
    let spaceID: UInt64
    let title: String
    let displayName: String
    let isFullscreen: Bool
}

enum DesktopSwipePreview {
    static func adjacentSpace(in order: [UInt64], from current: UInt64, forward: Bool) -> UInt64? {
        guard let index = order.firstIndex(of: current) else { return nil }
        let next = index + (forward ? 1 : -1)
        return order.indices.contains(next) ? order[next] : nil
    }
}

// Track Space identities, not desktop numbers: renumbering after deletion or
// reordering must not announce a switch when the current Space stayed the same.
struct DesktopChangeTracker {
    private var previous: [CGDirectDisplayID: UInt64] = [:]

    mutating func update(_ destinations: [DesktopChangeDestination]) -> [DesktopChangeDestination] {
        let changed = destinations.filter {
            guard let old = previous[$0.displayID] else { return false }
            return old != $0.spaceID
        }
        previous = Dictionary(uniqueKeysWithValues: destinations.map { ($0.displayID, $0.spaceID) })
        return changed
    }
}

// Require a short uninterrupted ready interval, rather than presenting on
// whichever notification happens to arrive first during a Space transition.
struct DesktopTooltipReadiness {
    private var readySince: TimeInterval?

    mutating func update(isReady: Bool, now: TimeInterval, settlingDuration: TimeInterval = 0.1) -> Bool {
        guard isReady else {
            readySince = nil
            return false
        }
        if readySince == nil { readySince = now }
        return now - (readySince ?? now) >= settlingDuration
    }
}

struct DesktopTooltipPlacement {
    static func centeredMenuBarAnchor(
        screenFrame: NSRect,
        visibleFrame: NSRect
    ) -> NSRect {
        let anchorY = min(screenFrame.maxY - 1, visibleFrame.maxY)
        return NSRect(x: screenFrame.midX - 1, y: anchorY, width: 2, height: 1)
    }
}

// Compatibility surface for systems that predate native Liquid Glass.
@MainActor
private final class DesktopPillMaterialView: NSVisualEffectView {
    private var maskedSize: NSSize = .zero

    override func layout() {
        super.layout()
        guard bounds.size != maskedSize, bounds.width > 0, bounds.height > 0 else { return }
        maskedSize = bounds.size
        maskImage = NSImage(size: bounds.size, flipped: false) { rect in
            NSColor.black.setFill()
            let radius = DesktopChangeTooltip.cornerRadius(forHeight: rect.height)
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
    }
}

@MainActor
private final class DesktopTooltipAnchorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// An app with a window on the desktop the pill shows.
struct DesktopChangeAppIcon {
    let image: NSImage
    let processIdentifier: pid_t
    let name: String
    /// The app in front on that desktop, which leads the row.
    var isCurrent = false
}

/// The thin line between the app in front and the rest of the pill's icons.
private final class DesktopChangeAppIconSeparator: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: DesktopChangeTooltip.currentAppSeparatorWidth, height: 14)
    }
    override var allowsVibrancy: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.width / 2, yRadius: bounds.width / 2).fill()
    }
}

/// One of the pill's app icons, which brings that app forward when clicked.
private final class DesktopChangeAppIconButton: NSButton {
    let processIdentifier: pid_t
    /// How much a hovered icon grows, about its center.
    private static let hoverScale: CGFloat = 1.18
    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            applyScale(animated: true)
        }
    }

    init(icon: DesktopChangeAppIcon) {
        processIdentifier = icon.processIdentifier
        super.init(frame: .zero)
        image = icon.image
        imageScaling = .scaleProportionallyUpOrDown
        isBordered = false
        title = ""
        wantsLayer = true
        setButtonType(.momentaryChange)
        setAccessibilityLabel(icon.name)
        toolTip = icon.name
    }

    required init?(coder: NSCoder) { nil }

    // The pill never becomes active, so the first click counts.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        applyScale(animated: false)
    }

    private func applyScale(animated: Bool) {
        guard let layer, bounds.width > 0 else { return }
        let scale = isHovered ? Self.hoverScale : 1
        // A layer scales about its anchor point; this keeps the icon centered.
        let offsetX = bounds.midX - layer.anchorPoint.x * bounds.width
        let offsetY = bounds.midY - layer.anchorPoint.y * bounds.height
        let target = CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeTranslation(-offsetX, -offsetY, 0),
                                CATransform3DMakeScale(scale, scale, 1)),
            CATransform3DMakeTranslation(offsetX, offsetY, 0))
        let current = layer.presentation()?.transform ?? layer.transform
        layer.transform = target
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: current)
        grow.toValue = NSValue(caTransform3D: target)
        grow.duration = 0.14
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(grow, forKey: "hoverScale")
    }
}

@MainActor
final class DesktopChangeTooltip: NSObject {
    // Native glass draws its rim and optical effects beyond its layout bounds.
    private static let glassOverflowInset: CGFloat = 10
    private static let hostHasInternalBattery: Bool = {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return sources.contains { source in
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { return false }
            return description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }()

    private func symbolName(for destination: DesktopChangeDestination) -> String {
        if destination.isFullscreen { return "arrow.up.left.and.arrow.down.right" }
        return CGDisplayIsBuiltin(destination.displayID) != 0 && Self.hostHasInternalBattery
            ? "laptopcomputer" : "display"
    }
    static let preferenceKey = "showDesktopChangeTooltip"
    static let durationPreferenceKey = "desktopChangeTooltipDuration"
    static let appIconsPreferenceKey = "desktopChangeTooltipShowsAppIcons"
    /// The most icons in one row.
    static let maximumAppIcons = 6
    static let appIconSpacing: CGFloat = 4
    /// The line after the app in front, and the space on each side of it.
    static let currentAppSeparatorWidth: CGFloat = 1
    static let currentAppSeparatorGap: CGFloat = 5
    /// How much wider the separator makes its row than an ordinary gap would.
    static var currentAppSeparatorExtraWidth: CGFloat {
        currentAppSeparatorWidth + 2 * currentAppSeparatorGap - appIconSpacing
    }
    /// The least space kept between a row of icons and the pill's edge.
    private static let iconRowMinimumMargin: CGFloat = 12
    /// The room the separator takes from its row's icons. It reaches into the
    /// pill's padding instead, so a row holds as many apps as without it.
    static var currentAppSeparatorRowCost: CGFloat {
        max(0, currentAppSeparatorExtraWidth
            - (pillLeadingPadding + pillTrailingPadding - 2 * iconRowMinimumMargin))
    }
    /// Gap between the text and the app icons beneath it.
    static let appIconRowSpacing: CGFloat = 6
    /// The pill's height without app icons.
    private static let basePillHeight: CGFloat = 44

    /// A capsule at the usual heights; a taller pill with app icons becomes a
    /// rounded rectangle instead of an oval.
    nonisolated static func cornerRadius(forHeight height: CGFloat) -> CGFloat {
        min(height / 2, 22)
    }
    static let defaultDuration: TimeInterval = 4.0
    static let minDuration: TimeInterval = 1.0
    static let maxDuration: TimeInterval = 10.0

    static var duration: TimeInterval {
        get {
            let saved = UserDefaults.standard.double(forKey: durationPreferenceKey)
            if saved >= minDuration && saved <= maxDuration {
                return saved
            }
            return defaultDuration
        }
        set {
            let clamped = min(maxDuration, max(minDuration, newValue))
            UserDefaults.standard.set(clamped, forKey: durationPreferenceKey)
        }
    }

    static var showsAppIcons: Bool {
        get { showsAppIcons(in: .standard) }
        set { UserDefaults.standard.set(newValue, forKey: appIconsPreferenceKey) }
    }

    static func showsAppIcons(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: appIconsPreferenceKey)
    }

    /// How many icons fit in a row of the given width, leaving room for a
    /// "+N" label when they don't all fit. The pill never grows for its icons.
    static func visibleAppIconCount(total: Int, rowWidth: CGFloat, iconSize: CGFloat,
                                    overflowLabelWidth: CGFloat) -> Int {
        func width(showing shown: Int) -> CGFloat {
            let overflow = shown < total ? appIconSpacing + overflowLabelWidth : 0
            guard shown > 0 else { return overflow }
            return CGFloat(shown) * iconSize + CGFloat(shown - 1) * appIconSpacing + overflow
        }
        var shown = min(total, maximumAppIcons)
        while shown > 0, width(showing: shown) > rowWidth { shown -= 1 }
        return shown
    }

    /// How many icons go in each row. Icons that fit in one row stay in one;
    /// beyond that they split evenly over two rows, the top one taking any
    /// extra (7 is 4 and 3). When even two full rows can't hold them all, the
    /// second row ends with "+N". `firstRowExtraWidth` is room the top row
    /// needs besides its icons, such as for the separator after the app in front.
    static func appIconRowCounts(total: Int, rowWidth: CGFloat, iconSize: CGFloat,
                                 overflowLabelWidth: CGFloat, firstRowExtraWidth: CGFloat = 0) -> [Int] {
        func fitting(_ width: CGFloat) -> Int {
            max(0, min(maximumAppIcons, Int((width + appIconSpacing) / (iconSize + appIconSpacing))))
        }
        let perRow = fitting(rowWidth)
        let perFirstRow = fitting(rowWidth - firstRowExtraWidth)
        guard total > 0, perFirstRow > 0 else { return [] }
        guard total > perFirstRow else { return [total] }
        guard total > perFirstRow + perRow else {
            let top = min(perFirstRow, (total + 1) / 2)
            return [top, total - top]
        }
        return [perFirstRow, visibleAppIconCount(total: total - perFirstRow, rowWidth: rowWidth,
                                                 iconSize: iconSize, overflowLabelWidth: overflowLabelWidth)]
    }

    /// The app in front leads, marked as current, then the rest by name. With
    /// no app in front among them, they're all by name.
    static func leadingWithCurrentApp(_ icons: [DesktopChangeAppIcon], current: pid_t?) -> [DesktopChangeAppIcon] {
        var lead: DesktopChangeAppIcon?
        var rest: [DesktopChangeAppIcon] = []
        for var icon in icons {
            icon.isCurrent = icon.processIdentifier == current && lead == nil
            if icon.isCurrent { lead = icon } else { rest.append(icon) }
        }
        rest.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (lead.map { [$0] } ?? []) + rest
    }


    /// Looks up a desktop's app icons, calling back on the main thread.
    var appIconProvider: ((UInt64, @escaping @MainActor ([DesktopChangeAppIcon]) -> Void) -> Void)?
    /// Brings forward the app whose icon was clicked.
    var onAppIconClick: ((pid_t) -> Void)?
    /// Follows the pointer while the pill shows, so the pill takes clicks
    /// only while the pointer is over it.
    private var pointerMonitors: [Any] = []
    /// Moves the app you switch to to the front of the row while the pill shows.
    private var activationObserver: NSObjectProtocol?
    /// Whether the pill steps aside, even while showing, such as in Mission
    /// Control, which shows the desktops itself.
    var mustStepAside: @MainActor () -> Bool = { false }

    private var tracker = DesktopChangeTracker()
    private var presentation: DispatchWorkItem?
    private var dismissal: DispatchWorkItem?
    private var activePanel: DesktopTooltipAnchorPanel?
    private var gestureContactsActive = false
    private var presentationActive = false
    private var readingDuration: TimeInterval { Self.duration }
    /// Whether this pill has the app icon row. Set when the pill is created,
    /// so the row never comes and goes with the icons.
    private var showsIconRow = false
    /// Rows of app icons the pill has room for, none for an empty desktop. A
    /// pill fits its rows before it fades in, and while showing it grows and
    /// shrinks smoothly as they change.
    private var iconRowCount = 1
    private weak var iconAreaHeightConstraint: NSLayoutConstraint?
    private var resizeAnimation: EasedAnimation?
    /// A new pill waiting for its icons before it fades in.
    private weak var pendingRevealPanel: NSPanel?
    private var iconAreaHeight: CGFloat {
        guard iconRowCount > 0 else { return 0 }
        return CGFloat(iconRowCount) * appIconSize + CGFloat(iconRowCount - 1) * Self.appIconSpacing
    }
    /// An empty desktop gets the regular pill, without room for icons.
    private var currentPillHeight: CGFloat {
        guard showsIconRow, iconRowCount > 0 else { return Self.basePillHeight }
        return Self.basePillHeight + iconAreaHeight + Self.appIconRowSpacing + 1
    }
    private var contentWidth: CGFloat = 220
    private var generation = 0
    private var latestDestinations: [DesktopChangeDestination] = []
    private var displayedDestination: DesktopChangeDestination?
    private weak var titleLabel: NSTextField?
    private weak var subtitleLabel: NSTextField?
    private weak var destinationIcon: NSImageView?
    /// Holds the column of icon rows, plus the outgoing column during a fade.
    private weak var appIconArea: NSView?
    /// The current column of icon rows.
    private weak var appIconStrip: NSStackView?
    private weak var pillSurface: NSView?
    private var displayedAppIcons: [DesktopChangeAppIcon] = []
    private let appIconSize: CGFloat = 18
    private var canRemainVisible: (@MainActor () -> Bool)?
    private var dismissalDeadline: TimeInterval = 0
    /// A window being built ahead of the first desktop change.
    private var preparing = false
    /// App icons of the desktops beside the current one, looked up as a swipe
    /// starts, so the pill has them the moment the swipe arrives.
    private var prefetchedAppIcons: [UInt64: (icons: [DesktopChangeAppIcon], time: TimeInterval)] = [:]
    /// Lookups still under way, with whatever is waiting for each.
    private var prefetchWaiters: [UInt64: [@MainActor ([DesktopChangeAppIcon]) -> Void]] = [:]
    private static let prefetchedIconsLifetime: TimeInterval = 4
    /// The pill eases in, settling this far down into place.
    private static let revealDrop: CGFloat = 5
    private static let revealDuration: TimeInterval = 0.25
    func resetPanel() {
        dismiss(animated: false)
        activePanel = nil
        titleLabel = nil
        subtitleLabel = nil
        destinationIcon = nil
        appIconArea = nil
        appIconStrip = nil
        pillSurface = nil
        displayedAppIcons = []
        iconRowCount = 1
    }

    private var isPresented: Bool {
        presentationActive
    }

    func desktopGestureContactsChanged(_ fingers: Int) {
        gestureContactsActive = fingers >= 3
        if gestureContactsActive {
            dismissalDeadline = ProcessInfo.processInfo.systemUptime + readingDuration
        }
    }

    func update(_ destinations: [DesktopChangeDestination], preferredDisplayID: CGDirectDisplayID,
                canPresent: @escaping @MainActor () -> Bool) {
        latestDestinations = destinations
        canRemainVisible = canPresent
        let changed = tracker.update(destinations)
        guard UserDefaults.standard.bool(forKey: Self.preferenceKey) else {
            dismiss()
            return
        }
        guard let destination = changed.first(where: { $0.displayID == preferredDisplayID }) ?? changed.first else {
            if let displayedDestination,
               let current = destinations.first(where: { $0.displayID == displayedDestination.displayID }),
               current != displayedDestination, isPresented {
                updateContent(current)
            }
            return
        }
        if isPresented && mustStepAside() {
            dismiss(animated: true)
            return
        }
        generation += 1
        presentation?.cancel()
        presentation = nil
        if isPresented {
            updateContent(destination)
            scheduleDismissal()
            return
        }
        guard canPresent() else {
            schedule(destination, generation: generation,
                     readiness: DesktopTooltipReadiness(), attemptsRemaining: 100, canPresent: canPresent)
            return
        }
        show(destination)
    }

    /// Looks up the app icons of the desktops a swipe could go to, so the
    /// pill shows them the moment the swipe arrives.
    func prefetchAppIcons(for spaceIDs: [UInt64]) {
        guard Self.showsAppIcons, let appIconProvider,
              UserDefaults.standard.bool(forKey: Self.preferenceKey) else { return }
        for spaceID in spaceIDs where prefetchWaiters[spaceID] == nil {
            prefetchWaiters[spaceID] = []
            appIconProvider(spaceID) { [weak self] icons in
                guard let self else { return }
                self.prefetchedAppIcons[spaceID] = (icons, ProcessInfo.processInfo.systemUptime)
                let waiters = self.prefetchWaiters.removeValue(forKey: spaceID) ?? []
                waiters.forEach { $0(icons) }
            }
        }
    }

    private func schedule(_ destination: DesktopChangeDestination, generation: Int,
                          readiness: DesktopTooltipReadiness,
                          attemptsRemaining: Int, canPresent: @escaping @MainActor () -> Bool) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation,
                  let current = self.latestDestinations.first(where: {
                      $0.displayID == destination.displayID && $0.spaceID == destination.spaceID
                  }),
                  UserDefaults.standard.bool(forKey: Self.preferenceKey) else { return }
            var readiness = readiness
            guard readiness.update(isReady: canPresent(),
                                   now: ProcessInfo.processInfo.systemUptime,
                                   settlingDuration: 0.05) else {
                if attemptsRemaining > 0 {
                    self.schedule(destination, generation: generation, readiness: readiness,
                                  attemptsRemaining: attemptsRemaining - 1, canPresent: canPresent)
                }
                return
            }
            self.presentation = nil
            self.show(current)
        }
        presentation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)
    }

    func dismiss(animated: Bool = false) {
        stopFollowingPointer()
        generation += 1
        let closingGeneration = generation
        presentation?.cancel()
        presentation = nil
        dismissal?.cancel()
        dismissal = nil
        presentationActive = false
        pendingRevealPanel = nil
        resizeAnimation?.invalidate()
        resizeAnimation = nil
        guard let panel = activePanel else { return }
        // Keep the window and native glass alive for the next presentation.
        // A late fade completion must never hide a newly refreshed capsule.
        if animated && panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self, weak panel] in
                Task { @MainActor in
                    guard let self, self.generation == closingGeneration,
                          !self.presentationActive else { return }
                    panel?.orderOut(nil)
                }
            }
        } else {
            panel.orderOut(nil)
        }
    }

    private func formatLabels(for destination: DesktopChangeDestination) -> (title: String, subtitle: String) {
        if destination.isFullscreen {
            let isGenericFullscreen = destination.title.caseInsensitiveCompare("fullscreen") == .orderedSame
            let title = isGenericFullscreen ? "Fullscreen" : destination.title
            return (title, destination.displayName)
        } else {
            return (destination.title, destination.displayName)
        }
    }

    private static let overflowFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    // Everything is centered, so both sides get the same padding.
    private static let pillLeadingPadding: CGFloat = 16
    private static let pillTrailingPadding: CGFloat = 16

    private func calculateContentWidth(titleText: String, subtitleText: String) -> CGFloat {
        let iconWidth: CGFloat = 16
        // Labels draw their text with about 2 pt of padding on each side.
        let labelPadding: CGFloat = 4
        let titleWidth = ceil((titleText as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)]).width) + labelPadding
        let subtitleWidth = ceil((subtitleText as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .regular)]).width) + labelPadding
        let leadingPadding = Self.pillLeadingPadding
        let spacingAfterIcon: CGFloat = 3
        let trailingPadding = Self.pillTrailingPadding
        // The glyph and title share the first line, centered over the display
        // name. The app icons fit within this width, so they never resize the pill.
        let labelWidth = max(iconWidth + spacingAfterIcon + titleWidth, subtitleWidth)
        let calculated = leadingPadding + labelWidth + trailingPadding
        return max(160, min(380, calculated))
    }

    private func panelFrame(for width: CGFloat, destination: DesktopChangeDestination) -> NSRect {
        let pillHeight = currentPillHeight
        let gapBelowMenuBar: CGFloat = 6
        let screen = NSScreen.screen(withDisplayID: destination.displayID)
            ?? NSScreen.main ?? NSScreen.screens.first

        guard let screen else {
            return NSRect(x: 0, y: 0, width: width, height: pillHeight)
                .insetBy(dx: -Self.glassOverflowInset, dy: -Self.glassOverflowInset)
        }

        let anchor = DesktopTooltipPlacement.centeredMenuBarAnchor(
            screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        var panelX = anchor.midX - width / 2
        let panelY = anchor.minY - pillHeight - gapBelowMenuBar
        let minX = screen.visibleFrame.minX + 8
        let maxX = screen.visibleFrame.maxX - width - 8
        if minX <= maxX {
            panelX = min(max(panelX, minX), maxX)
        }
        return NSRect(x: panelX, y: panelY, width: width, height: pillHeight)
            .insetBy(dx: -Self.glassOverflowInset, dy: -Self.glassOverflowInset)
    }

    private func updateContent(_ destination: DesktopChangeDestination, requestsIcons: Bool = true) {
        let shouldAnimate = presentationActive && activePanel?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let labels = formatLabels(for: destination)
        // Fade only text that changes. The fade drops a label's glass vibrancy
        // while it runs, so an unchanged display name would flash the backdrop's
        // color on every switch.
        for (label, text) in [(titleLabel, labels.title), (subtitleLabel, labels.subtitle)] {
            guard let label, label.stringValue != text else { continue }
            if shouldAnimate {
                label.wantsLayer = true
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.16
                label.layer?.add(fade, forKey: "desktopNumberChange")
            }
            label.stringValue = text
        }
        let desktopChanged = displayedDestination?.spaceID != destination.spaceID
        displayedDestination = destination
        if desktopChanged && requestsIcons { requestAppIcons(for: destination, crossFade: shouldAnimate) }
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        destinationIcon?.image = NSImage(systemSymbolName: symbolName(for: destination), accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        destinationIcon?.contentTintColor = destination.isFullscreen ? .systemGreen : .systemBlue

        resizePanel(toContentWidth: calculateContentWidth(titleText: labels.title, subtitleText: labels.subtitle),
                    destination: destination)
    }

    private func scheduleDismissal() {
        dismissal?.cancel()
        dismissalDeadline = ProcessInfo.processInfo.systemUptime + readingDuration
        checkDismissal(generation: generation)
    }

    private func checkDismissal(generation: Int) {
        let close = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation, self.isPresented else { return }
            if self.mustStepAside() {
                self.dismiss(animated: true)
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            let ready = self.canRemainVisible?() != false
            // It also stays while the pointer rests on it, to pick an app.
            if !ready || self.gestureContactsActive || self.pointerIsOverPill {
                self.dismissalDeadline = now + self.readingDuration
            }
            if now >= self.dismissalDeadline {
                self.dismiss(animated: true)
            } else {
                self.checkDismissal(generation: generation)
            }
        }
        dismissal = close
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: close)
    }

    private func show(_ destination: DesktopChangeDestination) {
        if let panel = activePanel {
            let wasVisible = panel.isVisible && panel.alphaValue > 0
            if !wasVisible {
                appIconArea?.subviews.forEach { $0.removeFromSuperview() }
                appIconStrip = nil
                displayedAppIcons = []
                setIconRowCount(1)
            }
            updateContent(destination, requestsIcons: wasVisible)
            presentationActive = true
            scheduleDismissal()
            if wasVisible { reveal(panel) } else { revealWithIcons(panel, destination: destination) }
            return
        }

        buildPanel(for: destination)
        guard let panel = activePanel else { return }
        presentationActive = true
        scheduleDismissal()
        revealWithIcons(panel, destination: destination)
    }

    /// Builds the pill's window ahead of the first desktop change, so that
    /// one appears as quickly as every later one. The window is drawn once,
    /// invisibly, then stays hidden until it's needed.
    func prepare(for destination: DesktopChangeDestination) {
        guard activePanel == nil, !preparing, UserDefaults.standard.bool(forKey: Self.preferenceKey) else { return }
        preparing = true
        // Out of the way of everything else DockAway does as it starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.preparing = false
            guard self.activePanel == nil, UserDefaults.standard.bool(forKey: Self.preferenceKey) else { return }
            self.buildPanel(for: destination)
            guard let panel = self.activePanel else { return }
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.contentView?.displayIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak panel] in
                guard let self, !self.presentationActive else { return }
                panel?.orderOut(nil)
            }
        }
    }

    /// Builds the pill's window, hidden, showing the given desktop.
    private func buildPanel(for destination: DesktopChangeDestination) {
        displayedAppIcons = []
        showsIconRow = Self.showsAppIcons
        iconRowCount = 1
        let pillHeight = currentPillHeight
        let leadingPadding = Self.pillLeadingPadding
        let trailingPadding = Self.pillTrailingPadding
        let spacingAfterIcon: CGFloat = 3
        let iconSize: CGFloat = 16

        let labels = formatLabels(for: destination)
        contentWidth = calculateContentWidth(titleText: labels.title, subtitleText: labels.subtitle)
        let frame = panelFrame(for: contentWidth, destination: destination)

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: symbolName(for: destination),
            accessibilityDescription: nil
        )
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        icon.contentTintColor = destination.isFullscreen ? .systemGreen : .systemBlue
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: labels.title)
        title.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center
        title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.required, for: .horizontal)

        let subtitle = NSTextField(labelWithString: labels.subtitle)
        subtitle.font = .systemFont(ofSize: 11, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 1
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        titleLabel = title
        subtitleLabel = subtitle
        destinationIcon = icon
        displayedDestination = destination

        // The display glyph sits just left of the title, and the two are
        // centered over the display name. The app icons get their own row
        // beneath, centered in the pill.
        let titleRow = NSStackView(views: [icon, title])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = spacingAfterIcon

        let labelRow = NSStackView(views: [titleRow, subtitle])
        labelRow.orientation = .vertical
        labelRow.alignment = .centerX
        labelRow.spacing = 1

        // The destination desktop's app icons, beneath the text and filled in
        // once they're looked up.
        let iconRow = NSView()
        iconRow.translatesAutoresizingMaskIntoConstraints = false
        iconRow.isHidden = !showsIconRow
        appIconArea = iconRow
        appIconStrip = nil

        let containerRow = NSStackView(views: [labelRow, iconRow])
        containerRow.orientation = .vertical
        containerRow.alignment = .centerX
        containerRow.spacing = Self.appIconRowSpacing
        containerRow.translatesAutoresizingMaskIntoConstraints = false
        // Full width, so the icons sit in the middle of the pill, and as tall
        // as the rows it has room for.
        let iconAreaHeight = iconRow.heightAnchor.constraint(equalToConstant: self.iconAreaHeight)
        iconAreaHeightConstraint = iconAreaHeight
        NSLayoutConstraint.activate([
            iconRow.widthAnchor.constraint(equalTo: containerRow.widthAnchor),
            iconAreaHeight
        ])

        let content = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: pillHeight))
        content.autoresizingMask = [.width, .height]
        // While the pill grows or shrinks, a second icon row is cut off at its
        // edge instead of drawing below it.
        content.clipsToBounds = true
        content.addSubview(containerRow)
        let surface: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: content.bounds)
            glass.style = .clear
            glass.cornerRadius = Self.cornerRadius(forHeight: pillHeight)
            glass.contentView = content
            surface = glass
        } else {
            let material = DesktopPillMaterialView(frame: content.bounds)
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.addSubview(content)
            surface = material
        }
        surface.autoresizingMask = [.width, .height]
        pillSurface = surface
        // Inherit the system appearance so a retained pill follows Light and
        // Dark changes.
        surface.appearance = nil

        // The text keeps its place at the top while a second icon row grows
        // the pill downward.
        let topInset = (Self.basePillHeight - labelRow.fittingSize.height) / 2
        NSLayoutConstraint.activate([
            containerRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: leadingPadding),
            containerRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -trailingPadding),
            containerRow.topAnchor.constraint(equalTo: content.topAnchor, constant: topInset),
            icon.widthAnchor.constraint(equalToConstant: iconSize),
            icon.heightAnchor.constraint(equalToConstant: iconSize)
        ])

        let panel = DesktopTooltipAnchorPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        surface.frame = container.bounds.insetBy(
            dx: Self.glassOverflowInset, dy: Self.glassOverflowInset)
        container.addSubview(surface)
        panel.contentView = container
        container.layoutSubtreeIfNeeded()
        activePanel = panel
    }

    /// Fades the pill in with its icons already in place, waiting only briefly
    /// for them so a slow lookup never delays the pill.
    private func revealWithIcons(_ panel: NSPanel, destination: DesktopChangeDestination) {
        guard showsIconRow, appIconProvider != nil else {
            reveal(panel)
            return
        }
        pendingRevealPanel = panel
        requestAppIcons(for: destination, crossFade: false) { [weak self] in
            self?.finishPendingReveal(panel)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.finishPendingReveal(panel)
        }
    }

    private func finishPendingReveal(_ panel: NSPanel) {
        guard pendingRevealPanel === panel, presentationActive else { return }
        pendingRevealPanel = nil
        reveal(panel)
    }

    /// Fills in the destination desktop's app icons once they're looked up,
    /// ignoring results for a desktop the pill no longer shows.
    private func requestAppIcons(for destination: DesktopChangeDestination, crossFade: Bool,
                                 completion: (() -> Void)? = nil) {
        guard showsIconRow, let appIconProvider else {
            completion?()
            return
        }
        let spaceID = destination.spaceID
        if let prefetched = prefetchedAppIcons[spaceID],
           ProcessInfo.processInfo.systemUptime - prefetched.time < Self.prefetchedIconsLifetime {
            if displayedDestination?.spaceID == spaceID, appIconArea != nil {
                setAppIcons(prefetched.icons, crossFade: crossFade)
            }
            completion?()
            return
        }
        let apply: @MainActor ([DesktopChangeAppIcon]) -> Void = { [weak self] icons in
            defer { completion?() }
            guard let self, self.displayedDestination?.spaceID == spaceID, self.appIconArea != nil else { return }
            self.setAppIcons(icons, crossFade: crossFade)
        }
        if prefetchWaiters[spaceID] != nil {
            prefetchWaiters[spaceID]?.append(apply)
        } else {
            appIconProvider(spaceID, apply)
        }
    }

    private func setAppIcons(_ icons: [DesktopChangeAppIcon], crossFade: Bool) {
        let unchanged = icons.map { ObjectIdentifier($0.image) } == displayedAppIcons.map { ObjectIdentifier($0.image) }
            && icons.map(\.processIdentifier) == displayedAppIcons.map(\.processIdentifier)
            && icons.map(\.isCurrent) == displayedAppIcons.map(\.isCurrent)
        displayedAppIcons = icons
        guard let area = appIconArea else { return }
        if unchanged, appIconStrip != nil { return }

        let (strip, rowCount) = makeAppIconStrip(for: icons)
        area.addSubview(strip)
        // Centered, with the first row right under the text, so it stays put
        // while the pill grows or shrinks for a second row.
        NSLayoutConstraint.activate([
            strip.centerXAnchor.constraint(equalTo: area.centerXAnchor),
            strip.topAnchor.constraint(equalTo: area.topAnchor)
        ])
        let outgoing = appIconStrip
        appIconStrip = strip
        // Drop any column still fading out from an earlier switch.
        area.subviews.filter { $0 !== strip && $0 !== outgoing }.forEach { $0.removeFromSuperview() }
        setIconRowCount(rowCount)

        guard let outgoing else { return }
        guard crossFade, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            outgoing.removeFromSuperview()
            return
        }
        // Each column keeps its own layout and fades in place. A snapshot fade
        // of one changing column would slide the old icons around, and fading
        // the icons and labels themselves keeps the text's glass vibrancy.
        // The new icons arrive a little ahead of the old ones leaving, so an
        // icon on both desktops barely dims.
        area.layoutSubtreeIfNeeded()
        let incoming = Self.fadingViews(in: strip)
        let leaving = Self.fadingViews(in: outgoing)
        incoming.forEach { $0.alphaValue = 0 }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            incoming.forEach { $0.animator().alphaValue = 1 }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            leaving.forEach { $0.animator().alphaValue = 0 }
        } completionHandler: {
            Task { @MainActor in outgoing.removeFromSuperview() }
        }
    }

    /// The icons and labels in a column, which fade individually.
    // MARK: - Clickable icons

    private var iconButtons: [DesktopChangeAppIconButton] {
        guard let strip = appIconStrip else { return [] }
        return Self.fadingViews(in: strip).compactMap { $0 as? DesktopChangeAppIconButton }
    }

    private var pointerIsOverPill: Bool {
        guard let panel = activePanel, panel.isVisible else { return false }
        return panel.frame.insetBy(dx: Self.glassOverflowInset, dy: Self.glassOverflowInset)
            .contains(NSEvent.mouseLocation)
    }

    private func startFollowingPointer() {
        guard pointerMonitors.isEmpty else { return }
        activePanel?.acceptsMouseMovedEvents = true
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.followPointer() }
        }) {
            pointerMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
            self?.followPointer()
            return event
        }) {
            pointerMonitors.append(local)
        }
        followPointer()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.frontmostApplicationChanged(app?.processIdentifier) }
        }
    }

    private func stopFollowingPointer() {
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors.removeAll()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        iconButtons.forEach { $0.isHovered = false }
        activePanel?.ignoresMouseEvents = true
    }

    /// With the pointer over the pill, the pill takes its clicks, so what's
    /// beneath can't be clicked through it; only its icons act on them.
    /// Anywhere else, clicks go through as if it weren't there.
    private func followPointer() {
        guard let panel = activePanel, presentationActive, panel.isVisible else { return }
        let pointer = NSEvent.mouseLocation
        let overPill = pointerIsOverPill
        let hovered = !overPill ? nil : iconButtons.first { button in
            guard let window = button.window, !button.isHiddenOrHasHiddenAncestor else { return false }
            return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(pointer)
        }
        for button in iconButtons { button.isHovered = button === hovered }
        if panel.ignoresMouseEvents == overPill { panel.ignoresMouseEvents = !overPill }
    }

    /// The app in front is usually known before the pill shows, from the
    /// desktop's window order. When another of its apps comes forward while
    /// the pill shows, such as the one macOS picks as you arrive, it moves to
    /// the front of the row.
    private func frontmostApplicationChanged(_ processIdentifier: pid_t?) {
        guard presentationActive, let processIdentifier,
              displayedAppIcons.contains(where: { $0.processIdentifier == processIdentifier }) else { return }
        setAppIcons(Self.leadingWithCurrentApp(displayedAppIcons, current: processIdentifier), crossFade: true)
    }

    @objc private func appIconClicked(_ sender: DesktopChangeAppIconButton) {
        let processIdentifier = sender.processIdentifier
        dismiss(animated: true)
        onAppIconClick?(processIdentifier)
    }

    private static func fadingViews(in strip: NSStackView) -> [NSView] {
        strip.arrangedSubviews.flatMap { ($0 as? NSStackView)?.arrangedSubviews ?? [$0] }
    }

    /// A column of icon rows for the given apps, empty when there are none.
    private func makeAppIconStrip(for icons: [DesktopChangeAppIcon]) -> (strip: NSStackView, rowCount: Int) {
        let strip = NSStackView()
        strip.orientation = .vertical
        strip.alignment = .centerX
        strip.spacing = Self.appIconSpacing
        strip.translatesAutoresizingMaskIntoConstraints = false
        guard !icons.isEmpty else { return (strip, 0) }
        let size = appIconSize
        let overflowWidth = ceil(("+\(icons.count)" as NSString).size(withAttributes: [.font: Self.overflowFont]).width)
        // The app in front leads, set apart from the rest by a thin line.
        let leadsWithCurrent = icons.count > 1 && icons[0].isCurrent
        let rowCounts = Self.appIconRowCounts(
            total: icons.count,
            rowWidth: contentWidth - Self.pillLeadingPadding - Self.pillTrailingPadding,
            iconSize: size,
            overflowLabelWidth: overflowWidth,
            firstRowExtraWidth: leadsWithCurrent ? Self.currentAppSeparatorRowCost : 0
        )
        let shown = rowCounts.reduce(0, +)
        var remaining = icons.prefix(shown)[...]
        for (index, count) in rowCounts.enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = Self.appIconSpacing
            // Hug the icons, so a shorter row is centered instead of stretched
            // to the column's width with its icons pushed to the left.
            row.setHuggingPriority(.required, for: .horizontal)
            for icon in remaining.prefix(count) {
                let view = DesktopChangeAppIconButton(icon: icon)
                view.target = self
                view.action = #selector(appIconClicked(_:))
                view.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    view.widthAnchor.constraint(equalToConstant: size),
                    view.heightAnchor.constraint(equalToConstant: size)
                ])
                row.addArrangedSubview(view)
                if leadsWithCurrent, icon.isCurrent {
                    let separator = DesktopChangeAppIconSeparator()
                    separator.setAccessibilityElement(false)
                    row.addArrangedSubview(separator)
                    row.setCustomSpacing(Self.currentAppSeparatorGap, after: view)
                    row.setCustomSpacing(Self.currentAppSeparatorGap, after: separator)
                }
            }
            remaining = remaining.dropFirst(count)
            if index == rowCounts.count - 1, shown < icons.count {
                let more = NSTextField(labelWithString: "+\(icons.count - shown)")
                more.font = Self.overflowFont
                more.textColor = .secondaryLabelColor
                more.setContentCompressionResistancePriority(.required, for: .horizontal)
                row.addArrangedSubview(more)
            }
            strip.addArrangedSubview(row)
        }
        return (strip, rowCounts.count)
    }

    private func setIconRowCount(_ count: Int) {
        guard showsIconRow, count != iconRowCount else { return }
        iconRowCount = count
        iconAreaHeightConstraint?.constant = iconAreaHeight
        if let displayedDestination {
            resizePanel(toContentWidth: contentWidth, destination: displayedDestination)
        }
    }

    private func resizePanel(toContentWidth newWidth: CGFloat, destination: DesktopChangeDestination) {
        contentWidth = newWidth
        guard let panel = activePanel else { return }
        if #available(macOS 26.0, *), let glass = pillSurface as? NSGlassEffectView {
            glass.cornerRadius = Self.cornerRadius(forHeight: currentPillHeight)
        }
        let newFrame = panelFrame(for: newWidth, destination: destination)
        resizeAnimation?.invalidate()
        resizeAnimation = nil
        guard newFrame != panel.frame else { return }
        let shouldAnimate = presentationActive && panel.isVisible
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard shouldAnimate, let view = panel.contentView else {
            panel.setFrame(newFrame, display: true)
            return
        }
        // Step the window once per display refresh, like the Desktop Manager
        // menu, keeping the top edge and center fixed. The content is pinned to
        // the top, so only the bottom edge moves as icon rows come and go.
        let start = panel.frame
        let scale = panel.backingScaleFactor
        func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        func mix(_ from: CGFloat, _ to: CGFloat, _ progress: CGFloat) -> CGFloat { from + (to - from) * progress }
        resizeAnimation = EasedAnimation(view: view, duration: 0.22, curve: easeInEaseOut) { [weak self, weak panel] progress, finished in
            guard let panel else { return }
            let width = pixel(mix(start.width, newFrame.width, progress))
            let height = pixel(mix(start.height, newFrame.height, progress))
            let top = pixel(mix(start.maxY, newFrame.maxY, progress))
            let x = pixel(mix(start.midX, newFrame.midX, progress) - width / 2)
            panel.setFrame(finished ? newFrame : NSRect(x: x, y: top - height, width: width, height: height),
                           display: true)
            if finished { self?.resizeAnimation = nil }
        }
    }

    /// Eases the pill in, settling a few points down into place under the
    /// menu bar. One still fading out comes straight back instead.
    private func reveal(_ panel: NSPanel) {
        startFollowingPointer()
        let fadingOut = panel.isVisible && panel.alphaValue > 0
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }
        if !fadingOut {
            panel.alphaValue = 0
            let target = panel.frame
            panel.setFrame(target.offsetBy(dx: 0, dy: Self.revealDrop), display: false)
            panel.orderFrontRegardless()
            if let view = panel.contentView {
                // A resize starting meanwhile takes over from wherever it is.
                resizeAnimation?.invalidate()
                let scale = panel.backingScaleFactor
                resizeAnimation = EasedAnimation(view: view, duration: Self.revealDuration,
                                                 curve: easeOutCubic) { [weak self, weak panel] progress, finished in
                    guard let panel else { return }
                    let y = ((target.minY + Self.revealDrop * (1 - progress)) * scale).rounded() / scale
                    panel.setFrame(finished ? target : NSRect(x: target.minX, y: y, width: target.width,
                                                              height: target.height), display: true)
                    if finished { self?.resizeAnimation = nil }
                }
            } else {
                panel.setFrame(target, display: true)
            }
        } else {
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.revealDuration
            context.timingFunction = easeOutCubicTiming
            panel.animator().alphaValue = 1
        }
    }
}
