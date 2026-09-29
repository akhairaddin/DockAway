import Cocoa
@preconcurrency import ApplicationServices
import Darwin

@MainActor
final class GreenButtonFillController {
    static let preferenceKey = "greenButtonFillsWindow"
    /// Each window's remembered unfilled size, so a relaunch or update can
    /// still restore it. Keyed by "pid:windowID"; values are [x, y, width, height].
    private static let restoreFramesKey = "greenButtonFillRestoreFrames"
    static let animationFrameRate: Double = 120
    private static let animationDuration: TimeInterval = 0.30

    private struct WindowKey: Hashable {
        let processIdentifier: pid_t
        let windowID: CGWindowID
    }

    private struct Target {
        let window: AXUIElement
        let key: WindowKey
    }

    private struct FillRequest {
        let target: Target
        let currentFrame: CGRect
        let destinationFrame: CGRect
        let restoreFrame: CGRect
        let willBeFilled: Bool
        /// False for the made-up default size, which apps may adjust.
        let requiresExactDestination: Bool
        let previousState: FillState?
    }

    private struct FillState {
        /// The window's unfilled size: the size it had when last filled.
        let restoreFrame: CGRect
        /// Direction of the most recent click; used to reverse an animation.
        var isFilled: Bool
    }

    private enum ClickHandling {
        case none
        case consumed
        case fullScreen
    }

    private var eventTap: EventTap?
    private var currentClickHandling = ClickHandling.none
    // Mutate only through setFillState(_:for:) so filled windows are saved.
    private var fillStates: [WindowKey: FillState] = [:]
    private var animationTimers: [WindowKey: Timer] = [:]

    func setEnabled(_ enabled: Bool) {
        if enabled {
            start()
        } else {
            stop()
        }
    }

    isolated deinit {
        stop()
    }

    /// Clears in-memory state only; saved frames survive for the next start.
    func stop() {
        currentClickHandling = .none
        animationTimers.values.forEach { $0.invalidate() }
        animationTimers.removeAll()
        fillStates.removeAll()
        eventTap?.invalidate()
        eventTap = nil
    }

    private func start() {
        guard eventTap == nil else { return }
        guard AXIsProcessTrusted() else {
            dockAwayDebugLog("Green-button fill did not start: Accessibility is not trusted")
            return
        }
        guard let tap = EventTap(events: [.leftMouseDown, .leftMouseUp], handler: { [weak self] type, event in
            self?.handle(type: type, event: event) ?? false
        }) else {
            dockAwayDebugLog("Green-button fill did not start: CGEvent tap creation failed")
            return
        }
        eventTap = tap
        fillStates = Self.loadSavedFillStates()
        dockAwayDebugLog("Green-button fill event tap started; loaded \(fillStates.count) remembered window size(s)")
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            dockAwayDebugLog("Green-button fill event tap disabled by system: \(type.rawValue); re-enabling")
            return false
        }

        switch type {
        case .leftMouseDown:
            guard let target = Self.target(at: event.location) else {
                currentClickHandling = .none
                return false
            }

            if event.flags.contains(.maskAlternate) {
                currentClickHandling = .fullScreen
                event.flags = Self.fullScreenClickFlags(event.flags)
                dockAwayDebugLog("Green-button Option-click passed through for fullscreen pid=\(target.key.processIdentifier) window=\(target.key.windowID)")
                return false
            }

            guard let request = prepareFillRequest(for: target) else {
                currentClickHandling = .none
                dockAwayDebugLog("Green-button fill passed through to macOS because its window could not be prepared pid=\(target.key.processIdentifier) window=\(target.key.windowID)")
                return false
            }

            guard beginFill(request) else {
                currentClickHandling = .none
                dockAwayDebugLog("Green-button fill passed through to macOS because the initial frame change failed pid=\(target.key.processIdentifier) window=\(target.key.windowID)")
                return false
            }

            Self.bringForward(target)
            currentClickHandling = .consumed
            dockAwayDebugLog("Green-button fill click consumed pid=\(target.key.processIdentifier) window=\(target.key.windowID)")
            return true

        case .leftMouseUp:
            defer { currentClickHandling = .none }
            switch currentClickHandling {
            case .consumed:
                return true
            case .fullScreen:
                event.flags = Self.fullScreenClickFlags(event.flags)
                return false
            case .none:
                return false
            }

        default:
            return false
        }
    }

    /// Consuming the native click also suppresses its normal window activation.
    /// Restore that behavior for this exact window, independently of hover policy.
    private static func bringForward(_ target: Target) {
        let mainResult = AXUIElementSetAttributeValue(
            target.window, kAXMainAttribute as CFString, kCFBooleanTrue
        )
        let activated = NSRunningApplication(processIdentifier: target.key.processIdentifier)?
            .activate(options: []) ?? false
        let raiseResult = AXUIElementPerformAction(target.window, kAXRaiseAction as CFString)
        if !activated || raiseResult != .success {
            dockAwayDebugLog("Green-button window activation pid=\(target.key.processIdentifier) window=\(target.key.windowID) activated=\(activated) main=\(mainResult.rawValue) raise=\(raiseResult.rawValue)")
        }
    }

    private func prepareFillRequest(for target: Target) -> FillRequest? {
        guard let currentFrame = Self.frame(of: target.window, key: target.key) else { return nil }
        guard let fillFrame = Self.fillFrame(for: currentFrame) else {
            dockAwayDebugLog("Green-button fill could not determine the display's visible frame window=\(target.key.windowID) current=\(currentFrame)")
            return nil
        }
        guard Self.canSetFrame(of: target.window, key: target.key) else { return nil }

        let previousState = fillStates[target.key]
        let isAnimating = animationTimers[target.key] != nil
        // The button toggles on the window's actual size. A click during an
        // animation reverses it, since the in-between frame is neither state.
        let isFilled = isAnimating
            ? previousState?.isFilled ?? false
            : Self.framesApproximatelyEqual(currentFrame, fillFrame)
        let willBeFilled = !isFilled

        let restoreFrame: CGRect
        var requiresExactDestination = true
        if willBeFilled {
            // Remember the size the user left the window at.
            restoreFrame = isAnimating ? previousState?.restoreFrame ?? currentFrame : currentFrame
        } else if let remembered = previousState?.restoreFrame,
                  !Self.framesApproximatelyEqual(remembered, fillFrame) {
            restoreFrame = remembered
        } else {
            // Nothing smaller to return to, e.g. the window was already filled
            // before DockAway saw it. Use a centered two-thirds default.
            restoreFrame = fillFrame.insetBy(dx: fillFrame.width / 6, dy: fillFrame.height / 6).integral
            requiresExactDestination = false
        }
        let destinationFrame = willBeFilled ? fillFrame : restoreFrame

        dockAwayDebugLog("Green-button fill prepared pid=\(target.key.processIdentifier) window=\(target.key.windowID) current=\(currentFrame) destination=\(destinationFrame) fill=\(willBeFilled)")
        return FillRequest(
            target: target,
            currentFrame: currentFrame,
            destinationFrame: destinationFrame,
            restoreFrame: restoreFrame,
            willBeFilled: willBeFilled,
            requiresExactDestination: requiresExactDestination,
            previousState: previousState
        )
    }

    /// Performs one real frame write before consuming the native click. If the
    /// target app refuses the Accessibility write, the click is allowed to
    /// reach macOS instead of being swallowed with no visible result.
    private func beginFill(_ request: FillRequest) -> Bool {
        let key = request.target.key
        let window = request.target.window

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || Self.framesApproximatelyEqual(request.currentFrame, request.destinationFrame, tolerance: 0.5) {
            guard Self.setFrame(request.destinationFrame, of: window, key: key,
                                verify: request.requiresExactDestination) else {
                _ = Self.setFrame(request.currentFrame, of: window, key: key, context: "rollback")
                return false
            }
            commit(request)
            dockAwayDebugLog("Green-button fill completed without animation pid=\(key.processIdentifier) window=\(key.windowID) fill=\(request.willBeFilled)")
            return true
        }

        // Start with a subpixel-scale step so that the event is only consumed
        // after the target accepted an actual geometry change.
        let initialTime = min(1.0 / Self.animationFrameRate, Self.animationDuration)
        let initialProgress = easeInOutCubic(initialTime / Self.animationDuration)
        let firstFrame = Self.interpolate(
            from: request.currentFrame,
            to: request.destinationFrame,
            progress: initialProgress
        )
        guard Self.setFrame(firstFrame, of: window, key: key) else {
            _ = Self.setFrame(request.currentFrame, of: window, key: key, context: "rollback")
            return false
        }

        commit(request)
        animateFrame(
            of: window,
            key: key,
            from: firstFrame,
            to: request.destinationFrame,
            rollbackFrame: request.currentFrame,
            verifyDestination: request.requiresExactDestination
        ) { [weak self] succeeded in
            guard let self else { return }
            if succeeded {
                dockAwayDebugLog("Green-button fill animation completed pid=\(key.processIdentifier) window=\(key.windowID) fill=\(request.willBeFilled)")
            } else {
                dockAwayDebugLog("Green-button fill animation rolled back pid=\(key.processIdentifier) window=\(key.windowID)")
                self.restore(request.previousState, for: key)
            }
        }
        return true
    }

    private func commit(_ request: FillRequest) {
        let key = request.target.key
        setFillState(
            FillState(restoreFrame: request.restoreFrame, isFilled: request.willBeFilled),
            for: key
        )
    }

    private func restore(_ state: FillState?, for key: WindowKey) {
        setFillState(state, for: key)
    }

    private func setFillState(_ state: FillState?, for key: WindowKey) {
        fillStates[key] = state
        UserDefaults.standard.set(Self.encoded(fillStates), forKey: Self.restoreFramesKey)
    }

    private static func encoded(_ states: [WindowKey: FillState]) -> [String: [Double]] {
        var saved: [String: [Double]] = [:]
        for (key, state) in states {
            let frame = state.restoreFrame
            saved["\(key.processIdentifier):\(key.windowID)"] = [
                frame.minX, frame.minY, frame.width, frame.height
            ].map(Double.init)
        }
        return saved
    }

    /// Saved entries whose window still exists under the same process.
    /// Window numbers are not reused while their owner keeps running.
    private static func loadSavedFillStates() -> [WindowKey: FillState] {
        guard let saved = UserDefaults.standard.dictionary(forKey: restoreFramesKey) as? [String: [Double]],
              !saved.isEmpty else { return [:] }
        let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let liveWindows = Set(windows.compactMap { info -> String? in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            return "\(pid):\(windowID)"
        })
        var states: [WindowKey: FillState] = [:]
        for (identifier, values) in saved where liveWindows.contains(identifier) && values.count == 4 {
            let parts = identifier.split(separator: ":")
            guard parts.count == 2,
                  let pid = pid_t(parts[0]),
                  let windowID = CGWindowID(parts[1]) else { continue }
            states[WindowKey(processIdentifier: pid, windowID: windowID)] = FillState(
                restoreFrame: CGRect(x: values[0], y: values[1], width: values[2], height: values[3]),
                isFilled: false
            )
        }
        if states.count != saved.count {
            UserDefaults.standard.set(encoded(states), forKey: restoreFramesKey)
        }
        return states
    }

    private func animateFrame(
        of window: AXUIElement,
        key: WindowKey,
        from startFrame: CGRect,
        to destinationFrame: CGRect,
        rollbackFrame: CGRect? = nil,
        verifyDestination: Bool = true,
        completion: ((Bool) -> Void)? = nil
    ) {
        animationTimers.removeValue(forKey: key)?.invalidate()
        guard !Self.framesApproximatelyEqual(startFrame, destinationFrame, tolerance: 0.5) else {
            completion?(true)
            return
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let duration = Self.animationDuration
        let failureRollbackFrame = rollbackFrame ?? startFrame
        let timer = Timer(timeInterval: 1.0 / Self.animationFrameRate, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                let linearProgress = min(1, max(0, elapsed / duration))
                let progress = easeInOutCubic(linearProgress)
                let frame = Self.interpolate(
                    from: startFrame,
                    to: destinationFrame,
                    progress: progress
                )
                guard Self.setFrame(
                    frame,
                    of: window,
                    key: key,
                    verify: verifyDestination && linearProgress >= 1
                ) else {
                    timer.invalidate()
                    _ = Self.setFrame(failureRollbackFrame, of: window, key: key, context: "animation rollback")
                    if self.animationTimers[key] === timer {
                        self.animationTimers.removeValue(forKey: key)
                        completion?(false)
                    }
                    return
                }
                guard linearProgress >= 1 else { return }
                timer.invalidate()
                if self.animationTimers[key] === timer {
                    self.animationTimers.removeValue(forKey: key)
                    completion?(true)
                }
            }
        }
        animationTimers[key] = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    static func fullScreenClickFlags(_ flags: CGEventFlags) -> CGEventFlags {
        Self.flags(flags, usingOption: false)
    }

    private static func flags(
        _ flags: CGEventFlags,
        usingOption: Bool
    ) -> CGEventFlags {
        var result = flags
        if usingOption {
            result.insert(.maskAlternate)
        } else {
            result.remove(.maskAlternate)
        }
        return result
    }

    static func framesApproximatelyEqual(
        _ first: CGRect,
        _ second: CGRect,
        tolerance: CGFloat = 4
    ) -> Bool {
        abs(first.minX - second.minX) <= tolerance
            && abs(first.minY - second.minY) <= tolerance
            && abs(first.width - second.width) <= tolerance
            && abs(first.height - second.height) <= tolerance
    }

    private static func interpolate(
        from start: CGRect,
        to destination: CGRect,
        progress: Double
    ) -> CGRect {
        let amount = CGFloat(progress)
        return CGRect(
            x: start.minX + (destination.minX - start.minX) * amount,
            y: start.minY + (destination.minY - start.minY) * amount,
            width: start.width + (destination.width - start.width) * amount,
            height: start.height + (destination.height - start.height) * amount
        )
    }

    private static func target(at point: CGPoint) -> Target? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hitElement) == .success,
              let hitElement else { return nil }

        let hitRole = hitElement.string(kAXRoleAttribute)
        guard hitRole == kAXButtonRole || hitRole == kAXImageRole else { return nil }
        var candidate: AXUIElement? = hitElement
        var fullScreenButtonFound = false
        var window: AXUIElement?
        for _ in 0..<6 {
            guard let current = candidate else { break }
            let role = CFEqual(current, hitElement) ? hitRole : current.string(kAXRoleAttribute)
            if current.string(kAXSubroleAttribute) == "AXFullScreenButton" {
                fullScreenButtonFound = true
            }
            if role == kAXWindowRole {
                window = current
                if let button = current.element(kAXFullScreenButtonAttribute),
                   (CFEqual(button, hitElement) || fullScreenButtonFound) {
                    fullScreenButtonFound = true
                }
                break
            }
            candidate = current.element(kAXParentAttribute)
        }
        guard fullScreenButtonFound, let window else { return nil }
        var processIdentifier: pid_t = 0
        let pidError = AXUIElementGetPid(window, &processIdentifier)
        guard pidError == .success, processIdentifier > 0 else {
            dockAwayDebugLog("Green-button fill found the traffic-light control but could not identify its app; Accessibility error=\(pidError)")
            return nil
        }
        guard let windowID = window.windowID else {
            dockAwayDebugLog("Green-button fill found the traffic-light control but could not identify its window pid=\(processIdentifier)")
            return nil
        }
        dockAwayDebugLog("Green-button fill detected native green button pid=\(processIdentifier) window=\(windowID)")
        return Target(window: window, key: WindowKey(processIdentifier: processIdentifier, windowID: windowID))
    }

    private static func frame(of window: AXUIElement, key: WindowKey) -> CGRect? {
        guard let frame = window.frame else {
            dockAwayDebugLog("Green-button fill could not read the window frame pid=\(key.processIdentifier) window=\(key.windowID)")
            return nil
        }
        return frame
    }

    private static func canSetFrame(of window: AXUIElement, key: WindowKey) -> Bool {
        func isSettable(_ attribute: String) -> Bool {
            var settable = DarwinBoolean(false)
            let error = AXUIElementIsAttributeSettable(window, attribute as CFString, &settable)
            guard error == .success else {
                dockAwayDebugLog("Green-button fill Accessibility settable check failed pid=\(key.processIdentifier) window=\(key.windowID) attribute=\(attribute) error=\(String(describing: error))")
                return false
            }
            guard settable.boolValue else {
                dockAwayDebugLog("Green-button fill target does not allow frame changes pid=\(key.processIdentifier) window=\(key.windowID) attribute=\(attribute)")
                return false
            }
            return true
        }

        return isSettable(kAXPositionAttribute as String)
            && isSettable(kAXSizeAttribute as String)
    }

    private static func fillFrame(for windowFrame: CGRect) -> CGRect? {
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        let screen = NSScreen.screens.first { screen in
            guard let displayID = screen.displayID else { return false }
            return CGDisplayBounds(displayID).contains(center)
        } ?? NSScreen.main
        guard let screen, let displayID = screen.displayID else {
            dockAwayDebugLog("Green-button fill could not match the window to a display center=\(center)")
            return nil
        }

        let displayBounds = CGDisplayBounds(displayID)
        let screenFrame = screen.frame
        let visible = screen.visibleFrame
        let frame = CGRect(
            x: displayBounds.minX + visible.minX - screenFrame.minX,
            y: displayBounds.minY + screenFrame.maxY - visible.maxY,
            width: visible.width,
            height: visible.height
        )
        dockAwayDebugLog("Green-button fill display frame resolved center=\(center) bounds=\(displayBounds) visible=\(frame)")
        return frame
    }

    @discardableResult
    private static func setFrame(
        _ requestedFrame: CGRect,
        of window: AXUIElement,
        key: WindowKey,
        context: String = "frame change",
        verify: Bool = false
    ) -> Bool {
        var position = requestedFrame.origin
        var size = requestedFrame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return false }

        let positionResult = AXUIElementSetAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            positionValue
        )
        guard positionResult == .success else {
            dockAwayDebugLog("Green-button fill \(context) failed pid=\(key.processIdentifier) window=\(key.windowID) attribute=position error=\(String(describing: positionResult))")
            return false
        }

        let sizeResult = AXUIElementSetAttributeValue(
            window,
            kAXSizeAttribute as CFString,
            sizeValue
        )
        guard sizeResult == .success else {
            dockAwayDebugLog("Green-button fill \(context) failed pid=\(key.processIdentifier) window=\(key.windowID) attribute=size error=\(String(describing: sizeResult))")
            return false
        }

        // Resizing can move some apps' windows around their resize anchor.
        // Reapply the requested top-left position and report any failure.
        let finalPositionResult = AXUIElementSetAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            positionValue
        )
        guard finalPositionResult == .success else {
            dockAwayDebugLog("Green-button fill \(context) failed pid=\(key.processIdentifier) window=\(key.windowID) attribute=position-after-size error=\(String(describing: finalPositionResult))")
            return false
        }

        if verify {
            guard let actualFrame = frame(of: window, key: key) else {
                dockAwayDebugLog("Green-button fill \(context) could not verify the resulting frame pid=\(key.processIdentifier) window=\(key.windowID)")
                return false
            }
            guard framesApproximatelyEqual(actualFrame, requestedFrame, tolerance: 2) else {
                dockAwayDebugLog("Green-button fill \(context) was constrained by the target app pid=\(key.processIdentifier) window=\(key.windowID) requested=\(requestedFrame) actual=\(actualFrame)")
                return false
            }
        }
        return true
    }
}
