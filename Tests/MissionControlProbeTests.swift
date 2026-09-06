import Foundation

// Explicit release points make the race tests independent of AX permission,
// Dock responsiveness, and assumptions about how long an IPC call takes.
nonisolated private final class ControlledMissionControlReader: @unchecked Sendable {
    private let condition = NSCondition()
    private var pids = [pid_t]()
    private var results = [Int: MissionControlProbeResult]()
    private var active = 0
    private var maximumActive = 0

    var requestedPIDs: [pid_t] {
        condition.lock()
        defer { condition.unlock() }
        return pids
    }

    var maximumConcurrentReads: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumActive
    }

    func release(_ call: Int, result: MissionControlProbeResult) {
        condition.lock()
        results[call] = result
        condition.broadcast()
        condition.unlock()
    }

    func read(pid: pid_t) -> MissionControlProbeResult {
        precondition(!Thread.isMainThread, "AX reads must not run on the UI thread")
        condition.lock()
        let call = pids.count
        pids.append(pid)
        active += 1
        maximumActive = max(maximumActive, active)
        while results[call] == nil { condition.wait() }
        let result = results.removeValue(forKey: call)!
        active -= 1
        condition.unlock()
        return result
    }
}

@main
struct MissionControlProbeTests {
    private static let active = MissionControlProbeResult(
        isActive: true, querySucceeded: true
    )
    private static let inactive = MissionControlProbeResult(
        isActive: false, querySucceeded: true
    )

    @MainActor
    static func main() async {
        testResultResolution()
        await testBlockedWorkerLeavesMainQueueResponsive()
        await testPeriodicRequestsCoalesceWithoutStarvingResults()
        await testStateEdgeRejectsStaleResult()
        await testPIDChangeRejectsStaleResult()
        await testInvalidateAndRestartDoNotOverlapWorkers()
        await testInvalidationDiscardsPendingRequest()
        await testInvalidPIDAndUnknownResult()
        print("PASS: Mission Control result resolution, main-thread responsiveness, coalescing, state edges, PID changes, cancellation, and serialized workers")
    }

    @MainActor
    private static func testResultResolution() {
        for windowServer: Bool? in [true, false, nil] {
            precondition(active.resolve(windowServer: windowServer) == true)
            // A positive marker remains authoritative regardless of the
            // success flag. The current reader emits true with success=true.
            precondition(MissionControlProbeResult(
                isActive: true, querySucceeded: false
            ).resolve(windowServer: windowServer) == true)
        }
        precondition(inactive.resolve(windowServer: true) == true)
        precondition(inactive.resolve(windowServer: false) == false)
        precondition(inactive.resolve(windowServer: nil) == false)
        precondition(MissionControlProbeResult.unknown.resolve(windowServer: true) == true)
        precondition(MissionControlProbeResult.unknown.resolve(windowServer: false) == false)
        precondition(MissionControlProbeResult.unknown.resolve(windowServer: nil) == nil)
    }

    @MainActor
    private static func waitUntil(
        _ message: String,
        condition: () -> Bool
    ) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition() {
            precondition(ProcessInfo.processInfo.systemUptime < deadline, message)
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor
    private static func testBlockedWorkerLeavesMainQueueResponsive() async {
        let reader = ControlledMissionControlReader()
        let probe = MissionControlProbe(readState: { reader.read(pid: $0) })
        var delivered = [MissionControlProbeResult]()
        probe.request(pid: 101) { result in
            precondition(Thread.isMainThread, "Results must reach the UI thread")
            delivered.append(result)
        }
        await waitUntil("Worker did not start") { reader.requestedPIDs.count == 1 }
        var mainQueueAnswered = false
        DispatchQueue.main.async { mainQueueAnswered = true }
        await waitUntil("Main queue blocked behind AX worker") { mainQueueAnswered }
        precondition(probe.isChecking && delivered.isEmpty)
        reader.release(0, result: active)
        await waitUntil("Result was not delivered") { delivered.count == 1 }
        precondition(delivered == [active] && !probe.isChecking)
    }

    @MainActor
    private static func testPeriodicRequestsCoalesceWithoutStarvingResults() async {
        let reader = ControlledMissionControlReader()
        let probe = MissionControlProbe(readState: { reader.read(pid: $0) })
        var callbacks = [Int]()
        probe.request(pid: 101) { _ in callbacks.append(0) }
        await waitUntil("First periodic sample did not start") { reader.requestedPIDs.count == 1 }
        for tick in 1...30 {
            probe.request(pid: 101) { _ in callbacks.append(tick) }
        }
        precondition(reader.requestedPIDs == [101])
        reader.release(0, result: active)
        await waitUntil("Periodic ticks starved initial result") { callbacks == [0] }
        await waitUntil("Coalesced follow-up did not start") { reader.requestedPIDs.count == 2 }
        reader.release(1, result: inactive)
        await waitUntil("Latest coalesced callback did not arrive") { callbacks.count == 2 }
        precondition(callbacks == [0, 30])
        precondition(reader.requestedPIDs == [101, 101])
        precondition(reader.maximumConcurrentReads == 1 && !probe.isChecking)
    }

    @MainActor
    private static func testStateEdgeRejectsStaleResult() async {
        let reader = ControlledMissionControlReader()
        let probe = MissionControlProbe(readState: { reader.read(pid: $0) })
        var staleCallbacks = 0
        var freshResults = [MissionControlProbeResult]()
        probe.request(pid: 101) { _ in staleCallbacks += 1 }
        await waitUntil("Old edge sample did not start") { reader.requestedPIDs.count == 1 }
        probe.request(pid: 101, invalidatingInFlightResult: true) { _ in staleCallbacks += 1 }
        // Another periodic tick may replace the pending callback but must not
        // erase the event revision that made the old sample stale.
        probe.request(pid: 101) { freshResults.append($0) }
        reader.release(0, result: inactive)
        await waitUntil("Fresh edge sample did not start") { reader.requestedPIDs.count == 2 }
        precondition(staleCallbacks == 0 && freshResults.isEmpty)
        reader.release(1, result: active)
        await waitUntil("Fresh edge result did not arrive") { freshResults == [active] }
        precondition(staleCallbacks == 0 && reader.maximumConcurrentReads == 1)
    }

    @MainActor
    private static func testPIDChangeRejectsStaleResult() async {
        let reader = ControlledMissionControlReader()
        let probe = MissionControlProbe(readState: { reader.read(pid: $0) })
        var staleCallbacks = 0
        var currentResults = [MissionControlProbeResult]()
        probe.request(pid: 101) { _ in staleCallbacks += 1 }
        await waitUntil("Old Dock sample did not start") { reader.requestedPIDs.count == 1 }
        probe.request(pid: 202) { _ in staleCallbacks += 1 }
        probe.request(pid: 303) { currentResults.append($0) }
        reader.release(0, result: active)
        await waitUntil("Replacement Dock sample did not start") { reader.requestedPIDs.count == 2 }
        precondition(reader.requestedPIDs == [101, 303] && staleCallbacks == 0)
        reader.release(1, result: inactive)
        await waitUntil("Replacement Dock result did not arrive") { currentResults == [inactive] }
        precondition(staleCallbacks == 0 && reader.maximumConcurrentReads == 1)
    }

    @MainActor
    private static func testInvalidateAndRestartDoNotOverlapWorkers() async {
        let reader = ControlledMissionControlReader()
        let probe = MissionControlProbe(readState: { reader.read(pid: $0) })
        var staleCallbacks = 0
        var restartedResults = [MissionControlProbeResult]()
        probe.request(pid: 101) { _ in staleCallbacks += 1 }
        await waitUntil("Pre-stop sample did not start") { reader.requestedPIDs.count == 1 }
        for _ in 0..<20 {
            probe.invalidate()
            probe.request(pid: 101) { restartedResults.append($0) }
        }
        precondition(probe.isChecking && reader.requestedPIDs == [101])
        reader.release(0, result: active)
        await waitUntil("Restarted sample did not start") { reader.requestedPIDs.count == 2 }
        precondition(staleCallbacks == 0 && restartedResults.isEmpty)
        reader.release(1, result: inactive)
        await waitUntil("Restarted result did not arrive") { restartedResults == [inactive] }
        precondition(reader.maximumConcurrentReads == 1)
    }

    @MainActor
    private static func testInvalidationDiscardsPendingRequest() async {
        let reader = ControlledMissionControlReader()
        let probe = MissionControlProbe(readState: { reader.read(pid: $0) })
        var callbacks = 0
        probe.request(pid: 101) { _ in callbacks += 1 }
        await waitUntil("Canceled sample did not start") { reader.requestedPIDs.count == 1 }
        probe.request(pid: 101) { _ in callbacks += 1 }
        probe.invalidate()
        reader.release(0, result: active)
        await waitUntil("Canceled worker did not retire") { !probe.isChecking }
        precondition(callbacks == 0 && reader.requestedPIDs == [101])
    }

    @MainActor
    private static func testInvalidPIDAndUnknownResult() async {
        let reader = ControlledMissionControlReader()
        let probe = MissionControlProbe(readState: { reader.read(pid: $0) })
        var results = [MissionControlProbeResult]()
        probe.request(pid: 0) { results.append($0) }
        precondition(results == [.unknown] && reader.requestedPIDs.isEmpty)
        precondition(MissionControlProbe.readSystemState(pid: -1) == .unknown)
        probe.request(pid: 101) { results.append($0) }
        await waitUntil("Unknown-result sample did not start") { reader.requestedPIDs.count == 1 }
        reader.release(0, result: .unknown)
        await waitUntil("Unknown result was not delivered") { results.count == 2 }
        precondition(results == [.unknown, .unknown])
    }
}
