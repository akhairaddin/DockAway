import Foundation
import Darwin

@main
struct PermissionMonitorTests {
    private static let modeKey = "DOCKAWAY_PERMISSION_TEST_MODE"
    private static let granted = PermissionSnapshot(
        accessibilityGranted: true, inputMonitoringGranted: true
    )
    private static let denied = PermissionSnapshot(
        accessibilityGranted: false, inputMonitoringGranted: false
    )

    @MainActor
    static func main() async {
        // PermissionMonitor launches this test binary, never DockAway. This
        // branch contains no real permission reads, requests, or app startup.
        if CommandLine.arguments.contains("--dockaway-permission-probe") {
            runFakeProbe()
        }

        let originalMode = getenv(modeKey).map { String(cString: $0) }
        defer {
            if let originalMode {
                setenv(modeKey, originalMode, 1)
            } else {
                unsetenv(modeKey)
            }
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])

        await testGrantThenRevoke(executable: executable)
        await testConfirmationSurvivesForceRefresh(executable: executable)
        await testRefreshPreservesObservation(executable: executable)
        await testReentrantCancellation(executable: executable)
        await testStopCancelsCallbacks(executable: executable)
        await testTimeoutClearsGrant(executable: executable)
        await testInvalidExits(executable: executable)
        await testMissingExecutable()

        print("PASS: permission monitor child lifecycle, confirmation, stop, timeout, and unknown results")
    }

    private static func runFakeProbe() -> Never {
        let mode = getenv(modeKey).map { String(cString: $0) } ?? "missing"
        switch mode {
        case "grant": exit(23)
        case "deny": exit(20)
        case "delayed-grant":
            usleep(250_000)
            exit(23)
        case "hang":
            sleep(5)
            exit(23)
        case "exit-one": exit(1)
        case "exit-zero": exit(0)
        case "unexpected": exit(24)
        case "signal":
            raise(SIGKILL)
            exit(23)
        default: exit(127)
        }
    }

    private static func setMode(_ mode: String) {
        precondition(setenv(modeKey, mode, 1) == 0)
    }

    @MainActor
    private static func waitUntil(
        _ message: String,
        timeout: TimeInterval = 3,
        condition: () -> Bool
    ) async {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            precondition(ProcessInfo.processInfo.systemUptime < deadline, message)
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    private static func testGrantThenRevoke(executable: URL) async {
        let monitor = PermissionMonitor(executableURL: executable)
        defer { monitor.stop() }
        var changes: [PermissionSnapshot?] = []
        monitor.onChange = { changes.append($0) }

        setMode("grant")
        monitor.refresh(minimumInterval: 0)
        await waitUntil("Grant probe did not finish") { changes.count == 1 }
        precondition(monitor.snapshot == granted)
        precondition(changes[0] == granted)

        setMode("deny")
        monitor.refresh(minimumInterval: 0)
        precondition(monitor.snapshot == granted)
        precondition(monitor.state.isChecking)
        await waitUntil("Revoke probe did not finish") { changes.count == 2 }
        precondition(monitor.snapshot == denied)
        precondition(changes[1] == denied)
        precondition(!monitor.state.isChecking)
    }

    @MainActor
    private static func testConfirmationSurvivesForceRefresh(executable: URL) async {
        let monitor = PermissionMonitor(executableURL: executable)
        defer { monitor.stop() }
        var changes: [PermissionSnapshot?] = []
        var confirmations: [PermissionSnapshot?] = []
        monitor.onChange = { changes.append($0) }

        setMode("delayed-grant")
        monitor.refresh(completion: { confirmations.append($0) })
        let confirmationGeneration = monitor.state.generation
        setMode("deny")
        monitor.refresh(force: true)
        monitor.refresh(minimumInterval: 0)
        precondition(monitor.state.generation == confirmationGeneration)
        await waitUntil("Forced refresh stranded the confirmation callback") {
            confirmations.count == 1
        }
        precondition(confirmations[0] == granted)
        precondition(changes == [granted])

        monitor.refresh(force: true)
        await waitUntil("Polling did not resume after confirmation") { changes.count == 2 }
        precondition(changes[1] == denied)
        precondition(confirmations.count == 1)
    }

    @MainActor
    private static func testRefreshPreservesObservation(executable: URL) async {
        let monitor = PermissionMonitor(executableURL: executable)
        defer { monitor.stop() }
        var changes: [PermissionSnapshot?] = []
        monitor.onChange = { changes.append($0) }
        setMode("grant")
        monitor.refresh(force: true)
        await waitUntil("Initial menu observation did not finish") { changes.count == 1 }
        setMode("delayed-grant")
        monitor.refresh(force: true)
        precondition(monitor.snapshot == granted)
        let superseded = monitor.state.generation
        setMode("deny")
        monitor.refresh(force: true)
        precondition(monitor.snapshot == granted)
        precondition(monitor.state.generation > superseded)
        await waitUntil("Replacement probe did not finish") { changes.count == 2 }
        try? await Task.sleep(nanoseconds: 350_000_000)
        precondition(changes == [granted, denied])
    }

    @MainActor
    private static func testReentrantCancellation(executable: URL) async {
        let monitor = PermissionMonitor(executableURL: executable)
        defer { monitor.stop() }
        var confirmations: [PermissionSnapshot?] = []
        monitor.onChange = { _ in monitor.stop() }
        setMode("grant")
        monitor.refresh(completion: { confirmations.append($0) })
        await waitUntil("Reentrant cancellation stranded callback") { confirmations.count == 1 }
        precondition(confirmations[0] == nil)
        precondition(monitor.snapshot == nil)
        monitor.onChange = nil
    }

    @MainActor
    private static func testStopCancelsCallbacks(executable: URL) async {
        let monitor = PermissionMonitor(executableURL: executable)
        defer { monitor.stop() }
        var changes: [PermissionSnapshot?] = []
        var confirmations: [PermissionSnapshot?] = []
        monitor.onChange = { changes.append($0) }

        setMode("delayed-grant")
        monitor.refresh(completion: { confirmations.append($0) })
        let canceledGeneration = monitor.state.generation
        monitor.stop()
        precondition(monitor.state.generation > canceledGeneration)
        precondition(monitor.snapshot == nil)
        precondition(!monitor.state.isChecking)
        try? await Task.sleep(nanoseconds: 350_000_000)
        precondition(changes.isEmpty)
        precondition(confirmations.isEmpty)

        setMode("deny")
        monitor.refresh(force: true)
        await waitUntil("Monitor could not restart after stop") { changes.count == 1 }
        precondition(changes[0] == denied)
        precondition(confirmations.isEmpty)
    }

    @MainActor
    private static func testTimeoutClearsGrant(executable: URL) async {
        let monitor = PermissionMonitor(executableURL: executable, timeout: 0.75)
        defer { monitor.stop() }
        var changes: [PermissionSnapshot?] = []
        monitor.onChange = { changes.append($0) }

        setMode("grant")
        monitor.refresh(minimumInterval: 0)
        await waitUntil("Initial grant probe did not finish") { changes.count == 1 }
        precondition(monitor.snapshot == granted)

        setMode("hang")
        monitor.refresh(minimumInterval: 0)
        precondition(monitor.snapshot == granted)
        await waitUntil("Probe deadline did not produce unknown") { changes.count == 2 }
        precondition(changes[1] == nil)
        precondition(monitor.snapshot == nil)
        precondition(!monitor.state.isChecking)

        setMode("deny")
        monitor.refresh(minimumInterval: 0)
        await waitUntil("Timed-out child blocked the next probe") { changes.count == 3 }
        precondition(changes[2] == denied)
    }

    @MainActor
    private static func testInvalidExits(executable: URL) async {
        let monitor = PermissionMonitor(executableURL: executable)
        defer { monitor.stop() }
        var changes: [PermissionSnapshot?] = []
        monitor.onChange = { changes.append($0) }

        for mode in ["exit-one", "exit-zero", "unexpected", "signal"] {
            setMode("grant")
            var expectedCount = changes.count + 1
            monitor.refresh(minimumInterval: 0)
            await waitUntil("Grant setup failed before \(mode)") { changes.count == expectedCount }
            precondition(monitor.snapshot == granted)

            setMode(mode)
            expectedCount += 1
            monitor.refresh(minimumInterval: 0)
            await waitUntil("Invalid result did not complete for \(mode)") {
                changes.count == expectedCount
            }
            precondition(changes.last! == nil)
            precondition(monitor.snapshot == nil)
            precondition(!monitor.state.isChecking)
        }
    }

    @MainActor
    private static func testMissingExecutable() async {
        for executable: URL? in [nil, URL(fileURLWithPath: "/dev/null")] {
            let monitor = PermissionMonitor(executableURL: executable)
            var confirmations: [PermissionSnapshot?] = []
            var changes: [PermissionSnapshot?] = []
            monitor.onChange = { changes.append($0) }
            monitor.refresh(completion: { confirmations.append($0) })
            await waitUntil("Missing or nonexecutable probe did not complete") {
                confirmations.count == 1
            }
            precondition(confirmations[0] == nil)
            precondition(changes.count == 1 && changes[0] == nil)
            precondition(monitor.snapshot == nil)
            precondition(!monitor.state.isChecking)
            monitor.stop()
        }
    }
}
