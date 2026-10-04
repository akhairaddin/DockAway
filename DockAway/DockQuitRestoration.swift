import AppKit
import OSLog

/// Restores the current login's Dock before AppKit completes termination.
/// The shortcut is tried only once. Failed restoration uses an idempotent
/// preference write and a verified, current-user-only native Dock restart.
/// Normal quits can require that restart even when the Dock is already shown.
@MainActor
final class DockQuitRestoration {
    struct State {
        var shown: Bool
        var dockReady: Bool
    }

    struct Environment {
        var read: () -> State
        var sendShortcut: () -> Bool
        var persistShown: () -> Bool
        var restart: (@escaping (String?) -> Void) -> Bool
        var now: () -> TimeInterval
        var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
        var restartInProgress: () -> Bool = { false }

        @MainActor static func live(sendShortcut: @escaping () -> Bool,
                         restarter: DockRestartController,
                         allowsFullscreenHiding: @escaping () -> Bool = { false }) -> Self {
            let domain = "com.apple.dock" as CFString
            let processes = DockRestartController.Environment.live()
            return Self(read: {
                CFPreferencesAppSynchronize(domain)
                let hidden = (CFPreferencesCopyAppValue("autohide" as CFString, domain) as? NSNumber)?.boolValue ?? false
                let dock = processes.currentDock()
                let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
                let hasPresentedDock = windows.contains {
                    ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == dock?.pid
                        && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 20
                }
                // Fullscreen normally conceals the Dock even when auto-hide is
                // off. On regular desktops require an actual presented window,
                // not merely a preference value from a frozen Dock process.
                return State(shown: !hidden,
                             dockReady: dock?.isReady == true && (hasPresentedDock || allowsFullscreenHiding()))
            }, sendShortcut: sendShortcut, persistShown: {
                guard !CFPreferencesAppValueIsForced("autohide" as CFString, domain) else { return false }
                CFPreferencesSetValue("autohide" as CFString, kCFBooleanFalse, domain,
                                      kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { return false }
                CFPreferencesAppSynchronize(domain)
                return (CFPreferencesCopyAppValue("autohide" as CFString, domain) as? NSNumber)?.boolValue == false
            }, restart: { restarter.restart(completion: $0) },
                now: { ProcessInfo.processInfo.systemUptime }, schedule: { delay, work in
                    DockLifecycleRunLoop.schedule(after: delay, work)
                }, restartInProgress: { restarter.isRestarting })
        }
    }

    private let environment: Environment
    private(set) var isRestoring = false
    private var generation = 0
    private let logger = Logger(subsystem: "AK.DockAway", category: "DockQuit")

    init(environment: Environment) { self.environment = environment }

    @discardableResult
    func restore(reloadPreferences: Bool = false, forceRestart: Bool = false,
                 completion: @escaping (String?) -> Void) -> Bool {
        guard !isRestoring else { return false }
        isRestoring = true
        generation += 1
        let operation = generation
        let began = environment.now()
        var fallbackStarted = false
        var stableReads = 0

        func finish(_ error: String?) {
            guard self.isRestoring, self.generation == operation else { return }
            self.isRestoring = false
            completion(error)
        }

        func verifyAfterRestart(until deadline: TimeInterval) {
            guard self.isRestoring, self.generation == operation else { return }
            let state = self.environment.read()
            stableReads = state.shown && state.dockReady ? stableReads + 1 : 0
            if stableReads >= 3 { finish(nil); return }
            guard self.environment.now() < deadline else {
                finish("macOS did not confirm restored Dock visibility after restarting.")
                return
            }
            self.environment.schedule(0.05) { verifyAfterRestart(until: deadline) }
        }

        func restartWhenIdle() {
            guard self.isRestoring, self.generation == operation else { return }
            // Quit can arrive while the startup/manual restarter is waiting for
            // launchd. Finish that operation before replacing its new Dock.
            guard !self.environment.restartInProgress() else {
                self.environment.schedule(0.05, restartWhenIdle)
                return
            }
            guard self.environment.persistShown() else {
                finish("DockAway could not save the shown Dock state. The setting may be managed by macOS.")
                return
            }
            self.logger.notice("Reloading the current login's Dock before quitting")
            let accepted = self.environment.restart { error in
                guard self.isRestoring, self.generation == operation else { return }
                if let error { finish(error); return }
                verifyAfterRestart(until: self.environment.now() + 1)
            }
            if !accepted { finish("DockAway could not start a safe Dock restart before quitting.") }
        }

        func fallback() {
            guard !fallbackStarted else { return }
            fallbackStarted = true
            stableReads = 0
            // Existing restarts are bounded at ten seconds. Allow time for one
            // such operation, our restart, and verification, without hanging
            // termination if a dependency never calls back.
            self.environment.schedule(self.environment.restartInProgress() ? 22 : 12) {
                finish("The Dock took too long to restore before quitting.")
            }
            restartWhenIdle()
        }

        func verifyShortcut() {
            guard self.isRestoring, self.generation == operation else { return }
            let state = self.environment.read()
            stableReads = state.shown && state.dockReady ? stableReads + 1 : 0
            // A short stable interval also lets an already-posted HIDE settle.
            if stableReads >= 3, self.environment.now() - began >= 0.2 {
                finish(nil)
                return
            }
            guard self.environment.now() - began < 0.8 else { fallback(); return }
            self.environment.schedule(0.05, verifyShortcut)
        }

        if reloadPreferences || forceRestart {
            fallback()
        } else {
            let state = environment.read()
            if !state.shown && !environment.sendShortcut() { fallback() }
            else { verifyShortcut() }
        }
        return true
    }
}
