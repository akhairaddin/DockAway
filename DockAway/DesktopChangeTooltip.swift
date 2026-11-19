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

    /// Dragging the icon away offers a close button under the pill, which
    /// the pill handles. Without these, the icon is a plain button.
    var onDragBegan: ((NSPoint) -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?
    /// The closed hand shows, or goes away again after a click.
    var onGrabChanged: ((Bool) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard let window, onDragBegan != nil else {
            super.mouseDown(with: event)
            return
        }
        let start = NSEvent.mouseLocation
        var dragging = false
        // Allowed now, so the hand can show the moment it's needed: allowed
        // only at that moment, the first change can be lost.
        BackgroundCursor.allow(true)
        // However the press ends, DockAway stops setting the pointer while
        // it's in the background.
        defer { BackgroundCursor.allow(false) }
        // Like a desktop in the Desktop Manager, the hand closes as soon as
        // the icon moves, or once it's held still for a moment.
        let grabTime = Date(timeIntervalSinceNow: 0.15)
        var grabbing = false
        func grab() {
            guard !grabbing else { return }
            grabbing = true
            onGrabChanged?(true)
        }
        while true {
            let wake = Date(timeIntervalSinceNow: 0.1)
            let next = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: grabbing ? wake : min(wake, grabTime),
                inMode: .eventTracking,
                dequeue: true
            )
            if !grabbing, Date() >= grabTime { grab() }
            // Whatever is under the pointer may put the arrow back.
            if grabbing { NSCursor.closedHand.set() }
            let point = NSEvent.mouseLocation
            // A release can go missing; never hold on once the button is up.
            if next?.type == .leftMouseUp || (next == nil && NSEvent.pressedMouseButtons & 1 == 0) {
                if dragging {
                    onDragEnded?(point)
                } else {
                    // Held but not dragged, it's still a click.
                    if grabbing { onGrabChanged?(false) }
                    BackgroundCursor.allow(false)
                    sendAction(action, to: target)
                }
                return
            }
            guard next?.type == .leftMouseDragged else { continue }
            if point != start { grab() }
            if !dragging, hypot(point.x - start.x, point.y - start.y) >= 4 {
                dragging = true
                onDragBegan?(start)
            }
            if dragging { onDragMoved?(point) }
        }
    }

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

/// Lets DockAway change the pointer while another app is in front, which
/// macOS otherwise ignores, through the window server's private
/// "SetsCursorInBackground" connection property. Looked up at run time; if
/// it's missing the pointer just stays an arrow.
@MainActor
enum BackgroundCursor {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    private static let functions: (MainConnection, SetProperty)? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connection = dlsym(defaultHandle, "CGSMainConnectionID"),
              let setProperty = dlsym(defaultHandle, "CGSSetConnectionProperty") else { return nil }
        return (unsafeBitCast(connection, to: MainConnection.self),
                unsafeBitCast(setProperty, to: SetProperty.self))
    }()

    static func allow(_ allowed: Bool) {
        guard let (mainConnection, setProperty) = functions else { return }
        let connection = mainConnection()
        _ = setProperty(connection, connection, "SetsCursorInBackground" as CFString,
                        (allowed ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    }
}

/// The round close button under the pill while an app icon is dragged.
/// Dropping the icon on it quits that app. On macOS 26 and later it's the
/// same clear Liquid Glass as the pill, tinted red while an icon is over it.
@MainActor
private final class DesktopChangeCloseTargetView: NSView {
    /// The glass, on macOS 26 and later.
    private var glass: NSView?
    /// The red fill used before macOS 26 instead of a glass tint.
    private let fill = NSView()
    private let symbol = NSImageView()
    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            updateHighlight(animated: true)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let diameter = frame.width
        symbol.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        symbol.symbolConfiguration = .init(pointSize: 12, weight: .bold)
        symbol.imageScaling = .scaleNone
        symbol.frame = bounds
        symbol.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .clear
            glass.cornerRadius = diameter / 2
            let content = NSView(frame: bounds)
            content.addSubview(symbol)
            glass.contentView = content
            glass.autoresizingMask = [.width, .height]
            addSubview(glass)
            self.glass = glass
        } else {
            let material = NSVisualEffectView(frame: bounds)
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.maskImage = NSImage(size: bounds.size, flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(ovalIn: rect).fill()
                return true
            }
            material.autoresizingMask = [.width, .height]
            addSubview(material)

            fill.frame = bounds
            fill.autoresizingMask = [.width, .height]
            fill.wantsLayer = true
            fill.layer?.cornerRadius = diameter / 2
            fill.layer?.backgroundColor = NSColor.systemRed.cgColor
            fill.alphaValue = 0
            addSubview(fill)
            addSubview(symbol)
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Quit App")
        updateHighlight(animated: false)
    }

    required init?(coder: NSCoder) { nil }

    private var maskedSize: NSSize = .zero

    /// The button grows and shrinks with its window, so its circle follows.
    override func layout() {
        super.layout()
        let radius = bounds.height / 2
        if #available(macOS 26.0, *), let glass = glass as? NSGlassEffectView, glass.cornerRadius != radius {
            glass.cornerRadius = radius
        }
        fill.layer?.cornerRadius = radius
        if let material = subviews.first as? NSVisualEffectView, bounds.size != maskedSize, bounds.width > 0 {
            maskedSize = bounds.size
            material.maskImage = NSImage(size: bounds.size, flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(ovalIn: rect).fill()
                return true
            }
        }
    }

    private func updateHighlight(animated: Bool) {
        symbol.contentTintColor = isHighlighted ? .white : .labelColor
        symbol.symbolConfiguration = .init(pointSize: isHighlighted ? 14 : 10, weight: .bold)
        if #available(macOS 26.0, *), let glass = glass as? NSGlassEffectView {
            glass.tintColor = isHighlighted ? NSColor.systemRed.withAlphaComponent(0.85) : nil
            return
        }
        let alpha: CGFloat = isHighlighted ? 0.9 : 0
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            fill.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            fill.animator().alphaValue = alpha
        }
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
    /// Puts the pill back on every desktop. macOS takes a hidden pill off all
    /// but one when a full-screen desktop closes, and it would then show only
    /// on that one.
    var restoreToEveryDesktop: @MainActor (NSWindow) -> Void = { _ in }

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
    private let appIconSize: CGFloat = 20
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
    private static let exitDuration: TimeInterval = 0.4
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
            // A showing pill has to be on the next desktop before the swipe slides it in.
            if presentationActive, let activePanel { restoreToEveryDesktop(activePanel) }
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
        cancelIconDrag()
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
            // The reverse of the reveal: a soft fade as the pill drifts back
            // up toward the menu bar. A desktop change meanwhile brings it
            // back from wherever it is.
            if let view = panel.contentView {
                let start = panel.frame
                let scale = panel.backingScaleFactor
                resizeAnimation = EasedAnimation(view: view, duration: Self.exitDuration,
                                                 curve: easeInOutCubic) { [weak panel] progress, _ in
                    guard let panel else { return }
                    let y = ((start.minY + Self.revealDrop * progress) * scale).rounded() / scale
                    panel.setFrame(NSRect(x: start.minX, y: y, width: start.width, height: start.height),
                                   display: true)
                }
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.exitDuration
                // Eases in and out like a sine, with no sudden start or stop.
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.37, 0, 0.63, 1)
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
        // With app icons, the narrowest pill still holds a full row of them.
        let fullIconRow = CGFloat(Self.maximumAppIcons) * appIconSize
            + CGFloat(Self.maximumAppIcons - 1) * Self.appIconSpacing
        let minimumWidth = showsIconRow
            ? max(160, leadingPadding + fullIconRow + trailingPadding)
            : 160
        return max(minimumWidth, min(380, calculated))
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
        // A pill already showing stays with you only if it's on every desktop.
        if presentationActive, let activePanel { restoreToEveryDesktop(activePanel) }
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
            if !ready || self.gestureContactsActive || self.pointerIsOverPill || self.isDraggingIcon {
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
            } else {
                // Caught fading out: it glides back down from where it drifted.
                presentationActive = true
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
        guard !isDraggingIcon, let panel = activePanel, presentationActive, panel.isVisible else { return }
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

    // MARK: - Dragging an app to quit it

    private var isDraggingIcon = false
    private weak var draggedIconButton: DesktopChangeAppIconButton?
    private var dragImagePanel: DesktopTooltipAnchorPanel?
    private var dragGrabOffset: NSPoint = .zero
    private var closeTargetPanel: DesktopTooltipAnchorPanel?
    private weak var closeTargetView: DesktopChangeCloseTargetView?
    /// The close button is small until an icon is dragged onto it.
    private static let closeTargetDiameter: CGFloat = 24
    private static let closeTargetHighlightedDiameter: CGFloat = 34
    /// Where the close button rests, centered under the pill.
    private var closeTargetCenter: NSPoint = .zero
    /// The close button leans a little toward the dragged icon: this share
    /// of the distance, never more than the maximum.
    private static let closeTargetFollow: CGFloat = 0.015
    private static let closeTargetMaxLean: CGFloat = 3
    /// How quickly it catches up with where it's heading, in seconds: its
    /// position, and its size, which is quicker.
    private static let closeTargetSmoothing: TimeInterval = 0.09
    private static let closeTargetSizeSmoothing: TimeInterval = 0.04
    /// How far up, under the pill, it slides out from and back into.
    private static let closeTargetSlide: CGFloat = 14
    private var closeTargetLink: CADisplayLink?
    private var closeTargetLastTick: CFTimeInterval = 0
    private var closeTargetLean: NSPoint = .zero
    private var closeTargetGoalLean: NSPoint = .zero
    private var closeTargetDiameterNow: CGFloat = 0
    private var closeTargetGoalDiameter: CGFloat = 0
    /// Out or on its way out, as opposed to fading away.
    private var closeTargetShowing = false
    private static let closeTargetGap: CGFloat = 10
    private static let dragImageSize: CGFloat = 28

    private var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func makeOverlayPanel(level: NSWindow.Level) -> DesktopTooltipAnchorPanel {
        let panel = DesktopTooltipAnchorPanel(
            contentRect: .zero,
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
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }

    private func screenFrame(of view: NSView) -> NSRect? {
        guard let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    private func dragImageFrame(at point: NSPoint) -> NSRect {
        let size = Self.dragImageSize
        return NSRect(x: point.x - dragGrabOffset.x - size / 2,
                      y: point.y - dragGrabOffset.y - size / 2,
                      width: size, height: size)
    }

    private func iconDragBegan(_ button: DesktopChangeAppIconButton, at start: NSPoint) {
        guard presentationActive, let iconFrame = screenFrame(of: button) else { return }
        isDraggingIcon = true
        iconSnapped = false
        iconSnapBlend = 0
        lastDragPoint = start
        draggedIconButton = button
        iconButtons.forEach { $0.isHovered = false }
        button.alphaValue = 0.3
        // Held at the same spot it was grabbed, scaled to the larger icon.
        let grow = Self.dragImageSize / max(iconFrame.width, 1)
        dragGrabOffset = NSPoint(x: (start.x - iconFrame.midX) * grow, y: (start.y - iconFrame.midY) * grow)

        let panel = dragImagePanel ?? makeOverlayPanel(level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1))
        dragImagePanel = panel
        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: Self.dragImageSize, height: Self.dragImageSize))
        imageView.image = button.image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        panel.contentView = imageView
        panel.setFrame(dragImageFrame(at: start), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        showCloseTarget()
        BackgroundCursor.allow(true)
        NSCursor.closedHand.set()
    }

    /// Near the close button, the dragged icon snaps onto it, in a quick
    /// ease, and stays until it's pulled a little further away than that.
    private static let closeTargetSnapDistance: CGFloat = 9
    private static let closeTargetUnsnapDistance: CGFloat = 14
    /// How quickly the icon eases onto and off the button, in seconds.
    private static let closeTargetSnapSmoothing: TimeInterval = 0.03
    private var iconSnapped = false
    /// How far the icon is drawn toward the button, from 0 under the pointer
    /// to 1 on it, eased toward whether it's snapped.
    private var iconSnapBlend: CGFloat = 0
    private var lastDragPoint: NSPoint = .zero

    /// Updates whether the dragged icon is snapped to the close button.
    private func updateIconSnap(at point: NSPoint) {
        let frame = dragImageFrame(at: point)
        guard let panel = closeTargetPanel, panel.isVisible, let view = closeTargetView else {
            iconSnapped = false
            return
        }
        let target = panel.convertToScreen(view.frame)
        let distance = hypot(target.midX - frame.midX, target.midY - frame.midY)
        iconSnapped = distance < (iconSnapped ? Self.closeTargetUnsnapDistance : Self.closeTargetSnapDistance)
    }

    /// Draws the dragged icon between the pointer and the close button, by
    /// how far it has eased onto the button.
    private func placeDraggedIcon() {
        guard let dragPanel = dragImagePanel else { return }
        var frame = dragImageFrame(at: lastDragPoint)
        if iconSnapBlend > 0, let panel = closeTargetPanel, panel.isVisible, let view = closeTargetView {
            let target = panel.convertToScreen(view.frame)
            frame.origin.x += (target.midX - frame.midX) * iconSnapBlend
            frame.origin.y += (target.midY - frame.midY) * iconSnapBlend
        }
        if dragPanel.frame != frame { dragPanel.setFrame(frame, display: true) }
    }

    private func iconDragMoved(to point: NSPoint) {
        guard isDraggingIcon, dragImagePanel != nil else { return }
        lastDragPoint = point
        updateIconSnap(at: point)
        if reducesMotion { iconSnapBlend = iconSnapped ? 1 : 0 }
        placeDraggedIcon()
        // Set on every move: whatever the pointer passes over may reset it.
        NSCursor.closedHand.set()
        // On the button exactly when it's snapped to it.
        let over = iconSnapped
        setCloseTargetGoal(pointer: point, highlighted: over)
        if let target = closeTargetView, target.isHighlighted != over {
            target.isHighlighted = over
            if over {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
    }

    private func iconDragEnded(_ button: DesktopChangeAppIconButton, at point: NSPoint) {
        guard isDraggingIcon else {
            // The drag never started, as when the pill was refreshing or
            // going away: put back the arrow and take away the close button
            // the held icon brought out.
            NSCursor.arrow.set()
            BackgroundCursor.allow(false)
            if closeTargetShowing { hideCloseTarget() }
            return
        }
        isDraggingIcon = false
        draggedIconButton = nil
        NSCursor.arrow.set()
        BackgroundCursor.allow(false)
        updateIconSnap(at: point)
        let dropped = iconSnapped
        iconSnapped = false
        iconSnapBlend = 0
        hideCloseTarget()
        dismissalDeadline = ProcessInfo.processInfo.systemUptime + readingDuration
        guard let panel = dragImagePanel else {
            button.alphaValue = 1
            return
        }
        if dropped, quitApp(button.processIdentifier) {
            // Gone from the pill right away; the app may still ask to save.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reducesMotion ? 0 : 0.15
                panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { panel.orderOut(nil) }
            }
            return
        }
        // Back into its place in the pill.
        guard let home = screenFrame(of: button), !reducesMotion else {
            panel.orderOut(nil)
            button.alphaValue = 1
            followPointer()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(home, display: true)
        } completionHandler: { [weak self, weak button] in
            MainActor.assumeIsolated {
                guard self?.isDraggingIcon != true else { return }
                panel.orderOut(nil)
                button?.alphaValue = 1
                self?.followPointer()
            }
        }
    }

    /// Ends a drag at once, as when the pill goes away mid-drag.
    private func cancelIconDrag() {
        guard isDraggingIcon || dragImagePanel?.isVisible == true || closeTargetPanel?.isVisible == true else { return }
        if isDraggingIcon {
            NSCursor.arrow.set()
            BackgroundCursor.allow(false)
        }
        isDraggingIcon = false
        draggedIconButton?.alphaValue = 1
        draggedIconButton = nil
        dragImagePanel?.orderOut(nil)
        closeTargetPanel?.orderOut(nil)
        closeTargetShowing = false
        stopCloseTargetLink()
    }

    private func showCloseTarget() {
        guard !closeTargetShowing, let pill = activePanel else { return }
        closeTargetShowing = true
        let pillFrame = pill.frame.insetBy(dx: Self.glassOverflowInset, dy: Self.glassOverflowInset)
        let diameter = Self.closeTargetDiameter
        // Centered under the pill, with room above it to grow.
        closeTargetCenter = NSPoint(
            x: pillFrame.midX.rounded(),
            y: (pillFrame.minY - Self.closeTargetGap - Self.closeTargetHighlightedDiameter / 2).rounded())
        // It slides down out from under the pill.
        closeTargetLean = reducesMotion ? .zero : NSPoint(x: 0, y: Self.closeTargetSlide)
        closeTargetGoalLean = .zero
        closeTargetDiameterNow = diameter
        closeTargetGoalDiameter = diameter
        // The window stays one size, with room for the button fully grown and
        // leaning. Only the button inside moves and resizes, which is smooth;
        // resizing the window each frame snaps to whole points and stutters.
        let canvas = Self.closeTargetCanvas
        let panelFrame = NSRect(x: closeTargetCenter.x - canvas / 2, y: closeTargetCenter.y - canvas / 2,
                                width: canvas, height: canvas)
        let panel: DesktopTooltipAnchorPanel
        if let existing = closeTargetPanel {
            panel = existing
        } else {
            panel = makeOverlayPanel(level: .statusBar)
            let container = NSView(frame: NSRect(x: 0, y: 0, width: canvas, height: canvas))
            let view = DesktopChangeCloseTargetView(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
            container.addSubview(view)
            panel.contentView = container
            closeTargetView = view
            closeTargetPanel = panel
        }
        closeTargetView?.isHighlighted = false
        panel.setFrame(panelFrame, display: false)
        closeTargetView?.frame = closeTargetFrame(diameter: diameter)
        panel.alphaValue = reducesMotion ? 1 : 0
        // Beneath the pill, so it comes out from behind it.
        panel.order(.below, relativeTo: pill.windowNumber)
        if !panel.isVisible { panel.orderFrontRegardless() }
        startCloseTargetLink()
        guard !reducesMotion else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// The close button's window: room for it fully grown, leaning either way.
    private static let closeTargetCanvas: CGFloat = closeTargetHighlightedDiameter + 2 * closeTargetMaxLean + 4

    /// The button's frame inside its window, which is centered on its rest spot.
    private func closeTargetFrame(diameter: CGFloat) -> NSRect {
        let middle = Self.closeTargetCanvas / 2
        return NSRect(x: middle + closeTargetLean.x - diameter / 2,
                      y: middle + closeTargetLean.y - diameter / 2,
                      width: diameter, height: diameter)
    }

    /// Where the close button heads: grown while an icon is over it, and
    /// leaning a little toward the pointer. Without motion, it stays put.
    private func setCloseTargetGoal(pointer: NSPoint, highlighted: Bool) {
        closeTargetGoalDiameter = highlighted ? Self.closeTargetHighlightedDiameter : Self.closeTargetDiameter
        guard !reducesMotion else {
            closeTargetGoalLean = .zero
            return
        }
        let dx = pointer.x - closeTargetCenter.x
        let dy = pointer.y - closeTargetCenter.y
        let distance = hypot(dx, dy)
        let lean = min(distance * Self.closeTargetFollow, Self.closeTargetMaxLean)
        closeTargetGoalLean = distance > 0
            ? NSPoint(x: dx / distance * lean, y: dy / distance * lean)
            : .zero
    }

    private func startCloseTargetLink() {
        guard closeTargetLink == nil, let view = closeTargetView else { return }
        closeTargetLastTick = CACurrentMediaTime()
        let link = view.displayLink(target: self, selector: #selector(closeTargetTick(_:)))
        link.add(to: .main, forMode: .common)
        closeTargetLink = link
    }

    private func stopCloseTargetLink() {
        closeTargetLink?.invalidate()
        closeTargetLink = nil
    }

    /// Eases the close button's size and lean toward their goals, each frame.
    @objc private func closeTargetTick(_ link: CADisplayLink) {
        guard let panel = closeTargetPanel, panel.isVisible else {
            stopCloseTargetLink()
            return
        }
        let now = CACurrentMediaTime()
        let dt = min(max(now - closeTargetLastTick, 1.0 / 240), 1.0 / 20)
        closeTargetLastTick = now
        let step = reducesMotion ? 1 : CGFloat(1 - exp(-dt / Self.closeTargetSmoothing))
        let sizeStep = reducesMotion ? 1 : CGFloat(1 - exp(-dt / Self.closeTargetSizeSmoothing))
        closeTargetDiameterNow += (closeTargetGoalDiameter - closeTargetDiameterNow) * sizeStep
        closeTargetLean.x += (closeTargetGoalLean.x - closeTargetLean.x) * step
        closeTargetLean.y += (closeTargetGoalLean.y - closeTargetLean.y) * step
        let frame = closeTargetFrame(diameter: closeTargetDiameterNow)
        if let view = closeTargetView, view.frame != frame { view.frame = frame }
        if isDraggingIcon {
            let snapStep = reducesMotion ? 1 : CGFloat(1 - exp(-dt / Self.closeTargetSnapSmoothing))
            let goal: CGFloat = iconSnapped ? 1 : 0
            iconSnapBlend += (goal - iconSnapBlend) * snapStep
            if abs(goal - iconSnapBlend) < 0.002 { iconSnapBlend = goal }
            placeDraggedIcon()
        }
    }

    private func hideCloseTarget() {
        closeTargetShowing = false
        guard let panel = closeTargetPanel, panel.isVisible else { return }
        // Back up under the pill as it fades.
        closeTargetGoalLean = NSPoint(x: 0, y: Self.closeTargetSlide)
        closeTargetGoalDiameter = Self.closeTargetDiameter
        guard !reducesMotion else {
            panel.orderOut(nil)
            stopCloseTargetLink()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard self?.closeTargetShowing != true else { return }
                panel.orderOut(nil)
                self?.stopCloseTargetLink()
            }
        }
    }

    /// Asks the app to quit, as Quit in its menu would, and drops it from
    /// the pill. Never DockAway itself.
    @discardableResult
    private func quitApp(_ processIdentifier: pid_t) -> Bool {
        guard processIdentifier != getpid(),
              let app = NSRunningApplication(processIdentifier: processIdentifier),
              !app.isTerminated,
              app.terminate() else { return false }
        removeAppIcon(processIdentifier)
        return true
    }

    /// Takes a quit app out of the pill. In a single row, its slot closes up
    /// and the icons beside it slide into its place. Otherwise, as when an
    /// icon would move up from a second row or out of the overflow count, the
    /// row is redrawn with a cross-fade.
    private func removeAppIcon(_ processIdentifier: pid_t) {
        let remaining = displayedAppIcons.filter { $0.processIdentifier != processIdentifier }
        guard let strip = appIconStrip,
              strip.arrangedSubviews.count == 1,
              let row = strip.arrangedSubviews.first as? NSStackView,
              !row.arrangedSubviews.contains(where: { $0 is NSTextField }),
              let button = row.arrangedSubviews.first(where: {
                  ($0 as? DesktopChangeAppIconButton)?.processIdentifier == processIdentifier
              }),
              !remaining.isEmpty else {
            setAppIcons(remaining, crossFade: true)
            return
        }
        // The app in front is set apart by a line; it goes too, unless
        // another app follows it in front.
        var collapsing: [NSView] = [button]
        let index = row.arrangedSubviews.firstIndex(of: button)!
        if index + 1 < row.arrangedSubviews.count,
           row.arrangedSubviews[index + 1] is DesktopChangeAppIconSeparator {
            collapsing.append(row.arrangedSubviews[index + 1])
        }
        if remaining.count == 1, let separator = row.arrangedSubviews.first(where: { $0 is DesktopChangeAppIconSeparator }) {
            collapsing.append(separator)
        }
        // The pill already shows the rest, so a refresh with the same apps
        // leaves this row alone.
        displayedAppIcons = remaining
        let finish = {
            for view in collapsing {
                row.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
        }
        guard !reducesMotion else {
            finish()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            for view in collapsing {
                view.animator().alphaValue = 0
                view.isHidden = true
            }
            row.layoutSubtreeIfNeeded()
        } completionHandler: {
            MainActor.assumeIsolated { finish() }
        }
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
                view.onDragBegan = { [weak self, weak view] start in
                    guard let self, let view else { return }
                    self.iconDragBegan(view, at: start)
                }
                view.onDragMoved = { [weak self] point in self?.iconDragMoved(to: point) }
                // The close button comes out as soon as the hand closes.
                view.onGrabChanged = { [weak self] grabbing in
                    if grabbing {
                        // AppKit skips setting a cursor it thinks is already
                        // showing, so the arrow first makes it a real change.
                        NSCursor.arrow.set()
                        NSCursor.closedHand.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                    if grabbing {
                        self?.showCloseTarget()
                    } else {
                        self?.hideCloseTarget()
                    }
                }
                view.onDragEnded = { [weak self, weak view] point in
                    guard let self, let view else { return }
                    self.iconDragEnded(view, at: point)
                }
                let processIdentifier = icon.processIdentifier
                view.setAccessibilityCustomActions([
                    NSAccessibilityCustomAction(name: "Quit \(icon.name)") { [weak self] in
                        self?.quitApp(processIdentifier) ?? false
                    }
                ])
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
        restoreToEveryDesktop(panel)
        // Leaving full screen can still take it off the other desktops just
        // after it shows, so look once more as it settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak panel] in
            guard let self, let panel, self.presentationActive, panel === self.activePanel else { return }
            self.restoreToEveryDesktop(panel)
        }
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
