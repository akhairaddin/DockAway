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
    static let cyclePreferenceKey = "cycleDockIconAppWindowsOnClick"
    static let dragThreshold: CGFloat = 6

    enum Mode: Equatable {
        case disabled
        case minimize
        case hide
        case cycle
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

    private struct CycleWindowBatch {
        let windows: [WindowReference]
        let frontToBack: [CGWindowID]
        let focusedWindowID: CGWindowID
    }

    private enum PreparedAction {
        case minimize(ManagedWindowBatch)
        case restore(ManagedWindowBatch)
        case hide
        case unhide
        case cycle(CycleWindowBatch)
    }

    private var eventTap: EventTap?
    private var pendingClick: PendingClick?
    private var managedWindows: [pid_t: ManagedWindowBatch] = [:]
    private var operationTokens: [pid_t: DockIconClickOperationToken] = [:]
    private var desiredHiddenStates: [pid_t: Bool] = [:]
    private var hiddenStateGenerations: [pid_t: UInt] = [:]
    private var windowCycles: [pid_t: DockAppWindowCycle] = [:]
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

    static func mode(minimizeEnabled: Bool, hideEnabled: Bool, cycleEnabled: Bool = false) -> Mode {
        if cycleEnabled { return .cycle }
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
        windowCycles.removeAll()
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
        case .cycle:
            return prepareCycleAction(for: processIdentifier, appWasFrontmost: appWasFrontmost)
        }
    }

    private func prepareCycleAction(for processIdentifier: pid_t,
                                    appWasFrontmost: Bool) -> PreparedAction? {
        // Keep native launch, activation, unhide and single-window behavior.
        guard appWasFrontmost else { return nil }
        let frontToBack = Self.onScreenWindowIDs(processIdentifier: processIdentifier,
                                               preservingMissionControl: true)
        guard frontToBack.count > 1 else { return nil }
        let visibleIDs = Set(frontToBack)
        let application = AXUIElementCreateApplication(processIdentifier)
        // The event tap must not spend an unbounded time querying a slow app.
        let budget = AccessibilityRequestBudget(seconds: 0.08, messageLimit: 0.015)
        guard let windows = budget.perform(on: application, {
            application.elements(kAXWindowsAttribute)
        }) ?? nil else { return nil }

        var eligible: [WindowReference] = []
        for window in windows {
            guard !budget.expired else { return nil }
            guard let windowID = budget.perform(on: window, { window.windowID }) ?? nil,
                  visibleIDs.contains(windowID),
                  budget.string(kAXRoleAttribute, of: window) == kAXWindowRole,
                  budget.string(kAXSubroleAttribute, of: window) == kAXStandardWindowSubrole,
                  budget.perform(on: window, { window.bool(kAXMinimizedAttribute) }) == false,
                  budget.perform(on: window, { window.bool("AXFullScreen") }) != true
            else { continue }
            var actions: CFArray?
            guard budget.perform(on: window, {
                AXUIElementCopyActionNames(window, &actions)
            }) == .success,
            (actions as? [String])?.contains(kAXRaiseAction) == true else { continue }
            eligible.append(WindowReference(element: window, windowID: windowID))
        }
        guard !budget.expired, eligible.count > 1 else { return nil }
        let eligibleIDs = Set(eligible.map(\.windowID))
        let focusedWindow = budget.element(kAXFocusedWindowAttribute, of: application)
            ?? budget.element(kAXMainWindowAttribute, of: application)
        let focusedID: CGWindowID?
        if let focusedWindow {
            guard budget.perform(on: focusedWindow, { focusedWindow.bool(kAXModalAttribute) }) != true,
                  !Self.hasAttachedSheet(focusedWindow, budget: budget)
            else { return nil }
            focusedID = budget.perform(on: focusedWindow, { focusedWindow.windowID }) ?? nil
            // Do not raise a different window behind a modal authentication or
            // document dialog that currently owns the application's focus.
            guard let focusedID, eligibleIDs.contains(focusedID) else { return nil }
        } else {
            focusedID = frontToBack.first(where: { eligibleIDs.contains($0) })
        }
        guard !budget.expired, let focusedID else { return nil }
        return .cycle(CycleWindowBatch(windows: eligible,
            frontToBack: frontToBack.filter { eligibleIDs.contains($0) }, focusedWindowID: focusedID))
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
        case .cycle(let batch):
            cycleWindows(batch, processIdentifier: processIdentifier)

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

    private func cycleWindows(_ batch: CycleWindowBatch, processIdentifier: pid_t) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else { return }
        var cycle = windowCycles[processIdentifier] ?? DockAppWindowCycle()
        guard let nextID = cycle.nextWindow(availableWindowIDs: batch.frontToBack,
            focusedWindowID: batch.focusedWindowID,
            operationInFlight: operationTokens[processIdentifier] != nil),
            let window = batch.windows.first(where: { $0.windowID == nextID }) else { return }
        windowCycles[processIdentifier] = cycle
        operationTokens.removeValue(forKey: processIdentifier)?.cancel()
        let token = DockIconClickOperationToken()
        operationTokens[processIdentifier] = token
        pruneFinishedApplicationsIfNeeded()

        operationQueue.async { [weak self] in
            let budget = AccessibilityRequestBudget(seconds: 0.25, messageLimit: 0.05)
            let application = AXUIElementCreateApplication(processIdentifier)
            let focused = budget.element(kAXFocusedWindowAttribute, of: application)
                ?? budget.element(kAXMainWindowAttribute, of: application)
            let modalBlocksCycle: Bool
            if let focused {
                modalBlocksCycle = budget.string(kAXSubroleAttribute, of: focused) != kAXStandardWindowSubrole
                    || budget.perform(on: focused, { focused.bool(kAXModalAttribute) }) == true
                    || Self.hasAttachedSheet(focused, budget: budget)
            } else {
                modalBlocksCycle = false
            }
            // The window may have closed or been minimized during mouse tracking.
            let valid = !token.isCancelled
                && !modalBlocksCycle
                && Self.onScreenWindowIDs(processIdentifier: processIdentifier,
                                          preservingMissionControl: true).contains(nextID)
                && budget.perform(on: window.element, { window.element.bool(kAXMinimizedAttribute) }) == false
                && budget.perform(on: window.element, { window.element.bool("AXFullScreen") }) != true
                && !budget.expired
            var raised = false
            if valid, !token.isCancelled {
                _ = budget.perform(on: application) {
                    AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString,
                                                 window.element)
                }
                guard !token.isCancelled else { return }
                _ = budget.perform(on: window.element) {
                    AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
                }
                guard !token.isCancelled else { return }
                raised = budget.perform(on: window.element) {
                    AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
                } == .success
            }
            let succeeded = raised
            DispatchQueue.main.async {
                guard let self, self.operationTokens[processIdentifier] === token,
                      !token.isCancelled else { return }
                self.operationTokens.removeValue(forKey: processIdentifier)
                self.windowCycles[processIdentifier]?.finished(windowID: nextID)
                if !succeeded {
                    dockAwayDebugLog("Dock icon window cycle failed pid=\(processIdentifier) window=\(nextID)")
                }
            }
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
        if windowCycles.count > 24 {
            windowCycles = windowCycles.filter {
                NSRunningApplication(processIdentifier: $0.key)?.isTerminated == false
            }
        }
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

    nonisolated private static func onScreenWindowIDs(processIdentifier: pid_t,
                                                       preservingMissionControl: Bool = false) -> [CGWindowID] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        if preservingMissionControl, windows.contains(where: {
            ($0[kCGWindowOwnerName as String] as? String) == "WindowManager"
                && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 14
        }) {
            return [] // Keep the Dock's native Mission Control exit behavior.
        }
        return windows.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
            guard (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue != 0 else { return nil }
            return (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
    }

    nonisolated private static func hasAttachedSheet(_ window: AXUIElement,
                                                     budget: AccessibilityRequestBudget) -> Bool {
        guard let children = budget.perform(on: window, {
            window.elements(kAXChildrenAttribute)
        }) ?? nil else { return budget.expired }
        for child in children {
            guard !budget.expired else { return true }
            if budget.string(kAXRoleAttribute, of: child) == kAXSheetRole { return true }
        }
        return budget.expired
    }

    /// Empty frames cannot contain a click, so treat them as unreadable.
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let frame = element.frame, frame.width > 0, frame.height > 0 else { return nil }
        return frame
    }
}
