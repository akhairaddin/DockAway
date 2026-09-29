import Cocoa
import ApplicationServices
import QuartzCore
import OSLog

func desktopInteractionTrace(_ phase: @autoclosure () -> String) {
#if DEBUG
    let phase = phase()
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    let event = NSApp.currentEvent
    Logger(subsystem: "AK.DockAway", category: "DesktopInteraction")
        .notice("\(phase, privacy: .public) buttons=\(NSEvent.pressedMouseButtons) front=\(front) event=\(event?.type.rawValue ?? 0) eventTime=\(event?.timestamp ?? 0)")
#endif
}

#if DEBUG
@MainActor
enum DesktopReleaseDiagnostics {
    private static var monitor: Any?
    private static var stopTimer: Timer?

    static func start() {
        stopTimer?.invalidate()
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            let source = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? 0
            desktopInteractionTrace("external mouse type=\(event.type.rawValue) source=\(source) time=\(event.timestamp)")
        }
    }

    static func finish() {
        stopTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: false) { _ in
            MainActor.assumeIsolated {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                stopTimer = nil
            }
        }
        stopTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
#endif

// Native menus run a nested event-tracking loop. Deliver IPC results and
// confirmation polling explicitly in that mode, without relying on MainActor tasks.
enum DesktopMenuOperation {
    static func run<Result: Sendable>(
        work: @escaping @Sendable () -> Result,
        attempts: Int,
        confirmed: @escaping @MainActor (Result) -> Bool,
        completion: @escaping @MainActor (Result, Bool) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            RunLoop.main.perform(inModes: [.default, .eventTracking]) {
                MainActor.assumeIsolated {
                    var remaining = attempts
                    let timer = Timer(timeInterval: 0.1, repeats: true) { timer in
                        MainActor.assumeIsolated {
                            let success = confirmed(result)
                            remaining -= 1
                            if success || remaining <= 0 {
                                timer.invalidate()
                                completion(result, success)
                            }
                        }
                    }
                    RunLoop.main.add(timer, forMode: .common)
                    RunLoop.main.add(timer, forMode: .eventTracking)
                    timer.fire()
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }
}

struct DesktopSelectionSnapshot: Equatable {
    let displayID: CGDirectDisplayID
    let currentID: UInt64
    let orderedSpaceIDs: [UInt64]
    let desktopIDs: [UInt64]
    let fullscreenSpaceIDs: [UInt64]
    let fullscreenContentSpaceIDs: [UInt64: [UInt64]]
    let fullscreenApplicationNames: [UInt64: String]

    init(
        displayID: CGDirectDisplayID,
        currentID: UInt64,
        orderedSpaceIDs: [UInt64],
        desktopIDs: [UInt64],
        fullscreenSpaceIDs: [UInt64] = [],
        fullscreenContentSpaceIDs: [UInt64: [UInt64]] = [:],
        fullscreenApplicationNames: [UInt64: String] = [:]
    ) {
        self.displayID = displayID
        self.currentID = currentID
        self.orderedSpaceIDs = orderedSpaceIDs
        self.desktopIDs = desktopIDs
        self.fullscreenSpaceIDs = fullscreenSpaceIDs
        self.fullscreenContentSpaceIDs = fullscreenContentSpaceIDs
        self.fullscreenApplicationNames = fullscreenApplicationNames
    }

    var managerSpaceIDs: [UInt64] {
        let visible = Set(desktopIDs + fullscreenSpaceIDs)
        return orderedSpaceIDs.filter { visible.contains($0) }
    }

    func reorderedSpaceIDs(moving source: UInt64, onto target: UInt64) -> [UInt64]? {
        guard source != target, managerSpaceIDs.contains(source), managerSpaceIDs.contains(target),
              let from = orderedSpaceIDs.firstIndex(of: source),
              let to = orderedSpaceIDs.firstIndex(of: target) else { return nil }
        var result = orderedSpaceIDs
        result.remove(at: from)
        result.insert(source, at: to)
        return result
    }

    func needsDirectJump(to target: UInt64) -> Bool {
        guard let from = orderedSpaceIDs.firstIndex(of: currentID),
              let to = orderedSpaceIDs.firstIndex(of: target) else { return false }
        return abs(to - from) > 1
    }

    // Includes fullscreen Spaces in the route, but not in the numbered tiles.
    func nextSpace(toward target: UInt64) -> (id: UInt64, right: Bool)? {
        guard let from = orderedSpaceIDs.firstIndex(of: currentID),
              let to = orderedSpaceIDs.firstIndex(of: target), from != to
        else { return nil }
        let right = to > from
        return (orderedSpaceIDs[from + (right ? 1 : -1)], right)
    }

    func associatedDesktopIndex(for spaceID: UInt64) -> Int? {
        if let idx = desktopIDs.firstIndex(of: spaceID) {
            return idx
        }
        guard let spaceOrderIdx = orderedSpaceIDs.firstIndex(of: spaceID) else {
            return nil
        }
        for i in stride(from: spaceOrderIdx - 1, through: 0, by: -1) {
            if let idx = desktopIDs.firstIndex(of: orderedSpaceIDs[i]) {
                return idx
            }
        }
        for i in (spaceOrderIdx + 1)..<orderedSpaceIDs.count {
            if let idx = desktopIDs.firstIndex(of: orderedSpaceIDs[i]) {
                return idx
            }
        }
        return nil
    }

}

struct DesktopNavigationShortcut {
    static func decode(_ preferences: Any?, right: Bool) -> DockShortcut? {
        let fallback = DockShortcut(
            keyCode: right ? 124 : 123, modifiers: [.maskControl, .maskSecondaryFn]
        )
        guard let preferences else { return fallback }
        guard let entries = preferences as? [String: Any] else { return nil }
        guard let raw = entries[right ? "81" : "79"] else { return fallback }
        guard let entry = raw as? [String: Any],
              (entry["enabled"] as? NSNumber)?.boolValue == true else { return nil }
        guard let rawValue = entry["value"] else { return fallback }
        guard let value = rawValue as? [String: Any],
              value["type"] as? String == "standard",
              let parameters = value["parameters"] as? [NSNumber],
              parameters.count == 3 else { return nil }
        let key = parameters[1].intValue
        let flags = parameters[2].int64Value
        let allowed: CGEventFlags = [.maskControl, .maskAlternate, .maskShift,
                                     .maskCommand, .maskSecondaryFn, .maskNumericPad]
        guard (0...127).contains(key), flags >= 0,
              UInt64(flags) & ~allowed.rawValue == 0 else { return nil }
        var modifiers = CGEventFlags(rawValue: UInt64(flags))
        if (123...126).contains(key) { modifiers.insert(.maskSecondaryFn) }
        return DockShortcut(keyCode: CGKeyCode(key), modifiers: modifiers)
    }

    static func current(right: Bool) -> DockShortcut? {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        return decode(CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain), right: right)
    }
}

enum DesktopNavigationInput {
    // Reuse the event source across steps and keep it alive with its events.
    private static let eventSource = CGEventSource(stateID: .hidSystemState)
    // Query actual modifier keys rather than the flags of the most recently
    // posted event. Our synthetic Control+Arrow also contributes event flags.
    static func heldModifiers(keyIsDown: (CGKeyCode) -> Bool) -> CGEventFlags {
        let keys: [(CGKeyCode, CGEventFlags)] = [
            (54, .maskCommand), (55, .maskCommand),
            (56, .maskShift), (60, .maskShift),
            (58, .maskAlternate), (61, .maskAlternate),
            (59, .maskControl), (62, .maskControl), (63, .maskSecondaryFn)
        ]
        return keys.reduce(into: CGEventFlags()) { flags, entry in
            if keyIsDown(entry.0) { flags.insert(entry.1) }
        }
    }

    static var hardwareModifiers: CGEventFlags {
        heldModifiers { CGEventSource.keyState(.hidSystemState, key: $0) }
    }

    static func events(for shortcut: DockShortcut, releaseFlags: CGEventFlags) -> (down: CGEvent, up: CGEvent)? {
        guard let source = eventSource,
              let down = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: false)
        else { return nil }
        source.localEventsSuppressionInterval = 0
        down.flags = shortcut.modifiers
        // Finish the chord. Keeping Control on key-up made the next route
        // step interpret our own shortcut as a modifier the user was holding.
        up.flags = releaseFlags
        return (down, up)
    }
}

// Neighbors use the native swipe; distant targets use one direct Space change.
// Never change
// Mission Control preferences or use screen capture, Dock injection, or AX clicks.
@MainActor
final class DesktopSwitcher {
    private var task: Task<Void, Never>?
    private var switchID: UInt64 = 0
    private static let eventTag: Int64 = 0x4441575350414345
    var isSwitching: Bool { task != nil }

    func cancel() { task?.cancel() }

    private func finishSwitching(id: UInt64, with message: String?, completion: (String?) -> Void) {
        if switchID == id {
            task = nil
        }
        completion(message)
    }

    func switchTo(
        _ target: UInt64,
        initial: DesktopSelectionSnapshot,
        forceDirectJump: Bool = false,
        snapshot: @escaping () -> DesktopSelectionSnapshot?,
        teleport: @escaping (UInt64, UInt64) async -> Bool = { _, _ in false },
        completion: @escaping (String?) -> Void
    ) {
        guard task == nil, initial.managerSpaceIDs.contains(target) else { return }
        switchID &+= 1
        let currentSwitchID = switchID
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.switchID == currentSwitchID {
                    self.task = nil
                }
            }
            // The native menu must finish tracking before posting a shortcut.
            let sleepTime: UInt64 = forceDirectJump ? 20_000_000 : 150_000_000
            try? await Task.sleep(nanoseconds: sleepTime)
            guard !Task.isCancelled else { return }
            let inputMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
            let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: inputMask) { [weak self] event in
                if event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.eventTag {
                    self?.cancel()
                }
            }
            let localMonitor = NSEvent.addLocalMonitorForEvents(matching: inputMask) { [weak self] event in
                if event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.eventTag {
                    self?.cancel()
                }
                return event
            }
            defer {
                if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
                if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            }
            guard AXIsProcessTrusted() else {
                self.finishSwitching(id: currentSwitchID, with: "Accessibility access is required to switch desktops.", completion: completion)
                return
            }
            if initial.currentID == target {
                self.finishSwitching(id: currentSwitchID, with: nil, completion: completion)
                return
            }
            if forceDirectJump || initial.needsDirectJump(to: target) {
                guard let live = snapshot(), live.displayID == initial.displayID,
                      live.orderedSpaceIDs == initial.orderedSpaceIDs,
                      (live.currentID == initial.currentID || forceDirectJump),
                      (forceDirectJump || Self.pointerIsOnDisplay(initial.displayID)),
                      NSEvent.pressedMouseButtons == 0,
                      DesktopNavigationInput.hardwareModifiers.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else {
                    self.finishSwitching(id: currentSwitchID, with: "The desktop layout or input changed. Open the menu and try again.", completion: completion)
                    return
                }
                if live.currentID == target {
                    self.finishSwitching(id: currentSwitchID, with: nil, completion: completion)
                    return
                }
                guard await teleport(target, live.currentID) else {
                    self.finishSwitching(id: currentSwitchID, with: "Direct desktop switching is unavailable on this macOS version. No intermediate swipes were sent.", completion: completion)
                    return
                }
                if let observed = snapshot(), observed.currentID == target {
                    self.finishSwitching(id: currentSwitchID, with: nil, completion: completion)
                    return
                }
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    guard !Task.isCancelled else { return }
                    guard let observed = snapshot(), observed.displayID == initial.displayID,
                          observed.orderedSpaceIDs == initial.orderedSpaceIDs else { break }
                    if observed.currentID == target {
                        self.finishSwitching(id: currentSwitchID, with: nil, completion: completion)
                        return
                    }
                }
                self.finishSwitching(id: currentSwitchID, with: "The direct desktop switch wasn't confirmed. No intermediate swipes were sent.", completion: completion)
                return
            }
            for _ in 0..<initial.orderedSpaceIDs.count {
                guard !Task.isCancelled else { return }
                guard let live = snapshot(), live.displayID == initial.displayID,
                      live.orderedSpaceIDs == initial.orderedSpaceIDs else {
                    self.finishSwitching(id: currentSwitchID, with: "The desktop layout changed. Open the menu and try again.", completion: completion)
                    return
                }
                if live.currentID == target {
                    self.finishSwitching(id: currentSwitchID, with: nil, completion: completion)
                    return
                }
                guard let next = live.nextSpace(toward: target) else {
                    self.finishSwitching(id: currentSwitchID, with: "The selected desktop is no longer available.", completion: completion)
                    return
                }
                guard Self.pointerIsOnDisplay(initial.displayID) else {
                    self.finishSwitching(id: currentSwitchID, with: "The pointer moved to a different display.", completion: completion)
                    return
                }
                guard NSEvent.pressedMouseButtons == 0,
                      DesktopNavigationInput.hardwareModifiers.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else {
                    self.finishSwitching(id: currentSwitchID, with: "A mouse button or modifier key is being held. Release it and try again.", completion: completion)
                    return
                }
                guard let shortcut = DesktopNavigationShortcut.current(right: next.right) else {
                    self.finishSwitching(id: currentSwitchID, with: "Enable Move left a space and Move right a space in System Settings > Keyboard > Keyboard Shortcuts > Mission Control.", completion: completion)
                    return
                }
                guard Self.post(shortcut) else {
                    self.finishSwitching(id: currentSwitchID, with: "macOS could not send the desktop shortcut.", completion: completion)
                    return
                }
                var arrived = false
                // Poll only during a user-requested switch. Give the slide time
                // to settle before sending another key; never queue blind swipes.
                for attempt in 0..<15 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled, let observed = snapshot(),
                          observed.orderedSpaceIDs == initial.orderedSpaceIDs else { break }
                    if observed.currentID != live.currentID && observed.currentID != next.id { break }
                    if observed.currentID == next.id && attempt >= 6 {
                        arrived = true
                        break
                    }
                }
                guard arrived else {
                    guard !Task.isCancelled else { return }
                    self.finishSwitching(id: currentSwitchID, with: "The desktop switch wasn't confirmed. Navigation stopped without changing your settings.", completion: completion)
                    return
                }
            }
            self.finishSwitching(id: currentSwitchID, with: snapshot()?.currentID == target ? nil : "The selected desktop could not be reached.", completion: completion)
        }
    }

    private static func pointerIsOnDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        guard let point = CGEvent(source: nil)?.location else { return false }
        return CGDisplayBounds(displayID).contains(point)
    }

    private static func post(_ shortcut: DockShortcut) -> Bool {
        let releaseFlags = DesktopNavigationInput.hardwareModifiers.union(
            CGEventSource.flagsState(.hidSystemState).intersection(.maskAlphaShift)
        )
        guard let (down, up) = DesktopNavigationInput.events(for: shortcut, releaseFlags: releaseFlags) else { return false }
        down.setIntegerValueField(.eventSourceUserData, value: eventTag)
        up.setIntegerValueField(.eventSourceUserData, value: eventTag)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

struct DesktopApplicationIcon {
    let name: String
    let image: NSImage
    var bundleIdentifier: String? = nil
}

private final class DesktopNumberLabel: NSTextField {
    // The cell draws its own text and shadow. Menu vibrancy otherwise treats
    // both as foreground artwork and can turn the black shadow into a halo.
    override var allowsVibrancy: Bool { false }
}

final class DesktopLabelCell: NSTextFieldCell {
    var isPillActive: Bool = false {
        didSet {
            if oldValue != isPillActive { controlView?.needsDisplay = true }
        }
    }
    var isKeyboardSelected: Bool = false {
        didSet {
            if oldValue != isKeyboardSelected { controlView?.needsDisplay = true }
        }
    }
    var isDesktopHovered: Bool = false {
        didSet {
            if oldValue != isDesktopHovered { controlView?.needsDisplay = true }
        }
    }
    var representsFullscreenSpace: Bool = false {
        didSet {
            if oldValue != representsFullscreenSpace { controlView?.needsDisplay = true }
        }
    }
    var activePillColor: NSColor = .systemBlue {
        didSet {
            if oldValue != activePillColor { controlView?.needsDisplay = true }
        }
    }
    var indicatorStyle: DesktopNumberIndicatorStyle = DesktopNumberStylePreference.currentStyle {
        didSet {
            if oldValue != indicatorStyle { controlView?.needsDisplay = true }
        }
    }

    var showsPill: Bool {
        if representsFullscreenSpace { return false }
        switch indicatorStyle {
        case .accentPill:
            return isPillActive
        case .subtleShadow:
            return isKeyboardSelected
        }
    }

    var isBoldWithShadow: Bool {
        switch indicatorStyle {
        case .accentPill:
            return isKeyboardSelected
        case .subtleShadow:
            return isPillActive
        }
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect { rect }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    func shadowForText(color: NSColor, bold: Bool, appearance: NSAppearance) -> NSShadow {
        if indicatorStyle == .accentPill && isDesktopHovered && !representsFullscreenSpace {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black
            shadow.shadowOffset = NSSize(width: 0, height: -1.25)
            shadow.shadowBlurRadius = 3.0
            return shadow
        }

        var luminance: CGFloat = 1.0
        appearance.performAsCurrentDrawingAppearance {
            let resolved = color.usingColorSpace(.sRGB) ?? color
            luminance = 0.299 * resolved.redComponent + 0.587 * resolved.greenComponent + 0.114 * resolved.blueComponent
        }

        let shadow = NSShadow()
        // White text = Black Shadow. Black Text = White Shadow.
        if luminance > 0.5 {
            // Light / White text -> Crisp Black Shadow
            shadow.shadowColor = NSColor.black.withAlphaComponent(bold ? 0.85 : 0.45)
            shadow.shadowOffset = NSSize(width: 0, height: -1.0)
            shadow.shadowBlurRadius = bold ? 2.5 : 1.2
        } else {
            // Dark / Black text -> Crisp White Shadow
            shadow.shadowColor = NSColor.white.withAlphaComponent(bold ? 0.70 : 0.40)
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            shadow.shadowBlurRadius = bold ? 1.8 : 1.0
        }
        return shadow
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let activeAppearance = controlView.effectiveAppearance
        let isDark = (activeAppearance.bestMatch(from: [.darkAqua, .aqua])
            ?? NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            ?? .aqua) == .darkAqua

        if showsPill {
            let pillText = NSMutableAttributedString(attributedString: attributedStringValue)
            let fullRange = NSRange(location: 0, length: pillText.length)
            pillText.removeAttribute(.shadow, range: fullRange)

            let textColor = NSColor.white
            pillText.addAttribute(.foregroundColor, value: textColor, range: fullRange)

            if isBoldWithShadow {
                pillText.addAttribute(
                    .font,
                    value: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
                    range: fullRange
                )
            }

            let shadow = shadowForText(color: textColor, bold: isBoldWithShadow, appearance: activeAppearance)
            pillText.addAttribute(.shadow, value: shadow, range: fullRange)

            let textSize = pillText.size()
            let pillWidth = max(17.0, ceil(textSize.width) + 6.0)
            let pillHeight: CGFloat = 14.0
            let pillRect = NSRect(
                x: floor(cellFrame.midX - pillWidth / 2.0),
                y: floor(cellFrame.minY),
                width: pillWidth,
                height: pillHeight
            )

            activePillColor.setFill()
            let pill = NSBezierPath(roundedRect: pillRect, xRadius: 3.5, yRadius: 3.5)
            pill.fill()

            pillText.draw(with: cellFrame, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        } else {
            let styledText = NSMutableAttributedString(attributedString: attributedStringValue)
            let fullRange = NSRange(location: 0, length: styledText.length)
            styledText.removeAttribute(.shadow, range: fullRange)

            let textColor: NSColor
            if isBoldWithShadow {
                if !representsFullscreenSpace {
                    styledText.addAttribute(
                        .font,
                        value: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
                        range: fullRange
                    )
                }
                textColor = isDark ? NSColor.white : NSColor.labelColor
                styledText.addAttribute(.foregroundColor, value: textColor, range: fullRange)
            } else {
                textColor = isDark ? NSColor.white : NSColor.labelColor
                styledText.addAttribute(.foregroundColor, value: textColor, range: fullRange)
            }

            let shadow = shadowForText(color: textColor, bold: isBoldWithShadow, appearance: activeAppearance)
            styledText.addAttribute(.shadow, value: shadow, range: fullRange)
            styledText.draw(with: cellFrame, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
    }
}

/// A departing tile's number label image during a deletion reflow; never takes clicks.
private final class DesktopReflowSnapshotView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Hosts a departing tile's live copy during a deletion reflow; never takes clicks.
private final class DesktopReflowReplicaHost: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class DesktopTileCell: NSButtonCell {
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        frame // The number is displayed by the label above the button.
    }
}

private final class DesktopDragPreview: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@available(macOS 26.0, *)
private final class DesktopGlassOutlineView: NSGlassEffectView {
    var outlineWidth: CGFloat = 1.5 {
        didSet {
            if oldValue != outlineWidth { updateOutlineMask() }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        style = .regular
        cornerRadius = 6
        wantsLayer = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updateOutlineMask()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateOutlineMask() {
        guard bounds.width > outlineWidth * 2, bounds.height > outlineWidth * 2 else { return }
        let path = CGMutablePath()
        path.addRoundedRect(in: bounds, cornerWidth: 6, cornerHeight: 6)
        let inner = bounds.insetBy(dx: outlineWidth, dy: outlineWidth)
        path.addRoundedRect(
            in: inner,
            cornerWidth: max(0, 6 - outlineWidth),
            cornerHeight: max(0, 6 - outlineWidth)
        )
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.path = path
        mask.fillRule = .evenOdd
        mask.fillColor = NSColor.black.cgColor
        layer?.mask = mask
    }
}

final class DesktopTileButton: NSButton {
    // Busy operations block input without flashing the native disabled bezel.
    var interactionBlocked = false

    override func mouseDown(with event: NSEvent) {
        guard !interactionBlocked else { return }
        super.mouseDown(with: event)
    }

    override func performClick(_ sender: Any?) {
        guard !interactionBlocked else { return }
        super.performClick(sender)
    }

    override func accessibilityPerformPress() -> Bool {
        guard !interactionBlocked else { return false }
        return super.accessibilityPerformPress()
    }

    override func isAccessibilityEnabled() -> Bool {
        !interactionBlocked && super.isAccessibilityEnabled()
    }

    var isKeyboardFocused = false {
        didSet {
            if oldValue != isKeyboardFocused {
                applyFocusScale(animated: true)
                (superview as? DesktopTilesView)?.updateFocusForTile(self, focused: isKeyboardFocused)
                needsDisplay = true
            }
        }
    }
    var belongsToActiveDisplay = true
    var representsFullscreenSpace = false { didSet { needsDisplay = true } }
    var showsFullscreenOutline = false { didSet { needsDisplay = true } }
    var canReorder = false
    var isDropTarget = false { didSet { needsDisplay = true } }
    var applicationIcons: [DesktopApplicationIcon] = [] {
        didSet { needsDisplay = true }
    }
    var isTileHovered = false {
        didSet {
            guard oldValue != isTileHovered else { return }
            needsDisplay = true
            hoverStateChanged?(isTileHovered)
        }
    }
    var hoverStateChanged: ((Bool) -> Void)?
    var showsDesktopOutline: Bool {
        isTileHovered || isDropTarget || state == .on || (representsFullscreenSpace && showsFullscreenOutline)
    }
    private weak var glassOutline: NSView?
    private let focusGlowLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        focusGlowLayer.masksToBounds = false
        focusGlowLayer.opacity = 0
        focusGlowLayer.isHidden = true
        layer?.addSublayer(focusGlowLayer)
        installGlassOutlineIfAvailable()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = false
        focusGlowLayer.masksToBounds = false
        focusGlowLayer.opacity = 0
        focusGlowLayer.isHidden = true
        layer?.addSublayer(focusGlowLayer)
        installGlassOutlineIfAvailable()
    }

    private func installGlassOutlineIfAvailable() {
        guard #available(macOS 26.0, *) else { return }
        let glass = DesktopGlassOutlineView(frame: bounds)
        glass.autoresizingMask = [.width, .height]
        addSubview(glass, positioned: .below, relativeTo: nil)
        glassOutline = glass
    }

    override func layout() {
        super.layout()
        glassOutline?.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        focusGlowLayer.frame = bounds
        focusGlowLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
            cornerWidth: 6,
            cornerHeight: 6,
            transform: nil
        )
        if isKeyboardFocused {
            applyFocusScale(animated: false)
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            isKeyboardFocused = false
            layer?.removeAnimation(forKey: "focusScale")
            focusGlowLayer.removeAnimation(forKey: "focusGlow")
            layer?.setAffineTransform(.identity)
            layer?.zPosition = 0
            focusGlowLayer.opacity = 0
            focusGlowLayer.isHidden = true
            (superview as? DesktopTilesView)?.updateFocusForTile(self, focused: false)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if isKeyboardFocused {
            applyFocusScale(animated: false)
        }
    }

    private func applyFocusScale(animated: Bool) {
        guard let layer else { return }
        let isFocused = isKeyboardFocused
        let scale: CGFloat = isFocused ? 1.08 : 1.0
        let transform: CGAffineTransform
        if isFocused {
            transform = CGAffineTransform(translationX: bounds.width / 2, y: bounds.height / 2)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -bounds.width / 2, y: -bounds.height / 2)
        } else {
            transform = .identity
        }

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let targetGlowOpacity: Float = isFocused ? 1.0 : 0.0

        layer.zPosition = isFocused ? 3 : (showsDesktopOutline ? 1 : 0)

        let accent = NSColor.controlAccentColor
        focusGlowLayer.strokeColor = accent.cgColor
        focusGlowLayer.lineWidth = 2.0
        focusGlowLayer.fillColor = nil
        focusGlowLayer.shadowColor = accent.cgColor
        focusGlowLayer.shadowRadius = 4.0
        focusGlowLayer.shadowOffset = .zero
        focusGlowLayer.shadowOpacity = isDark ? 0.85 : 0.65

        if isFocused {
            focusGlowLayer.isHidden = false
        }

        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shouldAnimate {
            let duration: TimeInterval = isFocused ? 0.14 : 0.16
            let timing = CAMediaTimingFunction(name: isFocused ? .easeOut : .easeInEaseOut)

            let animTransform = CABasicAnimation(keyPath: "transform")
            animTransform.duration = duration
            animTransform.timingFunction = timing
            animTransform.fromValue = layer.transform
            animTransform.toValue = CATransform3DMakeAffineTransform(transform)
            layer.add(animTransform, forKey: "focusScale")

            let animGlow = CABasicAnimation(keyPath: "opacity")
            animGlow.duration = duration
            animGlow.timingFunction = timing
            animGlow.fromValue = focusGlowLayer.opacity
            animGlow.toValue = targetGlowOpacity
            focusGlowLayer.add(animGlow, forKey: "focusGlow")
        } else {
            layer.removeAnimation(forKey: "focusScale")
            focusGlowLayer.removeAnimation(forKey: "focusGlow")
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(transform)
        focusGlowLayer.opacity = targetGlowOpacity
        if !isFocused {
            focusGlowLayer.isHidden = true
        }
        CATransaction.commit()
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        superview?.setNeedsDisplay(frame.insetBy(dx: -12, dy: -12))
    }

    static func iconFrames(count: Int, in bounds: NSRect) -> [NSRect] {
        let visibleCount = min(6, max(0, count))
        let stackedPair = visibleCount == 2 && bounds.height > 28
        let stackedThree = visibleCount == 3 && bounds.height > 28
        let horizontalPair = visibleCount == 2 && !stackedPair
        let size: CGFloat
        if stackedPair { size = min(bounds.width - 6, (bounds.height - 3) / 2) }
        else if stackedThree { size = min(bounds.width - 6, (bounds.height - 4) / 3) }
        else if horizontalPair { size = min(bounds.height - 6, (bounds.width - 5) / 2) }
        else { size = visibleCount == 1 ? min(bounds.width, bounds.height) - 6 : 11 }
        let iconColumns = min(2, visibleCount)
        let gridWidth = CGFloat(iconColumns) * 13 - 2
        let gridHeight = CGFloat((visibleCount + 1) / 2) * 13 - 2
        return (0..<visibleCount).map { index in
            let centered = visibleCount == 1 || stackedPair || stackedThree || (visibleCount % 2 == 1 && index == visibleCount - 1)
            let x = horizontalPair
                ? bounds.midX - (2 * size + 1) / 2 + CGFloat(index) * (size + 1)
                : (centered ? bounds.midX - size / 2 : bounds.midX - gridWidth / 2 + CGFloat(index % 2) * 13)
            let y = stackedPair || stackedThree
                ? bounds.midY - (CGFloat(visibleCount) * size + CGFloat(visibleCount - 1)) / 2 + CGFloat(index) * (size + 1)
                : (visibleCount == 1 || horizontalPair ? bounds.midY - size / 2 : bounds.midY - gridHeight / 2 + CGFloat(index / 2) * 13)
            return NSRect(x: x, y: y, width: size, height: size)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let icons = applicationIcons
        for (index, rect) in Self.iconFrames(count: icons.count, in: bounds).enumerated() {
            if icons.count > 6 && index == 5 {
                let text = "+\(icons.count - 5)" as NSString
                text.draw(in: rect.insetBy(dx: -1, dy: 0), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 8, weight: .semibold), .foregroundColor: NSColor.labelColor])
            } else {
                NSGraphicsContext.current?.imageInterpolation = .high
                icons[index].image.draw(in: backingAlignedRect(rect, options: [.alignAllEdgesNearest]), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        if #available(macOS 26.0, *), let glass = glassOutline as? DesktopGlassOutlineView {
            let persistentFullscreen = representsFullscreenSpace && showsFullscreenOutline
            let isActiveTile = state == .on || persistentFullscreen || isDropTarget
            if isKeyboardFocused {
                glass.tintColor = NSColor.controlAccentColor
                glass.outlineWidth = 2.25
            } else if showsDesktopOutline {
                if persistentFullscreen || contentTintColor == .systemGreen {
                    glass.tintColor = .systemGreen
                } else if !belongsToActiveDisplay {
                    glass.tintColor = .white
                } else {
                    glass.tintColor = .systemBlue
                }
                glass.outlineWidth = isActiveTile ? 2.75 : 2.0
            } else {
                glass.tintColor = NSColor.secondaryLabelColor.withAlphaComponent(0.32)
                glass.outlineWidth = 1.5
            }
            glass.isHidden = false
            return
        }
        guard showsDesktopOutline else {
            // Idle desktops keep their shape without bringing back the old
            // blue-tinted button fill.
            NSColor.secondaryLabelColor.withAlphaComponent(0.62).setStroke()
            let outline = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                xRadius: 5.5,
                yRadius: 5.5
            )
            outline.lineWidth = 1.0
            outline.stroke()
            return
        }
        let persistentFullscreen = representsFullscreenSpace && showsFullscreenOutline
        let isActiveTile = state == .on || persistentFullscreen || isDropTarget

        // Outline color policy: Keep outlines independent from DockAway blue.
        // - Green for fullscreen spaces
        // - White for active/hovered desktops on secondary monitors
        // - Blue for active desktops, drop targets, and hover on active display
        let outlineColor: NSColor
        if persistentFullscreen || (contentTintColor == .systemGreen) {
            outlineColor = .systemGreen
        } else if !belongsToActiveDisplay {
            outlineColor = .white
        } else {
            outlineColor = .systemBlue
        }

        let alpha: CGFloat = (isActiveTile || !belongsToActiveDisplay) ? 1.0 : 0.8
        let strokeColor = outlineColor.withAlphaComponent(alpha)

        if isActiveTile {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let activeLineWidth: CGFloat = 2.25
            // Expand outward rather than inward so interior icon padding remains spacious.
            let activeInset: CGFloat = -0.15
            let activeRadius: CGFloat = 6.0
            let outline = NSBezierPath(
                roundedRect: bounds.insetBy(dx: activeInset, dy: activeInset),
                xRadius: activeRadius,
                yRadius: activeRadius
            )
            outline.lineWidth = activeLineWidth

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.45 : 0.28)
            shadow.shadowBlurRadius = 3.0
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            shadow.set()

            strokeColor.setStroke()
            outline.stroke()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            strokeColor.setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            outline.lineWidth = 1.0
            outline.stroke()
        }
    }
}

final class DesktopAddButton: NSButton {
    // Busy operations block input without flashing the native disabled bezel.
    var interactionBlocked = false

    override func mouseDown(with event: NSEvent) {
        guard !interactionBlocked else { return }
        super.mouseDown(with: event)
    }

    override func performClick(_ sender: Any?) {
        guard !interactionBlocked else { return }
        super.performClick(sender)
    }

    override func accessibilityPerformPress() -> Bool {
        guard !interactionBlocked else { return false }
        return super.accessibilityPerformPress()
    }

    override func isAccessibilityEnabled() -> Bool {
        !interactionBlocked && super.isAccessibilityEnabled()
    }

    var isKeyboardFocused = false {
        didSet {
            if oldValue != isKeyboardFocused {
                applyHover(animated: true)
                needsDisplay = true
            }
        }
    }
    private(set) var isAddButtonHovered = false
    private var hoverTrackingArea: NSTrackingArea?
    private weak var glassOutline: NSView?
    private let focusGlowLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        focusGlowLayer.masksToBounds = false
        focusGlowLayer.opacity = 0
        focusGlowLayer.isHidden = true
        layer?.addSublayer(focusGlowLayer)
        if #available(macOS 26.0, *) {
            let glass = DesktopGlassOutlineView(frame: bounds)
            glass.autoresizingMask = [.width, .height]
            glass.tintColor = NSColor.secondaryLabelColor.withAlphaComponent(0.32)
            addSubview(glass, positioned: .below, relativeTo: nil)
            glassOutline = glass
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        glassOutline?.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        focusGlowLayer.frame = bounds
        focusGlowLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
            cornerWidth: 6,
            cornerHeight: 6,
            transform: nil
        )
        if isKeyboardFocused || isAddButtonHovered {
            applyHover(animated: false)
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            isKeyboardFocused = false
            setHovered(false, animated: false)
            layer?.removeAnimation(forKey: "hoverScale")
            focusGlowLayer.removeAnimation(forKey: "focusGlow")
            layer?.setAffineTransform(.identity)
            layer?.zPosition = 0
            focusGlowLayer.opacity = 0
            focusGlowLayer.isHidden = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if isKeyboardFocused || isAddButtonHovered {
            applyHover(animated: false)
        }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        superview?.setNeedsDisplay(frame.insetBy(dx: -12, dy: -12))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let isFocusedOrHovered = isAddButtonHovered || isKeyboardFocused
        if #available(macOS 26.0, *), let glass = glassOutline as? DesktopGlassOutlineView {
            glass.tintColor = isFocusedOrHovered
                ? NSColor.controlAccentColor
                : NSColor.secondaryLabelColor.withAlphaComponent(0.32)
            glass.outlineWidth = isFocusedOrHovered ? 2.0 : 1.5
        } else {
            NSColor.secondaryLabelColor.withAlphaComponent(0.62).setStroke()
            let outline = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                xRadius: 5.5,
                yRadius: 5.5
            )
            outline.lineWidth = 1.0
            outline.stroke()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled && !isHidden else { return }
        setHovered(true, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false, animated: true)
    }

    func setHovered(_ hovered: Bool, animated: Bool) {
        guard isAddButtonHovered != hovered else { return }
        isAddButtonHovered = hovered
        applyHover(animated: animated)
    }

    private func applyHover(animated: Bool) {
        guard let layer else { return }
        let isFocused = isKeyboardFocused
        let isHovered = isAddButtonHovered
        let isElevated = isFocused || isHovered
        let scale: CGFloat = isFocused ? 1.08 : (isHovered ? 1.10 : 1.0)
        let transform: CGAffineTransform
        if isElevated {
            transform = CGAffineTransform(translationX: bounds.width / 2, y: bounds.height / 2)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -bounds.width / 2, y: -bounds.height / 2)
        } else {
            transform = .identity
        }

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let targetGlowOpacity: Float = isFocused ? 1.0 : 0.0

        layer.zPosition = isFocused ? 3 : (isHovered ? 2 : 0)

        let accent = NSColor.controlAccentColor
        focusGlowLayer.strokeColor = accent.cgColor
        focusGlowLayer.lineWidth = 2.0
        focusGlowLayer.fillColor = nil
        focusGlowLayer.shadowColor = accent.cgColor
        focusGlowLayer.shadowRadius = 4.0
        focusGlowLayer.shadowOffset = .zero
        focusGlowLayer.shadowOpacity = isDark ? 0.85 : 0.65

        if isFocused {
            focusGlowLayer.isHidden = false
        }

        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shouldAnimate {
            let duration: TimeInterval = isFocused ? 0.14 : (isHovered ? 0.12 : 0.16)
            let timing = CAMediaTimingFunction(name: isElevated ? .easeOut : .easeInEaseOut)

            let animTransform = CABasicAnimation(keyPath: "transform")
            animTransform.duration = duration
            animTransform.timingFunction = timing
            animTransform.fromValue = layer.transform
            animTransform.toValue = CATransform3DMakeAffineTransform(transform)
            layer.add(animTransform, forKey: "hoverScale")

            let animGlow = CABasicAnimation(keyPath: "opacity")
            animGlow.duration = duration
            animGlow.timingFunction = timing
            animGlow.fromValue = focusGlowLayer.opacity
            animGlow.toValue = targetGlowOpacity
            focusGlowLayer.add(animGlow, forKey: "focusGlow")
        } else {
            layer.removeAnimation(forKey: "hoverScale")
            focusGlowLayer.removeAnimation(forKey: "focusGlow")
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(transform)
        focusGlowLayer.opacity = targetGlowOpacity
        if !isFocused {
            focusGlowLayer.isHidden = true
        }
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled && !isHidden else { return nil }
        let local = convert(point, from: superview)
        let hitBounds = isAddButtonHovered ? bounds.insetBy(dx: -2, dy: -2) : bounds
        guard hitBounds.contains(local) else { return nil }
        return self
    }
}

struct DesktopDisplaySection {
    let name: String
    let snapshot: DesktopSelectionSnapshot
}

private final class ActiveDisplayDot: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// Native labels over the existing desktop controls, without duplicating Spaces
/// when displays are mirrored or macOS uses one shared set of desktops.
final class DesktopDisplaySectionsView: NSView {
    enum NavigationTarget: Equatable {
        case desktop(UInt64)
        case add(CGDirectDisplayID)

        var spaceID: UInt64? {
            if case .desktop(let id) = self { return id }
            return nil
        }

        var displayID: CGDirectDisplayID? {
            if case .add(let id) = self { return id }
            return nil
        }
    }

    struct NavigationItem {
        let target: NavigationTarget
        let view: NSView
        let frame: NSRect
        let setFocused: (Bool) -> Void
        let isCurrent: Bool
    }

    private var keyboardTarget: NavigationTarget?
    private var keyboardSpaceIndex: Int?
    private var pendingClosureFocus: (removed: UInt64, successor: UInt64)?
    var currentKeyboardSpaceID: UInt64? { keyboardTarget?.spaceID }
    var currentKeyboardTarget: NavigationTarget? { keyboardTarget }

    func endKeyboardNavigation() {
        pendingClosureFocus = nil
        keyboardTarget = nil
        keyboardSpaceIndex = nil
        rows.forEach { row in
            row.tiles.navigationTiles.forEach { $0.button.isKeyboardFocused = false }
            row.tiles.addNavigationButton?.isKeyboardFocused = false
            row.tiles.clearKeyboardFocusSelection()
        }
    }

    func restoreKeyboardFocus(to spaceID: UInt64) {
        pendingClosureFocus = nil
        keyboardTarget = .desktop(spaceID)
        let items = navigationItems()
        if let index = items.firstIndex(where: { $0.target == .desktop(spaceID) }) {
            keyboardSpaceIndex = index
            for item in items { item.setFocused(item.target == keyboardTarget) }
            scrollToVisible(items[index].frame)
        }
    }

    func handleDesktopClosure(_ idToClose: UInt64) {
        let row = rows.first(where: { $0.tiles.navigationTiles.contains(where: { $0.id == idToClose }) })
        let tiles = row?.tiles.navigationTiles ?? rows.flatMap { $0.tiles.navigationTiles }
        guard let closedIndex = tiles.firstIndex(where: { $0.id == idToClose }) else { return }
        let targetIndex: Int
        if closedIndex + 1 < tiles.count {
            // The following desktop slides into the deleted tile's position.
            targetIndex = closedIndex + 1
        } else if closedIndex > 0 {
            targetIndex = closedIndex - 1
        } else {
            return
        }
        let targetID = tiles[targetIndex].id
        // Keep the ring on the old slot until the confirmed snapshot renumbers
        // the successor. Focusing it now flashes the next row's first tile.
        pendingClosureFocus = (idToClose, targetID)
    }

    private func navigationItems() -> [NavigationItem] {
        rows.flatMap { row in
            var items: [NavigationItem] = row.tiles.navigationTiles.map { tile in
                NavigationItem(
                    target: .desktop(tile.id),
                    view: tile.button,
                    frame: tile.button.convert(tile.button.bounds, to: self),
                    setFocused: { tile.button.isKeyboardFocused = $0 },
                    isCurrent: tile.button.belongsToActiveDisplay && tile.button.state == .on
                )
            }
            if let addBtn = row.tiles.addNavigationButton {
                items.append(NavigationItem(
                    target: .add(row.id),
                    view: addBtn,
                    frame: addBtn.convert(addBtn.bounds, to: self),
                    setFocused: { addBtn.isKeyboardFocused = $0 },
                    isCurrent: false
                ))
            }
            return items
        }
    }

    func handleNavigationKey(_ key: UInt16) -> Bool {
        guard !hasActiveDesktopGesture else { return false }
        let items = navigationItems()
        guard !items.isEmpty else { return false }
        let index = items.firstIndex { $0.target == keyboardTarget }
            ?? items.firstIndex { $0.isCurrent } ?? 0
        var next = index
        let prefs = KeyboardNavigationPreferences.current
        if prefs.isSelect(key) {
            switch items[index].target {
            case .desktop(let spaceID):
                onSelect?(spaceID)
            case .add(let displayID):
                onAdd?(displayID)
            }
            return true
        } else if prefs.isClose(key) {
            switch items[index].target {
            case .desktop(let spaceID):
                if onClose?(spaceID) == true {
                    handleDesktopClosure(spaceID)
                    return true
                }
                return false
            case .add:
                let prevIndex = max(0, index - 1)
                guard items.indices.contains(prevIndex),
                      case .desktop(let spaceID) = items[prevIndex].target else { return false }
                restoreKeyboardFocus(to: spaceID)
                return true
            }
        } else if prefs.isLeft(key) {
            next = max(0, index - 1)
        } else if prefs.isRight(key) {
            next = min(items.count - 1, index + 1)
        } else if prefs.isUp(key) || prefs.isDown(key) {
            let isDown = prefs.isDown(key)
            let origin = items[index].frame
            let candidates = items.indices.filter {
                isDown ? items[$0].frame.midY > origin.maxY : items[$0].frame.midY < origin.minY
            }
            if let nearest = candidates.min(by: {
                let a = abs(items[$0].frame.midY - origin.midY)
                let b = abs(items[$1].frame.midY - origin.midY)
                return abs(a - b) > 1 ? a < b
                    : abs(items[$0].frame.midX - origin.midX) < abs(items[$1].frame.midX - origin.midX)
            }) { next = nearest }
        } else {
            return false
        }
        keyboardTarget = items[next].target
        keyboardSpaceIndex = next
        for item in items { item.setFocused(item.target == keyboardTarget) }
        scrollToVisible(items[next].frame)
        return true
    }
    private var applicationIconsBySpace: [UInt64: [DesktopApplicationIcon]] = [:]
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { frame.size }
    var onSelect: ((UInt64) -> Void)?
    var onAdd: ((CGDirectDisplayID) -> Void)?
    var onClose: ((UInt64) -> Bool)?
    var onReorder: ((UInt64, UInt64) -> Void)?
    var onAppend: ((UInt64, UInt64) -> Void)?
    private var rows: [(id: CGDirectDisplayID, label: NSTextField, dot: ActiveDisplayDot, tiles: DesktopTilesView)] = []
    private var visibilityAnimation: EasedAnimation?
    private(set) var isAnimatingVisibility = false
    private(set) var isCollapsed: Bool = false

    var naturalHeight: CGFloat {
        var y: CGFloat = 0
        for row in rows {
            if !row.label.isHidden {
                y += 22
            }
            y += row.tiles.frame.height
        }
        return y
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityRole(.group)
        setAccessibilityLabel("Desktop Manager")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityRole(.group)
        setAccessibilityLabel("Desktop Manager")
    }

    var hasActiveDesktopGesture: Bool {
        rows.contains { $0.tiles.hasActiveDesktopGesture }
    }

    func update(_ sections: [DesktopDisplaySection], showLabels: Bool,
                enabled: Bool, canAdd: Bool, canClose: Bool, activeDisplayID: CGDirectDisplayID) {
        let maxBoxes = sections.map { $0.snapshot.managerSpaceIDs.count + (canAdd ? 1 : 0) }.max() ?? 0
        let targetWidth: CGFloat = sections.isEmpty ? (bounds.width > 0 ? bounds.width : 190) : (maxBoxes >= 5 ? 230 : 190)
        let previousWidth = frame.width
        let previousWindowFrame = window?.frame
        let widthChanged = abs(previousWidth - targetWidth) > 0.5
        if widthChanged {
            frame.size.width = targetWidth
            invalidateIntrinsicContentSize()
        }
        let ids = sections.map { $0.snapshot.displayID }
        for row in rows where !ids.contains(row.id) {
            row.label.removeFromSuperview()
            row.dot.removeFromSuperview()
            row.tiles.removeFromSuperview()
        }
        rows = sections.map { section in
            let row = rows.first { $0.id == section.snapshot.displayID } ?? {
                let label = NSTextField(labelWithString: section.name)
                label.font = .systemFont(ofSize: 11, weight: .semibold)
                label.textColor = .secondaryLabelColor
                label.lineBreakMode = .byTruncatingTail
                label.alignment = .left
                let dot = ActiveDisplayDot()
                dot.identifier = NSUserInterfaceItemIdentifier("activeDisplayDot")
                dot.setAccessibilityElement(false)
                let tiles = DesktopTilesView(frame: NSRect(x: 0, y: 0, width: targetWidth, height: 0))
                tiles.onSelect = { [weak self] in self?.onSelect?($0) }
                tiles.onAdd = { [weak self] in self?.onAdd?(section.snapshot.displayID) }
                tiles.onClose = { [weak self] idToClose in
                    if self?.onClose?(idToClose) == true {
                        self?.handleDesktopClosure(idToClose)
                    }
                }
                tiles.onReorder = { [weak self] in self?.onReorder?($0, $1) }
                tiles.onAppend = { [weak self] in self?.onAppend?($0, $1) }
                tiles.crossDisplayTarget = { [weak self, weak tiles] point in
                    guard let self else { return nil }
                    var target: DesktopTilesView.DropTarget?
                    for row in self.rows where row.tiles !== tiles {
                        let hit = row.tiles.desktopDropTarget(atWindowPoint: point)
                        row.tiles.highlightDesktopDrop(hit)
                        if let hit { target = hit }
                    }
                    return target
                }
                tiles.clearCrossDisplayTarget = { [weak self] animated in
                    self?.rows.forEach { $0.tiles.highlightDesktopDrop(nil, animated: animated) }
                }
                addSubview(label)
                addSubview(dot)
                addSubview(tiles)
                return (id: section.snapshot.displayID, label: label, dot: dot, tiles: tiles)
            }()
            if widthChanged || abs(row.tiles.frame.width - targetWidth) > 0.5 {
                row.tiles.frame.size.width = targetWidth
                row.tiles.needsLayout = true
            }
            row.label.stringValue = section.name
            row.dot.isHidden = !showLabels || section.snapshot.displayID != activeDisplayID
            row.dot.needsDisplay = true
            row.label.textColor = section.snapshot.displayID == activeDisplayID ? .labelColor : .secondaryLabelColor
            row.label.toolTip = section.name
            row.label.isHidden = !showLabels
            row.tiles.update(section.snapshot, enabled: enabled,
                             canAdd: canAdd, canClose: canClose,
                             isActiveDisplay: section.snapshot.displayID == activeDisplayID)
            // Desktop identity survives a monitor move. Seed rebuilt destination
            // controls before drawing rather than waiting for the next scan.
            row.tiles.updateApplicationIcons(applicationIconsBySpace)
            return row
        }
        arrangeSections()
        if widthChanged, let menu = enclosingMenuItem?.menu {
            // Flexible rows retain their expanded frame after AppKit lays them out.
            // Reset every custom row so none imposes the old width on contraction.
            for item in menu.items where item.view !== self {
                item.view?.setFrameSize(NSSize(width: targetWidth, height: item.view?.frame.height ?? 0))
                item.view?.invalidateIntrinsicContentSize()
            }
            menu.update()
            if let window, let previousWindowFrame {
                var targetFrame = window.frame
                targetFrame.size.width = previousWindowFrame.width + targetWidth - previousWidth
                targetFrame.origin.x = previousWindowFrame.maxX - targetFrame.width
                // The menu's scroll view does not normally resize with its
                // tracking window. Keep the native table and its single column
                // attached to the available width, including custom row hosts.
                var ancestor = superview
                while let host = ancestor, host !== window.contentView {
                    host.autoresizingMask.insert(.width)
                    if let table = host as? NSTableView {
                        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
                        for column in table.tableColumns {
                            column.minWidth = 0
                            column.resizingMask = .autoresizingMask
                        }
                    }
                    ancestor = host.superview
                }
                let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                if animate {
                    // AppKit can expand during update but retains the tracking
                    // window's width on shrink. Animate both directions explicitly.
                    var startFrame = targetFrame
                    startFrame.origin.x = previousWindowFrame.minX
                    startFrame.size.width = previousWindowFrame.width
                    window.setFrame(startFrame, display: false)
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.22
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        window.animator().setFrame(targetFrame, display: true)
                    }
                } else {
                    window.setFrame(targetFrame, display: true)
                }
            }
        }
        if let pending = pendingClosureFocus {
            let items = navigationItems()
            if keyboardTarget != .desktop(pending.removed) {
                pendingClosureFocus = nil
            } else if !items.contains(where: { $0.target == .desktop(pending.removed) }) {
                keyboardTarget = .desktop(pending.successor)
                pendingClosureFocus = nil
            }
        }
        if let target = keyboardTarget {
            let items = navigationItems()
            if let match = items.first(where: { $0.target == target }) {
                for item in items { item.setFocused(item.target == target) }
                keyboardSpaceIndex = items.firstIndex { $0.target == target }
                scrollToVisible(match.frame)
            } else if !items.isEmpty {
                let targetIndex = min(items.count - 1, max(0, keyboardSpaceIndex ?? 0))
                let newTarget = items[targetIndex].target
                keyboardTarget = newTarget
                keyboardSpaceIndex = targetIndex
                for item in items { item.setFocused(item.target == newTarget) }
                scrollToVisible(items[targetIndex].frame)
            }
        }
    }

    func updateApplicationIcons(_ icons: [UInt64: [DesktopApplicationIcon]]) {
        applicationIconsBySpace = icons
        rows.forEach { $0.tiles.updateApplicationIcons(icons) }
        arrangeSections()
    }

    func cancelActiveDrag(animated: Bool = false) {
        rows.forEach { $0.tiles.cancelActiveDrag(animated: animated) }
    }

    func cancelVisibilityAnimation() {
        visibilityAnimation?.invalidate()
        visibilityAnimation = nil
        isAnimatingVisibility = false
    }

    func prepareForExpand() {
        if !isAnimatingVisibility || frame.height <= 0.5 {
            cancelVisibilityAnimation()
            isCollapsed = false
            isAnimatingVisibility = true
            wantsLayer = true
            layer?.masksToBounds = true
            alphaValue = 0
            let currentW = bounds.width > 0 ? bounds.width : 190
            let nextFrame = Self.resizedFrame(NSRect(x: frame.minX, y: frame.minY, width: currentW, height: 0),
                                             height: 0,
                                             parentIsFlipped: superview?.isFlipped ?? true)
            preservingMenuTop {
                setFrameOrigin(nextFrame.origin)
                setFrameSize(nextFrame.size)
                invalidateIntrinsicContentSize()
            }
        } else {
            cancelVisibilityAnimation()
            isCollapsed = false
            isAnimatingVisibility = true
            wantsLayer = true
            layer?.masksToBounds = true
        }
    }

    func animateVisibility(expand: Bool, animated: Bool = true, duration: TimeInterval = 0.24,
                           onFrame: (() -> Void)? = nil, completion: (() -> Void)? = nil) {
        cancelVisibilityAnimation()
        isCollapsed = !expand

        let targetHeight = expand ? naturalHeight : 0
        let targetAlpha: CGFloat = expand ? 1.0 : 0.0

        guard animated, duration > 0,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finishImmediateVisibility(targetHeight: targetHeight, targetAlpha: targetAlpha)
            onFrame?()
            completion?()
            return
        }

        let startHeight = frame.height
        let startAlpha = alphaValue

        guard abs(startHeight - targetHeight) > 0.5 || abs(startAlpha - targetAlpha) > 0.05 else {
            finishImmediateVisibility(targetHeight: targetHeight, targetAlpha: targetAlpha)
            onFrame?()
            completion?()
            return
        }

        isAnimatingVisibility = true
        wantsLayer = true
        layer?.masksToBounds = true

        visibilityAnimation = EasedAnimation(view: self, duration: duration) { [weak self] progress, finished in
            guard let self else { return }
            let currentHeight = startHeight + (targetHeight - startHeight) * progress
            let currentAlpha = startAlpha + (targetAlpha - startAlpha) * progress

            let nextFrame = Self.resizedFrame(self.frame, height: currentHeight,
                                             parentIsFlipped: self.superview?.isFlipped ?? true)
            self.alphaValue = currentAlpha
            self.preservingMenuTop {
                self.setFrameOrigin(nextFrame.origin)
                self.setFrameSize(nextFrame.size)
                self.invalidateIntrinsicContentSize()
            }
            onFrame?()

            if finished {
                self.cancelVisibilityAnimation()
                let finalFrame = Self.resizedFrame(self.frame, height: targetHeight,
                                                   parentIsFlipped: self.superview?.isFlipped ?? true)
                self.alphaValue = targetAlpha
                if expand {
                    self.layer?.masksToBounds = false
                }
                self.preservingMenuTop {
                    self.setFrameOrigin(finalFrame.origin)
                    self.setFrameSize(finalFrame.size)
                    self.invalidateIntrinsicContentSize()
                }
                onFrame?()
                completion?()
            }
        }
    }

    private func finishImmediateVisibility(targetHeight: CGFloat, targetAlpha: CGFloat) {
        cancelVisibilityAnimation()
        isCollapsed = (targetHeight == 0)
        let nextFrame = Self.resizedFrame(frame, height: targetHeight,
                                         parentIsFlipped: superview?.isFlipped ?? true)
        alphaValue = targetAlpha
        if targetHeight > 0 {
            layer?.masksToBounds = false
        }
        preservingMenuTop {
            setFrameOrigin(nextFrame.origin)
            setFrameSize(nextFrame.size)
            invalidateIntrinsicContentSize()
        }
    }

    func finishVisibilityTransition(enabled: Bool) {
        let targetHeight = enabled ? naturalHeight : 0
        let targetAlpha: CGFloat = enabled ? 1.0 : 0.0
        finishImmediateVisibility(targetHeight: targetHeight, targetAlpha: targetAlpha)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            // Own the cleanup even if the menu delegate callback is delayed.
            cancelActiveDrag(animated: false)
            cancelVisibilityAnimation()
        }
    }

    fileprivate func arrangeSections() {
        var y: CGFloat = 0
        for row in rows {
            if !row.label.isHidden {
                // Keep a fixed leading dot gutter, including on inactive displays.
                row.label.frame = NSRect(x: 18, y: y + 4,
                                         width: max(0, bounds.width - 22), height: 16)
                row.dot.frame = NSRect(x: 10, y: y + 9, width: 5, height: 5)
                y += 22
            }
            row.tiles.frame.origin = NSPoint(x: 0, y: y)
            row.tiles.frame.size.width = bounds.width
            row.tiles.layoutSubtreeIfNeeded()
            y += row.tiles.frame.height
        }
        guard !isAnimatingVisibility else { return }
        let targetY = isCollapsed ? 0 : y
        if frame.height != targetY {
            // Menu-hosted views may live in an unflipped superview. Changing
            // only the height there grows the grid upward over the prior item.
            // Preserve its top edge while adding or removing a preview row.
            let nextFrame = Self.resizedFrame(frame, height: targetY,
                                             parentIsFlipped: superview?.isFlipped ?? true)
            preservingMenuTop {
                setFrameOrigin(nextFrame.origin)
                setFrameSize(nextFrame.size)
                invalidateIntrinsicContentSize()
            }
        }
    }

    /// Changes this view's height without moving the menu's top edge. A
    /// menu-bar menu resizes its window around a fixed bottom edge, so every
    /// height step would otherwise slide the whole menu, including the current
    /// desktop and the status header, away from the menu bar.
    private func preservingMenuTop(_ change: () -> Void) {
        let menuTop = window?.frame.maxY
        change()
        guard let window, let menuTop, abs(window.frame.maxY - menuTop) > 0.25 else { return }
        // A growing menu must still fit above the bottom of the screen.
        let lowestTop = (window.screen?.visibleFrame.minY ?? -.greatestFiniteMagnitude) + window.frame.height
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: max(menuTop, lowestTop)))
    }

    static func resizedFrame(_ frame: NSRect, height: CGFloat, parentIsFlipped: Bool) -> NSRect {
        NSRect(x: frame.minX,
               y: parentIsFlipped ? frame.minY : frame.maxY - height,
               width: frame.width, height: height)
    }

    override func layout() {
        super.layout()
        arrangeSections()
    }
}

final class DesktopTilesView: NSView {
    private var numberLabelYOffset: CGFloat {
        DesktopNumberStylePreference.labelYOffset
    }
    fileprivate var navigationTiles: [(id: UInt64, button: DesktopTileButton)] {
        Array(zip(desktopIDs, buttons)).map { (id: $0.0, button: $0.1) }
    }
    fileprivate var addNavigationButton: DesktopAddButton? {
        !addButton.isHidden ? addButton : nil
    }
    struct DropTarget: Equatable {
        let id: UInt64
        var after = false
    }
    var crossDisplayTarget: ((NSPoint) -> DropTarget?)?
    var clearCrossDisplayTarget: ((Bool) -> Void)?

    func desktopDropTarget(atWindowPoint point: NSPoint) -> DropTarget? {
        guard hoverEnabled else { return nil }
        let local = convert(point, from: nil)
        if externalDropTarget != nil {
            guard bounds.contains(local) else { return nil }
            // Use the row capacity that existed before this drag. NSMenu does
            // not support changing a custom item's size while it is tracking.
            let heights = previewRowHeights
            let capacity = heights.count * columns
            let slots = Self.tileFrames(count: min(desktopIDs.count + 2, capacity),
                                        width: bounds.width, heights: heights)
            if let index = slots.firstIndex(where: { $0.contains(local) }),
               desktopIDs.indices.contains(index) {
                return DropTarget(id: desktopIDs[index])
            }
            if let last = lastManagedSpaceID,
               slots.dropFirst(desktopIDs.count).contains(where: { $0.contains(local) }) {
                return DropTarget(id: last, after: true)
            }
            return externalDropTarget
        }
        if addButton.frame.contains(local), let last = lastManagedSpaceID {
            return DropTarget(id: last, after: true)
        }
        guard let index = dragSlots.firstIndex(where: { $0.contains(local) }),
              desktopIDs.indices.contains(index) else { return nil }
        return DropTarget(id: desktopIDs[index])
    }

    func highlightDesktopDrop(_ identifier: DropTarget?, animated: Bool = true) {
        guard externalDropTarget != identifier else { return }
        externalDropTarget = identifier
        closeContainer.isHidden = true
        if identifier != nil { addButton.setHovered(false, animated: false) }
        applyExternalShuffle(animated: animated)
    }

    func cancelActiveDrag(animated: Bool = false) {
        gestureGeneration &+= 1
        pendingDropGeneration &+= 1
        pressedDesktopID = nil
        mouseDownLocationInWindow = nil
        desktopDragStarted = false
        if dragSourceID != nil {
            finishReorder(cancelled: true, animated: animated)
        }
    }
    private var externalDropTarget: DropTarget?
    private var externalLayoutWidth: CGFloat = 0
    private var externalLayoutHeights: [CGFloat] = []

    private var previewRowHeights: [CGFloat] {
        var heights = rowHeights
        // Resting capacity includes every desktop and the plus button. External
        // drag previews must fit inside this geometry instead of growing NSMenu.
        let cellCount = buttons.count + 1
        if !buttons.isEmpty && cellCount > heights.count * columns {
            // A plus-only row has no application icons to accommodate. Do not
            // inherit the expanded height of a populated desktop in another row.
            heights.append(28)
        }
        return heights
    }

    private func applyExternalShuffle(animated: Bool) {
        guard dragSlots.count == buttons.count else { return }
        let insertion = externalDropTarget.flatMap { target in
            desktopIDs.firstIndex(of: target.id).map { $0 + (target.after ? 1 : 0) }
        }
        let heights = previewRowHeights
        let requestedCellCount = buttons.count + (insertion == nil ? 1 : 2)
        let hidesAddButton = requestedCellCount > heights.count * columns
        let visibleCellCount = requestedCellCount - (hidesAddButton ? 1 : 0)
        externalLayoutWidth = bounds.width
        externalLayoutHeights = heights
        let slots = Self.tileFrames(count: visibleCellCount, width: bounds.width, heights: heights)
        addButton.isHidden = desktopIDs.isEmpty || hidesAddButton
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.18 : 0
            for index in buttons.indices {
                let slot = index + ((insertion.map { index >= $0 } ?? false) ? 1 : 0)
                let frame = slots[slot]
                let labelMinX = max(0, frame.minX - 4)
                let labelWidth = min(bounds.width - labelMinX, frame.width + 8)
                let label = NSRect(x: labelMinX, y: frame.maxY + numberLabelYOffset, width: labelWidth, height: 20)
                if context.duration > 0 {
                    buttons[index].animator().frame = frame
                    numberLabels[index].animator().frame = label
                } else {
                    buttons[index].frame = frame
                    numberLabels[index].frame = label
                }
            }
            if !addButton.isHidden, let last = slots.last {
                if context.duration > 0 { addButton.animator().frame = last }
                else { addButton.frame = last }
            }
        }
    }

    /// Horizontal distance between neighboring tile slots.
    static let tilePitch: CGFloat = 44

    static func tileFrames(count: Int, width: CGFloat, heights: [CGFloat]) -> [NSRect] {
        let cols = width >= 220 ? 5 : 4
        let tileWidth: CGFloat = 36
        let pitch = tilePitch
        let margin = cols == 5 ? 10 : max(8, floor((width - CGFloat(cols - 1) * pitch - tileWidth) / 2))
        return (0..<count).map { index in
            let row = index / cols, column = index % cols
            return NSRect(x: margin + CGFloat(column) * pitch,
                          y: 8 + heights.prefix(row).reduce(0) { $0 + $1 + 26 },
                          width: tileWidth, height: heights[row])
        }
    }
    var onSelect: ((UInt64) -> Void)?
    var onAdd: (() -> Void)?
    var onClose: ((UInt64) -> Void)?
    var onReorder: ((UInt64, UInt64) -> Void)?
    var onAppend: ((UInt64, UInt64) -> Void)?
    private var dragAppends = false
    private var dragSourceID: UInt64?
    private var dragTargetID: UInt64?
    private var dragOriginalIDs: [UInt64] = []
    private var dragSlots: [NSRect] = []
    private var previewOrder: [UInt64] = []
    private var pendingDropGeneration: UInt = 0
    private let dragPreview = DesktopDragPreview()
    private let addButton = DesktopAddButton()
    private var portalExitButton: NSView?
    private var heightAnimation: EasedAnimation?

    private func cancelHeightAnimation() {
        heightAnimation?.invalidate()
        heightAnimation = nil
    }
    private let closeButton = NSButton()
    private var closeContainer = NSView()
    private var hoverArea: NSTrackingArea?
    private var hoveredID: UInt64?
    private var hoveredIndex: Int?
    private var closingEnabled = false
    private var hoverEnabled = false
    private var desktopIDs: [UInt64] = []
    private var latestSnapshot: DesktopSelectionSnapshot?
    private var applicationIconsBySpace: [UInt64: [DesktopApplicationIcon]] = [:]
    private var buttons: [DesktopTileButton] = []
    internal private(set) var numberLabels: [NSTextField] = []
    private var pressedDesktopID: UInt64?
    private var mouseDownLocationInWindow: NSPoint?
    private var desktopDragStarted = false
    private var gestureGeneration: UInt = 0
    private var animationGeneration: UInt = 0
    private var columns: Int { bounds.width >= 220 ? 5 : 4 }
    private var isAnimatingChange = false
    private var viewsPendingRemoval: [NSView] = []

    private var lastManagedSpaceID: UInt64? { desktopIDs.last }

    var hasActiveDesktopGesture: Bool {
        // One row owns the complete pointer sequence. Child buttons must not
        // split a drag when the pointer crosses a neighboring desktop tile.
        pressedDesktopID != nil || dragSourceID != nil
    }

    // MARK: - Keyboard Selection Indicator
    func updateFocusForTile(_ button: DesktopTileButton, focused: Bool) {
        guard let index = buttons.firstIndex(of: button),
              numberLabels.indices.contains(index),
              let labelCell = numberLabels[index].cell as? DesktopLabelCell else { return }
        labelCell.isKeyboardSelected = focused
        if !button.representsFullscreenSpace {
            let isBold = (focused && labelCell.indicatorStyle == .accentPill) || button.state == .on
            numberLabels[index].font = .monospacedDigitSystemFont(
                ofSize: isBold ? 12 : 11,
                weight: isBold ? .bold : .medium
            )
        }
        numberLabels[index].needsDisplay = true
        if !closeContainer.isHidden, let hoveredIndex, buttons.indices.contains(hoveredIndex) {
            let tile = buttons[hoveredIndex].frame
            let isFocused = buttons[hoveredIndex].isKeyboardFocused
            let xOffset: CGFloat = isFocused ? -(tile.width * 0.04) : 0
            let yOffset: CGFloat = isFocused ? -(tile.height * 0.04) : 0
            closeContainer.frame = NSRect(x: tile.minX - 7 + xOffset, y: tile.minY - 7 + yOffset, width: 12, height: 12)
            closeContainer.layer?.zPosition = 100
            if subviews.last !== closeContainer {
                addSubview(closeContainer, positioned: .above, relativeTo: nil)
            }
        }
    }

    func clearKeyboardFocusSelection() {
        for (index, label) in numberLabels.enumerated() {
            if let cell = label.cell as? DesktopLabelCell {
                cell.isKeyboardSelected = false
            }
            if buttons.indices.contains(index) && !buttons[index].representsFullscreenSpace {
                let isBold = buttons[index].state == .on
                label.font = .monospacedDigitSystemFont(
                    ofSize: isBold ? 12 : 11,
                    weight: isBold ? .bold : .medium
                )
            }
            label.needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Desktop Manager")
        wantsLayer = true
        layer?.masksToBounds = false
        addButton.bezelStyle = .regularSquare
        addButton.isBordered = false
        addButton.setButtonType(.momentaryPushIn)
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add desktop")
        addButton.imagePosition = .imageOnly
        addButton.title = ""
        addButton.target = self
        addButton.action = #selector(addDesktop)
        addButton.setAccessibilityLabel("Add desktop")
        addButton.isHidden = true
        addSubview(addButton)
        closeButton.title = ""
        closeButton.identifier = NSUserInterfaceItemIdentifier("desktopClose")
        closeButton.isBordered = false
        closeButton.setButtonType(.momentaryPushIn)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close desktop")?
            .withSymbolConfiguration(.init(pointSize: 6, weight: .heavy))
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .labelColor
        closeButton.target = self
        closeButton.action = #selector(closeDesktop)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 6
            glass.tintColor = .systemRed
            if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
            glass.wantsLayer = true
            glass.layer?.cornerRadius = 6
            glass.layer?.masksToBounds = true
            glass.layer?.backgroundColor = NSColor.systemRed.cgColor
            glass.layer?.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor
            glass.layer?.borderWidth = 0.5
            glass.layer?.zPosition = 100
            glass.contentView = closeButton
            closeContainer = glass
        } else {
            closeContainer.wantsLayer = true
            closeContainer.layer?.cornerRadius = 6
            closeContainer.layer?.masksToBounds = true
            closeContainer.layer?.backgroundColor = NSColor.systemRed.cgColor
            closeContainer.layer?.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor
            closeContainer.layer?.borderWidth = 0.5
            closeContainer.layer?.zPosition = 100
            closeContainer.addSubview(closeButton)
        }
        closeButton.wantsLayer = true
        closeButton.layer?.zPosition = 100
        closeContainer.identifier = NSUserInterfaceItemIdentifier("desktopCloseContainer")
        closeContainer.isHidden = true
        addSubview(closeContainer)
        dragPreview.isHidden = true
        dragPreview.alphaValue = 0.85
        addSubview(dragPreview)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshAccentColors),
            name: NSColor.systemColorsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cancelHeightAnimation()
            portalExitButton?.removeFromSuperview()
            portalExitButton = nil
            isAnimatingChange = false
            addButton.alphaValue = 1.0
            clearKeyboardFocusSelection()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        numberLabels.forEach { $0.needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        gestureGeneration &+= 1
        pressedDesktopID = nil
        mouseDownLocationInWindow = nil
        desktopDragStarted = false

        let point = convert(event.locationInWindow, from: nil)
        guard let index = buttons.firstIndex(where: { $0.frame.contains(point) }) else { return }
        pressedDesktopID = desktopIDs[index]
        mouseDownLocationInWindow = event.locationInWindow
        closeContainer.isHidden = true
        addButton.setHovered(false, animated: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let source = pressedDesktopID,
              let origin = mouseDownLocationInWindow,
              let index = desktopIDs.firstIndex(of: source),
              buttons.indices.contains(index), buttons[index].canReorder else { return }
        let beginning = !desktopDragStarted
        if beginning,
           hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) < 5 {
            return
        }
        desktopDragStarted = true
        trackReorder(buttons[index], event: event, beginning: beginning)
    }

    override func mouseUp(with event: NSEvent) {
        desktopInteractionTrace("row mouseUp received")
        guard let source = pressedDesktopID else { return }
        let completedDrag = desktopDragStarted
        let generation = gestureGeneration
        pressedDesktopID = nil
        mouseDownLocationInWindow = nil
        desktopDragStarted = false

        if completedDrag {
            // Let AppKit finish delivering the physical release, but stay in
            // NSMenu's tracking mode so completion cannot wait for menu close.
            RunLoop.main.perform(inModes: [.eventTracking, .default]) { [weak self] in
                guard let self, self.gestureGeneration == generation else { return }
                desktopInteractionTrace("row release completion")
                self.finishReorder(cancelled: self.window == nil)
            }
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        guard let index = desktopIDs.firstIndex(of: source),
              buttons.indices.contains(index),
              buttons[index].frame.contains(point), buttons[index].isEnabled else { return }
        selectDesktop(buttons[index])
    }

    private var isActiveDisplay = true

    private func createTileButton(index: Int, identifier: UInt64, applicationIcons: [DesktopApplicationIcon]) -> (DesktopTileButton, NSTextField) {
        let button = DesktopTileButton(title: "\(index + 1)", target: self, action: #selector(selectDesktop(_:)))
        button.applicationIcons = applicationIcons
        let names = button.applicationIcons.map(\.name).joined(separator: ", ")
        button.toolTip = names.isEmpty ? "Desktop \(index + 1)" : "Desktop \(index + 1): \(names)"
        button.cell = DesktopTileCell(textCell: "\(index + 1)")
        button.target = self
        button.action = #selector(selectDesktop(_:))
        button.tag = index
        // The manager draws its own active, hover, drop, and keyboard-focus
        // indicators. Suppress AppKit's square button bezel so idle desktops
        // do not sit on a permanent blue-tinted background.
        button.isBordered = false
        button.setButtonType(.pushOnPushOff)
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.setAccessibilityLabel("Desktop \(index + 1)")

        let label = DesktopNumberLabel(labelWithString: "\(index + 1)")
        label.wantsLayer = true
        label.cell = DesktopLabelCell(textCell: "\(index + 1)")
        label.isBordered = false
        label.isEditable = false
        label.drawsBackground = false
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.cell?.wraps = true
        label.cell?.usesSingleLineMode = false
        label.setAccessibilityElement(false)
        button.hoverStateChanged = { [weak label] isHovered in
            (label?.cell as? DesktopLabelCell)?.isDesktopHovered = isHovered
        }
        return (button, label)
    }

    private func updateButtonProperties(snapshot: DesktopSelectionSnapshot?, ids: [UInt64],
                                        enabled: Bool, canAdd: Bool, canClose: Bool) {
        let currentID = snapshot?.currentID
        let activeTileIndex = currentID.flatMap { id in
            ids.firstIndex(of: id) ?? snapshot?.associatedDesktopIndex(for: id)
        }

        for (index, button) in buttons.enumerated() {
            button.tag = index
            let isCurrent = index == activeTileIndex
            button.state = isCurrent ? .on : .off
            button.belongsToActiveDisplay = isActiveDisplay
            updateVisualState(at: index, snapshot: snapshot)

            // A current Space on another display remains a navigation target so
            // selecting it can transfer the pointer without changing Spaces.
            button.interactionBlocked = !enabled
            // Temporary work blocks input, not the tile's native appearance.
            button.isEnabled = true
            button.canReorder = enabled
                && !button.representsFullscreenSpace
                && (snapshot?.desktopIDs.count ?? 0) > 1
            // Keep the app inventory tooltip intact across status refreshes.
            if button.toolTip == nil { button.toolTip = "Desktop \(index + 1)" }
        }
        addButton.isHidden = ids.isEmpty
        if addButton.isHidden { addButton.setHovered(false, animated: false) }
        hoverEnabled = enabled
        let hasClosableDesktops = (snapshot?.desktopIDs.count ?? 0) > 1 || !(snapshot?.fullscreenSpaceIDs.isEmpty ?? true)
        closingEnabled = enabled && canClose && hasClosableDesktops
        closeButton.isEnabled = closingEnabled
        if !closingEnabled { closeContainer.isHidden = true }
        addButton.interactionBlocked = !enabled
        addButton.isEnabled = canAdd && !ids.isEmpty
        if !addButton.isEnabled { addButton.setHovered(false, animated: false) }
        addButton.toolTip = canAdd ? "Add a new desktop" : "Desktop creation is unavailable on this macOS version"
    }

    func update(_ snapshot: DesktopSelectionSnapshot?, enabled: Bool, canAdd: Bool = true, canClose: Bool = false,
                isActiveDisplay: Bool = true) {
        self.isActiveDisplay = isActiveDisplay
        latestSnapshot = snapshot
        let ids = snapshot?.managerSpaceIDs ?? []
        if dragSourceID == nil && enabled { previewOrder = [] }

        if isAnimatingChange {
            if ids != desktopIDs { cancelReflowAnimations() }
            if ids == desktopIDs {
                updateButtonProperties(snapshot: snapshot, ids: ids, enabled: enabled, canAdd: canAdd, canClose: canClose)
                needsLayout = true
                layoutSubtreeIfNeeded()
                return
            }
            animationGeneration &+= 1
            cancelHeightAnimation()
            if !viewsPendingRemoval.isEmpty {
                viewsPendingRemoval.forEach { $0.removeFromSuperview() }
                viewsPendingRemoval.removeAll()
            }
            portalExitButton?.removeFromSuperview()
            portalExitButton = nil
            isAnimatingChange = false
        } else {
            cancelHeightAnimation()
            if !viewsPendingRemoval.isEmpty {
                viewsPendingRemoval.forEach { $0.removeFromSuperview() }
                viewsPendingRemoval.removeAll()
            }
            portalExitButton?.removeFromSuperview()
            portalExitButton = nil
        }

        if ids != desktopIDs && Set(ids) == Set(desktopIDs) {
            // Preserve the controls participating in NSMenu's mouse tracking.
            // A reorder changes their positions, not their view identities.
            let existing = Dictionary(uniqueKeysWithValues: desktopIDs.enumerated().map {
                ($0.element, (buttons[$0.offset], numberLabels[$0.offset]))
            })
            if dragSourceID != nil { finishReorder(cancelled: true) }
            previewOrder = []
            buttons = ids.compactMap { existing[$0]?.0 }
            numberLabels = ids.compactMap { existing[$0]?.1 }
            desktopIDs = ids
            updateButtonProperties(snapshot: snapshot, ids: ids, enabled: enabled, canAdd: canAdd, canClose: canClose)
            refreshRowHeights()
            needsLayout = true
        } else if ids != desktopIDs {
            let isInitialSetup = desktopIDs.isEmpty
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let hasContinuity = !desktopIDs.isEmpty && !Set(desktopIDs).isDisjoint(with: Set(ids))
            let shouldAnimate = window != nil && !isInitialSetup && !ids.isEmpty && !reduceMotion && hasContinuity

            let previousIcons = Dictionary(uniqueKeysWithValues: zip(desktopIDs, buttons.map(\.applicationIcons)))
            finishReorder(cancelled: true)
            hoveredID = nil
            hoveredIndex = nil
            closeContainer.isHidden = true

            if !shouldAnimate {
                buttons.forEach { $0.removeFromSuperview() }
                numberLabels.forEach { $0.removeFromSuperview() }
                buttons = []
                numberLabels = []
                desktopIDs = ids
                for (index, identifier) in ids.enumerated() {
                    let (button, label) = createTileButton(index: index, identifier: identifier, applicationIcons: previousIcons[identifier] ?? [])
                    buttons.append(button)
                    numberLabels.append(label)
                    addSubview(button)
                    addSubview(label)
                }
                updateButtonProperties(snapshot: snapshot, ids: ids, enabled: enabled, canAdd: canAdd, canClose: canClose)
                refreshRowHeights()
                needsLayout = true
            } else {
                animationGeneration &+= 1
                let currentAnimGen = animationGeneration
                let oldPlusFrame = addButton.frame
                self.isAnimatingChange = true

                let oldIDs = desktopIDs
                let newIDs = ids
                let existingButtons = Dictionary(uniqueKeysWithValues: zip(oldIDs, buttons))
                let existingLabels = Dictionary(uniqueKeysWithValues: zip(oldIDs, numberLabels))
                let removedIDs = Set(oldIDs).subtracting(newIDs)
                let isDeletionOnly = Self.isDeletionOnly(from: oldIDs, to: newIDs)
                let isInsertionOnly = Self.isInsertionOnly(from: oldIDs, to: newIDs)
                let usesConveyor = isDeletionOnly || isInsertionOnly

                var newButtons: [DesktopTileButton] = []
                var newLabels: [NSTextField] = []
                var newAddedButtons: [(DesktopTileButton, NSTextField)] = []

                for (index, identifier) in newIDs.enumerated() {
                    if let button = existingButtons[identifier], let label = existingLabels[identifier] {
                        newButtons.append(button)
                        newLabels.append(label)
                    } else {
                        let (button, label) = createTileButton(index: index, identifier: identifier, applicationIcons: previousIcons[identifier] ?? [])
                        button.alphaValue = 0
                        label.alphaValue = 0
                        addSubview(button)
                        addSubview(label)
                        newButtons.append(button)
                        newLabels.append(label)
                        newAddedButtons.append((button, label))
                    }
                }

                var viewsToRemove: [NSView] = []
                for identifier in removedIDs {
                    if let button = existingButtons[identifier] { viewsToRemove.append(button) }
                    if let label = existingLabels[identifier] { viewsToRemove.append(label) }
                }

                self.buttons = newButtons
                self.numberLabels = newLabels
                self.desktopIDs = newIDs
                self.viewsPendingRemoval = viewsToRemove

                updateButtonProperties(snapshot: snapshot, ids: ids, enabled: enabled, canAdd: canAdd, canClose: canClose)

                // A tile changing rows leaves a copy to finish sliding off its
                // old row. The copy is made after renumbering, so it carries the
                // same number as the tile arriving in the other row and never
                // repeats the number of the neighbor that takes its place.
                var departingCopies: [Int: [NSView]] = [:]
                if usesConveyor {
                    let columns = self.columns
                    for (newIndex, identifier) in newIDs.enumerated() {
                        guard let oldIndex = oldIDs.firstIndex(of: identifier),
                              oldIndex / columns != newIndex / columns,
                              let button = existingButtons[identifier],
                              let label = existingLabels[identifier] else { continue }
                        departingCopies[newIndex] = [Self.replica(of: button), Self.snapshot(of: label)].compactMap { $0 }
                    }
                }

                let heights = previewRowHeights
                let targetFrames = Self.tileFrames(count: newButtons.count + 1, width: bounds.width, heights: heights)

                let labelYOffset = numberLabelYOffset
                for (button, label) in newAddedButtons {
                    if let index = newButtons.firstIndex(of: button) {
                        let targetFrame = targetFrames[index]
                        button.frame = targetFrame
                        let labelMinX = max(0, targetFrame.minX - 4)
                        let labelWidth = min(bounds.width - labelMinX, targetFrame.width + 8)
                        label.frame = NSRect(x: labelMinX, y: targetFrame.maxY + labelYOffset, width: labelWidth, height: 20)
                    }
                }

                let targetPlusFrame = targetFrames.last ?? addButton.frame

                let isAddRowWrap = !addButton.isHidden
                    && newButtons.count > oldIDs.count
                    && oldPlusFrame.width > 0
                    && oldPlusFrame.minY < targetPlusFrame.minY
                    && oldPlusFrame.minX > targetPlusFrame.minX

                let isRemoveRowWrap = !addButton.isHidden
                    && newButtons.count < oldIDs.count
                    && oldPlusFrame.width > 0
                    && oldPlusFrame.minY > targetPlusFrame.minY
                    && oldPlusFrame.minX < targetPlusFrame.minX

                let isRowWrap = isAddRowWrap || isRemoveRowWrap

                if isRowWrap {
                    let exit = DesktopAddButton(frame: oldPlusFrame)
                    exit.bezelStyle = addButton.bezelStyle
                    exit.setButtonType(.momentaryPushIn)
                    exit.image = addButton.image
                    exit.imagePosition = addButton.imagePosition
                    exit.title = ""
                    exit.isEnabled = false
                    exit.setAccessibilityElement(false)
                    exit.setHovered(false, animated: false)
                    addSubview(exit)
                    self.portalExitButton = exit
                    addButton.setHovered(false, animated: false)

                    // The conveyor slides the add button between rows; other
                    // changes crossfade it in place.
                    if !usesConveyor {
                        let exitFade = CABasicAnimation(keyPath: "opacity")
                        exitFade.fromValue = 1.0
                        exitFade.toValue = 0.0
                        exitFade.duration = 0.24
                        exitFade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        exitFade.preferredFrameRateRange = .fullRefresh(for: self)
                        exit.layer?.add(exitFade, forKey: "crossfadeExit")
                        exit.layer?.opacity = 0.0

                        addButton.layer?.removeAllAnimations()
                        addButton.frame = targetPlusFrame

                        let enterFade = CABasicAnimation(keyPath: "opacity")
                        enterFade.fromValue = 0.0
                        enterFade.toValue = 1.0
                        enterFade.duration = 0.26
                        enterFade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        enterFade.preferredFrameRateRange = .fullRefresh(for: self)
                        addButton.layer?.add(enterFade, forKey: "crossfadeEnter")
                        addButton.layer?.opacity = 1.0
                        addButton.alphaValue = 1.0
                    }
                }

                if usesConveyor {
                    animateHeight(to: expectedHeight, duration: 0.34)
                    animateConveyor(
                        isInsertion: isInsertionOnly,
                        changedViews: isInsertionOnly ? newAddedButtons.flatMap { [$0.0, $0.1] } : viewsToRemove,
                        tiles: Array(zip(newButtons, newLabels)),
                        targetFrames: targetFrames,
                        targetPlusFrame: targetPlusFrame,
                        plusExit: isRowWrap ? portalExitButton : nil,
                        departingCopies: departingCopies,
                        generation: currentAnimGen
                    )
                    return
                }

                let groupDuration: TimeInterval = isRowWrap ? 0.26 : 0.22
                animateHeight(to: expectedHeight, duration: groupDuration)

                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = groupDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    context.allowsImplicitAnimation = true

                    for view in viewsToRemove {
                        view.animator().alphaValue = 0
                    }

                    for (index, button) in newButtons.enumerated() {
                        let targetFrame = targetFrames[index]
                        button.animator().frame = targetFrame
                        newLabels[index].animator().frame = self.labelFrame(for: targetFrame)
                        button.animator().alphaValue = 1
                        newLabels[index].animator().alphaValue = 1
                    }

                    if !isRowWrap {
                        addButton.animator().frame = targetPlusFrame
                        addButton.animator().alphaValue = 1.0
                    }
                }, completionHandler: { [weak self] in
                    guard let self, self.animationGeneration == currentAnimGen else { return }
                    self.finishChangeAnimation(targetPlusFrame: targetPlusFrame)
                })
            }
        } else {
            updateButtonProperties(snapshot: snapshot, ids: ids, enabled: enabled, canAdd: canAdd, canClose: canClose)
            refreshRowHeights()
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    static func isDeletionOnly(from previous: [UInt64], to current: [UInt64]) -> Bool {
        guard current.count < previous.count else { return false }
        let surviving = Set(current)
        return previous.filter { surviving.contains($0) } == current
    }

    static func isInsertionOnly(from previous: [UInt64], to current: [UInt64]) -> Bool {
        isDeletionOnly(from: current, to: previous)
    }

    private func labelFrame(for tileFrame: NSRect) -> NSRect {
        let labelMinX = max(0, tileFrame.minX - 4)
        let labelWidth = min(bounds.width - labelMinX, tileFrame.width + 8)
        return NSRect(x: labelMinX, y: tileFrame.maxY + numberLabelYOffset, width: labelWidth, height: 20)
    }

    private static let reflowKey = "desktopReflow"
    private static let reflowOpacityKey = "desktopReflowOpacity"

    /// Desktops move like a conveyor. A removed desktop shrinks and fades in
    /// place while every tile after it glides one slot back. An added desktop
    /// grows into the slot that opens as every tile after it glides one slot
    /// forward. A tile or the add button that changes rows keeps sliding off
    /// the edge of its old row as a copy while the real one slides in from the
    /// opposite edge of its new row. Both halves run together, so no slot is
    /// ever empty and nothing crosses the grid diagonally.
    private func animateConveyor(
        isInsertion: Bool,
        changedViews: [NSView],
        tiles: [(DesktopTileButton, NSTextField)],
        targetFrames: [NSRect],
        targetPlusFrame: NSRect,
        plusExit: NSView?,
        departingCopies: [Int: [NSView]],
        generation: UInt
    ) {
        struct Move {
            let views: [NSView]
            let targets: [NSRect]
            let copies: [NSView]
            var changesRow: Bool { !copies.isEmpty }
        }
        var moves: [Move] = []
        for (index, (button, label)) in tiles.enumerated() {
            let target = targetFrames[index]
            guard !button.frame.equalTo(target) else { continue }
            moves.append(Move(views: [button, label], targets: [target, labelFrame(for: target)],
                              copies: departingCopies[index] ?? []))
        }
        if !addButton.frame.equalTo(targetPlusFrame) {
            moves.append(Move(views: [addButton], targets: [targetPlusFrame], copies: plusExit.map { [$0] } ?? []))
        }
        // The tile moving into the change goes first. After an insertion that is
        // the far end, so every slot empties before its next occupant arrives.
        if isInsertion { moves.reverse() }

        let frameRate = CAFrameRateRange.fullRefresh(for: self)
        // A gentle ripple, capped so long grids still settle promptly.
        let stagger: CFTimeInterval = min(0.025, 0.14 / CFTimeInterval(max(1, moves.count - 1)))
        // A closed tile is nearly gone before its successor arrives, so the two
        // never overlap semi-transparently. An added tile arrives as the tile
        // leaving its slot clears it.
        let firstDelay: CFTimeInterval = isInsertion ? 0 : 0.08
        let arrivalDelay = stagger * CFTimeInterval(max(0, moves.count - 1)) + 0.1
        // Tiles move back after a deletion and forward after an insertion.
        let exitOffset = isInsertion ? Self.tilePitch : -Self.tilePitch
        let entry: ReflowMotion = isInsertion ? .enterFromLeadingEdge : .enterFromTrailingEdge

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.animationGeneration == generation else { return }
                self.finishChangeAnimation(targetPlusFrame: targetPlusFrame)
            }
        }

        for view in changedViews {
            if isInsertion {
                appear(view, delay: arrivalDelay, frameRate: frameRate)
            } else {
                disappear(view, frameRate: frameRate)
            }
        }

        for (step, move) in moves.enumerated() {
            // After a deletion, a tile entering from the row's edge starts a
            // little earlier so it arrives as the closed tile fades, leaving no
            // empty frame between.
            let delay = firstDelay + stagger * CFTimeInterval(step) - (move.changesRow && !isInsertion ? 0.04 : 0)
            for copy in move.copies {
                if copy.superview == nil {
                    addSubview(copy, positioned: .below, relativeTo: closeContainer)
                    viewsPendingRemoval.append(copy)
                }
                slideOff(copy, by: exitOffset, delay: delay, frameRate: frameRate)
            }
            for (view, target) in zip(move.views, move.targets) {
                reflow(view, to: target, delay: delay, motion: move.changesRow ? entry : .glide, frameRate: frameRate)
            }
        }
        CATransaction.commit()
    }

    /// A transform that scales a layer about its center.
    private static func centeredScale(_ scale: CGFloat, in bounds: NSRect) -> CATransform3D {
        CATransform3DMakeAffineTransform(
            CGAffineTransform(translationX: bounds.width / 2, y: bounds.height / 2)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -bounds.width / 2, y: -bounds.height / 2)
        )
    }

    /// Shrinks a closed tile and fades it and its label out in place.
    private func disappear(_ view: NSView, frameRate: CAFrameRateRange) {
        guard let layer = view.layer else { return }
        let duration: CFTimeInterval = 0.16
        layer.removeAllAnimations()
        layer.zPosition = -1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.opacity
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.preferredFrameRateRange = frameRate
        layer.add(fade, forKey: Self.reflowOpacityKey)
        layer.opacity = 0
        guard view is DesktopTileButton else { return }
        let shrunk = Self.centeredScale(0.85, in: view.bounds)
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = layer.transform
        shrink.toValue = shrunk
        shrink.duration = duration
        shrink.timingFunction = CAMediaTimingFunction(name: .easeOut)
        shrink.preferredFrameRateRange = frameRate
        layer.add(shrink, forKey: Self.reflowKey)
        layer.transform = shrunk
    }

    /// Grows a new tile and fades it and its label in place.
    private func appear(_ view: NSView, delay: CFTimeInterval, frameRate: CAFrameRateRange) {
        view.alphaValue = 1
        guard let layer = view.layer else { return }
        let beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.22
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        var animations: [(CABasicAnimation, String)] = [(fade, Self.reflowOpacityKey)]
        if view is DesktopTileButton {
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = Self.centeredScale(0.85, in: view.bounds)
            grow.toValue = CATransform3DIdentity
            grow.duration = 0.3
            grow.timingFunction = Self.reflowTiming
            animations.append((grow, Self.reflowKey))
        }
        for (animation, key) in animations {
            animation.beginTime = beginTime
            animation.fillMode = .backwards
            animation.preferredFrameRateRange = frameRate
            layer.add(animation, forKey: key)
        }
    }

    private enum ReflowMotion {
        /// Slides from the current position to the new slot.
        case glide
        /// Slides one slot in from the row's trailing edge while fading in.
        case enterFromTrailingEdge
        /// Slides one slot in from the row's leading edge while fading in.
        case enterFromLeadingEdge
    }

    private static let reflowDuration: CFTimeInterval = 0.36
    private static let reflowTiming = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)

    /// Moves a view's model frame immediately and animates its layer there.
    private func reflow(_ view: NSView, to target: NSRect, delay: CFTimeInterval, motion: ReflowMotion,
                        frameRate: CAFrameRateRange) {
        guard let layer = view.layer else {
            view.frame = target
            return
        }
        let start = layer.presentation()?.position ?? layer.position
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            view.frame = target
        }
        let end = layer.position
        guard start != end else { return }
        let beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay

        let slide = CABasicAnimation(keyPath: "position")
        slide.toValue = end
        slide.duration = Self.reflowDuration
        slide.timingFunction = Self.reflowTiming
        slide.beginTime = beginTime
        slide.fillMode = .backwards
        slide.preferredFrameRateRange = frameRate

        switch motion {
        case .glide:
            slide.fromValue = start
            layer.add(slide, forKey: Self.reflowKey)
        case .enterFromTrailingEdge, .enterFromLeadingEdge:
            let offset = motion == .enterFromTrailingEdge ? Self.tilePitch : -Self.tilePitch
            slide.fromValue = CGPoint(x: end.x + offset, y: end.y)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.26
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fade.beginTime = beginTime
            fade.fillMode = .backwards
            fade.preferredFrameRateRange = frameRate
            layer.add(slide, forKey: Self.reflowKey)
            layer.add(fade, forKey: Self.reflowOpacityKey)
        }
    }

    /// Carries a departing copy one slot past the edge of its old row.
    private func slideOff(_ snapshot: NSView, by offset: CGFloat, delay: CFTimeInterval, frameRate: CAFrameRateRange) {
        guard let layer = snapshot.layer else { return }
        layer.zPosition = -0.5
        let start = layer.position
        let beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        let slide = CABasicAnimation(keyPath: "position")
        slide.fromValue = start
        slide.toValue = CGPoint(x: start.x + offset, y: start.y)
        slide.duration = Self.reflowDuration
        slide.timingFunction = Self.reflowTiming
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.26
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        for animation in [slide, fade] {
            animation.beginTime = beginTime
            animation.fillMode = .backwards
            animation.preferredFrameRateRange = frameRate
        }
        layer.add(slide, forKey: Self.reflowKey)
        layer.add(fade, forKey: Self.reflowOpacityKey)
        layer.position = slide.toValue as? CGPoint ?? start
        layer.opacity = 0
    }

    /// A live, non-interactive copy of `button` as currently drawn, at its
    /// frame. A cached bitmap cannot hold the tile's Liquid Glass outline,
    /// which would render as a solid dark square.
    private static func replica(of button: DesktopTileButton) -> NSView {
        let host = DesktopReflowReplicaHost(frame: button.frame)
        host.wantsLayer = true
        host.setAccessibilityElement(false)
        let replica = DesktopTileButton(frame: host.bounds)
        replica.cell = DesktopTileCell(textCell: button.title)
        replica.isBordered = false
        replica.setButtonType(.pushOnPushOff)
        replica.state = button.state
        replica.belongsToActiveDisplay = button.belongsToActiveDisplay
        replica.representsFullscreenSpace = button.representsFullscreenSpace
        replica.showsFullscreenOutline = button.showsFullscreenOutline
        replica.contentTintColor = button.contentTintColor
        replica.applicationIcons = button.applicationIcons
        replica.setAccessibilityElement(false)
        host.addSubview(replica)
        return host
    }

    /// A static, non-interactive image of `view` as currently drawn, at its frame.
    private static func snapshot(of view: NSView) -> NSView? {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: representation)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(representation)
        let snapshot = DesktopReflowSnapshotView(frame: view.frame)
        snapshot.image = image
        snapshot.imageScaling = .scaleAxesIndependently
        snapshot.wantsLayer = true
        snapshot.setAccessibilityElement(false)
        return snapshot
    }

    private func cancelReflowAnimations() {
        for view in buttons as [NSView] + numberLabels as [NSView] + [addButton] {
            view.layer?.removeAnimation(forKey: Self.reflowKey)
            view.layer?.removeAnimation(forKey: Self.reflowOpacityKey)
        }
    }

    private func finishChangeAnimation(targetPlusFrame: NSRect) {
        cancelHeightAnimation()
        portalExitButton?.removeFromSuperview()
        portalExitButton = nil
        addButton.layer?.removeAnimation(forKey: "crossfadeEnter")
        addButton.layer?.opacity = 1.0
        addButton.alphaValue = 1.0
        addButton.frame = targetPlusFrame
        viewsPendingRemoval.forEach { $0.removeFromSuperview() }
        viewsPendingRemoval.removeAll()
        isAnimatingChange = false
        refreshRowHeights()
        dragSlots = buttons.map(\.frame)
        if subviews.last !== closeContainer {
            addSubview(closeContainer, positioned: .above, relativeTo: nil)
        }
        closeContainer.layer?.zPosition = 100
        updateHover()
    }

    private var rowHeights: [CGFloat] {
        stride(from: 0, to: buttons.count, by: columns).map { start in
            buttons[start..<min(start + columns, buttons.count)].contains { $0.applicationIcons.count > 4 } ? 42 : 28
        }
    }

    private var isAddButtonAlone: Bool {
        !addButton.isHidden && buttons.count > 0 && buttons.count % columns == 0
    }

    private var expectedHeight: CGFloat {
        let heights = previewRowHeights
        let fullHeight: CGFloat = heights.isEmpty ? 0 : heights.reduce(6) { $0 + $1 + 26 }
        return isAddButtonAlone ? (fullHeight - 18) : fullHeight
    }

    private func refreshRowHeights() {
        cancelHeightAnimation()
        let height = expectedHeight
        if frame.height != height {
            frame.size.height = height
            (superview as? DesktopDisplaySectionsView)?.arrangeSections()
        }
        needsLayout = true
    }

    private func animateHeight(to targetHeight: CGFloat, duration: TimeInterval) {
        cancelHeightAnimation()

        let startHeight = frame.height
        guard duration > 0, abs(startHeight - targetHeight) > 0.5, window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            if frame.height != targetHeight {
                frame.size.height = targetHeight
                (superview as? DesktopDisplaySectionsView)?.arrangeSections()
            }
            return
        }

        heightAnimation = EasedAnimation(view: self, duration: duration) { [weak self] progress, finished in
            guard let self else { return }
            let currentHeight = startHeight + (targetHeight - startHeight) * progress
            if abs(self.frame.height - currentHeight) > 0.01 {
                self.frame.size.height = currentHeight
                (self.superview as? DesktopDisplaySectionsView)?.arrangeSections()
            }

            if finished {
                self.frame.size.height = targetHeight
                (self.superview as? DesktopDisplaySectionsView)?.arrangeSections()
                self.cancelHeightAnimation()
            }
        }
    }

    override func layout() {
        super.layout()
        if isAnimatingChange { return }
        if externalDropTarget != nil {
            // Background icon refreshes must not reset an expanded drag row
            // to its pre-drop size or interrupt the wrap with old tile frames.
            if externalLayoutWidth != bounds.width || externalLayoutHeights != previewRowHeights {
                applyExternalShuffle(animated: false)
            }
            return
        }
        let heights = previewRowHeights

        let frames = Self.tileFrames(count: buttons.isEmpty ? 0 : buttons.count + 1, width: bounds.width, heights: heights)
        let labelYOffset = numberLabelYOffset
        for (index, button) in buttons.enumerated() {
            button.frame = frames[index]
            let labelMinX = max(0, button.frame.minX - 4)
            let labelWidth = min(bounds.width - labelMinX, button.frame.width + 8)
            numberLabels[index].frame = NSRect(x: labelMinX, y: button.frame.maxY + labelYOffset, width: labelWidth, height: 20)
        }
        if let last = frames.last {
            addButton.frame = last
        }
        dragSlots = buttons.map(\.frame)
        applyShuffle(animated: false)
        if externalDropTarget != nil { applyExternalShuffle(animated: false) }
        // Keep the close control above all numbered buttons after a rebuild.
        if subviews.last !== closeContainer {
            addSubview(closeContainer, positioned: .above, relativeTo: nil)
        }
        closeContainer.layer?.zPosition = 100
        updateHover()
    }

    func updateApplicationIcons(_ applications: [UInt64: [DesktopApplicationIcon]]) {
        applicationIconsBySpace = applications
        for index in buttons.indices {
            updateVisualState(at: index, snapshot: latestSnapshot)
        }
        if !isAnimatingChange {
            refreshRowHeights()
        }
    }

    @objc private func refreshAccentColors() {
        for index in buttons.indices { updateVisualState(at: index, snapshot: latestSnapshot) }
    }

    private func updateVisualState(at index: Int, snapshot: DesktopSelectionSnapshot?) {
        guard buttons.indices.contains(index), numberLabels.indices.contains(index),
              desktopIDs.indices.contains(index) else { return }
        let button = buttons[index]
        let spaceID = desktopIDs[index]
        // Fullscreen Spaces have their own tiles. A neighboring numbered
        // desktop must never inherit their marker, color, or label styling.
        let representsFullscreenSpace = snapshot?.fullscreenSpaceIDs.contains(spaceID) == true
        let isCurrentOnActiveDisplay = button.state == .on && isActiveDisplay
        let currentID = snapshot?.currentID
        let isCurrentOnFullscreen = currentID.map { snapshot?.desktopIDs.contains($0) == false } ?? false
        let isAssociatedFullscreen = !representsFullscreenSpace
            && button.state == .on
            && isCurrentOnFullscreen
            && isCurrentOnActiveDisplay

        button.representsFullscreenSpace = representsFullscreenSpace
        let showsGreen = (representsFullscreenSpace || isAssociatedFullscreen)
            && DesktopBoxFullscreenPreference.greenOutlineEnabled
        button.showsFullscreenOutline = showsGreen
        let activeColor: NSColor = showsGreen ? .systemGreen : .systemBlue
        button.contentTintColor = (isCurrentOnActiveDisplay || representsFullscreenSpace)
            ? activeColor : .systemGray
        button.needsDisplay = true

        let displayedApps: [DesktopApplicationIcon]
        if representsFullscreenSpace, let snapshot {
            let contentIDs = snapshot.fullscreenContentSpaceIDs[spaceID] ?? []
            var seenNames = Set<String>()
            let contentApps = contentIDs
                .flatMap { self.applicationIconsBySpace[$0] ?? [] }
                .filter { seenNames.insert($0.name).inserted }
            displayedApps = contentApps.isEmpty
                ? (self.applicationIconsBySpace[spaceID] ?? [])
                : contentApps
        } else {
            displayedApps = applicationIconsBySpace[spaceID] ?? []
        }
        button.applicationIcons = displayedApps
        let textColor = isCurrentOnActiveDisplay ? activeColor : .labelColor
        let desktopNumber = snapshot?.desktopIDs.firstIndex(of: spaceID).map { $0 + 1 }
        let rawFullscreenName = snapshot?.fullscreenApplicationNames[spaceID]
            ?? displayedApps.first?.name
            ?? "Fullscreen"
        let bundleID = displayedApps.first?.bundleIdentifier
        let fullscreenName = DesktopBoxFullscreenPreference.displayFullscreenName(rawFullscreenName, bundleIdentifier: bundleID)
        if representsFullscreenSpace {
            numberLabels[index].lineBreakMode = .byWordWrapping
            numberLabels[index].attributedStringValue = DesktopBoxFullscreenPreference.formattedFullscreenName(
                fullscreenName, textColor: .labelColor, availableWidth: max(44.0, numberLabels[index].frame.width)
            )
        } else {
            numberLabels[index].lineBreakMode = .byTruncatingTail
            numberLabels[index].attributedStringValue = DesktopBoxFullscreenPreference.formattedLabel(
                desktopNumber: desktopNumber ?? index + 1,
                isFullscreen: isAssociatedFullscreen,
                textColor: textColor
            )
        }
        numberLabels[index].textColor = textColor
        if let labelCell = numberLabels[index].cell as? DesktopLabelCell {
            labelCell.isPillActive = isCurrentOnActiveDisplay && !representsFullscreenSpace
            labelCell.activePillColor = activeColor
            labelCell.indicatorStyle = DesktopNumberStylePreference.currentStyle
            labelCell.representsFullscreenSpace = representsFullscreenSpace
            labelCell.isKeyboardSelected = button.isKeyboardFocused
            labelCell.isDesktopHovered = button.isTileHovered
        }
        numberLabels[index].needsDisplay = true
        if let desktopNumber, !representsFullscreenSpace {
            let isBold = (button.isKeyboardFocused && DesktopNumberStylePreference.currentStyle == .accentPill)
                || button.state == .on
            numberLabels[index].font = .monospacedDigitSystemFont(
                ofSize: isBold ? 12 : 11,
                weight: isBold ? .bold : .medium
            )
            button.title = "\(desktopNumber)"
        } else {
            button.title = fullscreenName
        }

        let tooltip: String
        if representsFullscreenSpace {
            tooltip = "Fullscreen: \(fullscreenName)"
        } else {
            let names = displayedApps.map(\.name)
            let title = "Desktop \(desktopNumber ?? index + 1)"
            tooltip = title + ": " + (names.isEmpty ? "Empty" : names.joined(separator: ", "))
        }
        if button.toolTip != tooltip { button.toolTip = tooltip }
        button.setAccessibilityLabel(tooltip)
    }

    private func trackReorder(_ button: DesktopTileButton, event: NSEvent, beginning: Bool) {
        guard !isAnimatingChange, hoverEnabled, desktopIDs.indices.contains(button.tag) else { return }
        if beginning {
            pendingDropGeneration &+= 1
            layoutSubtreeIfNeeded()
            dragSourceID = desktopIDs[button.tag]
            dragOriginalIDs = desktopIDs
            previewOrder = desktopIDs
            closeContainer.isHidden = true
            addButton.setHovered(false, animated: false)
            if let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) {
                button.cacheDisplay(in: button.bounds, to: bitmap)
                let image = NSImage(size: button.bounds.size)
                image.addRepresentation(bitmap)
                dragPreview.image = image
            }
            dragPreview.frame.size = button.frame.size
            dragPreview.isHidden = false
            (superview ?? self).addSubview(dragPreview, positioned: .above, relativeTo: nil)
            button.alphaValue = 0.15
            numberLabels[button.tag].alphaValue = 0.35
        }
        guard dragOriginalIDs == desktopIDs else { finishReorder(cancelled: true); return }
        let point = convert(event.locationInWindow, from: nil)
        let previewPoint = (dragPreview.superview ?? self).convert(event.locationInWindow, from: nil)
        dragPreview.frame.origin = NSPoint(x: previewPoint.x - dragPreview.frame.width / 2, y: previewPoint.y - dragPreview.frame.height / 2)
        // Hit-test stationary slots, not the tiles moving out of the way.
        // Otherwise an animated neighbor can repeatedly reverse the shuffle.
        let destination = dragSlots.firstIndex { $0.insetBy(dx: -3, dy: -6).contains(point) }
        let externalTarget = crossDisplayTarget?(event.locationInWindow)
        dragAppends = externalTarget?.after ?? false
        let localTarget = destination.flatMap { desktopIDs.indices.contains($0) ? desktopIDs[$0] : nil }
        let target = externalTarget?.id ?? localTarget
        if target != dragTargetID {
            dragTargetID = target
            previewOrder = desktopIDs
            if let destination, let source = dragSourceID,
               let from = previewOrder.firstIndex(of: source) {
                previewOrder.remove(at: from)
                previewOrder.insert(source, at: destination)
            }
            applyShuffle(animated: true)
        }
    }

    private func applyShuffle(animated: Bool) {
        guard dragSlots.count == buttons.count, previewOrder.count == desktopIDs.count else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.18 : 0
            for (index, identifier) in desktopIDs.enumerated() {
                guard let slot = previewOrder.firstIndex(of: identifier) else { continue }
                let frame = dragSlots[slot]
                let labelMinX = max(0, frame.minX - 4)
                let labelWidth = min(bounds.width - labelMinX, frame.width + 8)
                let labelFrame = NSRect(x: labelMinX,
                    y: frame.maxY + numberLabelYOffset,
                    width: labelWidth, height: 20)
                if context.duration > 0 {
                    buttons[index].animator().frame = frame
                    numberLabels[index].animator().frame = labelFrame
                } else {
                    buttons[index].frame = frame
                    numberLabels[index].frame = labelFrame
                }
            }
        }
    }

    private func finishReorder(cancelled: Bool, animated: Bool = true) {
        pendingDropGeneration &+= 1
        let completionGeneration = pendingDropGeneration
        let appends = dragAppends
        dragAppends = false
        clearCrossDisplayTarget?(animated)
        let source = dragSourceID, target = dragTargetID
        let valid = !cancelled && dragOriginalIDs == desktopIDs
        dragSourceID = nil
        dragTargetID = nil
        dragOriginalIDs = []
        dragPreview.isHidden = true
        addSubview(dragPreview)
        buttons.forEach { $0.alphaValue = 1; $0.isDropTarget = false }
        numberLabels.forEach { $0.alphaValue = 1 }
        if !valid || source == target || target == nil {
            previewOrder = desktopIDs
            applyShuffle(animated: animated)
            previewOrder = []
        }
        if valid, let source, let target, source != target {
            let expectedIDs = desktopIDs
            // Complete on the menu's next tracking-loop turn. Main-queue work
            // waits for NSMenu to close, which would strand the drag preview and
            // make the user's next click fall through to the app underneath.
            RunLoop.main.perform(inModes: [.eventTracking, .default]) { [weak self] in
                guard let self,
                      self.pendingDropGeneration == completionGeneration,
                      self.window != nil,
                      self.desktopIDs == expectedIDs else { return }
                if appends { self.onAppend?(source, target) }
                else { self.onReorder?(source, target) }
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { updateHover() }
    override func mouseMoved(with event: NSEvent) { updateHover() }
    override func mouseExited(with event: NSEvent) {
        hoveredID = nil
        hoveredIndex = nil
        closeContainer.isHidden = true
        buttons.forEach { $0.isTileHovered = false }
        addButton.setHovered(false, animated: true)
    }

    private func updateHover() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        showCloseControl(at: point)
        updateAddButtonHover(at: point)
    }

    private func updateAddButtonHover(at point: NSPoint) {
        guard !isAnimatingChange, dragSourceID == nil else {
            if addButton.isAddButtonHovered { addButton.setHovered(false, animated: false) }
            return
        }
        guard !addButton.isHidden, addButton.isEnabled else {
            if addButton.isAddButtonHovered { addButton.setHovered(false, animated: false) }
            return
        }
        let hitRect = addButton.isAddButtonHovered
            ? addButton.frame.insetBy(dx: -2, dy: -2)
            : addButton.frame
        let isOver = hitRect.contains(point)
        if addButton.isAddButtonHovered != isOver {
            addButton.setHovered(isOver, animated: true)
        }
    }

    func closeHitbox(for index: Int) -> NSRect {
        guard buttons.indices.contains(index) else { return .zero }
        let tile = buttons[index].frame
        let isFocused = buttons[index].isKeyboardFocused
        let xOffset: CGFloat = isFocused ? -(tile.width * 0.04) : 0
        let yOffset: CGFloat = isFocused ? -(tile.height * 0.04) : 0
        let closeFrame = NSRect(x: tile.minX - 7 + xOffset, y: tile.minY - 7 + yOffset, width: 12, height: 12)
        let leftLimit: CGFloat = (index % columns == 0) ? 0 : buttons[index - 1].frame.maxX
        let topLimit: CGFloat = (index < columns) ? 0 : buttons[index - columns].frame.maxY
        let minX = max(leftLimit, closeFrame.minX - 6)
        let minY = max(topLimit, closeFrame.minY - 6)
        let maxX = closeFrame.maxX + 6
        let maxY = closeFrame.maxY + 6
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        // The press already belongs to this row until its release. Neither
        // the close badge nor the add button may take over midway through it.
        if pressedDesktopID != nil || dragSourceID != nil { return self }
        if closingEnabled && !isAnimatingChange {
            if !closeContainer.isHidden, let hoveredIndex, closeHitbox(for: hoveredIndex).contains(local) {
                return closeButton
            }
            if buttons.indices.contains(where: {
                let isClosable = buttons[$0].representsFullscreenSpace || (latestSnapshot?.desktopIDs.count ?? 0) > 1
                return isClosable && closeHitbox(for: $0).contains(local)
            }) {
                showCloseControl(at: local)
                return closeButton
            }
        }
        if !addButton.isHidden, addButton.isEnabled, addButton.frame.contains(local) {
            return addButton
        }
        // Keep the entire desktop row as one responder. If each NSButton owns
        // its own hit region, NSMenu can hand an in-progress gesture to the
        // neighboring tile and the original tile never receives mouseUp.
        return self
    }

    // Shared by live tracking and layout tests. The badge appears when hovering
    // the tile or when the pointer is near its close hitbox in the corner.
    func showCloseControl(at point: NSPoint) {
        updateAddButtonHover(at: point)
        guard dragSourceID == nil else { return }
        guard !isAnimatingChange else { return }
        guard hoverEnabled else {
            hoveredID = nil
            hoveredIndex = nil
            closeContainer.isHidden = true
            return
        }
        if !closeContainer.isHidden, let hoveredIndex, closeHitbox(for: hoveredIndex).contains(point) {
            return
        }
        let targetIndex = buttons.indices.first(where: { closeHitbox(for: $0).contains(point) })
            ?? buttons.firstIndex(where: { $0.frame.contains(point) })
        guard let index = targetIndex else {
            hoveredID = nil
            hoveredIndex = nil
            closeContainer.isHidden = true
            buttons.forEach { $0.isTileHovered = false }
            return
        }
        hoveredIndex = index
        hoveredID = desktopIDs[index]
        for (offset, button) in buttons.enumerated() { button.isTileHovered = offset == index }
        let isClosable = buttons[index].representsFullscreenSpace || (latestSnapshot?.desktopIDs.count ?? 0) > 1
        guard isClosable else {
            hoveredID = nil
            hoveredIndex = nil
            closeContainer.isHidden = true
            return
        }
        let tile = buttons[index].frame
        let isFocused = buttons[index].isKeyboardFocused
        let xOffset: CGFloat = isFocused ? -(tile.width * 0.04) : 0
        let yOffset: CGFloat = isFocused ? -(tile.height * 0.04) : 0
        closeContainer.frame = NSRect(x: tile.minX - 7 + xOffset, y: tile.minY - 7 + yOffset, width: 12, height: 12)
        closeButton.frame = closeContainer.bounds
        closeContainer.layer?.zPosition = 100
        if subviews.last !== closeContainer {
            addSubview(closeContainer, positioned: .above, relativeTo: nil)
        }
        let closeTitle: String
        if buttons[index].representsFullscreenSpace {
            if let appName = latestSnapshot?.fullscreenApplicationNames[desktopIDs[index]], !appName.isEmpty {
                closeTitle = "Close \(appName)"
            } else {
                closeTitle = "Close Fullscreen Desktop"
            }
        } else {
            let desktopNumber = latestSnapshot?.desktopIDs.firstIndex(of: desktopIDs[index]).map { $0 + 1 }
                ?? index + 1
            closeTitle = "Close Desktop \(desktopNumber)"
        }
        closeButton.toolTip = closeTitle
        closeButton.setAccessibilityLabel(closeTitle)
        closeContainer.isHidden = !closingEnabled
    }

    @objc private func closeDesktop() {
        guard !isAnimatingChange, closingEnabled, let hoveredID,
              let index = desktopIDs.firstIndex(of: hoveredID),
              buttons.indices.contains(index) else { return }
        let isClosable = buttons[index].representsFullscreenSpace || (latestSnapshot?.desktopIDs.count ?? 0) > 1
        guard isClosable else { return }
        let idToClose = hoveredID
        self.hoveredID = nil
        self.hoveredIndex = nil
        self.closeContainer.isHidden = true
        onClose?(idToClose)
    }

    @objc private func selectDesktop(_ sender: NSButton) {
        guard hoverEnabled, !isAnimatingChange, desktopIDs.indices.contains(sender.tag) else { return }
        sender.state = .off // Selection follows the live Space, not the click.
        onSelect?(desktopIDs[sender.tag])
    }

    @objc private func addDesktop() {
        guard hoverEnabled, !isAnimatingChange, addButton.isEnabled else { return }
        onAdd?()
    }
}
