import AppKit
import Darwin

/// AppKit waits for delayed termination in its modal run-loop mode, where a
/// block queued on the main dispatch queue need not run. Native Dock lifecycle
/// work must continue in that mode as well as during ordinary application use.
enum DockLifecycleRunLoop {
    nonisolated static func perform(_ work: @escaping @MainActor () -> Void) {
        RunLoop.main.perform(inModes: [.common, .modalPanel]) {
            MainActor.assumeIsolated { work() }
        }
    }

    nonisolated static func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        perform {
            let timer = Timer(timeInterval: max(0.001, delay), repeats: false) { _ in
                MainActor.assumeIsolated { work() }
            }
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .modalPanel)
        }
    }
}

@MainActor
private final class DockLaunchCompletion {
    private(set) var completed = false
    private let completion: (Bool) -> Void
    init(_ completion: @escaping (Bool) -> Void) { self.completion = completion }
    func finish(_ succeeded: Bool) {
        guard !completed else { return }
        completed = true
        completion(succeeded)
    }
}

/// One native Dock restart per DockAway launch. Permission setup, session
/// suspension, and protected desktop transitions can defer the attempt. A
/// settings/manual restart satisfies it too; a failure never creates a loop.
@MainActor
final class DockStartupRestartCoordinator {
    struct Environment {
        var isReady: () -> Bool
        var canRestart: () -> Bool
        var restart: () -> Void
        var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    }

    private let environment: Environment
    private(set) var isPending = true
    private var retryScheduled = false

    init(environment: Environment) {
        self.environment = environment
    }

    func requestIfReady() {
        guard isPending, environment.isReady() else { return }
        if environment.canRestart() {
            // Claim before the callback: startup and permission callbacks can
            // reenter the launch flow while the replacement Dock is pending.
            noteRestartAttempt()
            environment.restart()
        } else if !retryScheduled {
            retryScheduled = true
            environment.schedule(0.5) { [weak self] in
                guard let self else { return }
                self.retryScheduled = false
                self.requestIfReady()
            }
        }
    }

    func noteRestartAttempt() {
        isPending = false
    }
}

/// Restarts only the current user's native Dock. Dependencies are injectable
/// so timeout and launchd recovery can be tested without touching real desktops.
@MainActor
final class DockRestartController {
    struct DockProcess {
        let pid: pid_t
        let owner: uid_t
        let isReady: Bool
    }

    struct Environment {
        var currentDock: () -> DockProcess?
        var terminate: (pid_t) -> Bool
        var launchAgent: (@escaping (Bool) -> Void) -> Void
        var now: () -> TimeInterval
        var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void

        @MainActor static func live() -> Self {
            Self(currentDock: {
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock") {
                    guard !app.isTerminated,
                          app.bundleURL?.standardizedFileURL.path == "/System/Library/CoreServices/Dock.app" else { continue }
                    var info = proc_bsdinfo()
                    guard proc_pidinfo(app.processIdentifier, PROC_PIDTBSDINFO, 0, &info,
                                       Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                          info.pbi_uid == geteuid() else { continue }
                    let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
                    let hasWindow = windows?.contains {
                        ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier
                    } == true
                    return DockProcess(pid: app.processIdentifier, owner: info.pbi_uid,
                                       isReady: app.isFinishedLaunching && hasWindow)
                }
                return nil
            }, terminate: { pid in
                // Recheck ownership immediately before signaling a live PID.
                var info = proc_bsdinfo()
                guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                                   Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                      info.pbi_uid == geteuid() else { return false }
                // PROC_PIDPATHINFO_MAXSIZE is a C expression macro unavailable
                // to Swift; its public definition is four times MAXPATHLEN.
                var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                      String(cString: path) == "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock" else { return false }
                return kill(pid, SIGTERM) == 0
            }, launchAgent: { completion in
                // SIGTERM can produce a successful exit that launchd does not
                // automatically replace. Kickstart only our existing GUI agent.
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = ["kickstart", "gui/\(geteuid())/com.apple.Dock.agent"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                let result = DockLaunchCompletion(completion)
                process.terminationHandler = { child in
                    let succeeded = child.terminationStatus == 0
                    DockLifecycleRunLoop.perform { result.finish(succeeded) }
                }
                do { try process.run() }
                catch { result.finish(false); return }
                DockLifecycleRunLoop.schedule(after: 2) {
                    guard !result.completed else { return }
                    if process.isRunning { process.terminate() }
                    result.finish(false)
                }
            }, now: { ProcessInfo.processInfo.systemUptime }, schedule: { delay, work in
                DockLifecycleRunLoop.schedule(after: delay, work)
            })
        }
    }

    private let environment: Environment
    private let userID: uid_t
    private var generation = 0
    private(set) var isRestarting = false

    init(environment: Environment? = nil, userID: uid_t = geteuid()) {
        self.environment = environment ?? .live()
        self.userID = userID
    }

    @discardableResult
    func restart(completion: @escaping (String?) -> Void) -> Bool {
        guard !isRestarting else { return false }
        let previous = environment.currentDock()
        if let previous {
            guard previous.owner == userID, previous.pid > 0 else {
                completion("DockAway could not identify a safe Dock process for your login.")
                return false
            }
            guard environment.terminate(previous.pid) else {
                completion("DockAway could not stop the Dock. No other process was restarted.")
                return false
            }
        }
        isRestarting = true
        generation += 1
        let operation = generation
        let deadline = environment.now() + 10
        var requestedLaunch = false

        func finish(_ error: String?) {
            guard self.isRestarting, self.generation == operation else { return }
            self.isRestarting = false
            completion(error)
        }
        func poll() {
            guard self.isRestarting, self.generation == operation else { return }
            let dock = self.environment.currentDock()
            if let dock, dock.owner == self.userID, dock.pid != previous?.pid, dock.isReady {
                finish(nil)
                return
            }
            guard self.environment.now() < deadline else {
                finish("The Dock took too long to restart. Try Restart Dock again.")
                return
            }
            if dock == nil, !requestedLaunch {
                requestedLaunch = true
                self.environment.launchAgent { succeeded in
                    guard self.isRestarting, self.generation == operation else { return }
                    if !succeeded {
                        // launchd may have replaced it between our empty sample
                        // and kickstart. A verified live replacement still wins.
                        if let current = self.environment.currentDock(), current.owner == self.userID,
                           current.pid != previous?.pid, current.isReady {
                            finish(nil)
                        } else {
                            finish("macOS could not relaunch the Dock for your login. Try Restart Dock again.")
                        }
                    }
                }
            }
            self.environment.schedule(0.05, poll)
        }
        poll()
        return true
    }
}
