import Cocoa
@preconcurrency import ApplicationServices

private final class DockIconClickOperationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

@MainActor
final class DockIconClickMinimizeController {
    static let preferenceKey = "minimizeDockIconOnClick"
    static let hidePreferenceKey = "hideDockIconAppOnClick"
    static let dragThreshold: CGFloat = 6

    enum Mode: Equatable {
        case disabled
        case minimize
        case hide
    }

    enum ClickAction: Equatable {
        case passThrough
        case minimize
        case restore
    }

    enum HideClickAction: Equatable {
        case passThrough
        case hide
        case unhide
    }

    private struct DockTarget {
        let processIdentifier: pid_t
        let bundlePath: String
    }

    private struct PendingClick {
        let processIdentifier: pid_t
        let bundlePath: String
        let origin: CGPoint
        let action: PreparedAction
        var becameDrag: Bool
    }

    private struct WindowReference {
        let element: AXUIElement
        let windowID: CGWindowID
    }

    private struct ManagedWindowBatch {
        let windows: [WindowReference]
        let frontToBack: [CGWindowID]
        var desiredMinimized: Bool
    }

    private enum PreparedAction {
        case minimize(ManagedWindowBatch)
        case restore(ManagedWindowBatch)
        case hide
        case unhide
    }

    private var eventTap: EventTap?
    private var pendingClick: PendingClick?
    private var managedWindows: [pid_t: ManagedWindowBatch] = [:]
    private var operationTokens: [pid_t: DockIconClickOperationToken] = [:]
    private var desiredHiddenStates: [pid_t: Bool] = [:]
    private var hiddenStateGenerations: [pid_t: UInt] = [:]
    private(set) var mode: Mode = .disabled
    var onWillHideApplication: (() -> Void)?
    private let operationQueue = DispatchQueue(
        label: "AK.DockAway.dock-icon-click",
        qos: .userInteractive
    )
    private static let syntheticEventMarker: Int64 = 0x444F434B

    func setEnabled(_ enabled: Bool) {
        setMode(enabled ? .minimize : .disabled)
    }

    func setMode(_ newMode: Mode) {
        guard mode != newMode else {
            if newMode != .disabled { start() }
            return
        }
        stop()
        mode = newMode
        if newMode != .disabled { start() }
    }

    static func mode(minimizeEnabled: Bool, hideEnabled: Bool) -> Mode {
        if hideEnabled { return .hide }
        if minimizeEnabled { return .minimize }
        return .disabled
    }

    isolated deinit {
        stop()
    }

    func stop() {
        pendingClick = nil
        operationTokens.values.forEach { $0.cancel() }
        operationTokens.removeAll()
        managedWindows.removeAll()
        desiredHiddenStates.removeAll()
        hiddenStateGenerations.removeAll()
        eventTap?.invalidate()
        eventTap = nil
    }

    static func clickAction(
        appWasFrontmost: Bool,
        managedDesiredMinimized: Bool?,
        operationInFlight: Bool,
        managedWindowsRemainMinimized: Bool,
        hasVisibleWindows: Bool,
        becameDrag: Bool,
        hasModifiers: Bool
    ) -> ClickAction {
        guard !becameDrag, !hasModifiers else { return .passThrough }
        if let managedDesiredMinimized {
            if managedDesiredMinimized,
               operationInFlight || managedWindowsRemainMinimized {
                return .restore
            }
            if !managedDesiredMinimized, operationInFlight {
                return .minimize
            }
        }
        if appWasFrontmost, hasVisibleWindows { return .minimize }
        return .passThrough
    }

    static func isDragMovement(from origin: CGPoint, to point: CGPoint) -> Bool {
        hypot(point.x - origin.x, point.y - origin.y) > dragThreshold
    }

    static func hideClickAction(
        appWasFrontmost: Bool,
        appIsHidden: Bool,
        managedDesiredHidden: Bool?,
        becameDrag: Bool,
        hasModifiers: Bool
    ) -> HideClickAction {
        guard !becameDrag, !hasModifiers else { return .passThrough }
        if let managedDesiredHidden {
            return managedDesiredHidden ? .unhide : .hide
        }
        if appIsHidden { return .unhide }
        if appWasFrontmost { return .hide }
        return .passThrough
    }

    static func shouldDeferToVorssaint(
        vorssaintRunning: Bool,
        vorssaintMinimizeEnabled: Bool,
        dockAwayOwnsWindows: Bool
    ) -> Bool {
        vorssaintRunning && vorssaintMinimizeEnabled && !dockAwayOwnsWindows
    }

    private func start() {
        guard eventTap == nil, AXIsProcessTrusted() else { return }
        eventTap = EventTap(events: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] type, event in
            self?.handle(type: type, event: event) ?? false
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            return false
        }

        // Replayed mouse downs from DockAway or another event-tap utility are
        // transport for a Dock drag, not fresh Dock clicks to toggle again.
        if event.getIntegerValueField(.eventSourceUserData) != 0 {
            return false
        }

        switch type {
        case .leftMouseDown:
            pendingClick = nil
            guard event.flags.intersection([
                .maskCommand, .maskControl, .maskAlternate, .maskShift
            ]).isEmpty,
            let target = dockTarget(at: event.location),
            target.processIdentifier != getpid()
            else { return false }

            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard let action = prepareAction(
                for: target.processIdentifier,
                appWasFrontmost: frontmostPID == target.processIdentifier
            ) else { return false }
            pendingClick = PendingClick(
                processIdentifier: target.processIdentifier,
                bundlePath: target.bundlePath,
                origin: event.location,
                action: action,
                becameDrag: false
            )
            return true

        case .leftMouseDragged:
            guard var pendingClick else { return false }
            if Self.isDragMovement(from: pendingClick.origin, to: event.location) {
                pendingClick.becameDrag = true
                self.pendingClick = nil
                replayMouseDown(at: pendingClick.origin)
                return false
            }
            self.pendingClick = pendingClick
            return true

        case .leftMouseUp:
            guard let pendingClick else { return false }
            self.pendingClick = nil
            guard !pendingClick.becameDrag,
                  !Self.isDragMovement(from: pendingClick.origin, to: event.location),
                  let releasedTarget = dockTarget(at: event.location),
                  releasedTarget.processIdentifier == pendingClick.processIdentifier,
                  releasedTarget.bundlePath == pendingClick.bundlePath else { return true }

            commit(
                pendingClick.action,
                processIdentifier: pendingClick.processIdentifier
            )
            return true

        default:
            return false
        }
    }

    private func prepareAction(
        for processIdentifier: pid_t,
        appWasFrontmost: Bool
    ) -> PreparedAction? {
        switch mode {
        case .disabled:
            return nil
        case .hide:
            return prepareHideAction(
                for: processIdentifier,
                appWasFrontmost: appWasFrontmost
            )
        case .minimize:
            return prepareMinimizeAction(
                for: processIdentifier,
                appWasFrontmost: appWasFrontmost
            )
        }
    }

    private func prepareHideAction(
        for processIdentifier: pid_t,
        appWasFrontmost: Bool
    ) -> PreparedAction? {
        guard let application = NSRunningApplication(
            processIdentifier: processIdentifier
        ), !application.isTerminated else { return nil }
        switch Self.hideClickAction(
            appWasFrontmost: appWasFrontmost,
            appIsHidden: application.isHidden,
            managedDesiredHidden: desiredHiddenStates[processIdentifier],
            becameDrag: false,
            hasModifiers: false
        ) {
        case .hide:
            return .hide
        case .unhide:
            return .unhide
        case .passThrough:
            return nil
        }
    }

    private func prepareMinimizeAction(
        for processIdentifier: pid_t,
        appWasFrontmost: Bool
    ) -> PreparedAction? {
        var batch = managedWindows[processIdentifier]
        let operationInFlight = operationTokens[processIdentifier] != nil
        let managedWindowsRemainMinimized = batch?.windows.contains {
            $0.element.bool(kAXMinimizedAttribute) == true
        } == true

        if let existing = batch,
           !operationInFlight,
           existing.desiredMinimized,
           !managedWindowsRemainMinimized {
            managedWindows.removeValue(forKey: processIdentifier)
            batch = nil
        }

        if Self.shouldDeferToVorssaint(
            vorssaintRunning: !NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.vorssaint.utils"
            ).isEmpty,
            vorssaintMinimizeEnabled: UserDefaults(
                suiteName: "com.vorssaint.utils"
            )?.bool(forKey: "dockClickMinimize") == true,
            dockAwayOwnsWindows: batch != nil || operationInFlight
        ) {
            return nil
        }

        let needsVisibleWindows = batch == nil
        let visibleWindows = appWasFrontmost && needsVisibleWindows
            ? Self.standardUnminimizedWindows(processIdentifier: processIdentifier)
            : []
        let action = Self.clickAction(
            appWasFrontmost: appWasFrontmost,
            managedDesiredMinimized: batch?.desiredMinimized,
            operationInFlight: operationInFlight,
            managedWindowsRemainMinimized: managedWindowsRemainMinimized,
            hasVisibleWindows: !visibleWindows.isEmpty,
            becameDrag: false,
            hasModifiers: false
        )
        switch action {
        case .restore:
            guard let batch else { return nil }
            return .restore(batch)

        case .minimize:
            if let batch {
                return .minimize(batch)
            }
            return .minimize(ManagedWindowBatch(
                windows: visibleWindows,
                frontToBack: Self.onScreenWindowIDs(
                    processIdentifier: processIdentifier
                ),
                desiredMinimized: true
            ))

        case .passThrough:
            return nil
        }
    }

    private func commit(_ action: PreparedAction, processIdentifier: pid_t) {
        switch action {
        case .hide:
            setApplicationHidden(true, processIdentifier: processIdentifier)

        case .unhide:
            setApplicationHidden(false, processIdentifier: processIdentifier)

        case .restore(var batch):
            batch.desiredMinimized = false
            managedWindows[processIdentifier] = batch
            schedule(
                minimized: false,
                batch: batch,
                processIdentifier: processIdentifier
            )

        case .minimize(var batch):
            batch.desiredMinimized = true
            managedWindows[processIdentifier] = batch
            schedule(
                minimized: true,
                batch: batch,
                processIdentifier: processIdentifier
            )
            pruneFinishedApplicationsIfNeeded()
        }
    }

    private func setApplicationHidden(
        _ hidden: Bool,
        processIdentifier: pid_t
    ) {
        guard let application = NSRunningApplication(
            processIdentifier: processIdentifier
        ), !application.isTerminated else {
            desiredHiddenStates.removeValue(forKey: processIdentifier)
            hiddenStateGenerations.removeValue(forKey: processIdentifier)
            return
        }

        let generation = (hiddenStateGenerations[processIdentifier] ?? 0) &+ 1
        hiddenStateGenerations[processIdentifier] = generation
        desiredHiddenStates[processIdentifier] = hidden

        if hidden {
            onWillHideApplication?()
            application.hide()
        } else {
            application.unhide()
            _ = application.activate(options: [.activateAllWindows])
        }

        // Keep the intended state briefly so rapid repeated clicks toggle from
        // the user's last click instead of an in-between AppKit animation state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self,
                  self.hiddenStateGenerations[processIdentifier] == generation
            else { return }
            self.desiredHiddenStates.removeValue(forKey: processIdentifier)
            self.hiddenStateGenerations.removeValue(forKey: processIdentifier)
        }
    }

    private func replayMouseDown(at point: CGPoint) {
        guard let down = CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }
        down.setIntegerValueField(
            .eventSourceUserData,
            value: Self.syntheticEventMarker
        )
        down.post(tap: .cghidEventTap)
    }

    private func pruneFinishedApplicationsIfNeeded() {
        guard managedWindows.count > 24 else { return }
        managedWindows = managedWindows.filter {
            NSRunningApplication(processIdentifier: $0.key)?.isTerminated == false
        }
    }

    private func schedule(
        minimized: Bool,
        batch: ManagedWindowBatch,
        processIdentifier: pid_t
    ) {
        operationTokens.removeValue(forKey: processIdentifier)?.cancel()
        let token = DockIconClickOperationToken()
        operationTokens[processIdentifier] = token

        operationQueue.async { [weak self] in
            let windows: [WindowReference]
            if minimized {
                windows = batch.windows
            } else {
                windows = batch.windows.sorted { first, second in
                let firstDepth = batch.frontToBack.firstIndex(of: first.windowID) ?? Int.max
                let secondDepth = batch.frontToBack.firstIndex(of: second.windowID) ?? Int.max
                return firstDepth > secondDepth
            }
            }

            let value: CFBoolean = minimized ? kCFBooleanTrue : kCFBooleanFalse
            for window in windows {
                guard !token.isCancelled else { return }
                if window.element.bool(kAXMinimizedAttribute) == minimized {
                    continue
                }
                _ = AXUIElementSetAttributeValue(
                    window.element,
                    kAXMinimizedAttribute as CFString,
                    value
                )
            }

            guard !token.isCancelled else { return }
            DispatchQueue.main.async {
                guard let self,
                      self.operationTokens[processIdentifier] === token,
                      !token.isCancelled else { return }
                self.operationTokens.removeValue(forKey: processIdentifier)

                guard !minimized else { return }
                self.managedWindows.removeValue(forKey: processIdentifier)
                if let app = NSRunningApplication(processIdentifier: processIdentifier),
                   !app.isTerminated {
                    _ = app.activate(options: [])
                    if let frontmostID = batch.frontToBack.first,
                       let frontmostWindow = batch.windows.first(where: {
                           $0.windowID == frontmostID
                       }) {
                        _ = AXUIElementPerformAction(
                            frontmostWindow.element,
                            kAXRaiseAction as CFString
                        )
                    }
                }
            }
        }
    }

    private func dockTarget(at point: CGPoint) -> DockTarget? {
        guard DockHitTesting.pointIsNearDock(point),
              let dockPID = DockHitTesting.dockProcessIdentifier(),
              Self.dockOwns(point: point, processIdentifier: dockPID) else { return nil }

        let dock = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(dock, 0.25)
        guard let children = dock.elements(kAXChildrenAttribute) else { return nil }

        for list in children where list.string(kAXRoleAttribute) == "AXList" {
            guard let listFrame = Self.frame(of: list),
                  let items = list.elements(kAXChildrenAttribute) else { continue }
            let horizontal = listFrame.width >= listFrame.height
            for item in items {
                guard let itemFrame = Self.frame(of: item) else { continue }
                let matchesLongAxis = horizontal
                    ? (point.x >= itemFrame.minX && point.x <= itemFrame.maxX)
                    : (point.y >= itemFrame.minY && point.y <= itemFrame.maxY)
                guard matchesLongAxis,
                      let bundleURL = item.url(kAXURLAttribute) else { continue }
                let bundlePath = bundleURL.standardizedFileURL.path
                guard let app = NSWorkspace.shared.runningApplications.first(where: {
                    $0.activationPolicy == .regular
                        && !$0.isTerminated
                        && $0.bundleURL?.standardizedFileURL.path == bundlePath
                }) else { continue }
                return DockTarget(
                    processIdentifier: app.processIdentifier,
                    bundlePath: bundlePath
                )
            }
        }
        return nil
    }

    private static func dockOwns(point: CGPoint, processIdentifier: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
                return false
            }
            return frame.insetBy(dx: -4, dy: -4).contains(point)
        }
    }

    private static func standardUnminimizedWindows(
        processIdentifier: pid_t
    ) -> [WindowReference] {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.35)
        guard let windows = application.elements(kAXWindowsAttribute) else { return [] }

        return windows.compactMap { window in
            guard window.string(kAXRoleAttribute) == kAXWindowRole,
                  window.string(kAXSubroleAttribute) != kAXSystemDialogSubrole,
                  window.bool(kAXMinimizedAttribute) != true,
                  window.bool("AXFullScreen") != true,
                  let windowID = window.windowID else { return nil }
            var isSettable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(
                window,
                kAXMinimizedAttribute as CFString,
                &isSettable
            ) == .success, isSettable.boolValue else { return nil }
            return WindowReference(element: window, windowID: windowID)
        }
    }

    private static func onScreenWindowIDs(processIdentifier: pid_t) -> [CGWindowID] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return windows.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
            return (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
    }

    /// Empty frames cannot contain a click, so treat them as unreadable.
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let frame = element.frame, frame.width > 0, frame.height > 0 else { return nil }
        return frame
    }
}
