import Cocoa
import ApplicationServices
import OSLog

// The panel is visual only. A session-scoped event tap captures clicks inside
// its close button without activating DockAway or dismissing Mission Control.
@MainActor
final class MissionControlWindowClose {
    static let preferenceKey = "closeWindowsInMissionControl"
    static let keyboardPreferenceKey = "keyboardCommandsInMissionControl"
    enum Command: String { case close, minimize, quit, open }
    struct Shortcut {
        let command: Command
        let character: String
        let keyCode: Int64?
        let flags: CGEventFlags

        init?(_ entry: [String: Any]) {
            guard let action = entry["action"] as? String, let command = Command(rawValue: action),
                  let character = entry["character"] as? String, !character.isEmpty,
                  let modifiers = entry["modifiers"] as? NSNumber else { return nil }
            self.command = command
            self.character = character.lowercased()
            keyCode = (entry["keyCode"] as? NSNumber)?.int64Value
            var flags: CGEventFlags = []
            let mask = modifiers.uint32Value
            if mask & 8 == 0 { flags.insert(.maskCommand) }
            if mask & 1 != 0 { flags.insert(.maskShift) }
            if mask & 2 != 0 { flags.insert(.maskAlternate) }
            if mask & 4 != 0 { flags.insert(.maskControl) }
            self.flags = flags
        }
    }
    static func command(keyCode: Int64, character: String, flags: CGEventFlags, shortcuts: [Shortcut]) -> Command? {
        let modifiers = flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        let matches = shortcuts.filter {
            $0.flags == modifiers && ($0.keyCode.map { $0 == keyCode } ?? ($0.character == character.lowercased()))
        }
        if matches.count == 1 { return matches[0].command }
        if matches.isEmpty, modifiers.isEmpty, keyCode == 36 || keyCode == 76 { return .open }
        return nil
    }
    private var shortcuts: [pid_t: [Shortcut]] = [:]
    private var shortcutApplications: [pid_t: NSRunningApplication] = [:]
    private var shortcutRequest: UUID?
    private var consumedKeys = Set<Int64>()
    private var optionsEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.preferenceKey) || UserDefaults.standard.bool(forKey: Self.keyboardPreferenceKey)
    }
    private struct Target: Equatable {
        let pid: pid_t
        let id: CGWindowID
        let bounds: CGRect
    }

    private var timer: Timer?
    private var tap: EventTap?
    private var panel: NSPanel?
    private var button: NSButton?
    private var target: Target?
    private var pressedTarget: Target?
    private var buttonRect = CGRect.zero
    private var active = false
    private var suspended = false
    private var windowDragInProgress = false
    private var trackpadContacts = 0
    private var swipingDown = false
    private var swipeDownResetWorkItem: DispatchWorkItem?
    private var generation = 0
    private var busy = false
    private var readyAt: TimeInterval = 0

    var isSuppressedByGesture: Bool {
        swipingDown || trackpadContacts >= 3
    }
    private let logger = Logger(subsystem: "AK.DockAway", category: "MissionControlClose")
    private var lastDiagnostic = ""
    private func report(_ state: String) {
        guard state != lastDiagnostic else { return }
        lastDiagnostic = state
        logger.notice("\(state, privacy: .public)")
    }
    private let actions = DispatchQueue(label: "com.dockaway.mission-control-close", qos: .userInitiated)
    private let shortcutDiscovery = DispatchQueue(label: "com.dockaway.mission-control-shortcuts", qos: .utility)

    func trackpadContactsChanged(_ count: Int) {
        trackpadContacts = count
        if count >= 3 {
            hide()
        } else if count == 0, swipingDown {
            scheduleSwipeDownReset(after: 0.6)
        }
    }

    func handleDownwardSwipe() {
        swipingDown = true
        swipeDownResetWorkItem?.cancel()
        swipeDownResetWorkItem = nil
        if active {
            hide()
            report("Downward swipe detected; close button suppressed")
        }
    }

    func cancelDownwardSwipe() {
        guard swipingDown else { return }
        swipingDown = false
        swipeDownResetWorkItem?.cancel()
        swipeDownResetWorkItem = nil
        readyAt = ProcessInfo.processInfo.systemUptime + 0.2
    }

    private func scheduleSwipeDownReset(after delay: TimeInterval) {
        swipeDownResetWorkItem?.cancel()
        let request = generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.active, self.generation == request else { return }
            self.swipingDown = false
            self.readyAt = ProcessInfo.processInfo.systemUptime + 0.2
            self.refresh()
        }
        swipeDownResetWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func setActive(_ value: Bool) {
        if !value { stop(); return }
        guard !active else { return }
        guard optionsEnabled else { report("Entry blocked: options disabled"); return }
        guard AXIsProcessTrusted() else { report("Entry blocked: Accessibility unavailable"); return }
        for (pid, app) in shortcutApplications where app.isTerminated {
            shortcuts.removeValue(forKey: pid)
            shortcutApplications.removeValue(forKey: pid)
        }
        active = true
        suspended = false
        swipingDown = false
        swipeDownResetWorkItem?.cancel()
        swipeDownResetWorkItem = nil
        generation += 1
        readyAt = ProcessInfo.processInfo.systemUptime + 0.35
        guard installTap() else { stop(); report("Entry blocked: event tap creation failed"); return }
        report("Session started; event tap installed")
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        // Let the Mission Control entry animation finish before placing a button.
        let request = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.generation == request else { return }
            self.refresh()
        }
    }

    func stop() {
        if active { report("Session stopped") }
        active = false
        generation += 1
        timer?.invalidate()
        timer = nil
        tap?.invalidate()
        tap = nil
        pressedTarget = nil
        windowDragInProgress = false
        trackpadContacts = 0
        swipingDown = false
        swipeDownResetWorkItem?.cancel()
        swipeDownResetWorkItem = nil
        consumedKeys.removeAll()
        hide()
        panel?.close()
        panel = nil
        button = nil
    }

    private func installTap() -> Bool {
        // A disabled tap fails closed in handle(_:_:) instead of re-enabling.
        tap = EventTap(
            events: [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .keyDown, .keyUp, .scrollWheel],
            reenablesWhenDisabled: false
        ) { [weak self] type, event in
            self?.handle(type, event) ?? false
        }
        return tap != nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Fail closed rather than keeping stale buttons on screen.
            suspended = true
            hide()
            report("Session suspended: event tap disabled")
            return false
        }
        guard active else { return false }
        switch type {
        case .keyUp:
            return consumedKeys.remove(event.getIntegerValueField(.keyboardEventKeycode)) != nil
        case .keyDown:
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            if consumedKeys.contains(key) { return true }
            guard !suspended, !busy, !windowDragInProgress, !isSuppressedByGesture,
                  !Self.mouseButtonIsDown, pressedTarget == nil,
                  ProcessInfo.processInfo.systemUptime >= readyAt,
                  UserDefaults.standard.bool(forKey: Self.keyboardPreferenceKey),
                  event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
                  let hovered = hoveredTarget(),
                  let command = Self.command(keyCode: key,
                    character: NSEvent(cgEvent: event)?.charactersIgnoringModifiers ?? "",
                    flags: event.flags, shortcuts: shortcuts[hovered.pid] ?? []) else { return false }
            consumedKeys.insert(key)
            perform(command, on: hovered)
            return true
        case .mouseMoved:
            if isSuppressedByGesture {
                hide()
                return false
            }
            if let target, !Self.isHovering(event.location, thumbnail: target.bounds, keepingCurrentButton: true) {
                hide()
            }
            return false
        case .scrollWheel:
            let deltaY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let fixedDeltaY = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            if deltaY != 0 || fixedDeltaY != 0 {
                hide()
                readyAt = max(readyAt, ProcessInfo.processInfo.systemUptime + 0.35)
            }
            return false
        case .leftMouseDown:
            if isSuppressedByGesture {
                hide()
                return false
            }
            guard !suspended, !busy, panel?.isVisible == true,
                  buttonRect.contains(event.location), let target else {
                // Let Mission Control own all ordinary clicks and drags.
                windowDragInProgress = true
                hide()
                return false
            }
            pressedTarget = target
            button?.highlight(true)
            return true
        case .leftMouseDragged:
            guard pressedTarget != nil else {
                windowDragInProgress = true
                hide()
                return false
            }
            button?.highlight(buttonRect.contains(event.location))
            return true
        case .leftMouseUp:
            guard let pressed = pressedTarget else {
                windowDragInProgress = false
                readyAt = ProcessInfo.processInfo.systemUptime + 0.2
                return false
            }
            pressedTarget = nil
            button?.highlight(false)
            if buttonRect.contains(event.location), target == pressed { close(pressed) }
            return true
        default:
            return false
        }
    }

    private func hide() {
        panel?.orderOut(nil)
        target = nil
        buttonRect = .zero
    }

    private func refresh() {
        if pressedTarget == nil && Self.mouseButtonIsDown {
            windowDragInProgress = true
            hide()
            return
        }
        if windowDragInProgress {
            windowDragInProgress = false
            readyAt = ProcessInfo.processInfo.systemUptime + 0.2
        }
        if isSuppressedByGesture {
            hide()
            return
        }
        guard active, !suspended, !busy, pressedTarget == nil,
              ProcessInfo.processInfo.systemUptime >= readyAt else { return }
        guard optionsEnabled, AXIsProcessTrusted() else { stop(); return }
        guard let hovered = hoveredTarget(allowProximity: true) else { hide(); return }
        if UserDefaults.standard.bool(forKey: Self.keyboardPreferenceKey) { refreshShortcuts(for: hovered.pid) }
        if UserDefaults.standard.bool(forKey: Self.preferenceKey) { show(hovered) } else { hide() }
    }

    private func refreshShortcuts(for pid: pid_t) {
        // Retain both successful and empty results across Mission Control
        // sessions. A running-app reference prevents reuse after PID recycling.
        if shortcuts[pid] != nil, shortcutApplications[pid]?.isTerminated == false { return }
        guard shortcutRequest == nil,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        let request = UUID()
        shortcutRequest = request
        shortcutDiscovery.async { [weak self] in
            let entries = DockAwayMissionControlShortcuts(pid)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.shortcutRequest == request else { return }
                self.shortcutRequest = nil
                guard !app.isTerminated else { return }
                // Bound the cache even during unusually long app sessions.
                if self.shortcuts.count >= 64, self.shortcuts[pid] == nil,
                   let oldest = self.shortcuts.keys.first {
                    self.shortcuts.removeValue(forKey: oldest)
                    self.shortcutApplications.removeValue(forKey: oldest)
                }
                self.shortcuts[pid] = entries.compactMap { Shortcut($0) }
                self.shortcutApplications[pid] = app
            }
        }
    }

    func reloadKeyboardShortcuts() {
        shortcutRequest = nil
        shortcuts.removeAll()
        shortcutApplications.removeAll()
    }

    var keyboardCommandsToolTip: String {
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier ?? 0
        let bindings = shortcutApplications[pid]?.isTerminated == false ? shortcuts[pid] ?? [] : []
        return Self.shortcutHelp(appName: app?.localizedName, shortcuts: bindings)
    }

    static func shortcutHelp(appName: String?, shortcuts: [Shortcut]) -> String {
        let commands: [(Command, String, String)] = [
            (.close, "Close window", "⌘W"),
            (.minimize, "Minimize window", "⌘M"),
            (.quit, "Quit app", "⌘Q")
        ]
        var lines = ["In Mission Control, hover over a window."]
        if let appName { lines.append("Shortcuts for \(appName):") }
        for (command, title, fallback) in commands {
            let matches = shortcuts.filter { $0.command == command }
            guard matches.count == 1, let shortcut = matches.first else {
                lines.append("\(fallback)  \(title)")
                continue
            }
            var keys = ""
            if shortcut.flags.contains(.maskControl) { keys += "⌃" }
            if shortcut.flags.contains(.maskAlternate) { keys += "⌥" }
            if shortcut.flags.contains(.maskShift) { keys += "⇧" }
            if shortcut.flags.contains(.maskCommand) { keys += "⌘" }
            let special: [String: String] = ["\r": "↩", "\t": "⇥", " ": "Space", "\u{1b}": "⎋", "\u{7f}": "⌫"]
            keys += special[shortcut.character] ?? shortcut.character.uppercased()
            lines.append("\(keys)  \(title)")
        }
        lines.append("↩ Return  Open hovered window")
        lines.append("These bindings reflect the ones in your system settings.")
        return lines.joined(separator: "\n")
    }

    private func hoveredTarget(allowProximity: Bool = false) -> Target? {
        guard !isSuppressedByGesture else { return nil }
        // Verify Mission Control independently before ever showing a panel.
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
              windows.contains(where: { ($0[kCGWindowOwnerName as String] as? String) == "WindowManager"
                  && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 14 }),
              let pointer = CGEvent(source: nil)?.location else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var hovered: Target?
        var nearest = CGFloat.greatestFiniteMagnitude
        for info in windows {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let raw = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw),
                  bounds.width >= 60, bounds.height >= 40,
                  (allowProximity ? Self.isHovering(pointer, thumbnail: bounds, keepingCurrentButton: target?.id == id)
                      : bounds.contains(pointer)),
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular else { continue }
            let overCurrentButton = target?.id == id && Self.closeButtonRect(in: bounds).contains(pointer)
            let dx = max(bounds.minX - pointer.x, 0, pointer.x - bounds.maxX)
            let dy = max(bounds.minY - pointer.y, 0, pointer.y - bounds.maxY)
            let distance: CGFloat = overCurrentButton && allowProximity ? -1 : hypot(dx, dy)
            if distance < nearest {
                nearest = distance
                hovered = Target(pid: pid, id: id, bounds: bounds)
            }
        }
        return hovered
    }

    private static var mouseButtonIsDown: Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
            || CGEventSource.buttonState(.combinedSessionState, button: .right)
            || CGEventSource.buttonState(.combinedSessionState, button: .center)
    }

    static func closeButtonRect(in thumbnail: CGRect) -> CGRect {
        CGRect(x: thumbnail.minX - 16, y: thumbnail.minY - 16, width: 30, height: 30)
    }

    static func isHovering(_ point: CGPoint, thumbnail: CGRect, keepingCurrentButton: Bool) -> Bool {
        let approachMargin: CGFloat = keepingCurrentButton ? 12 : 8
        return thumbnail.insetBy(dx: -6, dy: -6).contains(point)
            || closeButtonRect(in: thumbnail).insetBy(dx: -approachMargin, dy: -approachMargin).contains(point)
    }

    static func makeCloseButton() -> NSButton {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        button.isBordered = false
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyUpOrDown
        let colors = NSImage.SymbolConfiguration(paletteColors: [.labelColor, .systemRed])
        button.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close window")?
            .withSymbolConfiguration(colors)
        button.toolTip = "Close window"
        button.setAccessibilityLabel("Close window")
        return button
    }

    static let overlayCollectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces, .stationary, .ignoresCycle
    ]

    static func appKitRect(from rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    private func show(_ hovered: Target) {
        if panel == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.level = .screenSaver
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.animationBehavior = .none
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            // Stationary and transient are mutually exclusive. Transient
            // windows are hidden by Mission Control even after orderFront.
            panel.collectionBehavior = Self.overlayCollectionBehavior
            let close = Self.makeCloseButton()
            let content = NSView(frame: close.frame)
            content.addSubview(close)
            panel.contentView = content
            self.panel = panel
            button = close
        }
        // Hide before retargeting so the shared panel never travels visibly
        // between thumbnails. Only the close badge's own panel is affected.
        if target != hovered { panel?.orderOut(nil) }
        target = hovered
        buttonRect = Self.closeButtonRect(in: hovered.bounds)
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        panel?.setFrame(Self.appKitRect(from: buttonRect, primaryTop: primaryTop), display: true, animate: false)
        panel?.orderFrontRegardless()
        report("Panel shown for window \(hovered.id); visible=\(panel?.isVisible == true)")
    }

    private func close(_ target: Target) {
        perform(.close, on: target)
    }

    private func perform(_ command: Command, on target: Target) {
        // Re-read membership immediately before dispatch; never substitute a
        // different window or send Cmd-W to whichever application is frontmost.
        guard let current = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
              current.contains(where: { ($0[kCGWindowOwnerName as String] as? String) == "WindowManager"
                  && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 14 }),
              current.contains(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.id
                  && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == target.pid
                  && ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } == target.bounds
              }) else { hide(); return }
        if command == .open {
            let point = CGPoint(x: target.bounds.midX, y: target.bounds.midY)
            guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return }
            suspended = true
            hide()
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return
        }
        if command == .quit {
            hide()
            if NSRunningApplication(processIdentifier: target.pid)?.terminate() != true { NSSound.beep() }
            return
        }
        busy = true
        hide()
        let request = generation
        actions.async { [weak self] in
            let succeeded = command == .minimize
                ? DockAwayMinimizeWindow(target.pid, target.id)
                : DockAwayCloseWindow(target.pid, target.id)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                guard self.active, self.generation == request else { return }
                if !succeeded { NSSound.beep() }
                self.refresh()
            }
        }
    }
}
