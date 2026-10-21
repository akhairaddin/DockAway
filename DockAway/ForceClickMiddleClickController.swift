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

    private(set) var phase: Phase = .idle
    private var heldAt: TimeInterval = 0
    private var fromTrackpad = false
    private var latestPressure: Float = 0

    /// A left press. `fingersOnTrackpad` is nil when that isn't known.
    mutating func mouseDown(fingersOnTrackpad: Int?, now: TimeInterval) -> Action {
        guard phase == .idle || phase == .passing else { return .pass }
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
    mutating func tick(now: TimeInterval) -> Action? {
        guard phase == .holding else { return nil }
        let held = now - heldAt
        let release = (!fromTrackpad && held >= Self.trackpadReportWait)
            || (held >= Self.settleCheck && latestPressure < Self.settledPressure)
            || held >= Self.forceWindow
        guard release else { return nil }
        phase = .passing
        return .replayHeld
    }

    /// Lets a held press go, such as when the tap stops or the feature turns off.
    mutating func reset() -> Action? {
        defer { phase = .idle }
        return phase == .holding ? .replayHeld : nil
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

    private var eventTap: EventTap?
    private var tracker = ForceClickMiddleClickTracker()
    private var heldPress: CGEvent?
    private var checks: [DispatchWorkItem] = []
    /// How many fingers are on the trackpad, or nil when that isn't known.
    var fingersOnTrackpad: () -> Int? = { nil }
    var isSuppressed: () -> Bool = { false }

    func setEnabled(_ enabled: Bool) {
        enabled ? start() : stop()
    }

    func stop() {
        releaseHeldPress()
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
            releaseHeldPress()
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
            if isSuppressed() { return false }
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

    private func perform(_ action: ForceClickMiddleClickTracker.Action, current: CGEvent) -> Bool {
        switch action {
        case .pass:
            return false
        case .swallow:
            return true
        case .replayHeld:
            replayHeldPress()
            return false
        case .replayHeldThenCurrent:
            replayHeldPress()
            if let copy = current.copy() { post(copy) }
            return true
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
                      ForceClickMiddleClickTracker.forceWindow] {
            let check = DispatchWorkItem { [weak self] in
                guard let self, self.tracker.tick(now: ProcessInfo.processInfo.systemUptime) == .replayHeld else { return }
                self.replayHeldPress()
            }
            checks.append(check)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.005, execute: check)
        }
    }

    private func cancelChecks() {
        checks.forEach { $0.cancel() }
        checks.removeAll()
    }

    private func releaseHeldPress() {
        if tracker.reset() == .replayHeld { replayHeldPress() }
        cancelChecks()
    }

    private func replayHeldPress() {
        cancelChecks()
        guard let held = heldPress else { return }
        heldPress = nil
        post(held)
    }

    /// Sends a held event on from where it was held, so whatever saw it
    /// before DockAway, such as Klack's click sounds, doesn't see it twice.
    private func post(_ event: CGEvent) {
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
