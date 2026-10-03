import AppKit
import Darwin

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
        var schedule: (TimeInterval, @escaping () -> Void) -> Void

        static func live() -> Self {
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
                var completed = false
                func finish(_ succeeded: Bool) {
                    guard !completed else { return }
                    completed = true
                    completion(succeeded)
                }
                process.terminationHandler = { child in
                    let succeeded = child.terminationStatus == 0
                    DispatchQueue.main.async { finish(succeeded) }
                }
                do { try process.run() }
                catch { finish(false); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    guard !completed else { return }
                    if process.isRunning { process.terminate() }
                    finish(false)
                }
            }, now: { ProcessInfo.processInfo.systemUptime }, schedule: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { work() }
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
