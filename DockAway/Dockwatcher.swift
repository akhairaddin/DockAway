import Cocoa
import ApplicationServices

final class DockWatcher {

    private var pendingSpaceCheck: DispatchWorkItem?
    private var dockIsShown = false
    private var safetyTimer: Timer?

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

        // Safety net — also catches cases where NO notification fires at all,
        // e.g. minimizing the last window of an app via a trackpad gesture.
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard (NSApp.delegate as? AppDelegate)?.isQuitting != true else { return }
            self.evaluateFrontmostApp(quiet: true)
        }

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
            // settled on the first pass yet — anchored to this exact swipe
            // rather than the independent safety timer, so the worst case
            // is always the same fixed delay instead of depending on timer
            // phase luck. No-ops instantly if the first check was correct.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.evaluateFrontmostApp(quiet: true)
            }
        }

        pendingSpaceCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
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

    /// Shows the Dock only when NO standard window from ANY app is visible
    /// on the current screen — i.e. the true desktop. Checking system-wide
    /// (rather than just the reported "frontmost" app) is what correctly
    /// handles cases like two tiled apps where minimizing one still leaves
    /// the other covering the screen.
    private func evaluate(app: NSRunningApplication, quiet: Bool) {
        let bundleID = app.bundleIdentifier ?? ""
        let onDesktop = !anyStandardWindowVisible()

        if !quiet {
            print(onDesktop
                  ? "  → No windows visible anywhere → desktop → showing Dock"
                  : "  → A window is still visible → hiding Dock")
        }

        setDockVisible(onDesktop)

        if !quiet {
            let label = app.localizedName ?? bundleID
            postStatus(onDesktop ? "Desktop — Dock shown" : "\(label) active")
        }
    }

    // MARK: - Window Detection

    /// True if at least one normal, reasonably sized window from any app
    /// is currently on screen. Minimized windows are excluded by macOS
    /// from this list automatically, so this also naturally detects
    /// "the only/last window on screen was just minimized."
    private func anyStandardWindowVisible() -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard
            let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return false }

        for info in list {
            guard
                let layer = info[kCGWindowLayer as String] as? Int,
                let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }

            guard layer == kCGNormalWindowLevel else { continue }

            let width = bounds["Width"] ?? 0
            let height = bounds["Height"] ?? 0
            guard width > 50, height > 50 else { continue }

            return true
        }
        return false
    }

    // MARK: - Public Helpers

    func resetState() {
        dockIsShown = false
        evaluateFrontmostApp(quiet: false)
    }

    func simulateOptionCommandDPublic() {
        simulateOptionCommandD()
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

        print("  ⌨️ Sent ⌥⌘D")
    }

    private func setDockVisible(_ shouldShow: Bool) {
        guard (NSApp.delegate as? AppDelegate)?.isQuitting != true else { return }
        let actuallyShown = !(UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false)

        if shouldShow && !actuallyShown {
            print("  ⚡ Forcing Dock SHOW")
            dockIsShown = true
            simulateOptionCommandD()
        } else if !shouldShow && actuallyShown {
            print("  ⚡ Forcing Dock HIDE")
            dockIsShown = false
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
