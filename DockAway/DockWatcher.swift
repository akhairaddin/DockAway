import Cocoa
import ApplicationServices

final class DockWatcher {

    private var pendingSpaceCheck: DispatchWorkItem?
    private var dockIsShown = false
    private var safetyTimer: Timer?
    private var lastToggleTime = Date.distantPast

    // ── SPEED TUNING ─────────────────────────────────────────────────────────
    // Raise any of these if the Dock starts double-toggling.
    private let spaceCheckDelay: TimeInterval  = 0.0    // was 0.15
    private let spaceRecheckDelay: TimeInterval = 0.12  // was 0.15
    private let safetyInterval: TimeInterval   = 0.12   // was 0.30
    private let toggleDebounce: TimeInterval   = 0.45   // was 1.00

    // Set by the pre-hide trigger. While a hold is active the Dock may be hidden
    // but never shown — the empty-desktop verdict is ignored entirely, so a tap
    // on the bare desktop will not yank it back up mid-gesture.
    private var holdLatched = false
    private var holdLatchExpiry = Date.distantPast   // safety cap, see below
    private var holdReleaseAt = Date.distantPast

    private var isHoldingHidden: Bool {
        if holdLatched && Date() < holdLatchExpiry { return true }
        return Date() < holdReleaseAt
    }

    // MARK: - Lifecycle

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(spaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        // Safety net: Catches cases where NO notification fires at all,
        // e.g. minimizing the last window of an app via a trackpad gesture.
        // .common, not the default mode: a scheduledTimer is parked in .default,
        // which the run loop suspends while it tracks a trackpad gesture — so
        // this net was asleep for the entire duration of every swipe.
        let timer = Timer(timeInterval: safetyInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard (NSApp.delegate as? AppDelegate)?.isQuitting != true else { return }
            self.evaluateFrontmostApp(quiet: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        safetyTimer = timer

        print("✅ DockStatus started")
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        safetyTimer?.invalidate()
    }

    // MARK: - Space Detection

    @objc private func spaceDidChange() {
        pendingSpaceCheck?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.evaluateFrontmostApp(quiet: false)
            // Re-check shortly after in case the window list hadn't fully
            // settled on the first pass yet, anchored to this exact swipe
            // rather than the independent safety timer, so the worst case
            // is always the same fixed delay instead of depending on timer
            // phase luck. No-ops instantly if the first check was correct.
            DispatchQueue.main.asyncAfter(deadline: .now() + self.spaceRecheckDelay) {
                self.evaluateFrontmostApp(quiet: true)
            }
        }

        pendingSpaceCheck = work
        if spaceCheckDelay <= 0 {
            DispatchQueue.main.async(execute: work)     // same run loop turn
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + spaceCheckDelay, execute: work)
        }
    }

    // MARK: - Notification Handler

    @objc private func activeAppDidChange(_ note: Notification) {
        guard
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }

        let appName = app.localizedName ?? (app.bundleIdentifier ?? "Unknown")
        print("▶ Active app: \(appName)")
        evaluate(app: app, quiet: false)
    }

    // MARK: - Core Logic

    /// Re-checks whatever app macOS currently reports as frontmost.
    private func evaluateFrontmostApp(quiet: Bool) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        evaluate(app: app, quiet: quiet)
    }

    /// Shows the Dock only when the display under the pointer has no standard
    /// app window. That is the display whose Space the user is interacting
    /// with during a multi-monitor desktop swipe.
    private func evaluate(app: NSRunningApplication, quiet: Bool) {
        let bundleID = app.bundleIdentifier ?? ""
        let activeDisplay = activeDisplayBounds()
        let onDesktop = !anyStandardWindowVisible(on: activeDisplay)

        if !quiet {
            print(onDesktop
                  ? "  → Active display is empty → desktop → showing Dock"
                  : "  → Active display has a window → hiding Dock")
        }

        setDockVisible(onDesktop)

        if !quiet {
            let label = app.localizedName ?? bundleID
            postStatus(onDesktop ? "Desktop - Dock shown" : "\(label) active")
        }
    }

    // MARK: - Window Detection

    /// True if at least one normal app window is visibly occupying the active
    /// display. A small edge overlap is ignored so window shadows across a
    /// monitor boundary cannot hide the Dock.
    private func anyStandardWindowVisible(on displayBounds: CGRect) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return false }

        for info in list {
            guard
                let layer = info[kCGWindowLayer as String] as? Int,
                let ownerName = info[kCGWindowOwnerName as String] as? String,
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary
            else { continue }

            // WindowManager owns the invisible "Click to reveal desktop" overlay in macOS 14+.
            let ignoredApps = ["DockAway", "Window Server", "Dock", "WindowManager", "Control Center"]
            if ignoredApps.contains(ownerName) { continue }

            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
            if alpha < 0.05 { continue }

            // Standard windows, plus transient layers reported while Spaces settles.
            guard layer == kCGNormalWindowLevel || (layer > 0 && layer < 25) else { continue }

            var windowRect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict, &windowRect) else { continue }
            guard windowRect.width > 50, windowRect.height > 50 else { continue }

            let overlap = windowRect.intersection(displayBounds)
            if overlap.width >= 50, overlap.height >= 50 {
                return true
            }
        }

        return false
    }

    /// Determines the display under the pointer. Unlike a Dock-window lookup,
    /// this remains reliable while the Dock is hidden.
    private func activeDisplayBounds() -> CGRect {
        // CGEvent(source: nil)?.location is in global display coordinates.
        guard let mouseLoc = CGEvent(source: nil)?.location else {
            return CGDisplayBounds(CGMainDisplayID())
        }

        var displayCount: UInt32 = 0
        var activeDisplays = [CGDirectDisplayID](repeating: 0, count: 10)
        let err = CGGetActiveDisplayList(10, &activeDisplays, &displayCount)

        if err == .success {
            for i in 0..<Int(displayCount) {
                let display = activeDisplays[i]
                let bounds = CGDisplayBounds(display)
                if bounds.contains(mouseLoc) {
                    return bounds
                }
            }
        }

        return CGDisplayBounds(CGMainDisplayID())
    }


    // MARK: - Public Helpers

    func resetState() {
        dockIsShown = false
        evaluateFrontmostApp(quiet: false)
    }

    func simulateOptionCommandDPublic() {
        simulateOptionCommandD()
    }

    /// Latch the Dock down: SHOW is ignored until released. Hiding is unaffected.
    ///
    /// `maximum` is a dead-man's switch. If the release callback never arrives —
    /// the trackpad device stops, a finger-lift frame is dropped — the latch
    /// expires on its own rather than leaving the Dock permanently stuck hidden.
    func beginHoldHidden(maximum: TimeInterval = 5.0) {
        holdLatched = true
        holdLatchExpiry = Date().addingTimeInterval(maximum)
    }

    /// Release the latch, keeping SHOW suppressed for a grace period so a swipe
    /// that is still landing isn't undone the instant fingers lift.
    func endHoldHidden(after seconds: TimeInterval) {
        holdLatched = false
        holdReleaseAt = Date().addingTimeInterval(seconds)
    }

    private func simulateOptionCommandD() {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            print("  ⚠️ Could not create CGEventSource")
            return
        }

        let keyD: CGKeyCode = 2

        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyD, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyD, keyDown: false)
        else { return }

        let modifiers: CGEventFlags = [.maskAlternate, .maskCommand]
        keyDown.flags = modifiers
        keyUp.flags = modifiers

        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)

        print("  ⌨️ Sent ⌘⌥D")
    }

    private func setDockVisible(_ shouldShow: Bool) {
        guard (NSApp.delegate as? AppDelegate)?.isQuitting != true else { return }

        // Stop the timers double-tapping while com.apple.dock's value catches up.
        if Date().timeIntervalSince(lastToggleTime) < toggleDebounce { return }

        let actuallyShown = !(UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false)

        if shouldShow && !actuallyShown {
            // Fingers are down, or a swipe is still landing. Stay hidden.
            if isHoldingHidden { return }

            print("  ⚡ Forcing Dock SHOW")
            dockIsShown = true
            lastToggleTime = Date()
            simulateOptionCommandD()
        } else if !shouldShow && actuallyShown {
            print("  ⚡ Forcing Dock HIDE")
            dockIsShown = false
            lastToggleTime = Date()
            simulateOptionCommandD()
        } else {
            dockIsShown = shouldShow
        }
    }

    // MARK: - Status Helpers

    private func postStatus(_ text: String) {
        (NSApp.delegate as? AppDelegate)?.updateStatus(text)
    }
}
