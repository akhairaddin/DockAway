import Cocoa
import ApplicationServices

// Keeps the unmanaged AX callback pointer safe without retaining DockWatcher.
// The observation owns this context for exactly as long as its run-loop source
// is installed.
private final class DockWatcherAXContext {
    let processIdentifier: pid_t
    let handler: (pid_t, AXObserver, AXUIElement, String) -> Void

    init(
        processIdentifier: pid_t,
        handler: @escaping (pid_t, AXObserver, AXUIElement, String) -> Void
    ) {
        self.processIdentifier = processIdentifier
        self.handler = handler
    }
}

private final class DockWatcherAXObservation {
    let observer: AXObserver
    let applicationElement: AXUIElement
    let context: DockWatcherAXContext
    var registeredApplicationNotifications = [String]()
    var unsupportedApplicationNotifications = Set<String>()
    var observedWindows = [AXUIElement]()
    var hasTransientRegistrationFailure = false

    init(
        observer: AXObserver,
        applicationElement: AXUIElement,
        context: DockWatcherAXContext
    ) {
        self.observer = observer
        self.applicationElement = applicationElement
        self.context = context
    }
}

private let dockWatcherAXCallback: AXObserverCallback = {
    observer, element, notification, refcon in
    guard let refcon else { return }

    let context = Unmanaged<DockWatcherAXContext>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    context.handler(
        context.processIdentifier,
        observer,
        element,
        notification as String
    )
}

// Read-only access to macOS' live Space ordering and the windows assigned to
// an inactive Space. These symbols are private, so every lookup is dynamic
// and optional. If Apple changes them, DockAway simply falls back to its
// existing on-screen destination probe instead of failing to launch.
private final class DockWatcherSpaceAPI {
    struct Space {
        let identifier: UInt64
        let type: Int
    }

    struct Neighbors {
        let previous: Space?
        let next: Space?
    }

    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpacesFn =
        @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopyWindowsWithOptionsAndTagsFn = @convention(c) (
        Int32,
        UInt32,
        CFArray,
        UInt32,
        UnsafeMutablePointer<UInt64>,
        UnsafeMutablePointer<UInt64>
    ) -> Unmanaged<CFArray>?

    private var libraryHandles = [UnsafeMutableRawPointer]()
    private var mainConnectionIDFn: MainConnectionIDFn?
    private var copyManagedDisplaySpacesFn: CopyManagedDisplaySpacesFn?
    private var copyWindowsWithOptionsAndTagsFn: CopyWindowsWithOptionsAndTagsFn?

    init() {
        let frameworkPaths = [
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
        ]

        for path in frameworkPaths {
            if let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) {
                libraryHandles.append(handle)
            }
        }

        // Prefer current SLS names, then the older CGS aliases. Resolve each
        // family from one image so the connection and query functions match.
        for handle in libraryHandles {
            if installFunctions(from: handle, prefix: "SLS") { return }
        }
        for handle in libraryHandles {
            if installFunctions(from: handle, prefix: "CGS") { return }
        }
    }

    deinit {
        for handle in libraryHandles {
            dlclose(handle)
        }
    }

    private func installFunctions(
        from handle: UnsafeMutableRawPointer,
        prefix: String
    ) -> Bool {
        guard
            let mainSymbol = dlsym(handle, "\(prefix)MainConnectionID"),
            let spacesSymbol = dlsym(handle, "\(prefix)CopyManagedDisplaySpaces"),
            let windowsSymbol = dlsym(handle, "\(prefix)CopyWindowsWithOptionsAndTags")
        else { return false }

        mainConnectionIDFn = unsafeBitCast(mainSymbol, to: MainConnectionIDFn.self)
        copyManagedDisplaySpacesFn = unsafeBitCast(
            spacesSymbol,
            to: CopyManagedDisplaySpacesFn.self
        )
        copyWindowsWithOptionsAndTagsFn = unsafeBitCast(
            windowsSymbol,
            to: CopyWindowsWithOptionsAndTagsFn.self
        )
        return true
    }

    func neighbors(on displayID: CGDirectDisplayID) -> Neighbors? {
        guard
            let mainConnectionIDFn,
            let copyManagedDisplaySpacesFn,
            let rawDisplays = copyManagedDisplaySpacesFn(
                mainConnectionIDFn()
            )?.takeRetainedValue(),
            let displays = Self.dictionaryArray(from: rawDisplays),
            let display = matchingDisplay(in: displays, displayID: displayID),
            let current = display["Current Space"] as? [String: Any],
            let currentID = Self.spaceIdentifier(in: current),
            let rawSpaces = display["Spaces"] as? NSArray,
            let spaces = Self.dictionaryArray(from: rawSpaces),
            let currentIndex = spaces.firstIndex(where: {
                Self.spaceIdentifier(in: $0) == currentID
            })
        else { return nil }

        func space(at index: Int) -> Space? {
            guard spaces.indices.contains(index) else { return nil }
            let dictionary = spaces[index]
            guard let identifier = Self.spaceIdentifier(in: dictionary) else {
                return nil
            }
            let type = (dictionary["type"] as? NSNumber)?.intValue ?? 0
            return Space(identifier: identifier, type: type)
        }

        return Neighbors(
            previous: space(at: currentIndex - 1),
            next: space(at: currentIndex + 1)
        )
    }

    func windowIDs(on spaceID: UInt64) -> [CGWindowID]? {
        guard
            let mainConnectionIDFn,
            let copyWindowsWithOptionsAndTagsFn
        else { return nil }

        let spaces = [NSNumber(value: spaceID)] as CFArray
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        guard let rawWindowIDs = copyWindowsWithOptionsAndTagsFn(
            mainConnectionIDFn(),
            0,
            spaces,
            0x2, // Include ordinary windows but exclude minimized windows.
            &setTags,
            &clearTags
        )?.takeRetainedValue() else { return nil }

        let values = rawWindowIDs as NSArray
        return values.compactMap {
            ($0 as? NSNumber).map { CGWindowID($0.uint32Value) }
        }
    }

    private func matchingDisplay(
        in displays: [[String: Any]],
        displayID: CGDirectDisplayID
    ) -> [String: Any]? {
        if !NSScreen.screensHaveSeparateSpaces {
            return displays.first {
                ($0["Display Identifier"] as? String) == "Main"
            } ?? (displays.count == 1 ? displays[0] : nil)
        }

        guard
            let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID)
        else {
            return displays.count == 1 ? displays[0] : nil
        }
        let uuid = unmanagedUUID.takeRetainedValue()
        let identifier = CFUUIDCreateString(nil, uuid) as String

        return displays.first {
            guard let candidate = $0["Display Identifier"] as? String else {
                return false
            }
            return candidate.caseInsensitiveCompare(identifier) == .orderedSame
        }
    }

    private static func spaceIdentifier(in dictionary: [String: Any]) -> UInt64? {
        if let number = dictionary["id64"] as? NSNumber {
            return number.uint64Value
        }
        if let number = dictionary["ManagedSpaceID"] as? NSNumber {
            return number.uint64Value
        }
        return nil
    }

    private static func dictionaryArray(from array: CFArray) -> [[String: Any]]? {
        dictionaryArray(from: array as NSArray)
    }

    private static func dictionaryArray(from array: NSArray) -> [[String: Any]]? {
        var dictionaries = [[String: Any]]()
        dictionaries.reserveCapacity(array.count)
        for value in array {
            guard let dictionary = value as? [String: Any] else { return nil }
            dictionaries.append(dictionary)
        }
        return dictionaries
    }
}

final class DockWatcher {

    private static let ignoredWindowBundleIdentifiersKey = "IgnoredWindowBundleIdentifiers"
    private static let ignoredWindowOwnerNames: Set<String> = [
        "DockAway",
        "Window Server",
        "Dock",
        "WindowManager",
        "Control Center"
    ]

    private enum DisplayWindowState {
        case empty
        case occupied
        case blacklisted
    }

    private enum DesktopTransitionPhase {
        case idle
        case settling
    }

    private enum HiddenHoldReason {
        case desktopSwipe
        case missionControlExit
    }

    private enum VisibleHoldReason {
        case desktopSwipe
        case missionControlExit
    }

    private struct HorizontalSpacePrediction {
        let displayID: CGDirectDisplayID
        let capturedAt: Date
        let previousState: DisplayWindowState?
        let nextState: DisplayWindowState?
    }

    private var pendingAccessibilityCheck: DispatchWorkItem?
    private var pendingAccessibilitySettleCheck: DispatchWorkItem?
    private var pendingDebounceCheck: DispatchWorkItem?
    private var pendingDesktopTransitionFinish: DispatchWorkItem?
    private var pendingHoldReleaseCheck: DispatchWorkItem?
    private var pendingVisibleHoldReleaseCheck: DispatchWorkItem?
    private var pendingMissionControlRefresh: DispatchWorkItem?
    private var pendingDockObserverRetry: DispatchWorkItem?
    private var pendingObserverRetries = [pid_t: DispatchWorkItem]()
    private var safetyTimer: Timer?
    private var pointerDisplayTimer: Timer?
    private var visibleHoldDestinationTimer: Timer?
    private var accessibilityObservations = [pid_t: DockWatcherAXObservation]()
    private var dockAccessibilityObservation: DockWatcherAXObservation?
    private var missionControlIsActive = false
    private var desktopTransitionPhase: DesktopTransitionPhase = .idle
    private var desktopTransitionGeneration = 0
    private var holdLatched = false
    private var hiddenHoldReason: HiddenHoldReason?
    private var holdLatchExpiry = Date.distantPast
    private var holdReleaseAt = Date.distantPast
    private var visibleHoldLatched = false
    private var visibleHoldReason: VisibleHoldReason?
    private var visibleHoldLatchExpiry = Date.distantPast
    private var visibleHoldReleaseAt = Date.distantPast
    private var visibleHoldDisplayID: CGDirectDisplayID?
    private var visibleHoldCanPrehideOccupiedDestination = false
    private var horizontalSpacePrediction: HorizontalSpacePrediction?
    private let spaceAPI = DockWatcherSpaceAPI()
    private var nextMissionControlProbeAt = Date.distantPast
    private var dockObserverRetryAttempt = 0
    private var lastPointerDisplayID: CGDirectDisplayID?
    private var lastEvaluatedDisplayID: CGDirectDisplayID?
    private var lastEvaluatedWindowState: DisplayWindowState?
    private var cachedIgnoredBundleIdentifiers = Set<String>()
    private var cachedBundleIdentifiersByPID = [pid_t: String]()
    // Stores both blacklist hits and misses. Most Window Server scans encounter
    // the same owner PIDs repeatedly, so remembering `false` is just as useful
    // as remembering `true`: neither NSRunningApplication nor prefix matching
    // needs to run again until the process or blacklist actually changes.
    private var cachedBlacklistStatusByPID = [pid_t: Bool]()
    private var lastCommandedDockVisibility: Bool?
    private var lastToggleTime = Date.distantPast
    private(set) var isRunning = false

    // ── SPEED TUNING ─────────────────────────────────────────────────────────
    // Raise any of these if the Dock starts double-toggling.
    private let accessibilityDebounce: TimeInterval = 0.05
    private let pointerDisplayInterval: TimeInterval = 0.12
    // Only runs during an empty-source gesture and its short landing grace. It
    // catches the incoming window before the ordinary Space-change correction.
    private let visibleHoldDestinationProbeInterval: TimeInterval = 0.03
    private let horizontalSpacePredictionLifetime: TimeInterval = 2.0
    private let accessibilityMessagingTimeout: Float = 0.25
    private let observerRetryDelays: [TimeInterval] = [0.25, 0.75, 1.5]
    // Mission Control is already confirmed absent by AX/WindowServer before
    // this runs. One fast tick is enough to let the selected app reach the
    // front without leaving the Dock visible for nearly another second.
    private let missionControlExitSettleDelay: TimeInterval = 0.12
    private let missionControlIdleProbeInterval: TimeInterval = 0.35
    private let missionControlActiveProbeInterval: TimeInterval = 0.12
    private let dockCommandSettleTimeout: TimeInterval = 1.0
    // AX notifications handle normal window changes. This intentionally slow
    // timer is only a backstop for apps that expose incomplete accessibility.
    private let safetyInterval: TimeInterval   = 2.0
    private let toggleDebounce: TimeInterval   = 0.45   // was 1.00

    private static let accessibilityNotifications = [
        kAXWindowCreatedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification
    ]

    private var isDesktopTransitionProtected: Bool {
        desktopTransitionPhase != .idle || missionControlIsActive
    }

    private var isHoldingHidden: Bool {
        if holdLatched, Date() >= holdLatchExpiry {
            holdLatched = false
        }
        return holdLatched || Date() < holdReleaseAt
    }

    private var isHoldingVisible: Bool {
        if visibleHoldLatched, Date() >= visibleHoldLatchExpiry {
            visibleHoldLatched = false
        }
        return visibleHoldLatched || Date() < visibleHoldReleaseAt
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        refreshBlacklistCacheFromDefaults()
        refreshRunningApplicationCache()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(spaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationVisibilityDidChange(_:)),
            name: NSWorkspace.didHideApplicationNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationVisibilityDidChange(_:)),
            name: NSWorkspace.didUnhideApplicationNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        startPointerDisplayTimer()
        // Establish Mission Control protection before the first occupancy
        // verdict. Starting or resuming DockAway from inside the overview must
        // not alter the Dock policy from a transitional window snapshot.
        installDockAccessibilityObserver()
        refreshMissionControlState(allowWindowServerFallback: true)
        evaluateFrontmostApp(quiet: true)
        installAccessibilityObserversForRunningApplications()
        scheduleAccessibilityEvaluation(includeSettleRecheck: true)

        // Slow safety net: catches applications that do not vend one or more
        // AX notifications, plus unusual Window Server transitions.
        // .common, not the default mode: a scheduledTimer is parked in .default,
        // which the run loop suspends while it tracks a trackpad gesture — so
        // this net was asleep for the entire duration of every swipe.
        let timer = Timer(timeInterval: safetyInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard (NSApp.delegate as? AppDelegate)?.isQuitting != true else { return }
            guard AXIsProcessTrusted() else {
                (NSApp.delegate as? AppDelegate)?.accessibilityPermissionWasRevoked()
                return
            }
            self.refreshBlacklistCacheFromDefaults()
            self.refreshMissionControlState(allowWindowServerFallback: true)
            self.evaluateFrontmostApp(quiet: true)
        }
        timer.tolerance = 0.20
        RunLoop.main.add(timer, forMode: .common)
        safetyTimer = timer

        dockAwayDebugLog("✅ DockStatus started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        pendingAccessibilityCheck?.cancel()
        pendingAccessibilityCheck = nil
        pendingAccessibilitySettleCheck?.cancel()
        pendingAccessibilitySettleCheck = nil
        pendingDebounceCheck?.cancel()
        pendingDebounceCheck = nil
        pendingDesktopTransitionFinish?.cancel()
        pendingDesktopTransitionFinish = nil
        pendingHoldReleaseCheck?.cancel()
        pendingHoldReleaseCheck = nil
        pendingVisibleHoldReleaseCheck?.cancel()
        pendingVisibleHoldReleaseCheck = nil
        pendingMissionControlRefresh?.cancel()
        pendingMissionControlRefresh = nil
        pendingDockObserverRetry?.cancel()
        pendingDockObserverRetry = nil
        for retry in pendingObserverRetries.values {
            retry.cancel()
        }
        pendingObserverRetries.removeAll()
        removeAllAccessibilityObservers()
        removeDockAccessibilityObserver()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        safetyTimer?.invalidate()
        safetyTimer = nil
        pointerDisplayTimer?.invalidate()
        pointerDisplayTimer = nil
        visibleHoldDestinationTimer?.invalidate()
        visibleHoldDestinationTimer = nil
        lastPointerDisplayID = nil
        missionControlIsActive = false
        desktopTransitionPhase = .idle
        desktopTransitionGeneration += 1
        holdLatched = false
        hiddenHoldReason = nil
        holdLatchExpiry = .distantPast
        holdReleaseAt = .distantPast
        visibleHoldLatched = false
        visibleHoldReason = nil
        visibleHoldLatchExpiry = .distantPast
        visibleHoldReleaseAt = .distantPast
        visibleHoldDisplayID = nil
        visibleHoldCanPrehideOccupiedDestination = false
        horizontalSpacePrediction = nil
        nextMissionControlProbeAt = .distantPast
        dockObserverRetryAttempt = 0
        lastEvaluatedDisplayID = nil
        lastEvaluatedWindowState = nil
        lastCommandedDockVisibility = nil
        dockAwayDebugLog("⏸️ DockStatus Paused")
    }

    deinit { stop() }

    // MARK: - Space Detection

    @objc private func spaceDidChange() {
        guard isRunning else { return }

        // A fast horizontal swipe can deliver this notification before the
        // raw-motion closure that consumes the gesture's adjacent-Space
        // prediction. Keep a fresh prediction alive so an occupied destination
        // still pre-hides before its animation; clearing it here forced the
        // live probe to hide mid-transition, which can make Chrome repaint its
        // tab bar black. Stale snapshots remain disposable, and all normal
        // gesture-end/consumption paths clear the prediction themselves.
        if let prediction = horizontalSpacePrediction {
            let predictionAge = Date().timeIntervalSince(prediction.capturedAt)
            if predictionAge > horizontalSpacePredictionLifetime {
                horizontalSpacePrediction = nil
            } else {
                dockAwayDebugLog(
                    String(
                        format: "  🔭 Space changed before motion → preserving %.3fs prediction",
                        predictionAge
                    )
                )
            }
        }

        // The destination can become classifiable just before this event. Give
        // the visible hold one immediate chance to hand off to hidden pre-hide.
        if isHoldingVisible {
            evaluateFrontmostApp(quiet: true)
        }

        // The four-finger pre-hide latch suppresses SHOW decisions while the
        // destination Space lands. Its own release check performs the final
        // scan, so this notification only needs to cover non-trackpad switches.
        scheduleAccessibilityEvaluation(includeSettleRecheck: true)
    }

    // MARK: - Accessibility Window Events

    private func installAccessibilityObserversForRunningApplications() {
        guard AXIsProcessTrusted() else { return }

        // Eagerly attach normal applications. Existing accessory apps attach
        // only if they later activate or otherwise produce an app lifecycle event,
        // avoiding needless startup IPC with every menu extra.
        for application in NSWorkspace.shared.runningApplications
        where application.activationPolicy == .regular {
            let installed = installAccessibilityObserver(for: application)
            if !installed
                || accessibilityObservations[application.processIdentifier]?
                    .hasTransientRegistrationFailure == true {
                scheduleObserverRetry(for: application.processIdentifier)
            }
        }
    }

    @discardableResult
    private func installAccessibilityObserver(for application: NSRunningApplication) -> Bool {
        let processIdentifier = application.processIdentifier
        guard
            isRunning,
            AXIsProcessTrusted(),
            processIdentifier > 0,
            processIdentifier != getpid(),
            !application.isTerminated,
            application.activationPolicy != .prohibited
        else { return false }

        if let observation = accessibilityObservations[processIdentifier] {
            if observation.hasTransientRegistrationFailure {
                refreshAccessibilityRegistrations(for: observation)
            }
            return true
        }

        var observer: AXObserver?
        guard
            AXObserverCreate(processIdentifier, dockWatcherAXCallback, &observer) == .success,
            let observer
        else { return false }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(
            applicationElement,
            accessibilityMessagingTimeout
        )
        let context = DockWatcherAXContext(processIdentifier: processIdentifier) {
            [weak self] processIdentifier, observer, element, notification in
            self?.accessibilityEventOccurred(
                processIdentifier: processIdentifier,
                observer: observer,
                element: element,
                notification: notification
            )
        }
        let observation = DockWatcherAXObservation(
            observer: observer,
            applicationElement: applicationElement,
            context: context
        )
        refreshAccessibilityRegistrations(for: observation)

        guard
            !observation.registeredApplicationNotifications.isEmpty
                || !observation.observedWindows.isEmpty
        else { return false }

        accessibilityObservations[processIdentifier] = observation
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        return true
    }

    private func refreshAccessibilityRegistrations(
        for observation: DockWatcherAXObservation
    ) {
        observation.hasTransientRegistrationFailure = false
        let refcon = Unmanaged.passUnretained(observation.context).toOpaque()

        notificationRegistration: for notification in Self.accessibilityNotifications
        where !observation.registeredApplicationNotifications.contains(notification)
            && !observation.unsupportedApplicationNotifications.contains(notification) {
            let result = AXObserverAddNotification(
                observation.observer,
                observation.applicationElement,
                notification as CFString,
                refcon
            )

            switch result {
            case .success, .notificationAlreadyRegistered:
                observation.registeredApplicationNotifications.append(notification)
            case .notificationUnsupported, .notImplemented:
                observation.unsupportedApplicationNotifications.insert(notification)
            case .cannotComplete:
                observation.hasTransientRegistrationFailure = true
                break notificationRegistration
            default:
                break
            }
        }

        guard !observation.hasTransientRegistrationFailure else { return }

        let windowSnapshot = accessibilityWindows(for: observation.applicationElement)
        if windowSnapshot.result == .cannotComplete {
            observation.hasTransientRegistrationFailure = true
            return
        }

        for window in windowSnapshot.windows {
            let result = registerWindowDestruction(window, with: observation)
            if result == .cannotComplete {
                observation.hasTransientRegistrationFailure = true
                break
            }
        }
    }

    private func accessibilityWindows(
        for applicationElement: AXUIElement
    ) -> (windows: [AXUIElement], result: AXError) {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &value
        )
        guard result == .success, let windows = value as? [AXUIElement] else {
            return ([], result)
        }

        return (windows, result)
    }

    @discardableResult
    private func registerWindowDestruction(
        _ window: AXUIElement,
        with observation: DockWatcherAXObservation
    ) -> AXError {
        guard !observation.observedWindows.contains(where: { CFEqual($0, window) }) else {
            return .notificationAlreadyRegistered
        }

        AXUIElementSetMessagingTimeout(window, accessibilityMessagingTimeout)
        let result = AXObserverAddNotification(
            observation.observer,
            window,
            kAXUIElementDestroyedNotification as CFString,
            Unmanaged.passUnretained(observation.context).toOpaque()
        )
        if result == .success || result == .notificationAlreadyRegistered {
            observation.observedWindows.append(window)
        }
        return result
    }

    private func accessibilityEventOccurred(
        processIdentifier: pid_t,
        observer: AXObserver,
        element: AXUIElement,
        notification: String
    ) {
        guard
            isRunning,
            let observation = accessibilityObservations[processIdentifier],
            CFEqual(observation.observer, observer)
        else { return }

        if notification == kAXWindowCreatedNotification {
            // The callback element is the new window. Register synchronously;
            // AX elements must not be passed unretained into delayed work.
            if registerWindowDestruction(element, with: observation) == .cannotComplete {
                observation.hasTransientRegistrationFailure = true
                scheduleObserverRetry(for: processIdentifier)
            }
        } else if notification == kAXUIElementDestroyedNotification {
            // A destroyed AX element is invalid for further AX calls. CFEqual
            // is explicitly safe and is all that is needed to forget it.
            observation.observedWindows.removeAll { CFEqual($0, element) }
        }

        scheduleAccessibilityEvaluation(includeSettleRecheck: true)
    }

    private func scheduleAccessibilityEvaluation(includeSettleRecheck: Bool) {
        guard isRunning, !isDesktopTransitionProtected else { return }

        pendingAccessibilityCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.pendingAccessibilityCheck = nil
            self.evaluateFrontmostApp(quiet: true)
        }
        pendingAccessibilityCheck = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + accessibilityDebounce,
            execute: work
        )

        guard includeSettleRecheck else { return }

        pendingAccessibilitySettleCheck?.cancel()
        let settleWork = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.pendingAccessibilitySettleCheck = nil
            self.evaluateFrontmostApp(quiet: true)
        }
        pendingAccessibilitySettleCheck = settleWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17, execute: settleWork)
    }

    private func removeAccessibilityObserver(for processIdentifier: pid_t) {
        guard let observation = accessibilityObservations.removeValue(
            forKey: processIdentifier
        ) else { return }

        // Remove the run-loop source before releasing its unretained refcon.
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observation.observer),
            .commonModes
        )

        // Releasing AXObserver drops its registrations. Avoid synchronous IPC
        // here, especially when this cleanup follows application termination.
    }

    private func removeAllAccessibilityObservers() {
        for processIdentifier in Array(accessibilityObservations.keys) {
            removeAccessibilityObserver(for: processIdentifier)
        }
    }

    private func scheduleObserverRetry(
        for processIdentifier: pid_t,
        attempt: Int = 0
    ) {
        guard
            processIdentifier > 0,
            processIdentifier != getpid(),
            attempt < observerRetryDelays.count,
            pendingObserverRetries[processIdentifier] == nil,
            let application = NSRunningApplication(
                processIdentifier: processIdentifier
            ),
            !application.isTerminated,
            application.activationPolicy != .prohibited
        else {
            return
        }

        let retry = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingObserverRetries[processIdentifier] = nil
            guard
                self.isRunning,
                let application = NSRunningApplication(
                    processIdentifier: processIdentifier
                ),
                !application.isTerminated
            else { return }

            let installed = self.installAccessibilityObserver(for: application)
            if installed {
                self.scheduleAccessibilityEvaluation(includeSettleRecheck: true)
            }

            if !installed
                || self.accessibilityObservations[processIdentifier]?
                    .hasTransientRegistrationFailure == true {
                self.scheduleObserverRetry(
                    for: processIdentifier,
                    attempt: attempt + 1
                )
            }
        }
        pendingObserverRetries[processIdentifier] = retry
        DispatchQueue.main.asyncAfter(
            deadline: .now() + observerRetryDelays[attempt],
            execute: retry
        )
    }

    @objc private func applicationDidLaunch(_ note: Notification) {
        guard let application = runningApplication(from: note) else { return }
        invalidateProcessCache(for: application.processIdentifier)
        cacheBundleIdentifier(for: application)

        if application.bundleIdentifier == "com.apple.dock" {
            pendingDockObserverRetry?.cancel()
            pendingDockObserverRetry = nil
            dockObserverRetryAttempt = 0
            installDockAccessibilityObserver()
            scheduleMissionControlRefresh(after: missionControlActiveProbeInterval)
            return
        }

        let installed = installAccessibilityObserver(for: application)
        if !installed
            || accessibilityObservations[application.processIdentifier]?
                .hasTransientRegistrationFailure == true {
            scheduleObserverRetry(for: application.processIdentifier)
        }
        scheduleAccessibilityEvaluation(includeSettleRecheck: true)
    }

    @objc private func applicationDidTerminate(_ note: Notification) {
        guard let application = runningApplication(from: note) else { return }

        let processIdentifier = application.processIdentifier
        invalidateProcessCache(for: processIdentifier)
        if dockAccessibilityObservation?.context.processIdentifier == processIdentifier {
            pendingDockObserverRetry?.cancel()
            pendingDockObserverRetry = nil
            dockObserverRetryAttempt = 0
            removeDockAccessibilityObserver()
            updateMissionControlState(false)
            return
        }

        pendingObserverRetries.removeValue(forKey: processIdentifier)?.cancel()
        removeAccessibilityObserver(for: processIdentifier)
        scheduleAccessibilityEvaluation(includeSettleRecheck: true)
    }

    @objc private func applicationVisibilityDidChange(_ note: Notification) {
        scheduleAccessibilityEvaluation(includeSettleRecheck: true)
    }

    private func runningApplication(from note: Notification) -> NSRunningApplication? {
        note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    // Window classification is latency-sensitive during a Space swipe. Keep
    // blacklist and process metadata in RAM, then refresh the defaults snapshot
    // on the slow safety pass so legacy `defaults write` changes still work.
    private func refreshBlacklistCacheFromDefaults() {
        let refreshedIdentifiers = Set(
            UserDefaults.standard.stringArray(
                forKey: Self.ignoredWindowBundleIdentifiersKey
            ) ?? []
        )
        guard refreshedIdentifiers != cachedIgnoredBundleIdentifiers else { return }

        cachedIgnoredBundleIdentifiers = refreshedIdentifiers
        cachedBlacklistStatusByPID.removeAll(keepingCapacity: true)
    }

    private func refreshRunningApplicationCache() {
        cachedBundleIdentifiersByPID.removeAll(keepingCapacity: true)
        cachedBlacklistStatusByPID.removeAll(keepingCapacity: true)
        for application in NSWorkspace.shared.runningApplications {
            cacheBundleIdentifier(for: application)
        }
    }

    private func cacheBundleIdentifier(for application: NSRunningApplication) {
        let processIdentifier = application.processIdentifier
        guard
            processIdentifier > 0,
            let bundleIdentifier = application.bundleIdentifier
        else { return }

        guard cachedBundleIdentifiersByPID[processIdentifier] != bundleIdentifier else {
            return
        }

        cachedBundleIdentifiersByPID[processIdentifier] = bundleIdentifier
        cachedBlacklistStatusByPID.removeValue(forKey: processIdentifier)
    }

    private func invalidateProcessCache(for processIdentifier: pid_t) {
        cachedBundleIdentifiersByPID.removeValue(forKey: processIdentifier)
        cachedBlacklistStatusByPID.removeValue(forKey: processIdentifier)
    }

    private func bundleIdentifier(for processIdentifier: pid_t) -> String? {
        if let cachedIdentifier = cachedBundleIdentifiersByPID[processIdentifier] {
            return cachedIdentifier
        }

        guard let application = NSRunningApplication(
            processIdentifier: processIdentifier
        ), let bundleIdentifier = application.bundleIdentifier else {
            return nil
        }

        cachedBundleIdentifiersByPID[processIdentifier] = bundleIdentifier
        return bundleIdentifier
    }

    private func isProcessBlacklisted(_ processIdentifier: pid_t) -> Bool {
        guard processIdentifier > 0, !cachedIgnoredBundleIdentifiers.isEmpty else {
            return false
        }
        if let cachedStatus = cachedBlacklistStatusByPID[processIdentifier] {
            return cachedStatus
        }

        let isBlacklistedStatus = bundleIdentifier(for: processIdentifier).map {
            isBlacklisted($0, in: cachedIgnoredBundleIdentifiers)
        } ?? false
        cachedBlacklistStatusByPID[processIdentifier] = isBlacklistedStatus
        return isBlacklistedStatus
    }

    // MARK: - Mission Control Detection

    // Mission Control is implemented by Dock.app. Its AX hierarchy gains a
    // first-level group whose stable identifier is `mc` while the overview is
    // visible. Dock also emits selected-children changes on entry and exit.
    private func installDockAccessibilityObserver() {
        guard isRunning, AXIsProcessTrusted() else { return }
        guard let dockApplication = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock"
        ).first else {
            scheduleDockObserverRetry()
            return
        }

        let processIdentifier = dockApplication.processIdentifier
        if let observation = dockAccessibilityObservation,
           observation.context.processIdentifier == processIdentifier {
            registerDockMissionControlNotificationIfNeeded(for: observation)
            refreshMissionControlState(allowWindowServerFallback: false)
            return
        }

        if dockAccessibilityObservation != nil {
            pendingDockObserverRetry?.cancel()
            pendingDockObserverRetry = nil
            dockObserverRetryAttempt = 0
        }
        removeDockAccessibilityObserver()

        var observer: AXObserver?
        guard
            AXObserverCreate(processIdentifier, dockWatcherAXCallback, &observer) == .success,
            let observer
        else {
            scheduleDockObserverRetry()
            return
        }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.10)
        let context = DockWatcherAXContext(processIdentifier: processIdentifier) {
            [weak self] processIdentifier, observer, element, notification in
            self?.dockAccessibilityEventOccurred(
                processIdentifier: processIdentifier,
                observer: observer,
                element: element,
                notification: notification
            )
        }
        let observation = DockWatcherAXObservation(
            observer: observer,
            applicationElement: applicationElement,
            context: context
        )

        dockAccessibilityObservation = observation
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        registerDockMissionControlNotificationIfNeeded(for: observation)
        nextMissionControlProbeAt = .distantPast
        refreshMissionControlState(allowWindowServerFallback: true)
    }

    private func registerDockMissionControlNotificationIfNeeded(
        for observation: DockWatcherAXObservation
    ) {
        guard !observation.registeredApplicationNotifications.contains(
            kAXSelectedChildrenChangedNotification
        ) else {
            pendingDockObserverRetry?.cancel()
            pendingDockObserverRetry = nil
            dockObserverRetryAttempt = 0
            return
        }

        let result = AXObserverAddNotification(
            observation.observer,
            observation.applicationElement,
            kAXSelectedChildrenChangedNotification as CFString,
            Unmanaged.passUnretained(observation.context).toOpaque()
        )
        switch result {
        case .success, .notificationAlreadyRegistered:
            observation.registeredApplicationNotifications.append(
                kAXSelectedChildrenChangedNotification
            )
            pendingDockObserverRetry?.cancel()
            pendingDockObserverRetry = nil
            dockObserverRetryAttempt = 0
        case .cannotComplete, .invalidUIElement:
            scheduleDockObserverRetry()
        case .notificationUnsupported, .notImplemented:
            // Polling the `mc` AX group and the WindowServer fallback still
            // provide correctness when this optional notification is absent.
            dockAwayDebugLog("⚠️ Dock AX event unavailable — using Mission Control polling")
        default:
            scheduleDockObserverRetry()
        }
    }

    private func scheduleDockObserverRetry() {
        guard
            isRunning,
            pendingDockObserverRetry == nil,
            dockObserverRetryAttempt < observerRetryDelays.count
        else { return }

        let attempt = dockObserverRetryAttempt
        dockObserverRetryAttempt += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDockObserverRetry = nil
            guard self.isRunning else { return }
            self.installDockAccessibilityObserver()
        }
        pendingDockObserverRetry = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + observerRetryDelays[attempt],
            execute: work
        )
    }

    private func removeDockAccessibilityObserver() {
        guard let observation = dockAccessibilityObservation else { return }

        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observation.observer),
            .commonModes
        )
        dockAccessibilityObservation = nil
    }

    private func dockAccessibilityEventOccurred(
        processIdentifier: pid_t,
        observer: AXObserver,
        element: AXUIElement,
        notification: String
    ) {
        guard
            isRunning,
            notification == kAXSelectedChildrenChangedNotification,
            let observation = dockAccessibilityObservation,
            observation.context.processIdentifier == processIdentifier,
            CFEqual(observation.observer, observer)
        else { return }

        refreshMissionControlState(allowWindowServerFallback: true)
        scheduleMissionControlRefresh(after: missionControlActiveProbeInterval)
    }

    private func scheduleMissionControlRefresh(after delay: TimeInterval) {
        pendingMissionControlRefresh?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.pendingMissionControlRefresh = nil
            self.refreshMissionControlState(allowWindowServerFallback: true)
        }
        pendingMissionControlRefresh = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, delay),
            execute: work
        )
    }

    private func refreshMissionControlStateIfNeeded() {
        let now = Date()
        guard now >= nextMissionControlProbeAt else { return }

        let needsRapidProbe = isDesktopTransitionProtected
            || isHoldingHidden
            || isHoldingVisible
        let interval = needsRapidProbe
            ? missionControlActiveProbeInterval
            : missionControlIdleProbeInterval
        nextMissionControlProbeAt = now.addingTimeInterval(interval)
        refreshMissionControlState(
            allowWindowServerFallback: needsRapidProbe
        )
    }

    private func refreshMissionControlState(allowWindowServerFallback: Bool) {
        guard isRunning else { return }

        if dockAccessibilityObservation == nil {
            installDockAccessibilityObserver()
        }

        let axState = missionControlAXState()
        var isActive = axState.isActive
        if !isActive,
           allowWindowServerFallback
                || !axState.querySucceeded
                || missionControlIsActive
                || desktopTransitionPhase != .idle
                || isHoldingHidden
                || isHoldingVisible {
            isActive = missionControlWindowServerState()
        }

        updateMissionControlState(isActive)
    }

    private func missionControlAXState() -> (
        isActive: Bool,
        querySucceeded: Bool
    ) {
        guard let applicationElement = dockAccessibilityObservation?.applicationElement else {
            return (false, false)
        }

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXChildrenAttribute as CFString,
            &value
        )
        guard result == .success, let children = value as? [AXUIElement] else {
            return (false, false)
        }

        var hadTransientIdentifierFailure = false
        for child in children {
            AXUIElementSetMessagingTimeout(child, 0.10)
            var identifierValue: CFTypeRef?
            let identifierResult = AXUIElementCopyAttributeValue(
                child,
                kAXIdentifierAttribute as CFString,
                &identifierValue
            )
            guard identifierResult == .success else {
                if identifierResult == .cannotComplete
                    || identifierResult == .invalidUIElement
                    || identifierResult == .apiDisabled
                    || identifierResult == .failure {
                    hadTransientIdentifierFailure = true
                }
                continue
            }

            if identifierValue as? String == "mc" {
                return (true, true)
            }
        }

        return (false, !hadTransientIdentifierFailure)
    }

    // Tahoe and the current beta expose a WindowManager "Spaces Bar" at
    // layer 14 only for Mission Control (not App Exposé or Show Desktop).
    // This is an undocumented fallback used only when AX is late or unavailable.
    private func missionControlWindowServerState() -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly]
        guard let windows = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        return windows.contains { info in
            let ownerName = info[kCGWindowOwnerName as String] as? String
            let layer = info[kCGWindowLayer as String] as? Int
            return ownerName == "WindowManager" && layer == 14
        }
    }

    private func updateMissionControlState(_ isActive: Bool) {
        guard missionControlIsActive != isActive else { return }

        missionControlIsActive = isActive
        nextMissionControlProbeAt = .distantPast

        if isActive {
            // A brief false AX/WindowServer edge may already have scheduled an
            // exit finish. Mission Control is authoritative again, so retire
            // that stale landing work before it can clear transition state.
            pendingDesktopTransitionFinish?.cancel()
            pendingDesktopTransitionFinish = nil
            desktopTransitionGeneration += 1
            desktopTransitionPhase = .idle
            cancelTransientDecisionWork()
            horizontalSpacePrediction = nil
            // A downward exit to an empty desktop deliberately owns a visible
            // hold. Preserve it across the brief false/true Mission Control
            // marker flicker that can occur during the closing animation.
            if visibleHoldReason != .missionControlExit || !isHoldingVisible {
                clearVisibleHold()
            }
            let canceledPreHide = cancelHoldHiddenForMissionControl()
            dockAwayDebugLog(
                canceledPreHide
                    ? "🖥️ Mission Control active → pre-hide canceled, Dock decisions paused"
                    : "🖥️ Mission Control active → Dock decisions paused"
            )
        } else {
            dockAwayDebugLog("🖥️ Mission Control closed → verifying landing")
            desktopTransitionPhase = .settling
            scheduleDesktopTransitionFinish(after: missionControlExitSettleDelay)
        }
    }

    // MARK: - Pointer Display Tracking

    // Changing which display is under the pointer changes DockAway's target,
    // even when no application or AX event occurs. This timer is intentionally
    // cheap: it compares one display ID and scans windows only on a transition.
    private func startPointerDisplayTimer() {
        lastPointerDisplayID = displayIDUnderPointer()

        let timer = Timer(timeInterval: pointerDisplayInterval, repeats: true) {
            [weak self] _ in
            guard let self, self.isRunning else { return }

            self.refreshMissionControlStateIfNeeded()
            let displayID = self.displayIDUnderPointer()
            let displayChanged = displayID != self.lastPointerDisplayID
            self.lastPointerDisplayID = displayID

            if self.isDesktopTransitionProtected {
                return
            }

            guard displayChanged else { return }
            self.evaluateFrontmostApp(quiet: true)
        }
        // Pointer/display changes are not latency-sensitive enough to require
        // every 120 ms wakeup exactly on schedule. Let macOS coalesce nearby
        // work without changing the polling interval or gesture behavior.
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        pointerDisplayTimer = timer
    }

    @objc private func screenParametersDidChange() {
        horizontalSpacePrediction = nil
        lastPointerDisplayID = displayIDUnderPointer()
        scheduleAccessibilityEvaluation(includeSettleRecheck: true)
    }

    // MARK: - Notification Handler

    @objc private func activeAppDidChange(_ note: Notification) {
        guard
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }

        cacheBundleIdentifier(for: app)

        let appName = app.localizedName ?? (app.bundleIdentifier ?? "Unknown")
        dockAwayDebugLog("▶ Active app: \(appName)")
        evaluate(app: app, quiet: false)

        // Some apps are not ready to vend their AX hierarchy at launch. App
        // activation is a reliable second opportunity to attach their observer.
        let installed = installAccessibilityObserver(for: app)
        if !installed
            || accessibilityObservations[app.processIdentifier]?
                .hasTransientRegistrationFailure == true {
            scheduleObserverRetry(for: app.processIdentifier)
        }

        // Window Server ordering can lag the activation notification briefly.
        // Keep the immediate verdict above, then correct it after the transition.
        scheduleAccessibilityEvaluation(includeSettleRecheck: true)
    }

    // MARK: - Core Logic

    // Re-checks whatever app macOS currently reports as frontmost.
    private func evaluateFrontmostApp(quiet: Bool) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        evaluate(app: app, quiet: quiet)
    }

    // Shows the Dock only when the display under the pointer has no standard
    // app window, or when a blacklisted app is visible there. That is the
    // display whose Space the user is interacting with during a multi-monitor
    // desktop swipe.
    private func evaluate(app: NSRunningApplication, quiet: Bool) {
        guard isRunning else { return }

        // Four-finger pre-hide owns the Dock until the swipe has landed. Any
        // AX, timer, pointer, or Space event that arrives meanwhile is ignored.
        if isHoldingHidden { return }

        // Mission Control and Space-switch animations temporarily report a
        // mixture of source and destination windows. Never let that transient
        // snapshot move the Dock. macOS presents its own temporary Dock in the
        // overview; changing the global autohide policy here makes app windows
        // recalculate their landing geometry and produces a visible bounce.
        if isDesktopTransitionProtected {
            return
        }

        let bundleID = app.bundleIdentifier ?? ""
        let activeDisplayID = displayIDUnderPointer()
        let activeDisplay = CGDisplayBounds(activeDisplayID)
        let windowState = displayWindowState(on: activeDisplay)
        lastEvaluatedDisplayID = activeDisplayID
        lastEvaluatedWindowState = windowState
        let shouldShowDock = windowState != .occupied

        if handOffVisibleHoldToHiddenIfNeeded(
            for: windowState,
            on: activeDisplayID
        ) {
            return
        }

        if !quiet {
            switch windowState {
            case .empty:
                dockAwayDebugLog("  → Active display is empty → showing Dock")
            case .blacklisted:
                dockAwayDebugLog("  → Active display has a blacklisted app → showing Dock")
            case .occupied:
                dockAwayDebugLog("  → Active display has a window → hiding Dock")
            }
        }

        setDockVisible(shouldShowDock)

        // Quiet evaluations suppress repetitive console output, but they are
        // also the authoritative post-transition correction. Always refresh
        // the menu so a Mission Control landing cannot leave the old app name.
        let label = app.localizedName ?? bundleID
        switch windowState {
        case .empty:
            postStatus("Desktop")
        case .blacklisted:
            postStatus(label)
        case .occupied:
            postStatus(label)
        }
    }

    // MARK: - Window Detection

    // Classifies the foremost normal app window on the active display. The
    // Core Graphics window list is ordered front-to-back, so a covered
    // blacklisted window cannot override the app actually in front of it. A
    // small edge overlap is ignored so window shadows across a monitor boundary
    // cannot hide the Dock.
    private func displayWindowState(on displayBounds: CGRect) -> DisplayWindowState {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return .empty
        }

        return classifyWindowState(in: list, on: displayBounds) ?? .empty
    }

    // Applies DockAway's normal front-to-back window rules to either the live
    // on-screen list or a Space-specific list of window IDs. Keeping one
    // classifier ensures the prediction honors blacklist behavior exactly as
    // the ordinary detector does.
    private func classifyWindowState(
        in list: [[String: Any]],
        on displayBounds: CGRect,
        orderedWindowIDs: [CGWindowID]? = nil,
        allowTransientLayers: Bool = true,
        requireUnambiguousBlacklist: Bool = false
    ) -> DisplayWindowState? {
        let orderedList: [[String: Any]]
        if let orderedWindowIDs {
            var windowInfoByID = [CGWindowID: [String: Any]]()
            for info in list {
                guard let number = info[kCGWindowNumber as String] as? NSNumber else {
                    continue
                }
                windowInfoByID[CGWindowID(number.uint32Value)] = info
            }
            orderedList = orderedWindowIDs.compactMap { windowInfoByID[$0] }
        } else {
            orderedList = list
        }

        var predictedCandidateState: DisplayWindowState?
        for info in orderedList {
            guard
                let layer = info[kCGWindowLayer as String] as? Int,
                let ownerName = info[kCGWindowOwnerName as String] as? String,
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary
            else { continue }

            // WindowManager owns the invisible "Click to reveal desktop" overlay in macOS 14+.
            if Self.ignoredWindowOwnerNames.contains(ownerName) { continue }

            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
            if alpha < 0.05 { continue }

            // Live Space transitions can temporarily promote standard windows
            // above layer zero. An inactive-Space prediction is intentionally
            // stricter so a tooltip or overlay can never pre-hide an otherwise
            // empty destination.
            let isStandardLayer = layer == kCGNormalWindowLevel
            let isAllowedTransientLayer = allowTransientLayers
                && layer > 0
                && layer < 25
            guard isStandardLayer || isAllowedTransientLayer else { continue }

            var windowRect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict, &windowRect) else { continue }
            guard windowRect.width > 50, windowRect.height > 50 else { continue }

            let overlap = windowRect.intersection(displayBounds)
            if overlap.width >= 50, overlap.height >= 50 {
                let candidateState: DisplayWindowState
                if let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                   isProcessBlacklisted(ownerPID) {
                    candidateState = .blacklisted
                } else {
                    candidateState = .occupied
                }

                guard requireUnambiguousBlacklist else {
                    return candidateState
                }
                if let predictedCandidateState,
                   predictedCandidateState != candidateState {
                    // Private inactive-Space ordering is undocumented. A mix
                    // of blacklisted and ordinary windows is therefore not a
                    // safe predictive verdict; let the live front-to-back
                    // destination probe decide once the Space begins moving.
                    return nil
                }
                predictedCandidateState = candidateState
            }
        }

        return predictedCandidateState ?? .empty
    }

    // Pre-classifies both adjacent Spaces while the fingers are resting, before
    // the horizontal animation has begun. That lets an occupied destination
    // use the stable build's early HIDE timing, while an empty destination can
    // keep the Dock continuously visible.
    func prepareHorizontalSpacePredictionAtGestureStart() {
        horizontalSpacePrediction = nil
        let predictionStartedAt = ProcessInfo.processInfo.systemUptime

        let displayID = displayIDUnderPointer()
        guard
            isRunning,
            !missionControlIsActive,
            lastEvaluatedDisplayID == displayID,
            lastEvaluatedWindowState == .empty,
            let neighbors = spaceAPI.neighbors(on: displayID)
        else { return }

        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let allWindowInfo = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let displayBounds = CGDisplayBounds(displayID)
        func state(for space: DockWatcherSpaceAPI.Space?) -> DisplayWindowState? {
            guard let space else { return nil }
            guard let windowIDs = spaceAPI.windowIDs(on: space.identifier) else {
                // A full-screen/tiled Space is occupied even if an OS update
                // briefly prevents its private window list from being copied.
                return space.type == 4 ? .occupied : nil
            }

            guard let state = classifyWindowState(
                in: allWindowInfo,
                on: displayBounds,
                orderedWindowIDs: windowIDs,
                allowTransientLayers: false,
                requireUnambiguousBlacklist: true
            ) else { return nil }
            return state == .empty && space.type == 4 ? .occupied : state
        }

        let previousState = state(for: neighbors.previous)
        let nextState = state(for: neighbors.next)
        horizontalSpacePrediction = HorizontalSpacePrediction(
            displayID: displayID,
            capturedAt: Date(),
            previousState: previousState,
            nextState: nextState
        )

        func label(for state: DisplayWindowState?) -> String {
            switch state {
            case .empty: "empty"
            case .occupied: "occupied"
            case .blacklisted: "blacklisted"
            case nil: "unknown/boundary"
            }
        }
        let elapsedMilliseconds = (
            ProcessInfo.processInfo.systemUptime - predictionStartedAt
        ) * 1_000
        dockAwayDebugLog(
            String(
                format: "  🔭 Adjacent Spaces: left=%@, right=%@ (%.2f ms)",
                label(for: previousState),
                label(for: nextState),
                elapsedMilliseconds
            )
        )
    }

    func endHorizontalSpacePredictionAtGestureEnd() {
        horizontalSpacePrediction = nil
    }

    // Helper processes commonly append a suffix to their parent app's bundle
    // identifier. Treat those as part of the selected app as well.
    private func isBlacklisted(_ bundleIdentifier: String, in identifiers: Set<String>) -> Bool {
        identifiers.contains {
            bundleIdentifier == $0 || bundleIdentifier.hasPrefix($0 + ".")
        }
    }

    private func displayIDUnderPointer() -> CGDirectDisplayID {
        // CGEvent(source: nil)?.location is in global display coordinates.
        guard let pointerLocation = CGEvent(source: nil)?.location else {
            return CGMainDisplayID()
        }

        var display = CGMainDisplayID()
        var displayCount: UInt32 = 0
        let result = CGGetDisplaysWithPoint(
            pointerLocation,
            1,
            &display,
            &displayCount
        )
        guard result == .success, displayCount > 0 else {
            return CGMainDisplayID()
        }

        return display
    }

    // MARK: - Public Helpers

    func updateBlacklist(_ identifiers: Set<String>) {
        guard identifiers != cachedIgnoredBundleIdentifiers else { return }
        cachedIgnoredBundleIdentifiers = identifiers
        cachedBlacklistStatusByPID.removeAll(keepingCapacity: true)
    }

    func resetState() {
        evaluateFrontmostApp(quiet: false)
    }

    func simulateOptionCommandDPublic() {
        simulateOptionCommandD()
    }

    // Captures the already-maintained Mission Control state on first contact.
    // This must remain a cache read: synchronous AX/Window Server work here
    // delays the following motion callback until the Space animation begins.
    func missionControlActiveAtGestureStart() -> Bool {
        isRunning && missionControlIsActive
    }

    // Keeps the Dock visible through a horizontal swipe only when the cached
    // source Space is already one where DockAway wants it shown. The cached
    // verdict avoids a synchronous window scan on the first motion frame.
    @discardableResult
    func beginVisibleHoldForHorizontalSwipeIfNeeded(
        movingToNextSpace: Bool,
        maximum: TimeInterval = 5.0
    ) -> Bool {
        let sourceDisplayID = displayIDUnderPointer()
        guard
            isRunning,
            !missionControlIsActive,
            lastEvaluatedDisplayID == sourceDisplayID,
            let sourceState = lastEvaluatedWindowState,
            sourceState != .occupied
        else { return false }

        var predictedDestinationState: DisplayWindowState?
        if let prediction = horizontalSpacePrediction,
           prediction.displayID == sourceDisplayID,
           Date().timeIntervalSince(prediction.capturedAt)
                <= horizontalSpacePredictionLifetime {
            predictedDestinationState = movingToNextSpace
                ? prediction.nextState
                : prediction.previousState
            horizontalSpacePrediction = nil

            if predictedDestinationState == .occupied {
                dockAwayDebugLog("  🔭 Occupied adjacent Space predicted → pre-hiding before animation")
                return false
            }
        } else {
            horizontalSpacePrediction = nil
        }

        // A blacklisted source may have other windows behind it, so only a
        // genuinely empty source makes the first occupied window unambiguous.
        // Likewise, a confidently blacklisted destination owns SHOW through
        // landing; mixed animation frames must not second-guess that verdict.
        return armVisibleHold(
            on: sourceDisplayID,
            reason: .desktopSwipe,
            canPrehideOccupiedDestination: sourceState == .empty
                && predictedDestinationState != .blacklisted,
            maximum: maximum
        )
    }

    // Mission Control freezes ordinary scans, so the last evaluated state is
    // the desktop that macOS is returning to. Keep its Dock visible throughout
    // the downward animation when that desktop was empty or blacklisted.
    @discardableResult
    func beginVisibleHoldForMissionControlExitIfNeeded(
        maximum: TimeInterval = 5.0
    ) -> Bool {
        let destinationDisplayID = displayIDUnderPointer()
        guard
            isRunning,
            lastEvaluatedDisplayID == destinationDisplayID,
            let destinationState = lastEvaluatedWindowState,
            destinationState != .occupied
        else { return false }

        return armVisibleHold(
            on: destinationDisplayID,
            reason: .missionControlExit,
            // If the cached empty state became stale while Mission Control was
            // open, the live landing probe may still hand off safely to HIDE.
            canPrehideOccupiedDestination: destinationState == .empty,
            maximum: maximum
        )
    }

    @discardableResult
    private func armVisibleHold(
        on displayID: CGDirectDisplayID,
        reason: VisibleHoldReason,
        canPrehideOccupiedDestination: Bool,
        maximum: TimeInterval
    ) -> Bool {
        clearHiddenHold()
        cancelTransientDecisionWork()
        visibleHoldLatched = true
        visibleHoldReason = reason
        visibleHoldLatchExpiry = Date().addingTimeInterval(maximum)
        visibleHoldReleaseAt = .distantPast
        visibleHoldDisplayID = displayID
        visibleHoldCanPrehideOccupiedDestination = canPrehideOccupiedDestination
        scheduleVisibleHoldReevaluation(after: max(0, maximum) + 0.02)
        if canPrehideOccupiedDestination {
            startVisibleHoldDestinationProbe()
        }
        return true
    }

    // Latch and pre-hide after raw contact motion has identified a horizontal
    // desktop swipe or a downward Mission Control exit. Motion classification
    // avoids hiding merely because four fingers are resting in the overview.
    @discardableResult
    func beginHoldHidden(
        missionControlWasActiveAtContact: Bool,
        maximum: TimeInterval = 5.0
    ) -> Bool {
        guard isRunning else { return false }

        // Direction has already disambiguated horizontal desktop motion from
        // upward Mission Control entry. Do not insert AX or Window Server IPC
        // between that first motion frame and the pre-hide command.
        horizontalSpacePrediction = nil
        clearVisibleHold()
        cancelTransientDecisionWork()
        holdLatched = true
        hiddenHoldReason = missionControlWasActiveAtContact
            ? .missionControlExit
            : .desktopSwipe
        holdLatchExpiry = Date().addingTimeInterval(maximum)
        holdReleaseAt = .distantPast
        scheduleHoldReevaluation(after: max(0, maximum) + 0.02)

        let actuallyShown = dockIsActuallyShown()
        reconcileLastDockCommand(with: actuallyShown)

        // In passive Mission Control mode the Dock can be visually present
        // even though its underlying autohide policy is already enabled. That
        // is the smooth stable-build path: latch SHOW off and let macOS dismiss
        // its temporary Dock without posting any global policy toggle.
        if missionControlWasActiveAtContact, !actuallyShown {
            return true
        }

        let commandAge = Date().timeIntervalSince(lastToggleTime)
        let hideIsLanding = lastCommandedDockVisibility == false
            && commandAge < dockCommandSettleTimeout
        let showIsLanding = lastCommandedDockVisibility == true
            && commandAge < dockCommandSettleTimeout
        guard (actuallyShown || showIsLanding), !hideIsLanding else { return true }

        pendingDebounceCheck?.cancel()
        pendingDebounceCheck = nil
        sendDockToggle(towardVisible: false, reason: "Pre-hiding Dock")
        return true
    }

    // Keep SHOW suppressed briefly after finger lift so the destination Space
    // is fully landed before one fresh occupancy decision is made.
    @discardableResult
    func endHoldHidden(after seconds: TimeInterval) -> Bool {
        guard isRunning, isHoldingHidden else { return false }

        holdLatched = false
        holdReleaseAt = Date().addingTimeInterval(seconds)
        scheduleHoldReevaluation(after: max(0, seconds) + 0.02)
        return true
    }

    // Keep HIDE suppressed briefly after finger lift. Window evaluations keep
    // running during this hold so its release can immediately apply the final
    // destination Space verdict.
    @discardableResult
    func endHoldVisible(after seconds: TimeInterval) -> Bool {
        guard isRunning, isHoldingVisible else { return false }

        visibleHoldLatched = false
        visibleHoldReleaseAt = Date().addingTimeInterval(seconds)
        scheduleVisibleHoldReevaluation(after: max(0, seconds) + 0.02)
        return true
    }

    private func clearHiddenHold() {
        holdLatched = false
        hiddenHoldReason = nil
        holdLatchExpiry = .distantPast
        holdReleaseAt = .distantPast
        pendingHoldReleaseCheck?.cancel()
        pendingHoldReleaseCheck = nil
    }

    private func clearVisibleHold() {
        stopVisibleHoldDestinationProbe()
        visibleHoldLatched = false
        visibleHoldReason = nil
        visibleHoldLatchExpiry = .distantPast
        visibleHoldReleaseAt = .distantPast
        visibleHoldDisplayID = nil
        visibleHoldCanPrehideOccupiedDestination = false
        pendingVisibleHoldReleaseCheck?.cancel()
        pendingVisibleHoldReleaseCheck = nil
    }

    private func startVisibleHoldDestinationProbe() {
        stopVisibleHoldDestinationProbe()

        let timer = Timer(
            timeInterval: visibleHoldDestinationProbeInterval,
            repeats: true
        ) { [weak self] _ in
            self?.probeVisibleHoldDestination()
        }
        RunLoop.main.add(timer, forMode: .common)
        visibleHoldDestinationTimer = timer

        // Return from the raw-motion handler before asking WindowServer for a
        // window list, while still taking the earliest practical first sample.
        DispatchQueue.main.async { [weak self] in
            self?.probeVisibleHoldDestination()
        }
    }

    private func stopVisibleHoldDestinationProbe() {
        visibleHoldDestinationTimer?.invalidate()
        visibleHoldDestinationTimer = nil
    }

    private func probeVisibleHoldDestination() {
        guard
            isRunning,
            isHoldingVisible,
            visibleHoldCanPrehideOccupiedDestination,
            let displayID = visibleHoldDisplayID
        else {
            stopVisibleHoldDestinationProbe()
            return
        }

        guard !isDesktopTransitionProtected else { return }

        // A trackpad gesture should not retarget because another input device
        // happened to move the pointer to a different monitor.
        guard displayIDUnderPointer() == displayID else {
            stopVisibleHoldDestinationProbe()
            visibleHoldCanPrehideOccupiedDestination = false
            return
        }

        let windowState = displayWindowState(on: CGDisplayBounds(displayID))
        lastEvaluatedDisplayID = displayID
        lastEvaluatedWindowState = windowState
        _ = handOffVisibleHoldToHiddenIfNeeded(
            for: windowState,
            on: displayID
        )
    }

    @discardableResult
    private func handOffVisibleHoldToHiddenIfNeeded(
        for windowState: DisplayWindowState,
        on displayID: CGDirectDisplayID
    ) -> Bool {
        guard
            isHoldingVisible,
            visibleHoldCanPrehideOccupiedDestination,
            visibleHoldDisplayID == displayID,
            windowState == .occupied,
            !isDesktopTransitionProtected
        else { return false }

        let fingersStillDown = visibleHoldLatched
        let remainingLandingGrace = max(
            0,
            visibleHoldReleaseAt.timeIntervalSinceNow
        )

        dockAwayDebugLog("  ⚡ Occupied destination detected → switching to hidden pre-hide")
        guard beginHoldHidden(missionControlWasActiveAtContact: false) else {
            return false
        }

        // If the incoming window became visible just after finger lift, do not
        // leave beginHoldHidden's five-second dead-man armed. Transfer only the
        // remainder of the existing landing grace to the hidden hold.
        if !fingersStillDown {
            _ = endHoldHidden(after: remainingLandingGrace)
        }
        return true
    }

    @discardableResult
    private func cancelHoldHiddenForMissionControl() -> Bool {
        guard isHoldingHidden else { return false }

        // During a downward exit the AX/WindowServer Mission Control marker can
        // flicker false/true once. That returning true edge must not undo the
        // deliberate HIDE and create a visible SHOW-then-HIDE bounce.
        guard hiddenHoldReason != .missionControlExit else { return false }

        holdLatched = false
        hiddenHoldReason = nil
        holdLatchExpiry = .distantPast
        holdReleaseAt = .distantPast
        pendingHoldReleaseCheck?.cancel()
        pendingHoldReleaseCheck = nil
        return true
    }

    private func scheduleHoldReevaluation(after delay: TimeInterval) {
        pendingHoldReleaseCheck?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.pendingHoldReleaseCheck = nil
            if self.holdLatched, Date() >= self.holdLatchExpiry {
                self.holdLatched = false
            }
            if !self.isHoldingHidden {
                self.hiddenHoldReason = nil
            }
            self.evaluateFrontmostApp(quiet: true)
        }
        pendingHoldReleaseCheck = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, delay),
            execute: work
        )
    }

    private func scheduleVisibleHoldReevaluation(after delay: TimeInterval) {
        pendingVisibleHoldReleaseCheck?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.pendingVisibleHoldReleaseCheck = nil
            if self.visibleHoldLatched,
               Date() >= self.visibleHoldLatchExpiry {
                self.visibleHoldLatched = false
            }
            if !self.isHoldingVisible {
                self.stopVisibleHoldDestinationProbe()
                self.visibleHoldReason = nil
                self.visibleHoldDisplayID = nil
                self.visibleHoldCanPrehideOccupiedDestination = false
            }
            self.evaluateFrontmostApp(quiet: true)
        }
        pendingVisibleHoldReleaseCheck = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, delay),
            execute: work
        )
    }

    private func scheduleDesktopTransitionFinish(after delay: TimeInterval) {
        pendingDesktopTransitionFinish?.cancel()
        desktopTransitionGeneration += 1
        let generation = desktopTransitionGeneration

        let work = DispatchWorkItem { [weak self] in
            guard
                let self,
                self.isRunning,
                generation == self.desktopTransitionGeneration
            else { return }

            self.pendingDesktopTransitionFinish = nil
            self.desktopTransitionPhase = .idle
            if self.missionControlIsActive {
                return
            }

            // A downward Mission Control gesture already owns Dock policy
            // through the animation—often without sending any toggle at all.
            // Keep that ownership until the hidden hold itself releases.
            if self.hiddenHoldReason == .missionControlExit,
               !self.isHoldingHidden {
                self.hiddenHoldReason = nil
            }
            self.cancelTransientDecisionWork()
            self.evaluateFrontmostApp(quiet: true)
        }
        pendingDesktopTransitionFinish = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, delay),
            execute: work
        )
    }

    private func cancelTransientDecisionWork() {
        pendingAccessibilityCheck?.cancel()
        pendingAccessibilityCheck = nil
        pendingAccessibilitySettleCheck?.cancel()
        pendingAccessibilitySettleCheck = nil
        pendingDebounceCheck?.cancel()
        pendingDebounceCheck = nil
    }

    @discardableResult
    private func simulateOptionCommandD() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            dockAwayDebugLog("  ⚠️ Could not create CGEventSource")
            return false
        }

        let keyD: CGKeyCode = 2

        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyD, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyD, keyDown: false)
        else { return false }

        let modifiers: CGEventFlags = [.maskAlternate, .maskCommand]
        keyDown.flags = modifiers
        keyUp.flags = modifiers

        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)

        dockAwayDebugLog("  ⌨️ Sent ⌘⌥D")
        return true
    }

    private func setDockVisible(_ shouldShow: Bool) {
        guard
            isRunning,
            (NSApp.delegate as? AppDelegate)?.isQuitting != true
        else { return }

        // A classified horizontal Space swipe owns HIDE until its landing
        // grace completes. Mission Control cancels an entry-time desktop latch
        // before taking passive ownership of DockAway's decisions.
        if isHoldingHidden {
            if shouldShow { return }
        }

        // An empty-source horizontal swipe owns SHOW through the landing grace.
        // Occupancy scans still run and cache the destination, but cannot hide
        // the Dock until the fingers are up and the Space has settled.
        if isHoldingVisible, !shouldShow {
            return
        }

        // Mission Control owns the Dock's temporary on-screen presentation.
        // Freeze DockAway's policy while protected so an already-dequeued AX
        // callback cannot change the work area during the system animation.
        if isDesktopTransitionProtected {
            return
        }

        let actuallyShown = dockIsActuallyShown()
        reconcileLastDockCommand(with: actuallyShown)

        let hasPendingDesiredCommand = lastCommandedDockVisibility == shouldShow
            && Date().timeIntervalSince(lastToggleTime) < dockCommandSettleTimeout
        if hasPendingDesiredCommand { return }

        let hasPendingOppositeCommand = lastCommandedDockVisibility != nil
            && lastCommandedDockVisibility != shouldShow
            && Date().timeIntervalSince(lastToggleTime) < dockCommandSettleTimeout
        guard actuallyShown != shouldShow || hasPendingOppositeCommand else { return }

        // Stop overlapping events double-tapping while com.apple.dock's value
        // catches up. Re-evaluate once the gate opens so the newest decision is
        // not silently lost now that the safety timer is intentionally slower.
        let timeSinceLastToggle = Date().timeIntervalSince(lastToggleTime)
        if timeSinceLastToggle < toggleDebounce {
            scheduleDebounceReevaluation(
                after: toggleDebounce - timeSinceLastToggle + 0.02
            )
            return
        }

        pendingDebounceCheck?.cancel()
        pendingDebounceCheck = nil

        sendDockToggle(towardVisible: shouldShow, reason: "Forcing Dock")
    }

    private func dockIsActuallyShown() -> Bool {
        let isShown = !(UserDefaults(suiteName: "com.apple.dock")?
            .bool(forKey: "autohide") ?? false)
        postDockVisibility(isShown)
        return isShown
    }

    private func reconcileLastDockCommand(with actuallyShown: Bool) {
        guard let commandedVisibility = lastCommandedDockVisibility else { return }

        let commandAge = Date().timeIntervalSince(lastToggleTime)
        if actuallyShown == commandedVisibility
            || commandAge >= dockCommandSettleTimeout {
            lastCommandedDockVisibility = nil
        }
    }

    private func sendDockToggle(towardVisible visible: Bool, reason: String) {
        dockAwayDebugLog("  ⚡ \(reason) \(visible ? "SHOW" : "HIDE")")
        lastToggleTime = Date()
        lastCommandedDockVisibility = visible
        if simulateOptionCommandD() {
            postDockVisibility(visible)
        }
    }

    private func scheduleDebounceReevaluation(after delay: TimeInterval) {
        pendingDebounceCheck?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.pendingDebounceCheck = nil
            self.evaluateFrontmostApp(quiet: true)
        }
        pendingDebounceCheck = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, delay),
            execute: work
        )
    }

    // MARK: - Status Helpers

    private func postStatus(_ text: String) {
        (NSApp.delegate as? AppDelegate)?.updateStatus(text)
    }

    private func postDockVisibility(_ isVisible: Bool) {
        (NSApp.delegate as? AppDelegate)?.updateDockVisibilityGlyph(isVisible)
    }
}
