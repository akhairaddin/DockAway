import AppKit
@preconcurrency import ApplicationServices

/// A cooperative deadline for a sequence of synchronous AX messages. macOS can
/// overrun a requested timeout, so this is not a hard real-time guarantee.
// This value owns no UI state. Each operation creates its own budget, whether
// it runs in the event tap or on a background Accessibility work queue.
nonisolated struct AccessibilityRequestBudget {
    private let deadline: TimeInterval
    private let clock: () -> TimeInterval
    private let messageLimit: TimeInterval

    init(seconds: TimeInterval, messageLimit: TimeInterval = 0.02,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        self.deadline = clock() + seconds
        self.messageLimit = messageLimit
    }

    var expired: Bool { deadline - clock() < 0.001 }

    func perform<Value>(_ body: (Float) -> Value) -> Value? {
        let remaining = deadline - clock()
        guard remaining >= 0.001 else { return nil }
        return body(Float(min(messageLimit, remaining)))
    }

    func perform<Value>(on element: AXUIElement, _ body: () -> Value) -> Value? {
        perform { timeout -> Value? in
            // Never set a system-wide timeout here: that changes unrelated AX
            // operations throughout DockAway. All callers use app/window objects.
            guard AXUIElementSetMessagingTimeout(element, timeout) == .success else { return nil }
            defer { AXUIElementSetMessagingTimeout(element, 0) }
            guard !expired else { return nil }
            return body()
        } ?? nil
    }

    func string(_ name: String, of element: AXUIElement) -> String? {
        perform(on: element) { element.string(name) } ?? nil
    }

    func element(_ name: String, of element: AXUIElement) -> AXUIElement? {
        perform(on: element) { element.element(name) } ?? nil
    }

    func frame(of element: AXUIElement) -> CGRect? {
        guard let position = perform(on: element, { element.point() }) ?? nil,
              let size = perform(on: element, { element.size() }) ?? nil else { return nil }
        return CGRect(origin: position, size: size)
    }
}

enum TrafficLightKind: Equatable { case fill, close, minimize }

struct TrafficLightTarget {
    let window: AXUIElement
    let processIdentifier: pid_t
    let windowID: CGWindowID
    let kind: TrafficLightKind
}

enum TrafficLightHitTest {
    static func receivingWindowID(for event: CGEvent?) -> CGWindowID? {
        guard let value = event?.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent),
              value > 0 else { return nil }
        return CGWindowID(exactly: value)
    }

    /// Conservative standard-title-bar band. Reject ordinary content clicks
    /// without sending any Accessibility messages to their app.
    static func isInTrafficLightArea(_ point: CGPoint, windowFrame: CGRect) -> Bool {
        CGRect(x: windowFrame.minX, y: windowFrame.minY,
               width: min(180, windowFrame.width), height: min(80, windowFrame.height)).contains(point)
    }

    static func kind(for subrole: String?) -> TrafficLightKind? {
        switch subrole {
        case "AXFullScreenButton", kAXZoomButtonSubrole: return .fill
        case kAXCloseButtonSubrole: return .close
        case kAXMinimizeButtonSubrole: return .minimize
        default: return nil
        }
    }

    static func candidateWindow(at point: CGPoint, receivingWindowID: CGWindowID?,
                                windows: [[String: Any]]) -> (pid_t, CGWindowID)? {
        for info in windows {
            guard (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue != 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.contains(point) else { continue }
            let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            // Native routing knows which overlays ignore mouse input. Their
            // rectangular CG bounds alone cannot tell us who receives a click.
            if let receivingWindowID, windowID != receivingWindowID { continue }
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  isInTrafficLightArea(point, windowFrame: frame),
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let windowID else { return nil }
            return (pid, windowID)
        }
        return nil
    }

    static func target(at point: CGPoint, receivingWindowID: CGWindowID? = nil,
                       budget: AccessibilityRequestBudget) -> TrafficLightTarget? {
        guard !budget.expired,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]],
              let (pid, windowID) = candidateWindow(at: point, receivingWindowID: receivingWindowID,
                                                  windows: windows) else { return nil }
        let application = AXUIElementCreateApplication(pid)
        var hit: AXUIElement?
        guard budget.perform(on: application, {
            AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit)
        }) == .success, let hit else { return nil }
        let role = budget.string(kAXRoleAttribute, of: hit)
        guard role == kAXButtonRole || role == kAXImageRole else { return nil }
        var current: AXUIElement? = hit
        for _ in 0..<3 {
            guard let button = current else { return nil }
            if let kind = kind(for: budget.string(kAXSubroleAttribute, of: button)),
               let window = budget.element(kAXWindowAttribute, of: button),
               let buttonFrame = budget.frame(of: button), buttonFrame.contains(point),
               budget.perform(on: window, { window.windowID }) == windowID {
                return TrafficLightTarget(window: window, processIdentifier: pid,
                                          windowID: windowID, kind: kind)
            }
            // An image may be the glyph inside the button. Never treat an
            // unrelated title-bar button as its window's green button.
            guard role == kAXImageRole else { return nil }
            current = budget.element(kAXParentAttribute, of: button)
        }
        return nil
    }
}
