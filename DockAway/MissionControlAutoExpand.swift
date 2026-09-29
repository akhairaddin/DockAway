import Cocoa
import ApplicationServices

@MainActor
final class MissionControlAutoExpand {
    static let preferenceKey = "autoExpandMissionControlDesktops"
    private var generation = 0
    private var restoringPointer = false
    private let probeQueue = DispatchQueue(label: "com.dockaway.mission-control-expand", qos: .userInitiated)
    private struct StripTarget: Sendable {
        let point: CGPoint
        let belowStrip: CGPoint
        let expanded: Bool
    }

    func cancel() { generation += 1 }

    func entered(isStillActive: @escaping () -> Bool) {
        cancel()
        guard UserDefaults.standard.bool(forKey: Self.preferenceKey) else { return }
        let request = generation
        dockAwayDebugLog("Mission Control auto-expand scheduled")
        locateStrip(request: request, attempt: 0, isStillActive: isStillActive)
    }

    private func locateStrip(request: Int, attempt: Int, didHover: Bool = false, isStillActive: @escaping () -> Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.generation == request, isStillActive(),
                  UserDefaults.standard.bool(forKey: Self.preferenceKey),
                  !self.restoringPointer, NSEvent.pressedMouseButtons == 0,
                  let original = CGEvent(source: nil)?.location else { return }
            let displays = NSScreen.screens.compactMap(\.displayID)
            guard let display = displays.first(where: { CGDisplayBounds($0).contains(original) }) else { return }
            let bounds = CGDisplayBounds(display)
            let pids = NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier == "com.apple.dock" || $0.bundleIdentifier == "com.apple.WindowManager"
            }.map(\.processIdentifier)
            self.probeQueue.async { [weak self] in
                let target = Self.stripTarget(pids: pids, display: bounds)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == request, isStillActive(),
                          UserDefaults.standard.bool(forKey: Self.preferenceKey) else { return }
                    guard let target else {
                        dockAwayDebugLog("Mission Control auto-expand: strip not ready, attempt \(attempt)")
                        if attempt < 3 { self.locateStrip(request: request, attempt: attempt + 1, didHover: didHover, isStillActive: isStillActive) }
                        return
                    }
                    if target.expanded {
                        if didHover {
                            // Once expanded, enter a real thumbnail and leave it
                            // so Mission Control receives its hover-exit event.
                            self.hover(target: target.point, belowStrip: target.belowStrip, display: display)
                        }
                        return
                    }
                    self.hover(target: target.point, belowStrip: nil, display: display)
                    // Opening animations may ignore the first hover. Confirm the
                    // native strip grew before stopping, with bounded retries.
                    if attempt < 3 { self.locateStrip(request: request, attempt: attempt + 1, didHover: true, isStillActive: isStillActive) }
                }
            }
        }
    }

    private func hover(target: CGPoint, belowStrip: CGPoint?, display: CGDirectDisplayID) {
            guard !restoringPointer, NSEvent.pressedMouseButtons == 0,
                  let original = CGEvent(source: nil)?.location,
                  CGDisplayBounds(display).contains(original),
                  let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                      mouseCursorPosition: target, mouseButton: .left) else { return }
            self.restoringPointer = true
            let request = generation
            dockAwayDebugLog("Mission Control auto-expand hover at \(target)")
            event.post(tap: .cghidEventTap)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { [self] in
                // Always finish restoration, even if disabled or stopped mid-pulse.
                // Never pull the pointer back if the user moved or began dragging.
                guard NSEvent.pressedMouseButtons == 0,
                      let current = CGEvent(source: nil)?.location,
                      hypot(current.x - target.x, current.y - target.y) < 2,
                      CGDisplayIsActive(display) != 0 else {
                    self.restoringPointer = false
                    return
                }
                guard self.generation == request, let belowStrip,
                      let exitHover = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                              mouseCursorPosition: belowStrip, mouseButton: .left) else {
                    CGWarpMouseCursorPosition(original)
                    self.restoringPointer = false
                    return
                }
                // A warp alone does not deliver a hover-exit event to Mission
                // Control. Briefly cross the strip's lower edge first.
                exitHover.post(tap: .cghidEventTap)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { [self] in
                    defer { self.restoringPointer = false }
                    guard NSEvent.pressedMouseButtons == 0,
                          let current = CGEvent(source: nil)?.location,
                          hypot(current.x - belowStrip.x, current.y - belowStrip.y) < 2,
                          CGDisplayIsActive(display) != 0 else { return }
                    // Center only after the complete thumbnail enter/exit sequence.
                    // Cancellation still restores the pre-hover position.
                    let bounds = CGDisplayBounds(display)
                    let destination = self.generation == request
                        ? CGPoint(x: bounds.midX, y: bounds.midY)
                        : original
                    CGWarpMouseCursorPosition(destination)
                }
            }
    }

    // Read-only AX work stays off the UI thread and has a shared time budget.
    nonisolated private static func stripTarget(pids: [pid_t], display: CGRect) -> StripTarget? {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.18
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
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) -> StripTarget? {
            guard depth < 6, visited < 100, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            visited += 1
            let identifier = value(element, kAXIdentifierAttribute) as? String
            let children = value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            if identifier == "mc.spaces.list", let strip = frame(element),
               strip.width > 0, strip.height > 0, display.contains(CGPoint(x: strip.midX, y: strip.midY)) {
                // The bottom of the collapsed strip is below notch overlays.
                // Aim inside a desktop label, not empty space or the add button.
                for child in children {
                    guard let rect = frame(child) else { continue }
                    let visible = rect.intersection(strip)
                    guard !visible.isNull, visible.width > 20, visible.height > 12 else { continue }
                    return StripTarget(point: CGPoint(x: visible.minX + 20,
                                                      y: strip.height > 110 ? visible.midY : strip.maxY - 12),
                                       belowStrip: CGPoint(x: visible.minX + 20,
                                                           y: min(display.maxY - 1, strip.maxY + 8)),
                                       expanded: strip.height > 110)
                }
            }
            // Skip the ordinary Dock icon list and unrelated application windows.
            if depth == 1 && identifier != "mc" && identifier != "mc.display" { return nil }
            for child in children {
                if let point = walk(child, depth: depth + 1) { return point }
            }
            return nil
        }
        for pid in pids {
            if let point = walk(AXUIElementCreateApplication(pid), depth: 0) { return point }
        }
        return nil
    }
}
