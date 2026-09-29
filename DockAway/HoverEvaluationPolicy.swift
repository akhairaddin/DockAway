import Foundation
import CoreGraphics

/// Pure scheduling policy shared by the controller and deterministic tests.
struct HoverEvaluationPolicy {
    static let idleInterval: TimeInterval = 0.25
    private var idle: (pid: pid_t?, buttons: Bool, deadline: TimeInterval)?

    mutating func invalidate() { idle = nil }

    mutating func becomeIdle(now: TimeInterval, pid: pid_t?, buttons: Bool) {
        idle = (pid, buttons, now + Self.idleInterval)
    }

    mutating func shouldEvaluate(now: TimeInterval, pointerMoved: Bool, pid: pid_t?, buttons: Bool) -> Bool {
        if let idle, !pointerMoved, idle.pid == pid, idle.buttons == buttons, now < idle.deadline {
            return false
        }
        idle = nil
        return true
    }
}

struct AuthenticationOwnerCache {
    private var cached: Set<pid_t>?
    mutating func invalidate() { cached = nil }
    mutating func owners(load: () -> Set<pid_t>) -> Set<pid_t> {
        if let cached { return cached }
        let value = load()
        cached = value
        return value
    }
}

enum AuthenticationWindowPolicy {
    static func visibleWindows(in windows: [[String: Any]], owners: Set<pid_t>) -> [CGWindowID: pid_t] {
        var visible: [CGWindowID: pid_t] = [:]
        for info in windows {
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  owners.contains(pid),
                  ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let dictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  bounds.width > 1, bounds.height > 1,
                  let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            visible[windowID] = pid
        }
        return visible
    }
}
