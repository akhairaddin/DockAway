import Foundation
import CoreGraphics

struct ShownDockWorkArea {
    let screenFrame: CGRect
    let visibleFrame: CGRect
    let capturedAt: TimeInterval

    func isUsable(on frame: CGRect, now: TimeInterval) -> Bool {
        screenFrame == frame && now >= capturedAt
            && now - capturedAt <= DockGapCorrectionRetryPolicy.lifetime
    }
}

/// Only reclaim the bottom Dock's reserved space. All rectangles use AX's
/// global, top-left coordinates. Never turn an ordinary window into a fill.
enum DockGapCorrectionGeometry {
    static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    static func expandedFrame(window: CGRect, oldWorkArea: CGRect, newWorkArea: CGRect) -> CGRect? {
        guard window.width > 0, window.height > 0,
              newWorkArea.maxY - oldWorkArea.maxY > 10,
              abs(newWorkArea.minY - oldWorkArea.minY) < 3,
              abs(newWorkArea.minX - oldWorkArea.minX) < 3,
              abs(newWorkArea.width - oldWorkArea.width) < 3,
              abs(window.minX - oldWorkArea.minX) <= 4,
              abs(window.minY - oldWorkArea.minY) <= 4,
              abs(window.width - oldWorkArea.width) <= 4,
              abs(window.maxY - oldWorkArea.maxY) <= 8 else { return nil }
        return CGRect(x: window.minX, y: window.minY, width: window.width,
                      height: newWorkArea.maxY - window.minY)
    }

    static func isExpansionInFlight(window: CGRect, oldWorkArea: CGRect, target: CGRect) -> Bool {
        abs(window.minX - target.minX) <= 2
            && abs(window.minY - target.minY) <= 2
            && abs(window.width - target.width) <= 2
            && window.maxY > oldWorkArea.maxY
            && window.maxY < target.maxY
    }
}

/// A successful AX write is not completion: an app can acknowledge it and
/// then apply its saved launch frame. Observe a stable result before retiring.
struct DockGapCorrectionRetryPolicy {
    enum Action: Equatable {
        case wait
        case resize(CGRect)
        case finish
    }

    static let lifetime: TimeInterval = 8
    static let verificationInterval: TimeInterval = 1.5
    static let maximumWrites = 12
    private let deadline: TimeInterval
    private(set) var writeCount = 0
    private(set) var requestedFrame: CGRect?
    private var verifiedSince: TimeInterval?
    private var lastAttemptAt = -TimeInterval.infinity

    init(now: TimeInterval) { deadline = now + Self.lifetime }
    func hasExpired(now: TimeInterval) -> Bool { now >= deadline }

    mutating func action(window: CGRect, oldWorkArea: CGRect,
                         newWorkArea: CGRect, now: TimeInterval) -> Action {
        guard !hasExpired(now: now) else { return .finish }
        if let requestedFrame, DockGapCorrectionGeometry.approximatelyEqual(window, requestedFrame) {
            if verifiedSince == nil { verifiedSince = now }
            return now - verifiedSince! >= Self.verificationInterval ? .finish : .wait
        }
        verifiedSince = nil
        // AX can expose intermediate animation frames. Give the app time to
        // finish, then retry if it stopped partway into the reclaimed space.
        if let requestedFrame, DockGapCorrectionGeometry.isExpansionInFlight(
            window: window, oldWorkArea: oldWorkArea, target: requestedFrame
        ) {
            guard now - lastAttemptAt >= 0.6 else { return .wait }
            return writeCount < Self.maximumWrites ? .resize(requestedFrame) : .finish
        }
        if let expanded = DockGapCorrectionGeometry.expandedFrame(
            window: window, oldWorkArea: oldWorkArea, newWorkArea: newWorkArea
        ) {
            guard now - lastAttemptAt >= 0.3 else { return .wait }
            return writeCount < Self.maximumWrites ? .resize(expanded) : .finish
        }
        // After our first write, an unrelated frame change means the user's
        // window manager or the app now owns its size. Do not fight it.
        return requestedFrame == nil ? .wait : .finish
    }

    mutating func didAttemptResize(to frame: CGRect, now: TimeInterval) {
        writeCount += 1
        requestedFrame = frame
        verifiedSince = nil
        lastAttemptAt = now
    }
}
