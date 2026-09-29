import AppKit
@preconcurrency import ApplicationServices
import Darwin

private final class HoverFocusWithoutRaiseBridge {
    static let shared = HoverFocusWithoutRaiseBridge()

    private struct ProcessSerialNumberValue {
        var highLongOfPSN: UInt32 = 0
        var lowLongOfPSN: UInt32 = 0
    }

    private typealias GetProcessFunction = @convention(c) (
        pid_t,
        UnsafeMutableRawPointer
    ) -> OSStatus
    private typealias SetFrontProcessFunction = @convention(c) (
        UnsafeMutableRawPointer,
        UInt32,
        UInt32
    ) -> CGError
    private typealias PostEventFunction = @convention(c) (
        UnsafeMutableRawPointer,
        UnsafeMutablePointer<UInt8>
    ) -> CGError

    private let getProcess: GetProcessFunction?
    private let setFrontProcess: SetFrontProcessFunction?
    private let postEvent: PostEventFunction?

    private init() {
        let processHandle = dlopen(nil, RTLD_LAZY)
        let skyLightHandle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        )
        getProcess = Self.load(
            "GetProcessForPID",
            from: processHandle,
            as: GetProcessFunction.self
        )
        setFrontProcess = Self.load(
            "_SLPSSetFrontProcessWithOptions",
            from: skyLightHandle,
            as: SetFrontProcessFunction.self
        )
        postEvent = Self.load(
            "SLPSPostEventRecordTo",
            from: skyLightHandle,
            as: PostEventFunction.self
        )
    }

    func focus(_ window: AXUIElement, processIdentifier: pid_t) -> Bool {
        guard let getProcess, let setFrontProcess, let postEvent,
              let windowID = window.windowID else {
            return false
        }

        var process = ProcessSerialNumberValue()
        let processLookupResult = withUnsafeMutablePointer(to: &process) {
            getProcess(processIdentifier, UnsafeMutableRawPointer($0))
        }
        guard processLookupResult == noErr else {
            return false
        }

        if NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
           let focusedWindow = Self.focusedWindow(for: processIdentifier) {
            if let focusedWindowID = focusedWindow.windowID {
                if focusedWindowID == windowID {
                    return true
                }
                postSameApplicationFocusTransition(
                    from: focusedWindowID,
                    to: windowID,
                    process: &process,
                    postEvent: postEvent
                )
            }
        }

        // kCPSUserGenerated selects the target for keyboard input without
        // applying a WindowServer ordering operation. The synthesized key
        // events complete AppKit's active/key-window state transition.
        let userGeneratedEvent: UInt32 = 0x200
        let focusResult = withUnsafeMutablePointer(to: &process) {
            setFrontProcess(UnsafeMutableRawPointer($0), windowID, userGeneratedEvent)
        }
        guard focusResult == .success else {
            return false
        }
        postMakeKeyEvents(windowID: windowID, process: &process, postEvent: postEvent)
        return true
    }

    private func postSameApplicationFocusTransition(
        from previousWindowID: CGWindowID,
        to windowID: CGWindowID,
        process: inout ProcessSerialNumberValue,
        postEvent: PostEventFunction
    ) {
        var event = [UInt8](repeating: 0, count: 0xf8)
        event[0x04] = 0xf8
        event[0x08] = 0x0d
        event[0x8a] = 0x02
        Self.write(previousWindowID, into: &event, at: 0x3c)
        Self.post(event: &event, process: &process, using: postEvent)

        usleep(40_000)
        event[0x8a] = 0x01
        Self.write(windowID, into: &event, at: 0x3c)
        Self.post(event: &event, process: &process, using: postEvent)
    }

    private func postMakeKeyEvents(
        windowID: CGWindowID,
        process: inout ProcessSerialNumberValue,
        postEvent: PostEventFunction
    ) {
        var event = [UInt8](repeating: 0, count: 0xf8)
        event[0x04] = 0xf8
        event[0x3a] = 0x10
        for index in 0x20..<0x30 { event[index] = 0xff }
        Self.write(windowID, into: &event, at: 0x3c)

        for eventType: UInt8 in [0x01, 0x02] {
            event[0x08] = eventType
            Self.post(event: &event, process: &process, using: postEvent)
        }
    }

    private static func post(
        event: inout [UInt8],
        process: inout ProcessSerialNumberValue,
        using postEvent: PostEventFunction
    ) {
        withUnsafeMutablePointer(to: &process) { processPointer in
            event.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                _ = postEvent(UnsafeMutableRawPointer(processPointer), baseAddress)
            }
        }
    }

    private static func focusedWindow(for processIdentifier: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        return application.element(kAXFocusedWindowAttribute)
            ?? application.element(kAXMainWindowAttribute)
    }

    private static func write(
        _ windowID: CGWindowID,
        into event: inout [UInt8],
        at offset: Int
    ) {
        withUnsafeBytes(of: windowID) { bytes in
            event.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
    }

    private static func load<Function>(
        _ symbol: String,
        from handle: UnsafeMutableRawPointer?,
        as type: Function.Type
    ) -> Function? {
        guard let handle, let pointer = dlsym(handle, symbol) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
}

struct HoverActivationDecision {
    static func isAuthenticationPromptOwner(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return ["com.apple.SecurityAgent", "com.apple.LocalAuthentication.UIAgent"].contains(bundleIdentifier)
    }

    static let interactiveAccessoryBundleIdentifiers: Set<String> = [
        "com.apple.CaptiveNetworkAssistant",
        "com.apple.wifi.WiFiAgent",
    ]

    static func isInteractiveAccessoryApp(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        if interactiveAccessoryBundleIdentifiers.contains(bundleIdentifier) { return true }
        let lower = bundleIdentifier.lowercased()
        return lower.contains("captivenetwork")
            || lower.contains("wifiagent")
    }

    static func acceptsWindow(activationPolicy: NSApplication.ActivationPolicy,
                              bundleIdentifier: String? = nil,
                              role: String?, subrole: String?) -> Bool {
        guard isWindowContainerRole(role) else { return false }
        if activationPolicy == .regular { return true }
        // Accessory apps can own interactive login and utility dialogs without
        // appearing in the Dock. Support Wi-Fi onboarding (e.g. Captive Network Assistant)
        // and interactive login dialogs.
        guard activationPolicy == .accessory, role == kAXWindowRole as String else { return false }
        if isInteractiveAccessoryApp(bundleIdentifier: bundleIdentifier) {
            return true
        }
        return subrole == kAXDialogSubrole as String
            || subrole == kAXSystemDialogSubrole as String
    }

    static func isMenuOrMenuBarRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return role == kAXMenuRole as String
            || role == kAXMenuItemRole as String
            || role == kAXMenuBarRole as String
            || role == kAXMenuBarItemRole as String
            || role == kAXMenuButtonRole as String
            || role == kAXPopUpButtonRole as String
            || role == "AXMenuExtra"
    }

    static func isWindowContainerRole(_ role: String?) -> Bool {
        role == kAXWindowRole as String
            || role == kAXSheetRole as String
            || role == kAXDrawerRole as String
            || role == "AXPopover"
    }

    static func isTransientWindowRole(_ role: String?) -> Bool {
        role == kAXSheetRole as String
            || role == kAXDrawerRole as String
            || role == "AXPopover"
            || role == "AXHelpTag"
    }

    static func isTransientWindowSubrole(_ subrole: String?) -> Bool {
        guard let subrole else { return false }
        return subrole == kAXFloatingWindowSubrole as String
            || subrole == kAXDialogSubrole as String
            || subrole == kAXSystemDialogSubrole as String
            || subrole == (kAXUnknownSubrole as String)
    }

    static func pointerMovedAfterSpaceTransition(
        from origin: CGPoint?,
        to current: CGPoint,
        minimumDistance: CGFloat = 6
    ) -> Bool {
        guard let origin else { return true }
        let dx = current.x - origin.x
        let dy = current.y - origin.y
        return dx * dx + dy * dy >= minimumDistance * minimumDistance
    }

    static func pointerIsMoving(
        from previous: CGPoint?,
        to current: CGPoint,
        minimumDistance: CGFloat = 0.5
    ) -> Bool {
        guard let previous else { return false }
        let dx = current.x - previous.x
        let dy = current.y - previous.y
        return dx * dx + dy * dy >= minimumDistance * minimumDistance
    }

    static func effectiveDelay(
        configuredDelay: TimeInterval,
        waitsForPointerToStop: Bool,
        stationaryFloor: TimeInterval
    ) -> TimeInterval {
        waitsForPointerToStop
            ? max(configuredDelay, stationaryFloor)
            : configuredDelay
    }

    static func shouldActivate(
        now: TimeInterval,
        candidateStartedAt: TimeInterval,
        delay: TimeInterval,
        mouseButtonsPressed: Bool,
        suppressed: Bool,
        frontmostApplicationIsProtected: Bool,
        menuIsOpen: Bool = false
    ) -> Bool {
        guard !mouseButtonsPressed,
              !suppressed,
              !frontmostApplicationIsProtected,
              !menuIsOpen else { return false }
        return now - candidateStartedAt >= max(0, delay)
    }
}

@MainActor
final class HoverActivationController {
    static let enabledPreferenceKey = "activateWindowsOnHover"
    static let delayPreferenceKey = "activateWindowsOnHoverDelay"
    static let waitsForPointerToStopPreferenceKey = "activateWindowsOnHoverWaitForPointerToStop"
    static let raisesWindowPreferenceKey = "raiseWindowOnHoverActivation"
    static let protectedBundleIdentifiersPreferenceKey = "hoverActivationProtectedBundleIdentifiers"
    static let defaultDelay: TimeInterval = 0.4
    static let pointerStationaryFloor: TimeInterval = 0.15

    private struct CandidateToken: Equatable {
        let processIdentifier: pid_t
        let windowHash: CFHashCode
    }

    private struct Candidate {
        let token: CandidateToken
        let application: NSRunningApplication
        let window: AXUIElement
    }

    private var timer: Timer?
    private var candidate: Candidate?
    private var candidateStartedAt: TimeInterval = 0
    private var lastActivatedToken: CandidateToken?
    private var previousPointer: CGPoint?
    private var spaceTransitionSuppressUntil: TimeInterval = 0
    private var spaceTransitionPointer: CGPoint?
    private var authenticationWindowIDs: Set<CGWindowID> = []
    private var evaluationPolicy = HoverEvaluationPolicy()
    private var defaultsObserver: NSObjectProtocol?
    private var runningApplicationsObservation: NSKeyValueObservation?
    /// Reading bundleIdentifier costs a LaunchServices round trip per app, so
    /// the helper PIDs are rebuilt only when the running-app list changes.
    private var authenticationPromptOwners = AuthenticationOwnerCache()
    private var workspaceObservers: [NSObjectProtocol] = []
    var isSuppressed: (() -> Bool)?

    /// Preferences consulted on every tick, cached until UserDefaults changes.
    private struct Settings: Equatable {
        let delay: TimeInterval
        let waitsForPointerToStop: Bool
        let protectedBundleIdentifiers: Set<String>
    }
    private static var cachedSettings: Settings?
    private static var settings: Settings {
        if let cachedSettings { return cachedSettings }
        let settings = Settings(
            delay: delay,
            waitsForPointerToStop: waitsForPointerToStop,
            protectedBundleIdentifiers: protectedBundleIdentifiers
        )
        cachedSettings = settings
        return settings
    }

    static let builtInIgnoredBundleIdentifiers: Set<String> = [
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.lowtechguys.rcmd",
        "com.supercmd.SuperCmd",
    ]

    static func isProtected(bundleIdentifier: String) -> Bool {
        isProtected(bundleIdentifier: bundleIdentifier, userProtected: protectedBundleIdentifiers)
    }

    private static func isProtected(bundleIdentifier: String, userProtected: Set<String>) -> Bool {
        builtInIgnoredBundleIdentifiers.contains(bundleIdentifier)
            || userProtected.contains(bundleIdentifier)
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledPreferenceKey)
    }

    static var delay: TimeInterval {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: delayPreferenceKey) != nil else {
            return defaultDelay
        }
        return min(2, max(0, defaults.double(forKey: delayPreferenceKey)))
    }

    static var raisesWindow: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: raisesWindowPreferenceKey) != nil else {
            return false
        }
        return defaults.bool(forKey: raisesWindowPreferenceKey)
    }

    static var waitsForPointerToStop: Bool {
        UserDefaults.standard.bool(forKey: waitsForPointerToStopPreferenceKey)
    }

    static var protectedBundleIdentifiers: Set<String> {
        Set(UserDefaults.standard.stringArray(
            forKey: protectedBundleIdentifiersPreferenceKey
        ) ?? [])
    }

    func setEnabled(_ enabled: Bool) {
        enabled ? start() : stop()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        defaultsObserver = nil
        Self.cachedSettings = nil
        runningApplicationsObservation?.invalidate()
        runningApplicationsObservation = nil
        authenticationPromptOwners.invalidate()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        spaceTransitionSuppressUntil = 0
        spaceTransitionPointer = nil
        previousPointer = nil
        authenticationWindowIDs.removeAll()
        resetCandidate()
    }

    func beginSpaceTransition() {
        guard timer != nil else { return }
        spaceTransitionSuppressUntil = ProcessInfo.processInfo.systemUptime + 1.0
        spaceTransitionPointer = CGEvent(source: nil)?.location
        resetCandidate()
    }

    private func start() {
        guard timer == nil, AXIsProcessTrusted() else { return }
        // Every preference writer lives in this process.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let previousSettings = Self.cachedSettings
                Self.cachedSettings = nil
                if previousSettings != Self.settings { self?.resetCandidate() }
            }
        }
        runningApplicationsObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.authenticationPromptOwners.invalidate()
                    self?.resetCandidate()
                }
            }
        }
        // Wake the cache immediately on helper launch/exit, even if the pointer
        // is stationary. Existing helpers presenting a new dialog are found by
        // the periodic WindowServer snapshot, not cached window visibility.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name != NSWorkspace.didActivateApplicationNotification {
                        self?.authenticationPromptOwners.invalidate()
                    }
                    self?.resetCandidate()
                }
            })
        }
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        timer.tolerance = 0.008
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    static func isAnyMenuOpen() -> Bool {
        isAnyMenuOpen(in: onScreenWindowInfo())
    }

    private static func onScreenWindowInfo() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
    }

    private static func isAnyMenuOpen(in windowInfo: [[String: Any]]?) -> Bool {
        guard let windowInfo else { return false }
        let popUpMenuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        for info in windowInfo {
            if let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
               layer == popUpMenuLevel {
                return true
            }
        }
        return false
    }

    private func isAuthenticationPromptVisible(in windowInfo: () -> [[String: Any]]?) -> Bool {
        // These helpers can outlive their dialogs. Block only while they own
        // an onscreen, visible window, including their elevated window levels.
        let owners = authenticationPromptOwners.owners {
            Set(NSWorkspace.shared.runningApplications.filter {
                HoverActivationDecision.isAuthenticationPromptOwner(bundleIdentifier: $0.bundleIdentifier)
            }.map(\.processIdentifier))
        }
        guard !owners.isEmpty else {
            authenticationWindowIDs.removeAll()
            return false
        }
        guard let windows = windowInfo() else {
            return !authenticationWindowIDs.isEmpty
        }
        let visible = AuthenticationWindowPolicy.visibleWindows(in: windows, owners: owners)
        for (windowID, pid) in visible {
            if !authenticationWindowIDs.contains(windowID) {
                // Restore native focus once on presentation. Never synthesize
                // input or repeatedly activate the authentication helper.
                _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [])
            }
        }
        authenticationWindowIDs = Set(visible.keys)
        return !visible.isEmpty
    }

    private func poll() {
        let now = ProcessInfo.processInfo.systemUptime
        guard let pointer = CGEvent(source: nil)?.location else {
            previousPointer = nil
            resetCandidate()
            return
        }

        let pointerIsMoving = HoverActivationDecision.pointerIsMoving(
            from: previousPointer,
            to: pointer
        )
        previousPointer = pointer


        if now < spaceTransitionSuppressUntil {
            resetCandidate()
            return
        }
        if !HoverActivationDecision.pointerMovedAfterSpaceTransition(
            from: spaceTransitionPointer,
            to: pointer
        ) {
            resetCandidate()
            return
        }
        spaceTransitionPointer = nil

        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let buttonsPressed = NSEvent.pressedMouseButtons != 0
        guard evaluationPolicy.shouldEvaluate(now: now, pointerMoved: pointerIsMoving,
            pid: frontmostApplication?.processIdentifier, buttons: buttonsPressed) else { return }
        func becomeIdle() {
            evaluationPolicy.becomeIdle(now: now, pid: frontmostApplication?.processIdentifier, buttons: buttonsPressed)
        }

        let settings = Self.settings
        let protected = frontmostApplication?.bundleIdentifier.map {
            Self.isProtected(bundleIdentifier: $0, userProtected: settings.protectedBundleIdentifiers)
        } ?? false
        // One WindowServer snapshot serves both window-level checks.
        var windowInfo: [[String: Any]]??
        let snapshot = {
            if let windowInfo { return windowInfo }
            let info = Self.onScreenWindowInfo()
            windowInfo = .some(info)
            return info
        }
        let suppressed = isSuppressed?() == true || isAuthenticationPromptVisible(in: snapshot)
        let menuIsOpen = !suppressed && Self.isAnyMenuOpen(in: snapshot())
        guard !suppressed, !menuIsOpen, !buttonsPressed, !protected else {
            resetCandidate()
            becomeIdle()
            return
        }

        guard let hovered = Self.window(at: pointer, protectedBundleIdentifiers: settings.protectedBundleIdentifiers) else {
            resetCandidate()
            becomeIdle()
            return
        }

        if candidate?.token != hovered.token {
            candidate = hovered
            candidateStartedAt = now
            lastActivatedToken = nil
            return
        }


        if settings.waitsForPointerToStop, pointerIsMoving {
            candidateStartedAt = now
            return
        }

        guard HoverActivationDecision.shouldActivate(
            now: now,
            candidateStartedAt: candidateStartedAt,
            delay: HoverActivationDecision.effectiveDelay(
                configuredDelay: settings.delay,
                waitsForPointerToStop: settings.waitsForPointerToStop,
                stationaryFloor: Self.pointerStationaryFloor
            ),
            mouseButtonsPressed: buttonsPressed,
            suppressed: suppressed,
            frontmostApplicationIsProtected: protected,
            menuIsOpen: menuIsOpen
        ) else { return }

        if lastActivatedToken == hovered.token {
            becomeIdle()
            return
        }

        if Self.isFocused(hovered) {
            becomeIdle()
            return
        }

        activate(hovered)
        lastActivatedToken = hovered.token
        // Require a fresh dwell period if activation failed or another utility
        // immediately restored focus.
        candidateStartedAt = now
    }

    private func activate(_ candidate: Candidate) {
        guard !candidate.application.isTerminated else {
            resetCandidate()
            return
        }

        if candidate.application.processIdentifier == getpid() {
            guard let windowID = candidate.window.windowID,
                  let nsWindow = NSApp.windows.first(where: { $0.windowNumber == Int(windowID) }) else {
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            if Self.raisesWindow {
                nsWindow.orderFrontRegardless()
            }
            nsWindow.makeKey()
            return
        }

        if candidate.application.activationPolicy == .accessory {
            if HoverActivationDecision.isInteractiveAccessoryApp(bundleIdentifier: candidate.application.bundleIdentifier) {
                _ = candidate.application.activate(options: [.activateIgnoringOtherApps])
                let applicationElement = AXUIElementCreateApplication(candidate.application.processIdentifier)
                AXUIElementSetMessagingTimeout(applicationElement, 0.12)
                _ = AXUIElementSetAttributeValue(
                    applicationElement,
                    kAXFocusedWindowAttribute as CFString,
                    candidate.window
                )
                _ = AXUIElementSetAttributeValue(
                    candidate.window,
                    kAXMainAttribute as CFString,
                    kCFBooleanTrue
                )
                if Self.raisesWindow {
                    _ = AXUIElementPerformAction(candidate.window, kAXRaiseAction as CFString)
                }
                return
            }
            // Accessory apps cannot be focused without raising via private WindowServer
            // ordering APIs without desynchronizing AppKit active state and bringing
            // panels forward. Only activate them if window raising is explicitly enabled.
            guard Self.raisesWindow else { return }
            _ = candidate.application.activate(options: [])
            return
        }

        if Self.raisesWindow {
            let applicationElement = AXUIElementCreateApplication(
                candidate.application.processIdentifier
            )
            AXUIElementSetMessagingTimeout(applicationElement, 0.12)
            _ = AXUIElementSetAttributeValue(
                applicationElement,
                kAXFocusedWindowAttribute as CFString,
                candidate.window
            )
            _ = AXUIElementSetAttributeValue(
                candidate.window,
                kAXMainAttribute as CFString,
                kCFBooleanTrue
            )
            _ = AXUIElementPerformAction(candidate.window, kAXRaiseAction as CFString)
            _ = candidate.application.activate(options: [])
            _ = AXUIElementPerformAction(candidate.window, kAXRaiseAction as CFString)
            return
        }

        if HoverFocusWithoutRaiseBridge.shared.focus(
            candidate.window,
            processIdentifier: candidate.application.processIdentifier
        ) {
            return
        }

        // Preserve the user's stacking order if a future macOS release no
        // longer exposes the focus-only WindowServer symbols.
        let applicationElement = AXUIElementCreateApplication(
            candidate.application.processIdentifier
        )
        _ = AXUIElementSetAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            candidate.window
        )
    }

    private func resetCandidate() {
        candidate = nil
        candidateStartedAt = 0
        lastActivatedToken = nil
        evaluationPolicy.invalidate()
    }

    private static func window(at point: CGPoint, protectedBundleIdentifiers: Set<String>) -> Candidate? {
        let systemWide = AXUIElementCreateSystemWide()
        // A timeout on the system-wide element is process-global;
        // Click hit-tests use their own scoped budgets rather than changing it.
        AXUIElementSetMessagingTimeout(systemWide, 0.05)
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &hitElement
        ) == .success,
        var element = hitElement else { return nil }

        // Deeply nested web content can place the AXWindow more than twenty
        // ancestors above the hit element. Keep walking to the application
        // boundary before falling back to WindowServer geometry.
        for _ in 0..<64 {
            let role = element.string(kAXRoleAttribute)
            if HoverActivationDecision.isMenuOrMenuBarRole(role) {
                return nil
            }
            if HoverActivationDecision.isWindowContainerRole(role) {
                if let candidate = candidate(for: element, protectedBundleIdentifiers: protectedBundleIdentifiers) {
                    return candidate
                }
                break
            }

            guard let parent = element.element(kAXParentAttribute) else { break }
            element = parent
        }
        // Embedded browser and web-app content can expose accessibility from a
        // helper process even though the visible window belongs to the
        // host app. Resolve the actual WindowServer owner as a native fallback.
        return visibleWindow(at: point, protectedBundleIdentifiers: protectedBundleIdentifiers)
    }

    private static func isDockAwayFocusableWindow(windowID: CGWindowID) -> Bool {
        guard let window = NSApp.windows.first(where: { $0.windowNumber == Int(windowID) }) else {
            return false
        }
        guard window.isVisible, window.canBecomeKey else { return false }
        if let panel = window as? NSPanel {
            return !panel.styleMask.contains(.nonactivatingPanel)
        }
        return true
    }

    private static func candidate(
        for window: AXUIElement,
        protectedBundleIdentifiers: Set<String>
    ) -> Candidate? {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(window, &processIdentifier) == .success else { return nil }

        if processIdentifier == getpid() {
            guard let windowID = window.windowID,
                  isDockAwayFocusableWindow(windowID: windowID) else {
                return nil
            }
            return Candidate(
                token: CandidateToken(
                    processIdentifier: processIdentifier,
                    windowHash: CFHash(window)
                ),
                application: NSRunningApplication.current,
                window: window
            )
        }

        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated,
              let bundleIdentifier = application.bundleIdentifier,
              !isProtected(bundleIdentifier: bundleIdentifier, userProtected: protectedBundleIdentifiers),
              HoverActivationDecision.acceptsWindow(
                activationPolicy: application.activationPolicy,
                bundleIdentifier: bundleIdentifier,
                role: window.string(kAXRoleAttribute),
                subrole: window.string(kAXSubroleAttribute)) else { return nil }
        return Candidate(
            token: CandidateToken(
                processIdentifier: processIdentifier,
                windowHash: CFHash(window)
            ),
            application: application,
            window: window
        )
    }

    private static func visibleWindow(at point: CGPoint, protectedBundleIdentifiers: Set<String>) -> Candidate? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let popUpMenuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let mainMenuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))

        for info in windowInfo {
            guard let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(
                    dictionaryRepresentation: boundsDictionary as CFDictionary
                  ),
                  bounds.contains(point) else { continue }

            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0

            // System authentication and other elevated windows must occlude
            // the app underneath them. Otherwise hover can focus the dimmed
            // window behind a Touch ID/password prompt.
            if layer == popUpMenuLevel || layer == mainMenuLevel || layer == statusLevel {
                return nil
            }

            guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            let winID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0

            let isDockAwayTarget = ownerPID == getpid() && isDockAwayFocusableWindow(windowID: winID)
            let isInteractiveAccessory: Bool = {
                guard let app = NSRunningApplication(processIdentifier: ownerPID) else { return false }
                return HoverActivationDecision.isInteractiveAccessoryApp(bundleIdentifier: app.bundleIdentifier)
            }()
            guard layer == 0 || isDockAwayTarget || (layer <= 10 && isInteractiveAccessory) else {
                return nil
            }

            if isDockAwayTarget {
                let applicationElement = AXUIElementCreateApplication(ownerPID)
                if let windows = applicationElement.elements(kAXWindowsAttribute),
                   let matchingWindow = windows.first(where: {
                       $0.windowID == winID
                   }),
                   let result = candidate(for: matchingWindow, protectedBundleIdentifiers: protectedBundleIdentifiers) {
                    return result
                }
                return nil
            }

            guard ownerPID != getpid() else { continue }
            guard let application = NSRunningApplication(processIdentifier: ownerPID),
                  application.activationPolicy != .prohibited,
                  !application.isTerminated else { return nil }

            let applicationElement = AXUIElementCreateApplication(ownerPID)
            AXUIElementSetMessagingTimeout(applicationElement, 0.06)
            guard let windows = applicationElement.elements(kAXWindowsAttribute) else { return nil }

            let matchingWindow = windows.first { window in
                guard let position = window.point(kAXPositionAttribute),
                      let size = window.size(kAXSizeAttribute) else {
                    return false
                }
                return CGRect(origin: position, size: size).contains(point)
            }
            if let matchingWindow, let result = candidate(for: matchingWindow, protectedBundleIdentifiers: protectedBundleIdentifiers) {
                return result
            }
            // The topmost window under the pointer blocks windows behind it,
            // even when its owner cannot expose a focusable AX window.
            return nil
        }
        return nil
    }

    private static func isFocused(_ candidate: Candidate) -> Bool {
        if candidate.application.processIdentifier == getpid() {
            guard let windowID = candidate.window.windowID,
                  let nsWindow = NSApp.windows.first(where: { $0.windowNumber == Int(windowID) }) else {
                return false
            }
            return nsWindow.isKeyWindow
        }

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == candidate.application.processIdentifier else { return false }
        let applicationElement = AXUIElementCreateApplication(
            candidate.application.processIdentifier
        )
        AXUIElementSetMessagingTimeout(applicationElement, 0.12)
        let focusedWindow = applicationElement.element(kAXFocusedWindowAttribute)
        if let focusedWindow {
            if CFEqual(focusedWindow, candidate.window) { return true }
            if isRelated(candidate.window, to: focusedWindow)
                || HoverActivationDecision.isTransientWindowRole(
                    focusedWindow.string(kAXRoleAttribute)
                )
                || HoverActivationDecision.isTransientWindowSubrole(
                    focusedWindow.string(kAXSubroleAttribute)
                ) {
                return true
            }
        }

        let mainWindow = applicationElement.element(kAXMainWindowAttribute)
        if let mainWindow {
            if CFEqual(mainWindow, candidate.window) { return true }
            if isRelated(candidate.window, to: mainWindow) {
                return true
            }
        }

        let candidateRole = candidate.window.string(kAXRoleAttribute)
        let candidateSubrole = candidate.window.string(kAXSubroleAttribute)
        if HoverActivationDecision.isTransientWindowRole(candidateRole)
            || HoverActivationDecision.isTransientWindowSubrole(candidateSubrole) {
            return true
        }

        // If the frontmost application only exposes one main AX window, that window
        // is already active. Re-activating it sends redundant focus transitions
        // and synthesized key events that dismiss popups and omnibox suggestions.
        if let windows = applicationElement.elements(kAXWindowsAttribute) {
            if windows.count <= 1, let first = windows.first, CFEqual(first, candidate.window) {
                return true
            }
        }

        // Fallback to WindowServer stacking order: if candidate.window is the
        // topmost on-screen window belonging to the frontmost application, it is
        // already the active window.
        if isTopmostWindowOfFrontmostApplication(candidate) {
            return true
        }

        return false
    }

    private static func isTopmostWindowOfFrontmostApplication(_ candidate: Candidate) -> Bool {
        guard let candidateWindowID = candidate.window.windowID else {
            return false
        }
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        let pid = candidate.application.processIdentifier
        for info in windowInfo {
            guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID == pid else { continue }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }
            guard let winID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }

            if winID == candidateWindowID {
                return true
            }

            // An auxiliary dropdown or autocomplete overlay (such as Chromium's
            // Omnibox popup) sits atop the active window. If the topmost layer-0
            // window for this process overlaps candidate.window, the candidate is
            // already the focused host window.
            if let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
               let overlayBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
               let candPos = candidate.window.point(kAXPositionAttribute),
               let candSize = candidate.window.size(kAXSizeAttribute) {
                let candRect = CGRect(origin: candPos, size: candSize)
                if candRect.intersects(overlayBounds) {
                    return true
                }
            }

            // The topmost window for this process is a separate document window.
            return false
        }
        return false
    }

    private static func isRelated(_ first: AXUIElement, to second: AXUIElement) -> Bool {
        func reaches(_ target: AXUIElement, from start: AXUIElement) -> Bool {
            var current = start
            for _ in 0..<64 {
                if CFEqual(current, target) { return true }
                guard let parent = current.element(kAXParentAttribute) else {
                    return false
                }
                current = parent
            }
            return false
        }
        return reaches(second, from: first) || reaches(first, from: second)
    }
}
