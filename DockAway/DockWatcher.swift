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

    struct DesktopInfo {
        let currentDesktopIndex: Int
        let totalDesktops: Int
        let isFullScreenApp: Bool
        let selection: DesktopSelectionSnapshot
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

    func currentDesktopInfo(on displayID: CGDirectDisplayID) -> DesktopInfo? {
        guard
            let mainConnectionIDFn,
            let copyManagedDisplaySpacesFn,
            let rawDisplays = copyManagedDisplaySpacesFn(
                mainConnectionIDFn()
            )?.takeRetainedValue(),
            let displays = Self.dictionaryArray(from: rawDisplays),
            let display = matchingDisplay(in: displays, displayID: displayID, allowFallback: false),
            let current = display["Current Space"] as? [String: Any],
            let currentID = Self.spaceIdentifier(in: current),
            let rawSpaces = display["Spaces"] as? NSArray,
            let spaces = Self.dictionaryArray(from: rawSpaces)
        else { return nil }

        let desktopSpaces = spaces.filter {
            (($0["type"] as? NSNumber)?.intValue ?? 0) == 0
        }
        let fullscreenSpaces = spaces.filter {
            (($0["type"] as? NSNumber)?.intValue ?? 0) == 4
        }
        var fullscreenContentSpaceIDs: [UInt64: [UInt64]] = [:]
        var fullscreenApplicationNames: [UInt64: String] = [:]
        for fullscreenSpace in fullscreenSpaces {
            guard let fullscreenID = Self.spaceIdentifier(in: fullscreenSpace),
                  let layout = fullscreenSpace["TileLayoutManager"] as? NSDictionary,
                  let rawTileSpaces = layout["TileSpaces"] as? NSArray,
                  let tileSpaces = Self.dictionaryArray(from: rawTileSpaces) else { continue }
            let contentIDs = tileSpaces.compactMap { Self.spaceIdentifier(in: $0) }
            if !contentIDs.isEmpty { fullscreenContentSpaceIDs[fullscreenID] = contentIDs }
            if let name = tileSpaces.compactMap({
                ($0["appName"] as? String) ?? ($0["name"] as? String)
            }).first(where: { !$0.isEmpty }) {
                let pid = tileSpaces.compactMap { ($0["pid"] as? NSNumber)?.int32Value }.first
                let bundleID = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
                fullscreenApplicationNames[fullscreenID] = DesktopBoxFullscreenPreference.displayFullscreenName(name, bundleIdentifier: bundleID)
            }
        }
        let selection = DesktopSelectionSnapshot(
            displayID: displayID,
            currentID: currentID,
            orderedSpaceIDs: spaces.compactMap { Self.spaceIdentifier(in: $0) },
            desktopIDs: desktopSpaces.compactMap { Self.spaceIdentifier(in: $0) },
            fullscreenSpaceIDs: fullscreenSpaces.compactMap { Self.spaceIdentifier(in: $0) },
            fullscreenContentSpaceIDs: fullscreenContentSpaceIDs,
            fullscreenApplicationNames: fullscreenApplicationNames
        )

        guard let currentIndex = desktopSpaces.firstIndex(where: {
            Self.spaceIdentifier(in: $0) == currentID
        }) else {
            return DesktopInfo(
                currentDesktopIndex: 0,
                totalDesktops: desktopSpaces.count,
                isFullScreenApp: true,
                selection: selection
            )
        }

        return DesktopInfo(
            currentDesktopIndex: currentIndex + 1,
            totalDesktops: desktopSpaces.count,
            isFullScreenApp: false,
            selection: selection
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
        displayID: CGDirectDisplayID,
        allowFallback: Bool = true
    ) -> [String: Any]? {
        guard
            let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID)
        else {
            return allowFallback ? displays.first : nil
        }
        let uuid = unmanagedUUID.takeRetainedValue()
        let identifier = CFUUIDCreateString(nil, uuid) as String

        let exact = displays.first {
            guard let candidate = $0["Display Identifier"] as? String else {
                return false
            }
            return candidate.caseInsensitiveCompare(identifier) == .orderedSame
        }
        if let exact { return exact }
        // Prefer the live UUID mapping even while the system's display-mode
        // flag is stale. Shared Spaces explicitly use the "Main" identifier.
        if !NSScreen.screensHaveSeparateSpaces,
           let shared = displays.first(where: { ($0["Display Identifier"] as? String) == "Main" }) {
            return shared
        }
        return allowFallback ? displays.first : nil
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

    private enum DockDisplayHandoffTrigger {
        case activation
        case hover
    }

    private struct HorizontalSpacePrediction {
        let displayID: CGDirectDisplayID
        let capturedAt: Date
        let previousState: DisplayWindowState?
        let nextState: DisplayWindowState?
    }

    private var pendingAccessibilityCheck: DispatchWorkItem?
    private var pendingAccessibilitySettleCheck: DispatchWorkItem?
    private struct LaunchWindowCorrection {
        let processIdentifier: pid_t
        let displayID: CGDirectDisplayID
        let screenFrame: CGRect
        let oldWorkArea: CGRect
        let primaryTop: CGFloat
        let pointerAtArm: CGPoint
        var retry: DockGapCorrectionRetryPolicy
        var window: AXUIElement?
        var lastFailure: String?
    }
    private var launchWindowCorrection: LaunchWindowCorrection?
    private var launchWindowCorrectionTimer: Timer?
    private var shownDockWorkAreas = [CGDirectDisplayID: ShownDockWorkArea]()
    private var pendingDebounceCheck: DispatchWorkItem?
    private var pendingDesktopTransitionFinish: DispatchWorkItem?
    private var pendingHoldReleaseCheck: DispatchWorkItem?
    private var pendingVisibleHoldReleaseCheck: DispatchWorkItem?
    private var pendingMissionControlRefresh: DispatchWorkItem?
    private var pendingDockObserverRetry: DispatchWorkItem?
    private var pendingDockDisplayHandoffWork: DispatchWorkItem?
    private var pendingObserverRetries = [pid_t: DispatchWorkItem]()
    private var safetyTimer: Timer?
    private var pointerDisplayTimer: Timer?
    private var visibleHoldDestinationTimer: Timer?
    private var accessibilityObservations = [pid_t: DockWatcherAXObservation]()
    private var dockAccessibilityObservation: DockWatcherAXObservation?
    private let missionControlProbe = MissionControlProbe()
    private let missionControlAutoExpand = MissionControlAutoExpand()
    private let missionControlWindowClose = MissionControlWindowClose()
    private var missionControlTrackpadContacts = 0
    private var missionControlNeedsBootstrap = true
    private var missionControlFallbackRequested = false
    private var missionControlIsActive = false
    var isMissionControlActive: Bool {
        missionControlIsActive
    }
    var onAccessibilityEvent: ((pid_t, AXUIElement, String) -> Void)?
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
    // A hover-triggered display handoff must not issue the global SHOW command
    // before Dock.app confirms that it owns the empty destination. This marker
    // keeps unrelated safety/AX reevaluations quiet during that short handoff.
    private var pointerOnlyEmptyDisplayID: CGDirectDisplayID?
    private var cachedDockDisplayID: CGDirectDisplayID?
    private var dockDisplayCacheValidUntil = Date.distantPast
    private var dockDisplayHandoffTargetID: CGDirectDisplayID?
    private var dockDisplayHandoffPointerAnchor: CGPoint?
    private var dockDisplayHandoffExpectedState: DisplayWindowState?
    private var dockDisplayHandoffExpectedBundleIdentifier: String?
    private var dockDisplayHandoffTrigger: DockDisplayHandoffTrigger = .activation
    private var dockDisplayHoverCooldownUntil = [CGDirectDisplayID: Date]()
    private var dockDisplayHandoffGeneration = 0
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
    private var windowMovementSettlesAt = Date.distantPast
    private var pendingMovedWindow: (pid: pid_t, window: AXUIElement)?
    private var isWindowMovementSettling: Bool {
        Date() < windowMovementSettlesAt
    }
    private let pointerDisplayInterval: TimeInterval = 0.12
    private let dockDisplayCacheLifetime: TimeInterval = 0.50
    private let dockDisplayHoverSettleInterval: TimeInterval = 0.05
    private let dockDisplayHoverCooldown: TimeInterval = 0.40
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
    private var dockCommandSettleTimeout: TimeInterval = 1.0
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

    private var windowMoveProtectionExpiry: Date = .distantPast

    var isWindowMoveTransitionProtected: Bool {
        Date() < windowMoveProtectionExpiry
    }

    func protectWindowMoveTransition(duration: TimeInterval = 0.55) {
        windowMoveProtectionExpiry = Date().addingTimeInterval(duration)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { [weak self] in
            guard let self, self.isRunning else { return }
            self.evaluateFrontmostApp(quiet: true)
        }
    }

    private var isDesktopTransitionProtected: Bool {
        desktopTransitionPhase != .idle || missionControlIsActive
            || (isRunning && missionControlNeedsBootstrap)
            || isWindowMoveTransitionProtected
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
        refreshDockCommandSettleTimeout()
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

    private func refreshDockCommandSettleTimeout() {
        let customDuration = (
            UserDefaults(suiteName: "com.apple.dock")?
                .object(forKey: "autohide-time-modifier") as? NSNumber
        )?.doubleValue

        // Keep the stable one-second gate for the system default and all fast
        // presets. Slower custom animations need extra time to land before a
        // later AX event is allowed to reconcile or reverse the command.
        if let customDuration, customDuration > 1.0 {
            dockCommandSettleTimeout = min(customDuration + 0.5, 3.0)
        } else {
            dockCommandSettleTimeout = 1.0
        }
    }

    func stop() {
        cancelLaunchWindowCorrection()
        shownDockWorkAreas.removeAll()
        pendingMovedWindow = nil
        windowMovementSettlesAt = .distantPast
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
        cancelDockDisplayHandoff()
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
        pointerOnlyEmptyDisplayID = nil
        cachedDockDisplayID = nil
        dockDisplayCacheValidUntil = .distantPast
        dockDisplayHoverCooldownUntil.removeAll(keepingCapacity: true)
        missionControlIsActive = false
        missionControlAutoExpand.cancel()
        missionControlWindowClose.stop()
        missionControlTrackpadContacts = 0
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

        cancelDockDisplayHandoff()

        // A Space switch is an intentional interaction with the display under
        // the pointer, so an empty destination may now own a SHOW decision.
        pointerOnlyEmptyDisplayID = nil

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
        if isHoldingVisible, visibleHoldCanPrehideOccupiedDestination {
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

        if notification == kAXWindowMovedNotification {
            // Launching apps also emit moved notifications while positioning
            // their new window. Only an actual user drag cancels correction.
            if let correction = launchWindowCorrection,
               correction.processIdentifier == processIdentifier,
               NSEvent.pressedMouseButtons != 0,
               hypot(NSEvent.mouseLocation.x - correction.pointerAtArm.x,
                     NSEvent.mouseLocation.y - correction.pointerAtArm.y) > 6 {
                cancelLaunchWindowCorrection()
            }
            if NSScreen.screens.count > 1 {
                pendingMovedWindow = (processIdentifier, element)
                // Native display transfers animate outside Mission Control.
                // Keep the work area stable until movement notifications stop.
                windowMovementSettlesAt = Date().addingTimeInterval(0.35)
            }
        } else if notification == kAXWindowResizedNotification {
            if let correction = launchWindowCorrection,
               correction.processIdentifier == processIdentifier,
               let window = correction.window, CFEqual(window, element),
               NSEvent.pressedMouseButtons != 0,
               hypot(NSEvent.mouseLocation.x - correction.pointerAtArm.x,
                     NSEvent.mouseLocation.y - correction.pointerAtArm.y) > 6 {
                cancelLaunchWindowCorrection()
            }
            if isWindowMovementSettling {
                windowMovementSettlesAt = Date().addingTimeInterval(0.35)
            }
        }

        onAccessibilityEvent?(processIdentifier, element, notification)
        scheduleAccessibilityEvaluation(includeSettleRecheck: true)
    }

    private func scheduleAccessibilityEvaluation(includeSettleRecheck: Bool) {
        guard isRunning, !isDesktopTransitionProtected else { return }
        let movementDelay = max(0, windowMovementSettlesAt.timeIntervalSinceNow)

        pendingAccessibilityCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.pendingAccessibilityCheck = nil
            self.evaluateFrontmostApp(quiet: true)
        }
        pendingAccessibilityCheck = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(accessibilityDebounce, movementDelay),
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
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.17, movementDelay + 0.05), execute: settleWork)
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
            refreshMissionControlState(allowWindowServerFallback: true)
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
            self.refreshMissionControlState(allowWindowServerFallback: true)
        }
        pendingDockObserverRetry = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + observerRetryDelays[attempt],
            execute: work
        )
    }

    private func removeDockAccessibilityObserver() {
        missionControlProbe.invalidate()
        missionControlNeedsBootstrap = true
        missionControlFallbackRequested = false
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

        refreshMissionControlState(
            allowWindowServerFallback: true,
            invalidatingInFlightResult: true
        )
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

    private func refreshMissionControlState(
        allowWindowServerFallback: Bool,
        invalidatingInFlightResult: Bool = false
    ) {
        guard isRunning else { return }

        if dockAccessibilityObservation == nil {
            installDockAccessibilityObserver()
        }

        // Coalescing a periodic tick must not discard an earlier notification's
        // request for a fresh WindowServer cross-check.
        missionControlFallbackRequested = missionControlFallbackRequested
            || allowWindowServerFallback || invalidatingInFlightResult
        if invalidatingInFlightResult {
            // A real Dock state edge makes the previous snapshot uncertain.
            // Protect decisions until its replacement arrives, not the UI thread.
            missionControlNeedsBootstrap = true
        }

        // Startup must protect the Dock before the first occupancy decision.
        // A notification also gets an immediate entry check while AX runs off
        // the UI thread. Never interpret a failed snapshot as an empty desktop.
        if missionControlNeedsBootstrap || invalidatingInFlightResult {
            let snapshot = missionControlWindowServerStateSnapshot()
            if snapshot == true {
                updateMissionControlState(true)
            }
        }

        guard let pid = dockAccessibilityObservation?.context.processIdentifier else {
            if let snapshot = missionControlWindowServerStateSnapshot() {
                missionControlNeedsBootstrap = false
                updateMissionControlState(snapshot)
            }
            return
        }

        missionControlProbe.request(
            pid: pid,
            invalidatingInFlightResult: invalidatingInFlightResult
        ) { [weak self] result in
            guard let self, self.isRunning,
                  self.dockAccessibilityObservation?.context.processIdentifier == pid else { return }
            var fallback: Bool?
            if !result.isActive,
               self.missionControlFallbackRequested || !result.querySucceeded
                    || self.missionControlIsActive || self.desktopTransitionPhase != .idle
                    || self.isHoldingHidden || self.isHoldingVisible {
                fallback = self.missionControlWindowServerStateSnapshot()
            }
            guard let isActive = result.resolve(windowServer: fallback) else {
                // Both sources are uncertain. Keep protection and retry on
                // the existing timer instead of publishing a false exit.
                return
            }
            let wasBootstrapping = self.missionControlNeedsBootstrap
            self.missionControlNeedsBootstrap = false
            self.missionControlFallbackRequested = false
            self.updateMissionControlState(isActive)
            if wasBootstrapping {
                self.scheduleAccessibilityEvaluation(includeSettleRecheck: true)
            }
        }
    }

    // Tahoe and the current beta expose a WindowManager "Spaces Bar" at
    // layer 14 only for Mission Control (not App Exposé or Show Desktop).
    // This is an undocumented fallback used only when AX is late or unavailable.
    private func missionControlWindowServerStateSnapshot() -> Bool? {
        let options: CGWindowListOption = [.optionOnScreenOnly]
        guard let windows = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        return windows.contains { info in
            let ownerName = info[kCGWindowOwnerName as String] as? String
            let layer = info[kCGWindowLayer as String] as? Int
            return ownerName == "WindowManager" && layer == 14
        }
    }

    func missionControlTrackpadContactsChanged(_ count: Int) {
        let wasSwiping = missionControlTrackpadContacts >= 3
        missionControlTrackpadContacts = count
        missionControlWindowClose.trackpadContactsChanged(count)
        if count >= 3 {
            missionControlAutoExpand.cancel()
        } else if wasSwiping && missionControlIsActive && isRunning {
            scheduleMissionControlExpansion()
        }
    }

    func missionControlTrackpadMotionDetected(_ motion: MultitouchWatcher.FourFingerMotion) {
        guard isRunning && missionControlIsActive else { return }
        switch motion {
        case .downward:
            missionControlWindowClose.handleDownwardSwipe()
        case .upward:
            missionControlWindowClose.cancelDownwardSwipe()
        default:
            break
        }
    }

    private func scheduleMissionControlExpansion() {
        missionControlAutoExpand.entered { [weak self] in
            self?.isRunning == true && self?.missionControlIsActive == true
                && (self?.missionControlTrackpadContacts ?? 0) < 3
        }
    }

    private func updateMissionControlState(_ isActive: Bool) {
        guard missionControlIsActive != isActive else { return }

        missionControlIsActive = isActive
        missionControlWindowClose.setActive(isActive)
        if isActive && missionControlTrackpadContacts < 3 {
            scheduleMissionControlExpansion()
        } else {
            missionControlAutoExpand.cancel()
        }
        nextMissionControlProbeAt = .distantPast

        if isActive {
            cancelDockDisplayHandoff()
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

    func refreshMissionControlClosePreference() {
        missionControlWindowClose.stop()
        if isRunning && missionControlIsActive { missionControlWindowClose.setActive(true) }
    }

    func reloadMissionControlKeyboardShortcuts() {
        missionControlWindowClose.reloadKeyboardShortcuts()
    }

    var missionControlKeyboardCommandsToolTip: String {
        missionControlWindowClose.keyboardCommandsToolTip
    }

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
            self.evaluateFrontmostApp(
                quiet: true,
                pointerDisplayChanged: true
            )
        }
        // Pointer/display changes are not latency-sensitive enough to require
        // every 120 ms wakeup exactly on schedule. Let macOS coalesce nearby
        // work without changing the polling interval or gesture behavior.
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        pointerDisplayTimer = timer
    }

    @objc private func screenParametersDidChange() {
        cancelDockDisplayHandoff()
        horizontalSpacePrediction = nil
        pointerOnlyEmptyDisplayID = nil
        cachedDockDisplayID = nil
        dockDisplayCacheValidUntil = .distantPast
        dockDisplayHoverCooldownUntil.removeAll(keepingCapacity: true)
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
        prepareLaunchWindowCorrection(for: app)
        dockAwayDebugLog("▶ Active app: \(appName)")

        // Finder activation is the click-based fallback if a hover handoff did
        // not finish. Ordinary app activations do not clear the pending-empty
        // marker unless a window actually occupies this display.
        let finderActivated = app.bundleIdentifier == "com.apple.finder"
        // App activation is a correctness boundary: never route a SHOW from a
        // potentially stale Dock-owner snapshot.
        cachedDockDisplayID = nil
        dockDisplayCacheValidUntil = .distantPast
        if finderActivated {
            // If the click beats the 120 ms pointer timer, consume that display
            // change here so the next tick cannot launch a duplicate hover
            // handoff for the same confirmed desktop click.
            lastPointerDisplayID = displayIDUnderPointer()
            pointerOnlyEmptyDisplayID = nil
        } else {
            cancelDockDisplayHandoff()
        }
        evaluate(
            app: app,
            quiet: false,
            applicationActivated: true,
            finderActivated: finderActivated
        )

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

    // Capture the reserved work area before hiding. AX registration order is
    // not a reliable way to distinguish a just-created or restored window.
    private func prepareLaunchWindowCorrection(for app: NSRunningApplication) {
        if launchWindowCorrection?.processIdentifier == app.processIdentifier { return }
        cancelLaunchWindowCorrection()
        let displayID = displayIDUnderPointer()
        guard isRunning, !isDesktopTransitionProtected,
              app.activationPolicy == .regular,
              app.bundleIdentifier != "com.apple.finder",
              !isProcessBlacklisted(app.processIdentifier),
              let screen = NSScreen.screen(withDisplayID: displayID) else { return }
        let screenFrame = screen.frame
        // Prediction can hide the Dock before macOS delivers activation or
        // publishes the new focused window. Keep the last genuinely reserved
        // work area across that short boundary instead of requiring SHOW now.
        let shown = dockIsActuallyShown()
        let now = ProcessInfo.processInfo.systemUptime
        let oldFrame: CGRect
        if shown, screen.visibleFrame.minY - screenFrame.minY > 10 {
            oldFrame = screen.visibleFrame
        } else if let snapshot = shownDockWorkAreas[displayID],
                  snapshot.isUsable(on: screenFrame, now: now) {
            oldFrame = snapshot.visibleFrame
        } else { return }
        // Side-positioned Docks need position changes as well. Reclaim only
        // the bottom-edge gap, without altering the window's position or width.
        guard oldFrame.minY - screenFrame.minY > 10,
              abs(oldFrame.minX - screenFrame.minX) < 3,
              abs(oldFrame.width - screenFrame.width) < 3 else { return }
        let pid = app.processIdentifier
        guard let primaryTop = NSScreen.screens.first?.frame.maxY else { return }
        launchWindowCorrection = LaunchWindowCorrection(
            processIdentifier: pid, displayID: displayID, screenFrame: screenFrame,
            oldWorkArea: CGRect(x: oldFrame.minX, y: primaryTop - oldFrame.maxY,
                                width: oldFrame.width, height: oldFrame.height),
            primaryTop: primaryTop,
            pointerAtArm: NSEvent.mouseLocation,
            retry: DockGapCorrectionRetryPolicy(now: ProcessInfo.processInfo.systemUptime)
        )
        dockAwayDebugLog("  → Window correction armed pid=\(pid) oldFrame=\(oldFrame)")
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.recheckLaunchWindowCorrection()
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        launchWindowCorrectionTimer = timer
    }

    private func cancelLaunchWindowCorrection() {
        launchWindowCorrectionTimer?.invalidate()
        launchWindowCorrectionTimer = nil
        launchWindowCorrection = nil
    }

    private func recheckLaunchWindowCorrection() {
        guard var correction = launchWindowCorrection else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard isRunning, !correction.retry.hasExpired(now: now),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == correction.processIdentifier,
              !isProcessBlacklisted(correction.processIdentifier),
              let screen = NSScreen.screen(withDisplayID: correction.displayID),
              screen.frame == correction.screenFrame,
              NSScreen.screens.first?.frame.maxY == correction.primaryTop else {
            dockAwayDebugLog("  → Window correction ended or invalidated pid=\(correction.processIdentifier), lastFailure=\(correction.lastFailure ?? "none")")
            cancelLaunchWindowCorrection()
            return
        }
        // Retry after launch positioning and Dock animation settle, rather
        // than permanently losing the operation to one transitional snapshot.
        guard !isDesktopTransitionProtected, !isWindowMovementSettling,
              NSEvent.pressedMouseButtons == 0, !dockIsActuallyShown() else { return }
        let visible = screen.visibleFrame
        let newWorkArea = CGRect(x: visible.minX, y: correction.primaryTop - visible.maxY,
                                 width: visible.width, height: visible.height)
        guard abs(newWorkArea.minX - correction.oldWorkArea.minX) < 3,
              abs(newWorkArea.minY - correction.oldWorkArea.minY) < 3,
              abs(newWorkArea.width - correction.oldWorkArea.width) < 3 else {
            cancelLaunchWindowCorrection()
            return
        }
        guard newWorkArea.maxY - correction.oldWorkArea.maxY > 10 else { return }
        let budget = AccessibilityRequestBudget(seconds: 0.08)
        let application = AXUIElementCreateApplication(correction.processIdentifier)
        guard let focused = budget.element(kAXFocusedWindowAttribute, of: application)
                ?? budget.element(kAXMainWindowAttribute, of: application),
              budget.string(kAXSubroleAttribute, of: focused) == kAXStandardWindowSubrole,
              (budget.perform(on: focused, { focused.bool("AXFullScreen") }) ?? nil) != true,
              budget.perform(on: focused, { focused.bool(kAXMinimizedAttribute) }) == false,
              let frame = budget.frame(of: focused) else {
            noteLaunchWindowCorrectionFailure("Window hierarchy/frame not ready or not a standard resizable window")
            return
        }
        // Stay with one window once a write has been attempted. An app may
        // open a dialog or switch focused windows while restoring its session.
        if let window = correction.window, !CFEqual(window, focused) {
            cancelLaunchWindowCorrection()
            return
        }
        // AX can expose a focused window on another Space. Only resize when
        // WindowServer also reports this normal window on the visible desktop.
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0)
                as? [[String: Any]],
              windows.contains(where: { info in
                  guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == correction.processIdentifier,
                        (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                        let bounds = info[kCGWindowBounds as String] as? [String: Any],
                        let cgFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
                  return DockGapCorrectionGeometry.approximatelyEqual(frame, cgFrame, tolerance: 4)
              }) else {
            noteLaunchWindowCorrectionFailure("WindowServer has not confirmed the window on this desktop")
            return
        }
        switch correction.retry.action(window: frame, oldWorkArea: correction.oldWorkArea,
                                       newWorkArea: newWorkArea, now: now) {
        case .finish:
            dockAwayDebugLog("  → Window correction finished pid=\(correction.processIdentifier) writes=\(correction.retry.writeCount)")
            cancelLaunchWindowCorrection()
        case .wait:
            launchWindowCorrection = correction
        case .resize(let target):
            var settable = DarwinBoolean(false)
            guard budget.perform(on: focused, {
                AXUIElementIsAttributeSettable(focused, kAXSizeAttribute as CFString, &settable)
            }) == .success, settable.boolValue else {
                noteLaunchWindowCorrectionFailure("AX size is not writable yet")
                return
            }
            var size = target.size
            guard let value = AXValueCreate(.cgSize, &size),
                  let result = budget.perform(on: focused, {
                      AXUIElementSetAttributeValue(focused, kAXSizeAttribute as CFString, value)
                  }) else {
                noteLaunchWindowCorrectionFailure("AX resize exceeded the request budget")
                return
            }
            correction.window = focused
            correction.retry.didAttemptResize(to: target, now: now)
            correction.lastFailure = result == .success ? nil : "AX resize error \(result.rawValue)"
            launchWindowCorrection = correction
            dockAwayDebugLog("  → Launch window Dock-gap write \(correction.retry.writeCount): \(result.rawValue), awaiting verification")
        }
    }

    private func noteLaunchWindowCorrectionFailure(_ reason: String) {
        guard var correction = launchWindowCorrection else { return }
        if correction.lastFailure != reason {
            dockAwayDebugLog("  → Window correction waiting pid=\(correction.processIdentifier): \(reason)")
        }
        correction.lastFailure = reason
        launchWindowCorrection = correction
    }

    // MARK: - Core Logic

    private func consumeWindowTransferAway(from displayID: CGDirectDisplayID) -> Bool {
        guard let moved = pendingMovedWindow else { return false }
        pendingMovedWindow = nil
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == moved.pid else { return false }
        let application = AXUIElementCreateApplication(moved.pid)
        AXUIElementSetMessagingTimeout(application, 0.05)
        guard let focused = application.element(kAXFocusedWindowAttribute),
              CFEqual(focused, moved.window),
              let frame = moved.window.frame,
              frame.width > 0, frame.height > 0 else { return false }
        guard !frame.intersects(CGDisplayBounds(displayID)) else { return false }
        return NSScreen.screens.contains { screen in
            guard let otherID = screen.displayID, otherID != displayID else { return false }
            return CGDisplayBounds(otherID).contains(CGPoint(x: frame.midX, y: frame.midY))
        }
    }

    // Re-checks whatever app macOS currently reports as frontmost.
    private func evaluateFrontmostApp(
        quiet: Bool,
        pointerDisplayChanged: Bool = false
    ) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        evaluate(
            app: app,
            quiet: quiet,
            pointerDisplayChanged: pointerDisplayChanged
        )
    }

    // Shows the Dock only when the display under the pointer has no standard
    // app window, or when a blacklisted app is visible there. That is the
    // display whose Space the user is interacting with during a multi-monitor
    // desktop swipe.
    private func evaluate(
        app: NSRunningApplication,
        quiet: Bool,
        pointerDisplayChanged: Bool = false,
        applicationActivated: Bool = false,
        finderActivated: Bool = false
    ) {
        guard isRunning, !isWindowMovementSettling else { return }

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
        // A failed WindowServer read is not evidence of an empty desktop.
        // Preserve the last confirmed decision; the safety timer will retry.
        guard let windowState = displayWindowState(on: activeDisplay) else { return }
        lastEvaluatedDisplayID = activeDisplayID
        lastEvaluatedWindowState = windowState

        let transferredAway = consumeWindowTransferAway(from: activeDisplayID)
        if transferredAway, windowState == .empty,
           !pointerDisplayChanged, !finderActivated, !applicationActivated {
            // The pointer left behind by a native transfer is not a request
            // to show the Dock. Reuse the empty-display intent gate, cleared
            // by a display crossing, Finder activation, or an incoming window.
            pointerOnlyEmptyDisplayID = activeDisplayID
            cancelDockDisplayHandoff()
            dockAwayDebugLog("  → Window transferred away; deferring empty-source Dock show until desktop interaction")
        }

        // App activation is delivered before a newly opened window is always
        // present in WindowServer's list. For a regular, non-blacklisted app,
        // use that early signal to start hiding the Dock while the previous
        // state still looks empty or blacklisted, before the new window is
        // sized against its visible frame. The existing AX settle evaluation
        // remains authoritative and restores the Dock if no window appears.
        let predictsIncomingWindow = applicationActivated
            && windowState != .occupied
            && app.activationPolicy == .regular
            && bundleID != "com.apple.finder"
            && !isProcessBlacklisted(app.processIdentifier)

        let pointerEnteredEmptyDisplay = pointerDisplayChanged
            && windowState == .empty
        if pointerDisplayChanged {
            if windowState != .empty {
                cancelDockDisplayHandoff()
            }
            // A display crossing is rare and correctness-sensitive. Refresh the
            // cached Dock owner before deciding whether SHOW is already safe or
            // a verified handoff is required.
            cachedDockDisplayID = nil
            dockDisplayCacheValidUntil = .distantPast
            pointerOnlyEmptyDisplayID = windowState == .empty
                ? activeDisplayID
                : nil
        } else if pointerOnlyEmptyDisplayID == activeDisplayID,
                  windowState != .empty {
            // An app or blacklisted window appearing on the hovered display is
            // a real state change. HIDE/blacklist behavior takes over normally.
            pointerOnlyEmptyDisplayID = nil
        }

        let shouldShowDock = windowState != .occupied
            && !predictsIncomingWindow
        let suppressPendingHoverShow = shouldShowDock
            && !pointerEnteredEmptyDisplay
            && windowState == .empty
            && pointerOnlyEmptyDisplayID == activeDisplayID

        if handOffVisibleHoldToHiddenIfNeeded(
            for: windowState,
            on: activeDisplayID
        ) {
            return
        }

        let suppressUnsafeDisplayShow = shouldShowDock
            && showNeedsDisplaySafetySuppression(
                targetDisplayID: activeDisplayID
            )

        // Entering an empty display, focusing its Finder desktop, or activating
        // a blacklisted app expresses intent to use that display. macOS does
        // not always move an already-hidden Dock there by itself, so ask
        // Dock.app to process an edge pulse and permit SHOW only after its own
        // window proves that the display handoff succeeded.
        let handoffExpectedState: DisplayWindowState?
        if pointerEnteredEmptyDisplay
            || (finderActivated && windowState == .empty) {
            handoffExpectedState = .empty
        } else if applicationActivated,
                  windowState == .blacklisted,
                  isBlacklisted(
                      bundleID,
                      in: cachedIgnoredBundleIdentifiers
                  ) {
            handoffExpectedState = .blacklisted
        } else {
            handoffExpectedState = nil
        }

        let isFinderOnDesktop = app.bundleIdentifier == "com.apple.finder"
            && !finderHasNormalWindow(on: activeDisplay)
        let label = isFinderOnDesktop ? "Desktop" : (app.localizedName ?? bundleID)
        let appText = windowState == .empty ? "Desktop" : label

        if suppressUnsafeDisplayShow,
           let handoffExpectedState,
           beginDockDisplayHandoff(
                to: activeDisplayID,
                expectedState: handoffExpectedState,
                frontmostBundleIdentifier: bundleID,
                trigger: pointerEnteredEmptyDisplay ? .hover : .activation
           ) {
            postStatus(appText, displayID: activeDisplayID)
            return
        }

        if pointerEnteredEmptyDisplay, !suppressUnsafeDisplayShow {
            // Dock.app already owns this display, so no routing pulse is
            // necessary and the hover can show it immediately.
            pointerOnlyEmptyDisplayID = nil
        }

        if predictsIncomingWindow {
            dockAwayDebugLog("  → Regular app activated while Dock is shown → predictively hiding Dock")
        } else if !quiet {
            switch windowState {
            case .empty:
                dockAwayDebugLog("  → Active display is empty → showing Dock")
            case .blacklisted:
                dockAwayDebugLog("  → Active display has a blacklisted app → showing Dock")
            case .occupied:
                dockAwayDebugLog("  → Active display has a window → hiding Dock")
            }
        }

        if suppressPendingHoverShow {
            dockAwayDebugLog("  → Empty-display handoff pending → SHOW suppressed")
        } else if suppressUnsafeDisplayShow {
            dockAwayDebugLog("  → Dock target is unsafe or unresolved → SHOW suppressed")
        } else {
            setDockVisible(shouldShowDock)
        }

        // Quiet evaluations suppress repetitive console output, but they are
        // also the authoritative post-transition correction. Always refresh
        // the menu so a Mission Control landing cannot leave the old app name.
        postStatus(appText, displayID: activeDisplayID)
    }

    // MARK: - Window Detection

    // Classifies the foremost normal app window on the active display. The
    // Core Graphics window list is ordered front-to-back, so a covered
    // blacklisted window cannot override the app actually in front of it. A
    // small edge overlap is ignored so window shadows across a monitor boundary
    // cannot hide the Dock.
    private func displayWindowState(on displayBounds: CGRect) -> DisplayWindowState? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        return classifyWindowState(in: list, on: displayBounds) ?? .empty
    }

    private func finderHasNormalWindow(on displayBounds: CGRect) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for info in list {
            guard
                let ownerName = info[kCGWindowOwnerName as String] as? String,
                ownerName == "Finder",
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == kCGNormalWindowLevel,
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary
            else { continue }

            var windowRect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict, &windowRect) else { continue }
            let overlap = windowRect.intersection(displayBounds)
            if overlap.width >= 50, overlap.height >= 50 {
                return true
            }
        }
        return false
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
        guard !missionControlNeedsBootstrap else { return }
        cancelDockDisplayHandoff()
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

    private func pointerDisplaySnapshot() -> (
        location: CGPoint,
        displayID: CGDirectDisplayID
    )? {
        // CGEvent(source: nil)?.location is in global display coordinates.
        guard let pointerLocation = CGEvent(source: nil)?.location else {
            return nil
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
            return nil
        }

        return (pointerLocation, display)
    }

    private func displayIDUnderPointer() -> CGDirectDisplayID {
        pointerDisplaySnapshot()?.displayID ?? CGMainDisplayID()
    }

    // Cmd-Option-D changes Dock autohide globally; it cannot choose which
    // display receives the Dock. Dock.app keeps one full-display layer at the
    // Dock window level whose bounds identify the display it currently owns,
    // even while autohide is enabled. Use this read-only hint to avoid showing
    // the Dock over an app on another screen.
    private func dockAssignedDisplayID() -> CGDirectDisplayID? {
        let now = Date()
        if now < dockDisplayCacheValidUntil {
            return cachedDockDisplayID
        }

        defer {
            dockDisplayCacheValidUntil = now.addingTimeInterval(
                dockDisplayCacheLifetime
            )
        }

        guard let windows = CGWindowListCopyWindowInfo(
            .optionAll,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            cachedDockDisplayID = nil
            return nil
        }

        var displayCount: UInt32 = 0
        guard
            CGGetActiveDisplayList(0, nil, &displayCount) == .success,
            displayCount > 0
        else {
            cachedDockDisplayID = nil
            return nil
        }

        var displayIDs = [CGDirectDisplayID](
            repeating: 0,
            count: Int(displayCount)
        )
        guard CGGetActiveDisplayList(
            displayCount,
            &displayIDs,
            &displayCount
        ) == .success else {
            cachedDockDisplayID = nil
            return nil
        }

        let dockWindowLevel = Int(CGWindowLevelForKey(.dockWindow))
        for info in windows {
            guard
                info[kCGWindowOwnerName as String] as? String == "Dock",
                info[kCGWindowLayer as String] as? Int == dockWindowLevel,
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary
            else { continue }

            var dockBounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(
                boundsDictionary,
                &dockBounds
            ) else { continue }

            if let displayID = displayIDs.prefix(Int(displayCount)).first(
                where: { displayBounds(CGDisplayBounds($0), match: dockBounds) }
            ) {
                cachedDockDisplayID = displayID
                return displayID
            }
        }

        cachedDockDisplayID = nil
        return nil
    }

    private func displayBounds(_ lhs: CGRect, match rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 1.0
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private func displaysRepresentSameTarget(
        _ lhs: CGDirectDisplayID,
        _ rhs: CGDirectDisplayID
    ) -> Bool {
        lhs == rhs
            || displayBounds(
                CGDisplayBounds(lhs),
                match: CGDisplayBounds(rhs)
            )
    }

    private func showNeedsDisplaySafetySuppression(
        targetDisplayID: CGDirectDisplayID
    ) -> Bool {
        guard let dockDisplayID = dockAssignedDisplayID() else {
            // With more than one display, an unknown Dock owner is not enough
            // evidence to issue a global SHOW. A later event can retry once
            // Dock.app exposes its ownership window again.
            var displayCount: UInt32 = 0
            guard CGGetActiveDisplayList(
                0,
                nil,
                &displayCount
            ) == .success else { return true }
            return displayCount > 1
        }

        // Mirrored displays can have distinct IDs but identical global bounds.
        // Treat them as one destination for Dock routing purposes.
        if displaysRepresentSameTarget(dockDisplayID, targetDisplayID) {
            return false
        }

        // A global SHOW would appear on Dock.app's current owner, not on the
        // display DockAway just evaluated. Route every non-mirrored mismatch
        // through the verified handoff, regardless of what is on the old
        // display.
        return true
    }

    // A real Dock-edge gesture tells Dock.app which display should own the
    // Dock. App activation and an empty-desktop hover alone do not. Reproduce
    // only that routing hint in one synchronous pulse and immediately restore
    // the pointer to its live position. Unlike the former nudge experiment, no
    // cursor position is held at the edge and SHOW remains forbidden until
    // ownership is verified.
    @discardableResult
    private func beginDockDisplayHandoff(
        to targetDisplayID: CGDirectDisplayID,
        expectedState: DisplayWindowState,
        frontmostBundleIdentifier: String,
        trigger: DockDisplayHandoffTrigger = .activation
    ) -> Bool {
        cancelDockDisplayHandoff()

        guard
            let pointerSnapshot = pointerDisplaySnapshot(),
            pointerSnapshot.displayID == targetDisplayID
        else { return false }

        if trigger == .hover {
            guard
                NSEvent.pressedMouseButtons == 0,
                dockDisplayHoverCooldownUntil[targetDisplayID, default: .distantPast]
                    <= Date()
            else { return false }
        }

        dockDisplayHandoffPointerAnchor = pointerSnapshot.location
        dockDisplayHandoffExpectedState = expectedState
        dockDisplayHandoffExpectedBundleIdentifier = frontmostBundleIdentifier
        dockDisplayHandoffTrigger = trigger

        guard dockDisplayHandoffIsStillValid(for: targetDisplayID) else {
            finishDockDisplayHandoff()
            return false
        }

        let generation = dockDisplayHandoffGeneration
        dockDisplayHandoffTargetID = targetDisplayID

        scheduleInitialDockDisplayHandoffPulse(
            targetDisplayID: targetDisplayID,
            generation: generation,
            readinessAttempt: 0,
            after: trigger == .hover ? dockDisplayHoverSettleInterval : 0
        )
        return true
    }

    private func scheduleInitialDockDisplayHandoffPulse(
        targetDisplayID: CGDirectDisplayID,
        generation: Int,
        readinessAttempt: Int,
        after delay: TimeInterval
    ) {
        pendingDockDisplayHandoffWork?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard
                let self,
                self.isRunning,
                generation == self.dockDisplayHandoffGeneration,
                self.dockDisplayHandoffTargetID == targetDisplayID
            else { return }

            guard self.dockDisplayHandoffIsStillValid(
                for: targetDisplayID
            ) else {
                self.cancelDockDisplayHandoff()
                return
            }

            if self.dockDisplayHandoffTrigger == .hover {
                // A hover means the pointer has actually settled on the empty
                // display, not merely crossed its seam at speed. Re-anchor while
                // it is moving and emit at most one pulse after a quiet sample.
                guard
                    NSEvent.pressedMouseButtons == 0,
                    let pointerSnapshot = self.pointerDisplaySnapshot(),
                    pointerSnapshot.displayID == targetDisplayID,
                    let pointerAnchor = self.dockDisplayHandoffPointerAnchor
                else {
                    self.cancelDockDisplayHandoff()
                    return
                }

                let movement = hypot(
                    pointerSnapshot.location.x - pointerAnchor.x,
                    pointerSnapshot.location.y - pointerAnchor.y
                )
                if movement > 10 {
                    guard readinessAttempt < 20 else {
                        self.cancelDockDisplayHandoff()
                        return
                    }
                    self.dockDisplayHandoffPointerAnchor =
                        pointerSnapshot.location
                    self.scheduleInitialDockDisplayHandoffPulse(
                        targetDisplayID: targetDisplayID,
                        generation: generation,
                        readinessAttempt: readinessAttempt + 1,
                        after: self.dockDisplayHoverSettleInterval
                    )
                    return
                }
            } else if NSEvent.pressedMouseButtons != 0 {
                // App activation can arrive on mouse-down. Never synthesize the
                // edge pulse until that click is released; temporary movement
                // while a button is held could otherwise become a drag.
                guard readinessAttempt < 20 else {
                    self.cancelDockDisplayHandoff()
                    return
                }
                self.scheduleInitialDockDisplayHandoffPulse(
                    targetDisplayID: targetDisplayID,
                    generation: generation,
                    readinessAttempt: readinessAttempt + 1,
                    after: 0.01
                )
                return
            }

            guard self.postDockEdgePulse(to: targetDisplayID) else {
                self.cancelDockDisplayHandoff()
                return
            }

            if self.dockDisplayHandoffTrigger == .hover {
                self.dockDisplayHoverCooldownUntil[targetDisplayID] =
                    Date().addingTimeInterval(self.dockDisplayHoverCooldown)
            }

            dockAwayDebugLog(
                "  🖥️ Target display → requesting Dock display handoff"
            )
            self.scheduleDockDisplayHandoffCheck(
                targetDisplayID: targetDisplayID,
                generation: generation,
                attempt: 1,
                mouseUpWaitAttempt: 0,
                after: 0.06
            )
        }
        pendingDockDisplayHandoffWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, delay),
            execute: work
        )
    }

    private func scheduleDockDisplayHandoffCheck(
        targetDisplayID: CGDirectDisplayID,
        generation: Int,
        attempt: Int,
        mouseUpWaitAttempt: Int,
        after delay: TimeInterval
    ) {
        pendingDockDisplayHandoffWork?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard
                let self,
                self.isRunning,
                generation == self.dockDisplayHandoffGeneration,
                self.dockDisplayHandoffTargetID == targetDisplayID
            else { return }

            guard self.dockDisplayHandoffIsStillValid(
                for: targetDisplayID
            ) else {
                self.cancelDockDisplayHandoff()
                return
            }

            if self.dockDisplayHandoffTrigger == .hover,
               NSEvent.pressedMouseButtons != 0 {
                guard mouseUpWaitAttempt < 20 else {
                    self.cancelDockDisplayHandoff()
                    return
                }
                self.scheduleDockDisplayHandoffCheck(
                    targetDisplayID: targetDisplayID,
                    generation: generation,
                    attempt: attempt,
                    mouseUpWaitAttempt: mouseUpWaitAttempt + 1,
                    after: 0.01
                )
                return
            }

            self.cachedDockDisplayID = nil
            self.dockDisplayCacheValidUntil = .distantPast

            if let dockDisplayID = self.dockAssignedDisplayID(),
               self.displaysRepresentSameTarget(
                   dockDisplayID,
                   targetDisplayID
               ) {
                if self.pointerOnlyEmptyDisplayID == targetDisplayID {
                    self.pointerOnlyEmptyDisplayID = nil
                }
                self.finishDockDisplayHandoff()
                dockAwayDebugLog(
                    "  ✅ Dock display handoff confirmed → showing on focused display"
                )
                self.setDockVisible(true)
                return
            }

            // Dock's ownership window can lag the pulse. Hover checks remain
            // read-only after their one settled pulse so synthetic movement can
            // never race a pointer that has started moving again. Activation
            // handoffs retain two bounded retries for the existing click path.
            if attempt < 3 {
                if self.dockDisplayHandoffTrigger == .activation,
                   !self.postDockEdgePulse(to: targetDisplayID) {
                    self.finishDockDisplayHandoff()
                    return
                }
                self.scheduleDockDisplayHandoffCheck(
                    targetDisplayID: targetDisplayID,
                    generation: generation,
                    attempt: attempt + 1,
                    mouseUpWaitAttempt: 0,
                    after: attempt == 1 ? 0.08 : 0.10
                )
                return
            }

            self.finishDockDisplayHandoff()
            dockAwayDebugLog(
                "  ⚠️ Dock display handoff was not confirmed → leaving Dock hidden"
            )
        }
        pendingDockDisplayHandoffWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, delay),
            execute: work
        )
    }

    private func dockDisplayHandoffIsStillValid(
        for targetDisplayID: CGDirectDisplayID
    ) -> Bool {
        let pointerStayedNearAnchor: Bool
        if dockDisplayHandoffTrigger == .activation {
            guard
                let pointerAnchor = dockDisplayHandoffPointerAnchor,
                let pointerLocation = CGEvent(source: nil)?.location
            else { return false }

            pointerStayedNearAnchor = hypot(
                pointerLocation.x - pointerAnchor.x,
                pointerLocation.y - pointerAnchor.y
            ) <= 8
        } else {
            // Hover handoffs use a dedicated pre-pulse settle check. After that
            // single pulse, validity only requires the live pointer to remain
            // on the intended empty display while Dock.app confirms ownership.
            pointerStayedNearAnchor = true
        }

        guard
            isRunning,
            !isDesktopTransitionProtected,
            !isHoldingHidden,
            !isHoldingVisible,
            let expectedState = dockDisplayHandoffExpectedState,
            let expectedBundleIdentifier =
                dockDisplayHandoffExpectedBundleIdentifier,
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == expectedBundleIdentifier,
            let pointerSnapshot = pointerDisplaySnapshot(),
            pointerSnapshot.displayID == targetDisplayID,
            pointerStayedNearAnchor
        else { return false }

        return displayWindowState(
            on: CGDisplayBounds(targetDisplayID)
        ) == expectedState
    }

    private func postDockEdgePulse(
        to targetDisplayID: CGDirectDisplayID
    ) -> Bool {
        guard
            NSEvent.pressedMouseButtons == 0,
            let source = CGEventSource(stateID: .hidSystemState),
            let pointerSnapshot = pointerDisplaySnapshot(),
            pointerSnapshot.displayID == targetDisplayID
        else { return false }

        let pointerLocation = pointerSnapshot.location

        // Do not let synthetic motion suppress real hardware input. The pulse
        // is posted back-to-back and restored immediately to minimize any
        // presentation of its temporary edge location.
        source.localEventsSuppressionInterval = 0

        let bounds = CGDisplayBounds(targetDisplayID)
        let orientation = UserDefaults(suiteName: "com.apple.dock")?
            .string(forKey: "orientation") ?? "bottom"
        let horizontalPosition = min(
            max(pointerLocation.x, bounds.minX + 24),
            bounds.maxX - 24
        )
        let verticalPosition = min(
            max(pointerLocation.y, bounds.minY + 24),
            bounds.maxY - 24
        )

        let edgePoints: [CGPoint]
        let deltaX: Int64
        let deltaY: Int64

        switch orientation {
        case "left":
            edgePoints = [4, 2, 1].map {
                CGPoint(x: bounds.minX + CGFloat($0), y: verticalPosition)
            }
            deltaX = -64
            deltaY = 0
        case "right":
            edgePoints = [4, 2, 1].map {
                CGPoint(x: bounds.maxX - CGFloat($0), y: verticalPosition)
            }
            deltaX = 64
            deltaY = 0
        default:
            edgePoints = [4, 2, 1].map {
                CGPoint(x: horizontalPosition, y: bounds.maxY - CGFloat($0))
            }
            deltaX = 0
            deltaY = 64
        }

        var events = [CGEvent]()
        events.reserveCapacity(edgePoints.count)
        for point in edgePoints {
            guard let event = CGEvent(
                mouseEventSource: source,
                mouseType: .mouseMoved,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else { return false }

            event.setIntegerValueField(.mouseEventDeltaX, value: deltaX)
            event.setIntegerValueField(.mouseEventDeltaY, value: deltaY)
            events.append(event)
        }

        for event in events {
            event.post(tap: .cghidEventTap)
        }

        let restoreResult = CGWarpMouseCursorPosition(pointerLocation)
        if restoreResult != .success {
            dockAwayDebugLog("  ⚠️ Could not restore pointer after Dock display pulse")
            return false
        }
        return true
    }

    private func finishDockDisplayHandoff() {
        pendingDockDisplayHandoffWork?.cancel()
        pendingDockDisplayHandoffWork = nil
        dockDisplayHandoffTargetID = nil
        dockDisplayHandoffPointerAnchor = nil
        dockDisplayHandoffExpectedState = nil
        dockDisplayHandoffExpectedBundleIdentifier = nil
        dockDisplayHandoffTrigger = .activation
    }

    private func cancelDockDisplayHandoff() {
        dockDisplayHandoffGeneration += 1
        finishDockDisplayHandoff()
    }

    // MARK: - Public Helpers

    // Dock.app also owns Mission Control and the Spaces animation. Restarting
    // it during any protected transition can leave the destination Space in a
    // partial state, so Dock settings remain disabled until all holds, handoffs,
    // and settling work are idle.
    var canRestartDockSafely: Bool {
        guard let missionControlIsVisible = missionControlWindowServerStateSnapshot(),
              !missionControlIsVisible else { return false }
        guard isRunning else { return true }
        return !isDesktopTransitionProtected
            && !isHoldingHidden
            && !isHoldingVisible
            && dockDisplayHandoffTargetID == nil
    }

    // launchd can assign the replacement Dock process to a different display.
    // Treat the current pointer display as a fresh destination so the existing
    // verified handoff path repairs ownership before any global SHOW command.
    func repairStateAfterDockRestart() {
        guard isRunning else { return }

        cancelDockDisplayHandoff()
        pointerOnlyEmptyDisplayID = nil
        cachedDockDisplayID = nil
        dockDisplayCacheValidUntil = .distantPast
        dockDisplayHoverCooldownUntil.removeAll(keepingCapacity: true)
        lastCommandedDockVisibility = nil
        lastToggleTime = .distantPast
        lastPointerDisplayID = displayIDUnderPointer()

        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let finderIsFrontmost = app.bundleIdentifier == "com.apple.finder"
        evaluate(
            app: app,
            quiet: false,
            pointerDisplayChanged: true,
            applicationActivated: true,
            finderActivated: finderIsFrontmost
        )
        scheduleAccessibilityEvaluation(includeSettleRecheck: true)
    }

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
    func missionControlActiveAtGestureStart() -> Bool? {
        guard isRunning, !missionControlNeedsBootstrap else { return nil }
        return missionControlIsActive
    }

    // Keeps the Dock visible through a horizontal swipe only when the cached
    // source Space is already one where DockAway wants it shown. The cached
    // verdict avoids a synchronous window scan on the first motion frame.
    @discardableResult
    func beginVisibleHoldForHorizontalSwipeIfNeeded(
        movingToNextSpace: Bool,
        maximum: TimeInterval = 5.0
    ) -> Bool {
        guard !missionControlNeedsBootstrap else { return false }
        let sourceDisplayID = displayIDUnderPointer()

        // If visible hold is already latched for this swipe, keep holding unless
        // the gesture reversed direction into a known occupied destination.
        if isHoldingVisible,
           visibleHoldReason == .desktopSwipe,
           visibleHoldDisplayID == sourceDisplayID {
            if let prediction = horizontalSpacePrediction,
               Date().timeIntervalSince(prediction.capturedAt) <= horizontalSpacePredictionLifetime {
                let predictedDestinationState = movingToNextSpace
                    ? prediction.nextState
                    : prediction.previousState
                if predictedDestinationState == .occupied {
                    dockAwayDebugLog("  🔭 Reversed into occupied Space → canceling visible hold")
                    clearVisibleHold()
                    return false
                }
            }
            return true
        }

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

            if predictedDestinationState == .occupied {
                dockAwayDebugLog("  🔭 Occupied adjacent Space predicted → pre-hiding before animation")
                return false
            }
        }

        // A blacklisted source may have other windows behind it, so only a
        // genuinely empty source makes the first occupied window unambiguous.
        // Likewise, a confidently blacklisted or empty destination owns SHOW
        // through landing; mixed animation frames must not second-guess that verdict.
        return armVisibleHold(
            on: sourceDisplayID,
            reason: .desktopSwipe,
            canPrehideOccupiedDestination: sourceState == .empty
                && predictedDestinationState == nil,
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
        guard !missionControlNeedsBootstrap else { return false }
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
        if visibleHoldLatched,
           visibleHoldReason == reason,
           visibleHoldDisplayID == displayID,
           visibleHoldCanPrehideOccupiedDestination == canPrehideOccupiedDestination {
            return true
        }

        cancelDockDisplayHandoff()
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
        guard isRunning, !missionControlNeedsBootstrap else { return false }

        cancelDockDisplayHandoff()

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

        guard let windowState = displayWindowState(on: CGDisplayBounds(displayID)) else { return }
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
        guard let shortcut = DockShortcut.current() else {
            (NSApp.delegate as? AppDelegate)?.updateDockShortcutWarning(
                "Enable the Dock hiding shortcut"
            )
            return false
        }
        (NSApp.delegate as? AppDelegate)?.updateDockShortcutWarning(nil)
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            dockAwayDebugLog("  ⚠️ Could not create CGEventSource")
            return false
        }

        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: false)
        else { return false }

        keyDown.flags = shortcut.modifiers
        keyUp.flags = shortcut.modifiers

        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)

        dockAwayDebugLog("  ⌨️ Sent configured Dock shortcut")
        return true
    }

    private func setDockVisible(_ shouldShow: Bool) {
        guard
            isRunning,
            !isWindowMovementSettling,
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

        // Same-app Dock clicks do not always emit an activation notification.
        // The final HIDE boundary is a second opportunity to capture the gap.
        if !shouldShow, actuallyShown, let app = NSWorkspace.shared.frontmostApplication {
            prepareLaunchWindowCorrection(for: app)
        }
        sendDockToggle(towardVisible: shouldShow, reason: "Forcing Dock")
    }

    private func dockIsActuallyShown() -> Bool {
        let isShown = !(UserDefaults(suiteName: "com.apple.dock")?
            .bool(forKey: "autohide") ?? false)
        if isShown {
            for screen in NSScreen.screens {
                guard let displayID = screen.displayID,
                      screen.visibleFrame.minY - screen.frame.minY > 10,
                      abs(screen.visibleFrame.minX - screen.frame.minX) < 3,
                      abs(screen.visibleFrame.width - screen.frame.width) < 3 else { continue }
                shownDockWorkAreas[displayID] = ShownDockWorkArea(
                    screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                    capturedAt: ProcessInfo.processInfo.systemUptime
                )
            }
        }
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
        if simulateOptionCommandD() {
            lastToggleTime = Date()
            lastCommandedDockVisibility = visible
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

    func refreshStatus() {
        guard isRunning else { return }
        evaluateFrontmostApp(quiet: true)
    }

    func desktopSelection(on displayID: CGDirectDisplayID) -> DesktopSelectionSnapshot? {
        // Do not navigate using cached topology or a disconnected display.
        guard NSScreen.screen(withDisplayID: displayID) != nil else { return nil }
        return spaceAPI.currentDesktopInfo(on: displayID)?.selection
    }

    private func desktopStatusLabel(on displayID: CGDirectDisplayID) -> String? {
        guard let info = spaceAPI.currentDesktopInfo(on: displayID) else {
            return nil
        }
        if info.isFullScreenApp {
            return "Desktop: Fullscreen"
        }
        return "Desktop: \(info.currentDesktopIndex) of \(info.totalDesktops)"
    }

    private func postStatus(_ text: String, displayID: CGDirectDisplayID) {
        let desktopText = desktopStatusLabel(on: displayID)
        (NSApp.delegate as? AppDelegate)?.updateStatus(text, desktopText: desktopText)
    }

    private func postDockVisibility(_ isVisible: Bool) {
        (NSApp.delegate as? AppDelegate)?.updateDockVisibilityGlyph(isVisible)
    }
}
