import AppKit
import ApplicationServices

/// Mission Control shows a desktop's close button only after the pointer has
/// rested on it for a moment, but every desktop's at once while Option is
/// held. With the pointer over the desktop strip, DockAway holds Option for
/// the person, so the close buttons show straight away, and lets go when the
/// pointer leaves the strip or Mission Control closes.
@MainActor
final class MissionControlDesktopCloseButtons {
    static let preferenceKey = "instantMissionControlDesktopCloseButtons"
    /// Option, as the keyboard reports it.
    private static let optionKeyCode: CGKeyCode = 58

    private var timer: Timer?
    /// Each display's desktop strip, in global display coordinates.
    private var strips: [CGRect] = []
    private var stripsCheckedAt: TimeInterval = -.infinity
    private var probing = false
    private var holdingOption = false
    private let probeQueue = DispatchQueue(label: "com.dockaway.mission-control-close-buttons", qos: .userInitiated)

    func setActive(_ active: Bool) {
        if active, UserDefaults.standard.bool(forKey: Self.preferenceKey) {
            start()
        } else {
            stop()
        }
    }

    /// Lets go of Option, if it's held, and stops watching.
    func stop() {
        timer?.invalidate()
        timer = nil
        releaseOption()
        strips = []
        stripsCheckedAt = -.infinity
    }

    private func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        // The strip grows as it expands, so its place is looked up again often.
        if now - stripsCheckedAt > 0.3 { refreshStrips(now: now) }
        guard let pointer = CGEvent(source: nil)?.location else { return }
        let overStrip = strips.contains { $0.insetBy(dx: 0, dy: -4).contains(pointer) }
        if overStrip {
            // Not the start of a drag: Option could change what it does.
            if NSEvent.pressedMouseButtons == 0 { pressOption() }
        } else {
            releaseOption()
        }
    }

    private func refreshStrips(now: TimeInterval) {
        guard !probing else { return }
        probing = true
        stripsCheckedAt = now
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == "com.apple.dock" || $0.bundleIdentifier == "com.apple.WindowManager" }
            .map(\.processIdentifier)
        probeQueue.async { [weak self] in
            let found = Self.stripFrames(pids: pids)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.probing = false
                    guard self.timer != nil else { return }
                    self.strips = found
                }
            }
        }
    }

    /// The physical modifier keys, without anything DockAway posted.
    private static var hardwareFlags: CGEventFlags {
        CGEventSource.flagsState(.hidSystemState)
            .intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn])
    }

    private func pressOption() {
        guard !holdingOption else { return }
        // The person is holding Option already: nothing to add.
        guard !Self.hardwareFlags.contains(.maskAlternate) else { return }
        holdingOption = true
        Self.postOption(down: true, flags: Self.hardwareFlags.union(.maskAlternate))
    }

    private func releaseOption() {
        guard holdingOption else { return }
        holdingOption = false
        // Ends with the keys actually held, so no modifier is left stuck.
        Self.postOption(down: false, flags: Self.hardwareFlags)
    }

    private static func postOption(down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .combinedSessionState),
                                  virtualKey: optionKeyCode, keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cgSessionEventTap)
    }

    /// Mission Control's desktop strip on each display, found through the
    /// Dock's and Window Manager's accessibility, within a short time limit.
    nonisolated private static func stripFrames(pids: [pid_t]) -> [CGRect] {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            AXUIElementSetMessagingTimeout(element, Float(min(remaining, 0.04)))
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
            return result
        }
        func frame(_ element: AXUIElement) -> CGRect? {
            guard let p = value(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
                  let s = value(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
                  AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
            return CGRect(origin: point, size: size)
        }
        var frames: [CGRect] = []
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 6, visited < 120, ProcessInfo.processInfo.systemUptime < deadline else { return }
            visited += 1
            let identifier = value(element, kAXIdentifierAttribute) as? String
            if identifier == "mc.spaces.list" {
                if let strip = frame(element), strip.width > 0, strip.height > 0 { frames.append(strip) }
                return
            }
            // Skip the ordinary Dock icon list.
            if depth == 1 && identifier != "mc" && identifier != "mc.display" { return }
            for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                walk(child, depth: depth + 1)
            }
        }
        for pid in pids { walk(AXUIElementCreateApplication(pid), depth: 0) }
        return frames
    }
}
