import AppKit
import IOKit.pwr_mgt

/// Decides from plain values whether a fullscreen video is playing, so tests
/// don't need real windows or power assertions.
struct FullscreenVideoDecision {
    struct Assertion: Equatable {
        let ownerPID: pid_t
        let onBehalfOfPID: pid_t?
        let type: String
    }

    /// Video players keep the display awake while playing, and stop on pause.
    static let displaySleepAssertionTypes: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]

    /// Only the frontmost app counts, while it fills a display and keeps the
    /// display awake. Browsers and WebKit apps may hold the assertion in a
    /// helper process, which `responsiblePID` maps back to the app.
    static func isPlayingFullscreenVideo(
        frontmostPID: pid_t?,
        fullscreenPIDs: Set<pid_t>,
        assertions: [Assertion],
        responsiblePID: (pid_t) -> pid_t?
    ) -> Bool {
        guard let frontmostPID, fullscreenPIDs.contains(frontmostPID) else { return false }
        return assertions.contains { assertion in
            displaySleepAssertionTypes.contains(assertion.type)
                && (assertion.ownerPID == frontmostPID
                    || assertion.onBehalfOfPID == frontmostPID
                    || responsiblePID(assertion.ownerPID) == frontmostPID)
        }
    }

    /// The timeout to put back once the video ends. A value the user chose in
    /// System Settings meanwhile stays as it is.
    static func timeoutToRestore(saved: TimeInterval, current: TimeInterval?, videoTimeout: TimeInterval) -> TimeInterval? {
        current == videoTimeout ? saved : nil
    }

    /// The timeout to put back when the option is turned off: the one from
    /// before it set Never, unless the timer no longer reads Never.
    static func timeoutAfterTurningOff(before: TimeInterval?, current: TimeInterval?) -> TimeInterval? {
        current == 0 ? before : nil
    }
}

/// Turns the keyboard backlight off while a video plays fullscreen by briefly
/// shortening macOS's own inactivity timer, so macOS dims the light itself and
/// brightness, the slider, and auto-brightness are never touched.
@MainActor
final class FullscreenVideoKeyboardLightController {
    static let preferenceKey = "keyboardLightOffForFullscreenVideo"
    /// macOS turns the light off this long after the last input during a video.
    static let videoTimeout: TimeInterval = 1

    /// The choices System Settings offers for "Turn keyboard backlight off
    /// after inactivity". Never is stored as 0.
    static let inactivityChoices: [(seconds: TimeInterval, title: String)] = [
        (0, "Never"), (5, "After 5 Seconds"), (10, "After 10 Seconds"), (30, "After 30 Seconds"),
        (60, "After 1 Minute"), (300, "After 5 Minutes")
    ]

    /// A short label for the current value, including values set outside
    /// System Settings' choices.
    static func inactivityLabel(for seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "Never" }
        let whole = Int(seconds.rounded())
        if whole % 60 == 0 { return whole == 60 ? "1 Minute" : "\(whole / 60) Minutes" }
        return whole == 1 ? "1 Second" : "\(whole) Seconds"
    }

    /// The user's timeout, stored while DockAway has it shortened, so an
    /// interrupted run puts it back on the next launch.
    private static let savedTimeoutKey = "keyboardLightTimeoutBeforeFullscreenVideo"
    /// The user's timeout from before turning the option on set Never.
    private static let timeoutBeforeOptionKey = "keyboardLightTimeoutBeforeOption"
    /// Left by development builds that paused macOS's timer instead.
    private static let legacyIdleSuspensionKey = "keyboardLightIdleDimmingPausedByDockAway"

    private let backlight: KeyboardBacklight
    private let fullscreenSpacePIDs: () -> Set<pid_t>
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var isRunning = false
    private var pendingWindowCheck = false

    init(backlight: KeyboardBacklight? = nil, fullscreenSpacePIDs: @escaping () -> Set<pid_t>) {
        self.backlight = backlight ?? .shared
        self.fullscreenSpacePIDs = fullscreenSpacePIDs
    }

    var isAvailable: Bool { backlight.isAvailable }

    /// The user's "Turn keyboard backlight off after inactivity" value, in
    /// seconds (0 is Never), even while a video has it shortened.
    var inactivityTimeout: TimeInterval? {
        savedTimeout ?? backlight.inactivityTimeout
    }

    /// A choice from the menu. It replaces the value turning the option off
    /// would otherwise put back.
    func setInactivityTimeout(_ seconds: TimeInterval) {
        UserDefaults.standard.removeObject(forKey: Self.timeoutBeforeOptionKey)
        applyInactivityTimeout(seconds)
    }

    private func applyInactivityTimeout(_ seconds: TimeInterval) {
        if savedTimeout != nil {
            // Applied when the video ends.
            savedTimeout = seconds
        } else {
            backlight.setInactivityTimeout(seconds)
        }
    }

    private var savedTimeout: TimeInterval? {
        get { (UserDefaults.standard.object(forKey: Self.savedTimeoutKey) as? NSNumber)?.doubleValue }
        set { UserDefaults.standard.set(newValue, forKey: Self.savedTimeoutKey) }
    }

    /// Puts back a timer left behind by an interrupted run.
    func recoverPreviousSession() {
        if UserDefaults.standard.bool(forKey: Self.legacyIdleSuspensionKey) {
            backlight.resumeIdleDimming()
            UserDefaults.standard.removeObject(forKey: Self.legacyIdleSuspensionKey)
        }
        restoreTimeout()
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
        enabled ? start() : stop()
    }

    /// Turning the option on from the menu also sets the timer to Never, so the
    /// light stays on except during fullscreen video. Turning it off puts the
    /// previous value back.
    func setEnabledFromMenu(_ enabled: Bool) {
        let defaults = UserDefaults.standard
        if enabled {
            if let current = inactivityTimeout, current != 0 {
                defaults.set(current, forKey: Self.timeoutBeforeOptionKey)
                applyInactivityTimeout(0)
            }
            setEnabled(true)
        } else {
            setEnabled(false)
            let before = (defaults.object(forKey: Self.timeoutBeforeOptionKey) as? NSNumber)?.doubleValue
            if let restore = FullscreenVideoDecision.timeoutAfterTurningOff(before: before, current: inactivityTimeout) {
                backlight.setInactivityTimeout(restore)
            }
            defaults.removeObject(forKey: Self.timeoutBeforeOptionKey)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        timer?.invalidate()
        timer = nil
        restoreTimeout()
    }

    private func start() {
        guard !isRunning, backlight.isAvailable else { return }
        isRunning = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluateSoon() }
            })
        }
        evaluate()
    }

    /// The frontmost app's window was resized or a new one opened. A player
    /// going fullscreen without a Space of its own does that and nothing
    /// else, so it's checked once the resizing settles. Once fullscreen, the
    /// regular check takes over.
    func frontmostWindowChanged() {
        guard isRunning, timer == nil, !pendingWindowCheck else { return }
        pendingWindowCheck = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.pendingWindowCheck = false
            self.evaluate()
        }
    }

    /// Checks now and again once a Space transition has settled, since its
    /// notification can arrive before the new Space reports as fullscreen.
    private func evaluateSoon() {
        evaluate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.evaluate() }
    }

    private func evaluate() {
        guard isRunning else { return }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var fullscreenPIDs = fullscreenSpacePIDs()
        if let frontmostPID, !fullscreenPIDs.contains(frontmostPID),
           Self.coversDisplay(processIdentifier: frontmostPID) {
            fullscreenPIDs.insert(frontmostPID)
        }
        let isFullscreen = frontmostPID.map(fullscreenPIDs.contains) ?? false
        // Only a fullscreen app can start or stop a video that matters here,
        // so nothing polls the rest of the time.
        setPolling(isFullscreen)

        let isPlaying = isFullscreen && FullscreenVideoDecision.isPlayingFullscreenVideo(
            frontmostPID: frontmostPID,
            fullscreenPIDs: fullscreenPIDs,
            assertions: Self.assertions(),
            responsiblePID: Self.responsiblePID(for:)
        )
        isPlaying ? shortenTimeout() : restoreTimeout()
    }

    private func shortenTimeout() {
        guard savedTimeout == nil, let current = backlight.inactivityTimeout else { return }
        savedTimeout = current
        backlight.setInactivityTimeout(Self.videoTimeout)
    }

    private func restoreTimeout() {
        guard let savedTimeout else { return }
        if let restore = FullscreenVideoDecision.timeoutToRestore(
            saved: savedTimeout, current: backlight.inactivityTimeout, videoTimeout: Self.videoTimeout
        ) {
            backlight.setInactivityTimeout(restore)
        }
        self.savedTimeout = nil
    }

    private func setPolling(_ enabled: Bool) {
        guard enabled != (timer != nil) else { return }
        guard enabled else {
            timer?.invalidate()
            timer = nil
            return
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Players that skip macOS's fullscreen Spaces instead cover a whole display.
    private static func coversDisplay(processIdentifier: pid_t) -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return false }
        let displayBounds = displays.prefix(Int(count)).map(CGDisplayBounds)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return false }
            return displayBounds.contains { frame.insetBy(dx: -1, dy: -1).contains($0) }
        }
    }

    private static func assertions() -> [FullscreenVideoDecision.Assertion] {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byProcess = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        return byProcess.flatMap { owner, assertions in
            assertions.compactMap { assertion -> FullscreenVideoDecision.Assertion? in
                guard (assertion["AssertLevel"] as? NSNumber)?.intValue != 0,
                      let type = (assertion["AssertionTrueType"] ?? assertion["AssertType"]) as? String
                else { return nil }
                return FullscreenVideoDecision.Assertion(
                    ownerPID: owner.int32Value,
                    onBehalfOfPID: (assertion["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value,
                    type: type
                )
            }
        }
    }

    private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t
    private static let responsiblePIDFunction: ResponsiblePIDFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
    }()

    private static func responsiblePID(for processIdentifier: pid_t) -> pid_t? {
        guard let responsiblePIDFunction else { return nil }
        let responsible = responsiblePIDFunction(processIdentifier)
        return responsible > 0 ? responsible : nil
    }
}
