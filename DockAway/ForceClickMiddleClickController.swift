import AppKit

/// Decides what happens to a click that might become a force click.
///
/// A force click begins as an ordinary click, so a trackpad click's press is
/// held back for a moment. Pressing on to a force click in that moment makes
/// it a middle click instead, and the app never sees the ordinary click. Let
/// go, start dragging, or keep holding without pressing harder, and the held
/// press goes through as it was.
struct ForceClickMiddleClickTracker {
    enum Phase: Equatable {
        case idle
        /// The press is held back, waiting to see if it becomes a force click.
        case holding
        /// It became a middle click; the rest of this press is swallowed.
        case middle
        /// It went through as an ordinary click.
        case passing
    }

    enum Action: Equatable {
        /// Let the event through.
        case pass
        /// Hold or drop the event.
        case swallow
        /// Discard a stale held press without posting an orphaned mouse-down.
        case discardHeld
        /// Send the held press, then let things carry on.
        case replayHeld
        /// Send the held press, then this event after it, keeping their order.
        case replayHeldThenCurrent
        /// Drop this event and send a middle click instead.
        case middleClick
    }

    /// Long enough for the trackpad to report a press's pressure. A click with
    /// no finger reported on the trackpad, such as a mouse's, isn't held.
    static let trackpadReportWait: TimeInterval = 0.04
    /// After this, a press that hasn't started pressing harder goes through.
    static let settleCheck: TimeInterval = 0.15
    static let settledPressure: Float = 0.25
    /// The longest a press waits to become a force click.
    static let forceWindow: TimeInterval = 0.6
    /// How long after the force window a lifted button's release may still
    /// be on its way before the held press is given up on.
    static let releaseGrace: TimeInterval = 0.1

    private(set) var phase: Phase = .idle
    private var heldAt: TimeInterval = 0
    private var fromTrackpad = false
    private var latestPressure: Float = 0

    /// A left press. `fingersOnTrackpad` is nil when that isn't known.
    mutating func mouseDown(fingersOnTrackpad: Int?, now: TimeInterval) -> Action {
        if fingersOnTrackpad == 0 {
            phase = .passing
            return .pass
        }
        phase = .holding
        heldAt = now
        fromTrackpad = fingersOnTrackpad != nil
        latestPressure = 0
        return .swallow
    }

    /// A pressure report, stage 2 being a force click.
    mutating func pressure(stage: Int, pressure: Float) -> Action {
        switch phase {
        case .holding:
            fromTrackpad = true
            if stage >= 2 { return forceClick() }
            latestPressure = pressure
            return .swallow
        case .middle:
            return .swallow
        case .idle, .passing:
            return .pass
        }
    }

    /// A force click, from its pressure or from the Look Up gesture macOS
    /// sends for it, whichever comes first.
    mutating func forceClick() -> Action {
        switch phase {
        case .holding:
            phase = .middle
            return .middleClick
        case .middle:
            return .swallow
        case .idle, .passing:
            return .pass
        }
    }

    mutating func drag() -> Action {
        switch phase {
        case .holding:
            phase = .passing
            return .replayHeldThenCurrent
        case .middle:
            return .swallow
        case .idle, .passing:
            return .pass
        }
    }

    mutating func mouseUp() -> Action {
        let previous = phase
        phase = .idle
        switch previous {
        case .holding:
            return .replayHeldThenCurrent
        case .middle:
            return .swallow
        case .idle, .passing:
            return .pass
        }
    }

    /// A timed check while holding. Nil when nothing changes.
    mutating func tick(now: TimeInterval, isButtonStillDown: Bool = true) -> Action? {
        guard phase == .holding else { return nil }
        let held = now - heldAt
        if !isButtonStillDown {
            // The button reads up a moment before its release reaches the
            // tap, so wait for the release to replay the click. Only a
            // release that never arrives leaves the held press to discard.
            guard held >= Self.forceWindow + Self.releaseGrace else { return nil }
            phase = .idle
            return .discardHeld
        }
        let release = (!fromTrackpad && held >= Self.trackpadReportWait)
            || (held >= Self.settleCheck && latestPressure < Self.settledPressure)
            || held >= Self.forceWindow
        guard release else { return nil }
        phase = .passing
        return .replayHeld
    }

    /// Lets a held press go only while the physical button is still down.
    /// Otherwise discards it so an orphaned press can never stick down.
    mutating func reset(isButtonStillDown: Bool = true) -> Action? {
        let previous = phase
        if previous == .holding && isButtonStillDown {
            phase = .passing
            return .replayHeld
        }
        phase = .idle
        return nil
    }

    mutating func discard() {
        phase = .idle
    }
}

/// Extras: a force click on the trackpad, pressing on past an ordinary click,
/// makes a middle click.
@MainActor
final class ForceClickMiddleClickController {
    static let preferenceKey = "forceClickMiddleClick"
    /// macOS's pressure reports and its Look Up gesture on a force click.
    /// The trackpad's pressure arrives wrapped in a general gesture event.
    private static let gestureEventType: UInt32 = 29
    private static let pressureEventType: UInt32 = 34
    private static let quickLookEventType: UInt32 = 33

    /// How long after a replayed press its release follows.
    private static let releaseGap: TimeInterval = 0.015

    private var eventTap: EventTap?
    private var tracker = ForceClickMiddleClickTracker()
    private var heldPress: CGEvent?
    private var checks: [DispatchWorkItem] = []
    private var pendingRelease: (workItem: DispatchWorkItem, event: CGEvent)?
    /// How many fingers are on the trackpad, or nil when that isn't known.
    var fingersOnTrackpad: () -> Int? = { nil }
    var isSuppressed: () -> Bool = { false }
    var isLeftMouseButtonDown: () -> Bool = {
        CGEventSource.buttonState(.hidSystemState, button: .left)
    }

    isolated deinit {
        stop()
    }

    func setEnabled(_ enabled: Bool) {
        enabled ? start() : stop()
    }

    func stop() {
        flushPendingRelease()
        releaseHeldPress(stopping: true)
        eventTap?.invalidate()
        eventTap = nil
    }

    private func start() {
        guard eventTap == nil, AXIsProcessTrusted() else { return }
        eventTap = EventTap(events: [.leftMouseDown, .leftMouseUp, .leftMouseDragged],
                            rawEventTypes: [Self.gestureEventType, Self.pressureEventType,
                                            Self.quickLookEventType]) { [weak self] type, event in
            self?.handle(type: type, event: event) ?? false
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            flushPendingRelease()
            releaseHeldPress(stopping: false)
            return false
        }
        // Only the trackpad's own events. Clicks DockAway or another tool
        // posts, including the presses replayed here, go straight through.
        guard event.getIntegerValueField(.eventSourceUserData) == 0,
              event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid())
        else { return false }

        let action: ForceClickMiddleClickTracker.Action
        switch type.rawValue {
        case Self.gestureEventType, Self.pressureEventType, Self.quickLookEventType:
            // Only a press DockAway is holding, or has made a middle click,
            // needs these. The rest of the time they go straight through.
            guard tracker.phase == .holding || tracker.phase == .middle,
                  let gesture = NSEvent(cgEvent: event) else { return false }
            switch gesture.type {
            case .pressure:
                action = tracker.pressure(stage: gesture.stage, pressure: gesture.pressure)
            case .quickLook:
                // Look Up arrives about when the force click does; either
                // makes the middle click, and Look Up never shows.
                action = tracker.forceClick()
            default:
                return false
            }
        case CGEventType.leftMouseDown.rawValue:
            // Deliver any delayed release from the previous click before a new press starts.
            flushPendingRelease()
            discardHeldPress()
            if isSuppressed() || Self.landsOnHostedUI(event) {
                tracker.discard()
                return false
            }
            action = tracker.mouseDown(fingersOnTrackpad: fingersOnTrackpad(),
                                       now: ProcessInfo.processInfo.systemUptime)
            if action == .swallow {
                heldPress = event.copy()
                scheduleChecks()
            }
        case CGEventType.leftMouseDragged.rawValue:
            action = tracker.drag()
        case CGEventType.leftMouseUp.rawValue:
            action = tracker.mouseUp()
        default:
            return false
        }
        return perform(action, current: event)
    }

    /// Whether a press lands on DockAway itself, System Settings, or on a window an
    /// out-of-process helper draws for an app, such as a settings page's
    /// pop-up menu or sheet, or an Open or Save dialog. Holding a press there
    /// and sending it on afterward could leave the helper's menu or sheet
    /// stuck, so System Settings stopped responding; those presses go
    /// through untouched.
    private static func landsOnHostedUI(_ event: CGEvent) -> Bool {
        let windowID = CGWindowID(truncatingIfNeeded: event.getIntegerValueField(.mouseEventWindowUnderMousePointer))
        guard windowID != 0,
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first,
              let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return false }
        if pid == getpid() { return true }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.bundleIdentifier == "com.apple.systempreferences" || app.activationPolicy == .prohibited
    }

    private func perform(_ action: ForceClickMiddleClickTracker.Action, current: CGEvent) -> Bool {
        switch action {
        case .pass:
            return false
        case .swallow:
            return true
        case .discardHeld:
            discardHeldPress()
            return false
        case .replayHeld:
            replayHeldPress()
            return false
        case .replayHeldThenCurrent:
            if current.type == .leftMouseUp {
                guard heldPress != nil else {
                    cancelChecks()
                    return false
                }
                guard let copy = current.copy() else {
                    replayHeldPress()
                    return false
                }
                replayHeldPress()
                // A release right on the heels of its press reads to some
                // apps as no click at all, so it follows a moment later.
                let workItem = DispatchWorkItem { [weak self] in
                    self?.flushPendingRelease()
                }
                pendingRelease = (workItem, copy)
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseGap, execute: workItem)
                return true
            } else {
                replayHeldPress()
                return false
            }
        case .middleClick:
            postMiddleClick(at: heldPress?.location ?? current.location)
            heldPress = nil
            cancelChecks()
            return true
        }
    }

    /// Checks the held press as time passes, since nothing else may arrive
    /// while a finger rests still.
    private func scheduleChecks() {
        cancelChecks()
        for delay in [ForceClickMiddleClickTracker.trackpadReportWait,
                      ForceClickMiddleClickTracker.settleCheck,
                      ForceClickMiddleClickTracker.forceWindow,
                      ForceClickMiddleClickTracker.forceWindow + ForceClickMiddleClickTracker.releaseGrace] {
            let check = DispatchWorkItem { [weak self] in
                guard let self else { return }
                switch self.tracker.tick(now: ProcessInfo.processInfo.systemUptime,
                                         isButtonStillDown: self.isLeftMouseButtonDown()) {
                case .replayHeld:
                    self.replayHeldPress()
                case .discardHeld:
                    self.discardHeldPress()
                default:
                    break
                }
            }
            checks.append(check)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.005, execute: check)
        }
    }

    private func cancelChecks() {
        checks.forEach { $0.cancel() }
        checks.removeAll()
    }

    private func flushPendingRelease() {
        guard let pending = pendingRelease else { return }
        pendingRelease = nil
        pending.workItem.cancel()
        post(pending.event)
    }

    private func discardHeldPress() {
        cancelChecks()
        heldPress = nil
    }

    private func releaseHeldPress(stopping: Bool) {
        let stillDown = isLeftMouseButtonDown()
        if tracker.reset(isButtonStillDown: stillDown) == .replayHeld {
            if stopping { tracker.discard() }
            replayHeldPress()
        } else {
            discardHeldPress()
        }
    }

    private func replayHeldPress() {
        cancelChecks()
        guard let held = heldPress else { return }
        heldPress = nil
        post(held)
    }

    /// Sends a held event on. Sent while its original is being handled, it
    /// goes on from where it was held, so whatever saw it before DockAway,
    /// such as Klack's click sounds, doesn't see it twice. Sent later, as a
    /// delayed release is, it enters at the session like any posted event.
    private func post(_ event: CGEvent) {
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        event.setIntegerValueField(.eventSourceUserData, value: EventTap.replayedClickMarker)
        if let eventTap {
            eventTap.post(event)
        } else {
            event.post(tap: .cgSessionEventTap)
        }
    }

    private func postMiddleClick(at location: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: location, mouseButton: .center) else { continue }
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.setIntegerValueField(.eventSourceUserData, value: EventTap.replayedClickMarker)
            event.post(tap: .cghidEventTap)
        }
        dockAwayDebugLog("Force click: sent a middle click")
    }
}
