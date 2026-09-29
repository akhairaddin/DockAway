import Cocoa
import ApplicationServices

@MainActor
final class ChromiumWebAppPlacementController {
    static let preferenceKey = "OpenWebAppsOnActiveDesktop"

    static var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: preferenceKey)
        }
    }

    weak var cursorTeleportManager: CursorTeleportManager?
    var currentSpaceProvider: ((CGDirectDisplayID) -> UInt64?)?

    private(set) var isRunning = false
    private var launchObserver: NSObjectProtocol?
    private var activateObserver: NSObjectProtocol?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var activeTrackingTasks: [pid_t: Task<Void, Never>] = [:]

    private enum WindowPlacementKind: Equatable {
        case chromiumWebApp
        case trash
        case finder(existingWids: Set<CGWindowID>)
        case anyNewRegularWindow(existingWids: Set<CGWindowID>)
    }

    private struct PendingTarget {
        let kind: WindowPlacementKind
        let displayID: CGDirectDisplayID
        let spaceID: UInt64
        let deadline: Date
    }

    private var pendingTargets: [pid_t: PendingTarget] = [:]

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

    func start() {
        guard !isRunning else { return }
        isRunning = true

        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.isRunning,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }
                self.handleApplicationLaunched(app)
            }
        }

        activateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.isRunning,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }
                self.handleApplicationActivated(app)
            }
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.handleMouseDown(at: CursorTeleportManager.currentCursorQuartzPoint())
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, self.isRunning else { return event }
            self.handleMouseDown(at: CursorTeleportManager.currentCursorQuartzPoint())
            return event
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
            self.launchObserver = nil
        }
        if let activateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activateObserver)
            self.activateObserver = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }

        for task in activeTrackingTasks.values {
            task.cancel()
        }
        activeTrackingTasks.removeAll()
        pendingTargets.removeAll()
    }

    // MARK: - Event Handling

    private func handleMouseDown(at point: CGPoint) {
        guard isRunning, DockHitTesting.pointIsNearDock(point) else { return }
        guard let dockPID = DockHitTesting.dockProcessIdentifier() else { return }

        let dock = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(dock, 0.1)
        var elem: AXUIElement?
        guard AXUIElementCopyElementAtPosition(dock, Float(point.x), Float(point.y), &elem) == .success,
              let elem = elem else { return }

        let title = elem.string(kAXTitleAttribute)
        let subrole = elem.string(kAXSubroleAttribute)

        let isTrash = subrole == "AXTrashDockItem" || title == Self.localizedTrashName || (title?.localizedCaseInsensitiveContains("trash") == true)
        let isFinder = (subrole == "AXApplicationDockItem" || subrole == nil) && title == "Finder"

        if isTrash {
            handleTrashDockClicked(at: point)
        } else if isFinder {
            handleFinderDockClicked(at: point)
        } else {
            // Check if it's a Chromium Web App Dock item
            if let url = elem.url(kAXURLAttribute) {
                let bundlePath = url.standardizedFileURL.path
                if let app = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleURL?.standardizedFileURL.path == bundlePath && Self.isChromiumWebApp($0)
                }) {
                    let activeDisplays = CursorTeleportManager.activeDisplays()
                    let targetDisplayID = CursorTeleportManager.display(containing: point, in: activeDisplays) ?? CGMainDisplayID()
                    if let targetSpaceID = currentSpaceProvider?(targetDisplayID) {
                        trackPendingWindow(
                            for: app,
                            targetDisplayID: targetDisplayID,
                            targetSpaceID: targetSpaceID,
                            kind: .chromiumWebApp
                        )
                    }
                }
            }
        }
    }

    private func handleTrashDockClicked(at point: CGPoint) {
        let activeDisplays = CursorTeleportManager.activeDisplays()
        let targetDisplayID = CursorTeleportManager.display(containing: point, in: activeDisplays) ?? CGMainDisplayID()
        guard let targetSpaceID = currentSpaceProvider?(targetDisplayID) else { return }
        guard let finder = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.finder" && !$0.isTerminated
        }) else { return }

        let finderPID = finder.processIdentifier

        // 1. If Trash is ALREADY open, relocate it immediately to this display/space.
        if let trashWid = Self.findTrashWindowID(for: finderPID),
           let info = Self.regularWindowInfo(for: trashWid, pid: finderPID) {
            relocateWindowIfNeeded(
                processIdentifier: finderPID,
                windowID: trashWid,
                bounds: info.bounds,
                targetDisplayID: targetDisplayID,
                targetSpaceID: targetSpaceID
            )
            return
        }

        // 2. Otherwise, track pending Trash window creation.
        pendingTargets[finderPID] = PendingTarget(
            kind: .trash,
            displayID: targetDisplayID,
            spaceID: targetSpaceID,
            deadline: Date().addingTimeInterval(3.0)
        )

        trackPendingWindow(
            for: finder,
            targetDisplayID: targetDisplayID,
            targetSpaceID: targetSpaceID,
            kind: .trash
        )
    }

    private func handleFinderDockClicked(at point: CGPoint) {
        let activeDisplays = CursorTeleportManager.activeDisplays()
        let targetDisplayID = CursorTeleportManager.display(containing: point, in: activeDisplays) ?? CGMainDisplayID()
        guard let targetSpaceID = currentSpaceProvider?(targetDisplayID) else { return }
        guard let finder = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.finder" && !$0.isTerminated
        }) else { return }

        let finderPID = finder.processIdentifier
        let countOnTarget = Self.regularWindowCount(for: finderPID, on: targetDisplayID)
        // If Finder already has a regular window on this display, let normal cycling happen.
        guard countOnTarget == 0 else { return }

        let existingWids = Self.regularWindowIDs(for: finderPID)
        pendingTargets[finderPID] = PendingTarget(
            kind: .finder(existingWids: existingWids),
            displayID: targetDisplayID,
            spaceID: targetSpaceID,
            deadline: Date().addingTimeInterval(3.0)
        )

        trackPendingWindow(
            for: finder,
            targetDisplayID: targetDisplayID,
            targetSpaceID: targetSpaceID,
            kind: .finder(existingWids: existingWids)
        )
    }

    private func handleApplicationLaunched(_ app: NSRunningApplication) {
        guard Self.isChromiumWebApp(app) else { return }
        initiateTracking(for: app, kind: .chromiumWebApp)
    }

    private func handleApplicationActivated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        if Self.isChromiumWebApp(app) {
            if Self.visibleRegularWindowCount(for: pid) == 0 {
                initiateTracking(for: app, kind: .chromiumWebApp)
            }
        } else if app.bundleIdentifier == "com.apple.finder" {
            let pointer = CursorTeleportManager.currentCursorQuartzPoint()
            if DockHitTesting.pointIsNearDock(pointer) {
                let activeDisplays = CursorTeleportManager.activeDisplays()
                let targetDisplayID = CursorTeleportManager.display(containing: pointer, in: activeDisplays) ?? CGMainDisplayID()
                if Self.regularWindowCount(for: pid, on: targetDisplayID) == 0 {
                    let existingWids = Self.regularWindowIDs(for: pid)
                    initiateTracking(for: app, targetDisplayID: targetDisplayID, kind: .finder(existingWids: existingWids))
                }
            }
        }
    }

    func handleWindowCreated(processIdentifier pid: pid_t, windowElement: AXUIElement) {
        guard isRunning, Self.isManaged(pid: pid) else { return }
        guard let wid = windowElement.windowID,
              let info = Self.regularWindowInfo(for: wid, pid: pid) else {
            return
        }

        let targetDisplayID: CGDirectDisplayID
        let targetSpaceID: UInt64

        if let pending = pendingTargets[pid], pending.deadline > Date() {
            targetDisplayID = pending.displayID
            targetSpaceID = pending.spaceID
        } else {
            let pointer = CursorTeleportManager.currentCursorQuartzPoint()
            let activeDisplays = CursorTeleportManager.activeDisplays()
            targetDisplayID = CursorTeleportManager.display(containing: pointer, in: activeDisplays) ?? CGMainDisplayID()
            guard let spaceID = currentSpaceProvider?(targetDisplayID) else { return }
            targetSpaceID = spaceID
        }

        relocateWindowIfNeeded(
            processIdentifier: pid,
            windowID: wid,
            bounds: info.bounds,
            targetDisplayID: targetDisplayID,
            targetSpaceID: targetSpaceID
        )
    }

    private func initiateTracking(
        for app: NSRunningApplication,
        targetDisplayID: CGDirectDisplayID? = nil,
        kind: WindowPlacementKind
    ) {
        let pointer = CursorTeleportManager.currentCursorQuartzPoint()
        let activeDisplays = CursorTeleportManager.activeDisplays()
        let resolvedDisplayID = targetDisplayID ?? CursorTeleportManager.display(containing: pointer, in: activeDisplays) ?? CGMainDisplayID()

        guard let targetSpaceID = currentSpaceProvider?(resolvedDisplayID) else { return }

        pendingTargets[app.processIdentifier] = PendingTarget(
            kind: kind,
            displayID: resolvedDisplayID,
            spaceID: targetSpaceID,
            deadline: Date().addingTimeInterval(3.0)
        )

        trackPendingWindow(
            for: app,
            targetDisplayID: resolvedDisplayID,
            targetSpaceID: targetSpaceID,
            kind: kind
        )
    }

    private func trackPendingWindow(
        for app: NSRunningApplication,
        targetDisplayID: CGDirectDisplayID,
        targetSpaceID: UInt64,
        kind: WindowPlacementKind
    ) {
        let pid = app.processIdentifier
        activeTrackingTasks[pid]?.cancel()

        activeTrackingTasks[pid] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.activeTrackingTasks.removeValue(forKey: pid)
                if self.pendingTargets[pid]?.deadline ?? .distantPast <= Date() {
                    self.pendingTargets.removeValue(forKey: pid)
                }
            }

            let trashName = Self.localizedTrashName

            for iteration in 0..<60 { // Poll for up to 3.0s (60 * 50ms)
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled, self.isRunning else { return }

                guard let windowInfo = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
                    continue
                }

                var candidateWindowID: CGWindowID?
                var candidateWindowBounds: CGRect?

                for info in windowInfo {
                    guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                          let ownerPID = info[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid,
                          let widNum = info[kCGWindowNumber as String] as? UInt32,
                          let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                          let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                          bounds.width >= 100, bounds.height >= 100 else {
                        continue
                    }

                    let wid = widNum
                    let name = info[kCGWindowName as String] as? String ?? ""

                    switch kind {
                    case .trash:
                        if name == trashName || name.localizedCaseInsensitiveContains("trash") {
                            candidateWindowID = wid
                            candidateWindowBounds = bounds
                        }
                    case .finder(let existingWids):
                        if !existingWids.contains(wid) {
                            candidateWindowID = wid
                            candidateWindowBounds = bounds
                        }
                    case .anyNewRegularWindow(let existingWids):
                        if !existingWids.contains(wid) {
                            candidateWindowID = wid
                            candidateWindowBounds = bounds
                        }
                    case .chromiumWebApp:
                        candidateWindowID = wid
                        candidateWindowBounds = bounds
                    }

                    if candidateWindowID != nil {
                        break
                    }
                }

                // Fallback for Finder: after 300ms (iteration 6), if no new window was created,
                // but Finder is active and has a regular window, take its frontmost regular window.
                if candidateWindowID == nil, case .finder = kind, iteration >= 6,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                    for info in windowInfo {
                        guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                              let ownerPID = info[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid,
                              let widNum = info[kCGWindowNumber as String] as? UInt32,
                              let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                              bounds.width >= 100, bounds.height >= 100 else {
                            continue
                        }
                        candidateWindowID = widNum
                        candidateWindowBounds = bounds
                        break
                    }
                }

                guard let wid = candidateWindowID, let bounds = candidateWindowBounds else {
                    continue
                }

                self.relocateWindowIfNeeded(
                    processIdentifier: pid,
                    windowID: wid,
                    bounds: bounds,
                    targetDisplayID: targetDisplayID,
                    targetSpaceID: targetSpaceID
                )
                return
            }
        }
    }

    @discardableResult
    private func relocateWindowIfNeeded(
        processIdentifier pid: pid_t,
        windowID wid: CGWindowID,
        bounds: CGRect,
        targetDisplayID: CGDirectDisplayID,
        targetSpaceID: UInt64
    ) -> Bool {
        let isAlreadyOnTargetSpace = DockAwayIsWindowOnSpace(wid, targetSpaceID)
        let currentDisplay = CursorTeleportManager.display(for: bounds, in: CursorTeleportManager.activeDisplays())
        let isWrongDisplay = currentDisplay != targetDisplayID

        if !isAlreadyOnTargetSpace || isWrongDisplay {
            cursorTeleportManager?.suppressNextApplicationActivationTeleport(duration: 1.2)

            if !isAlreadyOnTargetSpace {
                DockAwayMoveWindowToSpace(wid, targetSpaceID)
            }

            DockAwayRepositionWindowToDisplay(pid, wid, CGDisplayBounds(targetDisplayID))
            DockAwayActivateSpace(targetSpaceID)
            return true
        }
        return false
    }

    // MARK: - Identification Helpers

    static func isManaged(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return false
        }
        if app.bundleIdentifier == "com.apple.finder" {
            return true
        }
        return isChromiumWebApp(app)
    }

    static func isChromiumWebApp(_ app: NSRunningApplication) -> Bool {
        if let bundleID = app.bundleIdentifier {
            if bundleID.hasPrefix("com.google.Chrome.app.") ||
               bundleID.hasPrefix("com.microsoft.edgemac.app.") ||
               bundleID.hasPrefix("com.brave.Browser.app.") ||
               bundleID.hasPrefix("org.chromium.Chromium.app.") ||
               bundleID.hasPrefix("com.vivaldi.Vivaldi.app.") ||
               bundleID.hasPrefix("com.operasoftware.Opera.app.") ||
               bundleID.contains(".app.crx_") {
                return true
            }
        }
        if let bundlePath = app.bundleURL?.path {
            if bundlePath.contains("/Chrome Apps") ||
               bundlePath.contains("/Edge Apps") ||
               bundlePath.contains("/Brave Apps") ||
               bundlePath.contains("app_mode_loader") {
                return true
            }
        }
        if let execURL = app.executableURL {
            if execURL.path.contains("app_mode_loader") ||
               execURL.lastPathComponent == "app_mode_loader" {
                return true
            }
        }
        return false
    }

    static var localizedTrashName: String {
        guard let url = try? FileManager.default.url(
            for: .trashDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return "Trash"
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    static func findTrashWindowID(for pid: pid_t) -> CGWindowID? {
        guard let windowInfo = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let trashName = localizedTrashName
        for info in windowInfo {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid,
                  let wid = info[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 100, bounds.height >= 100 else {
                continue
            }
            let name = info[kCGWindowName as String] as? String ?? ""
            if name == trashName || name.localizedCaseInsensitiveContains("trash") {
                return wid
            }
        }
        return nil
    }

    static func regularWindowIDs(for pid: pid_t) -> Set<CGWindowID> {
        guard let windowInfo = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var ids = Set<CGWindowID>()
        for info in windowInfo {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid,
                  let wid = info[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 100, bounds.height >= 100 else {
                continue
            }
            ids.insert(wid)
        }
        return ids
    }

    static func regularWindowCount(for pid: pid_t, on displayID: CGDirectDisplayID) -> Int {
        guard let windowInfo = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return 0
        }
        let activeDisplays = CursorTeleportManager.activeDisplays()
        var count = 0
        for info in windowInfo {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 100, bounds.height >= 100 else {
                continue
            }
            if CursorTeleportManager.display(for: bounds, in: activeDisplays) == displayID {
                count += 1
            }
        }
        return count
    }

    static func regularWindowInfo(for wid: CGWindowID, pid: pid_t) -> (bounds: CGRect, name: String)? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            .optionIncludingWindow,
            wid
        ) as? [[String: Any]], let info = windowInfo.first else {
            return nil
        }
        guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
              let ownerPID = info[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid,
              let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
              bounds.width >= 100, bounds.height >= 100 else {
            return nil
        }
        let name = info[kCGWindowName as String] as? String ?? ""
        return (bounds, name)
    }

    static func visibleRegularWindowCount(for pid: pid_t) -> Int {
        guard let windowInfo = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return 0
        }
        var count = 0
        for info in windowInfo {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 100, bounds.height >= 100 else {
                continue
            }
            count += 1
        }
        return count
    }
}
