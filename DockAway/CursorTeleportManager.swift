import Cocoa
import CoreGraphics
import ApplicationServices

enum CursorTeleportPreference {
    static let appActivationPreferenceKey = "TeleportCursorToActiveAppDisplay"
    static let windowMovePreferenceKey = "TeleportCursorOnWindowMoveToDisplay"

    // Backward-compatible alias
    static let preferenceKey = appActivationPreferenceKey

    static var isAppActivationTeleportEnabled: Bool {
        get {
            guard let value = UserDefaults.standard.object(forKey: appActivationPreferenceKey) as? Bool else {
                return true // Enabled by default
            }
            return value
        }
        set {
            UserDefaults.standard.set(newValue, forKey: appActivationPreferenceKey)
        }
    }

    static var isWindowMoveTeleportEnabled: Bool {
        get {
            guard let value = UserDefaults.standard.object(forKey: windowMovePreferenceKey) as? Bool else {
                return true // Enabled by default
            }
            return value
        }
        set {
            UserDefaults.standard.set(newValue, forKey: windowMovePreferenceKey)
        }
    }

    static var isEnabled: Bool {
        get { isAppActivationTeleportEnabled }
        set { isAppActivationTeleportEnabled = newValue }
    }
}

// Wait for a released click and stable window geometry instead of dropping an
// activation delivered before the Dock has finished restoring the window.
struct CursorTeleportActivationRequest {
    enum Result: Equatable { case wait, cancel, ready(CGRect) }
    let startedAt: TimeInterval
    let pointerOrigin: CGPoint
    private var previousRect: CGRect?
    private var stableSince: TimeInterval?

    init(startedAt: TimeInterval, pointerOrigin: CGPoint) {
        self.startedAt = startedAt
        self.pointerOrigin = pointerOrigin
    }

    mutating func evaluate(now: TimeInterval, pointer: CGPoint, buttonsPressed: Bool,
                           eligible: Bool, windowRect: CGRect?) -> Result {
        guard eligible, now - startedAt < 1.5,
              hypot(pointer.x - pointerOrigin.x, pointer.y - pointerOrigin.y) < 12 else {
            return .cancel
        }
        guard !buttonsPressed, let rect = windowRect else {
            previousRect = nil
            stableSince = nil
            return .wait
        }
        if previousRect != rect {
            previousRect = rect
            stableSince = now
            return .wait
        }
        guard let stableSince, now - stableSince >= 0.10 else { return .wait }
        return .ready(rect)
    }
}

struct CursorTeleportActivationSuppression {
    private var deadline: TimeInterval?

    mutating func suppressNext(now: TimeInterval, duration: TimeInterval) {
        let newDeadline = now + duration
        if let current = deadline {
            deadline = max(current, newDeadline)
        } else {
            deadline = newDeadline
        }
    }

    mutating func consumeIfActive(now: TimeInterval) -> Bool {
        guard let deadline else { return false }
        if now <= deadline {
            return true
        }
        self.deadline = nil
        return false
    }

    mutating func clear() {
        deadline = nil
    }
}

final class CursorTeleportManager {
    var isMissionControlActive: (() -> Bool)?
    var onWindowMoveTransitionStarted: (() -> Void)?
    private var isRunning = false
    private var observer: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var activationTimer: Timer?
    private var lastTeleportUptime: TimeInterval = 0
    private var lastTeleportedPID: pid_t = 0
    private var activationSuppression = CursorTeleportActivationSuppression()
    private var windowDisplayMap: [CFHashCode: CGDirectDisplayID] = [:]
    private var lastWindowMoveTeleportUptime: TimeInterval = 0

    deinit {
        stop()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self.handleApplicationActivated(app)
        }

        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.suppressNextApplicationActivationTeleport(duration: 1.2)
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard CursorTeleportPreference.isAppActivationTeleportEnabled,
                  Self.activeDisplays().count > 1 else { return }
            let point = Self.currentCursorQuartzPoint()
            if Self.isCloseOrMinimizeButtonClick(at: point, event: event.cgEvent) {
                self?.suppressNextApplicationActivationTeleport(duration: 1.2)
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard CursorTeleportPreference.isAppActivationTeleportEnabled,
                  Self.activeDisplays().count > 1 else { return event }
            let point = Self.currentCursorQuartzPoint()
            if Self.isCloseOrMinimizeButtonClick(at: point, event: event.cgEvent) {
                self?.suppressNextApplicationActivationTeleport(duration: 1.2)
            }
            return event
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        activationTimer?.invalidate()
        activationTimer = nil
        activationSuppression.clear()
        windowDisplayMap.removeAll()
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
    }

    private func handleApplicationActivated(_ app: NSRunningApplication) {
        activationTimer?.invalidate()
        activationTimer = nil
        if activationSuppression.consumeIfActive(
            now: ProcessInfo.processInfo.systemUptime
        ) {
            return
        }
        guard CursorTeleportPreference.isAppActivationTeleportEnabled,
              app.processIdentifier != getpid(),
              app.bundleIdentifier != "com.apple.finder",
              app.activationPolicy == .regular,
              isMissionControlActive?() != true,
              Self.activeDisplays().count > 1,
              let origin = CGEvent(source: nil)?.location else { return }

        let activeDisplays = Self.activeDisplays()
        if let cursorDisplay = Self.display(containing: origin, in: activeDisplays),
           let localWin = Self.windowRect(for: app, preferredCursorPoint: origin),
           Self.display(for: localWin, in: activeDisplays) == cursorDisplay {
            // Cursor is already on the same monitor as an on-screen window for this app.
            return
        }

        var request = CursorTeleportActivationRequest(
            startedAt: ProcessInfo.processInfo.systemUptime, pointerOrigin: origin)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self, self.isRunning, let pointer = CGEvent(source: nil)?.location else {
                timer.invalidate()
                return
            }
            let eligible = CursorTeleportPreference.isAppActivationTeleportEnabled
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
                && self.isMissionControlActive?() != true
            let pressed = NSEvent.pressedMouseButtons != 0
            let rect = eligible && !pressed ? Self.windowRect(for: app, preferredCursorPoint: pointer) : nil
            switch request.evaluate(now: ProcessInfo.processInfo.systemUptime,
                                    pointer: pointer, buttonsPressed: pressed,
                                    eligible: eligible, windowRect: rect) {
            case .wait:
                break
            case .cancel:
                timer.invalidate()
                self.activationTimer = nil
            case .ready(let rect):
                timer.invalidate()
                self.activationTimer = nil
                if self.activationSuppression.consumeIfActive(now: ProcessInfo.processInfo.systemUptime) {
                    return
                }
                self.teleportCursorIfNeeded(for: app, resolvedWindowRect: rect)
            }
        }
        activationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    func suppressNextApplicationActivationTeleport(
        duration: TimeInterval = 1.2
    ) {
        activationTimer?.invalidate()
        activationTimer = nil
        activationSuppression.suppressNext(
            now: ProcessInfo.processInfo.systemUptime,
            duration: duration
        )
    }

    func handleAccessibilityEvent(processIdentifier: pid_t, windowElement: AXUIElement, notification: String) {
        guard isRunning else { return }

        if notification == kAXUIElementDestroyedNotification {
            windowDisplayMap.removeValue(forKey: CFHash(windowElement))
            suppressNextApplicationActivationTeleport(duration: 1.2)
            return
        }

        if notification == kAXWindowMiniaturizedNotification {
            suppressNextApplicationActivationTeleport(duration: 1.2)
            return
        }

        if notification == kAXFocusedWindowChangedNotification ||
           notification == kAXMainWindowChangedNotification ||
           notification == kAXWindowCreatedNotification {
            if let bounds = Self.axWindowBounds(windowElement) {
                let displays = Self.activeDisplays()
                if let display = Self.display(for: bounds, in: displays) {
                    windowDisplayMap[CFHash(windowElement)] = display
                }
            }
            return
        }

        if notification == kAXWindowMovedNotification {
            teleportCursorOnWindowMove(processIdentifier: processIdentifier, windowElement: windowElement)
        }
    }

    @discardableResult
    func teleportCursorOnWindowMove(
        processIdentifier: pid_t,
        windowElement: AXUIElement,
        in displays: [CGDirectDisplayID]? = nil,
        debounceDelay: TimeInterval = 0
    ) -> Bool {
        guard CursorTeleportPreference.isWindowMoveTeleportEnabled else { return false }
        guard processIdentifier != getpid() else { return false }
        guard NSEvent.pressedMouseButtons == 0 else { return false }
        guard isMissionControlActive?() != true else { return false }

        // Debounce rapid move notifications within 400ms to avoid synchronous AX overhead during animation
        let now = ProcessInfo.processInfo.systemUptime
        guard (now - lastWindowMoveTeleportUptime) >= 0.40 else { return false }

        let activeDisplays = displays ?? Self.activeDisplays()
        guard activeDisplays.count > 1 else { return false }

        // Must belong to the frontmost active application
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier == processIdentifier,
              frontApp.bundleIdentifier != Bundle.main.bundleIdentifier,
              frontApp.bundleIdentifier != "com.apple.finder",
              frontApp.activationPolicy == .regular else {
            return false
        }

        guard let mouseLocation = CGEvent(source: nil)?.location else { return false }
        guard let cursorDisplay = Self.display(containing: mouseLocation, in: activeDisplays) else {
            return false
        }

        guard let newRect = Self.axWindowBounds(windowElement) else {
            return false
        }
        guard newRect.width >= 100, newRect.height >= 100 else { return false }

        guard let targetDisplay = Self.display(for: newRect, in: activeDisplays) else { return false }

        let elementHash = CFHash(windowElement)
        let previousDisplay = windowDisplayMap[elementHash]
        windowDisplayMap[elementHash] = targetDisplay

        // Bound memory footprint
        if windowDisplayMap.count > 120 {
            windowDisplayMap.removeAll()
            windowDisplayMap[elementHash] = targetDisplay
        }

        // If the window is still on the same display as the cursor, do nothing
        guard targetDisplay != cursorDisplay else { return false }

        // Verify the window actually changed displays
        guard let previousDisplay, previousDisplay != targetDisplay else { return false }

        // Protect DockWatcher from toggling the Dock and invalidating window backing store during transition
        onWindowMoveTransitionStarted?()

        let targetPoint = Self.targetCursorPoint(for: newRect, on: targetDisplay)
        guard Self.warpCursor(to: targetPoint) else { return false }

        lastWindowMoveTeleportUptime = now
        dockAwayDebugLog("🎯 Teleported cursor on window move for '\(frontApp.localizedName ?? "")' from Display \(cursorDisplay) to Display \(targetDisplay) at \(targetPoint)")
        return true
    }

    @discardableResult
    func teleportCursorIfNeeded(for app: NSRunningApplication, in displays: [CGDirectDisplayID]? = nil, resolvedWindowRect: CGRect? = nil) -> Bool {
        guard CursorTeleportPreference.isEnabled else { return false }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
        guard app.bundleIdentifier != "com.apple.finder" else { return false }
        guard app.activationPolicy == .regular else { return false }
        guard NSEvent.pressedMouseButtons == 0 else { return false }
        guard isMissionControlActive?() != true else { return false }

        let activeDisplays = displays ?? Self.activeDisplays()
        guard activeDisplays.count > 1 else { return false }

        guard let mouseLocation = CGEvent(source: nil)?.location else { return false }
        guard let cursorDisplay = Self.display(containing: mouseLocation, in: activeDisplays) else {
            return false
        }

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
        guard let winRect = resolvedWindowRect ?? Self.windowRect(for: app, preferredCursorPoint: mouseLocation) else { return false }
        guard let targetDisplay = Self.display(for: winRect, in: activeDisplays) else { return false }

        // If the cursor is already inside the window or on the same monitor as the app's window, do nothing.
        guard !winRect.contains(mouseLocation) && targetDisplay != cursorDisplay else { return false }

        // Debounce repeated activations for the same app within 250ms
        let now = ProcessInfo.processInfo.systemUptime
        if app.processIdentifier == lastTeleportedPID && (now - lastTeleportUptime) < 0.25 {
            return false
        }

        let targetPoint = Self.targetCursorPoint(for: winRect, on: targetDisplay)
        guard Self.warpCursor(to: targetPoint) else { return false }

        lastTeleportUptime = now
        lastTeleportedPID = app.processIdentifier
        dockAwayDebugLog("🎯 Teleported cursor for '\(app.localizedName ?? "")' from Display \(cursorDisplay) to Display \(targetDisplay) at \(targetPoint)")
        return true
    }

    // MARK: - Display & Geometry Utilities

    static func activeDisplays() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return [CGMainDisplayID()] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)
        return displays
    }

    static func display(containing point: CGPoint, in displays: [CGDirectDisplayID]) -> CGDirectDisplayID? {
        displays.first { CGDisplayBounds($0).contains(point) }
    }

    static func display(for windowRect: CGRect, in displays: [CGDirectDisplayID]) -> CGDirectDisplayID? {
        let center = CGPoint(x: windowRect.midX, y: windowRect.midY)
        if let containing = displays.first(where: { CGDisplayBounds($0).contains(center) }) {
            return containing
        }

        // Fallback to the display with the greatest intersection area
        return displays.max { d1, d2 in
            let a = CGDisplayBounds(d1).intersection(windowRect)
            let b = CGDisplayBounds(d2).intersection(windowRect)
            let areaA = a.isNull ? 0 : a.width * a.height
            let areaB = b.isNull ? 0 : b.width * b.height
            return areaA < areaB
        }
    }

    static func targetCursorPoint(for windowRect: CGRect, on displayID: CGDirectDisplayID) -> CGPoint {
        let displayBounds = CGDisplayBounds(displayID)
        let center = CGPoint(x: windowRect.midX, y: windowRect.midY)

        // Keep cursor comfortably inside the display borders by 40 pt
        let minX = displayBounds.minX + min(40, displayBounds.width / 4)
        let maxX = displayBounds.maxX - min(40, displayBounds.width / 4)
        let minY = displayBounds.minY + min(40, displayBounds.height / 4)
        let maxY = displayBounds.maxY - min(40, displayBounds.height / 4)

        return CGPoint(
            x: min(max(center.x, minX), maxX),
            y: min(max(center.y, minY), maxY)
        )
    }

    static func windowRect(for app: NSRunningApplication, preferredCursorPoint: CGPoint? = nil) -> CGRect? {
        let pid = app.processIdentifier
        let isFinder = app.bundleIdentifier == "com.apple.finder"
        let activeDisplays = Self.activeDisplays()
        let cursorDisplay = preferredCursorPoint.flatMap { Self.display(containing: $0, in: activeDisplays) }

        // 1. Primary authority: On-screen regular windows currently composited by WindowServer
        if let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            let windows = findOnScreenWindowRects(in: onScreen, forPID: pid)
            if !windows.isEmpty {
                // If the app already has a window on the monitor containing the cursor,
                // prefer that window so the cursor is NOT teleported away from the user's active monitor!
                if let cursorDisplay,
                   let localWindow = windows.first(where: { Self.display(for: $0, in: activeDisplays) == cursorDisplay }) {
                    return localWindow
                }
                // Otherwise return the topmost on-screen window of the application
                return windows.first
            }
        }

        if isFinder {
            return nil
        }

        // 2. Secondary fallback: Accessibility API for focused or main window
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.08)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let window = appElement.element(attribute),
               let rect = axWindowBounds(window), rect.width >= 100, rect.height >= 100 {
                return rect
            }
        }

        // 3. Last-resort fallback: All windows (including newly created / settling windows)
        if let allWindows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            let windows = findOnScreenWindowRects(in: allWindows, forPID: pid)
            if let cursorDisplay,
               let localWindow = windows.first(where: { Self.display(for: $0, in: activeDisplays) == cursorDisplay }) {
                return localWindow
            }
            return windows.first
        }

        return nil
    }

    private static func axWindowBounds(_ windowElement: AXUIElement) -> CGRect? {
        guard windowElement.bool(kAXMinimizedAttribute) != true else { return nil }
        return windowElement.frame
    }

    private static func findOnScreenWindowRects(in windowList: [[String: Any]], forPID pid: pid_t) -> [CGRect] {
        var rects = [CGRect]()
        for w in windowList {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? CGFloat ?? 1.0) > 0.1,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? CGFloat,
                  let y = b["Y"] as? CGFloat,
                  let width = b["Width"] as? CGFloat,
                  let height = b["Height"] as? CGFloat,
                  width >= 100, height >= 100 else {
                continue
            }
            rects.append(CGRect(x: x, y: y, width: width, height: height))
        }
        return rects
    }

    @discardableResult
    static func warpCursor(to targetPoint: CGPoint) -> Bool {
        let err = CGWarpMouseCursorPosition(targetPoint)
        return err == .success
    }

    static func currentCursorQuartzPoint() -> CGPoint {
        if let cgEvent = CGEvent(source: nil) {
            return cgEvent.location
        }
        let cocoa = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: cocoa.x, y: primaryHeight - cocoa.y)
    }

    static func isCloseOrMinimizeButtonClick(at point: CGPoint, event: CGEvent? = nil) -> Bool {
        guard let target = TrafficLightHitTest.target(at: point,
            receivingWindowID: TrafficLightHitTest.receivingWindowID(for: event),
            budget: AccessibilityRequestBudget(seconds: 0.04)) else { return false }
        return target.kind == .close || target.kind == .minimize
    }
}
