import Foundation
import Darwin

private final class FakeAccessReader: @unchecked Sendable {
    private let lock = NSLock()
    private var access: (Bool, Bool)
    private let delay: UInt32
    private var reads = 0
    private var finishedReads = 0
    private var maximumActiveReads = 0

    init(access: (Bool, Bool), delay: UInt32 = 0) {
        self.access = access
        self.delay = delay
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    var finishedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return finishedReads
    }

    var maxConcurrentReads: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActiveReads
    }

    func setAccess(_ access: (Bool, Bool)) {
        lock.lock()
        self.access = access
        lock.unlock()
    }

    func read() -> (Bool, Bool) {
        precondition(!Thread.isMainThread, "Access checks must run off the main thread")
        lock.lock()
        reads += 1
        maximumActiveReads = max(maximumActiveReads, reads - finishedReads)
        let result = access
        lock.unlock()
        if delay > 0 { usleep(delay) }
        lock.lock()
        finishedReads += 1
        lock.unlock()
        return result
    }
}

@main
struct RuntimePermissionAccessTests {
    @MainActor
    static func main() async {
        await testGrantAndSingleSample()
        await testTimeoutRejectsLateGrant()
        await testInvalidationRejectsLateGrant()
        await testInvalidationBeforeStart()
        await testExplicitRefreshAfterGrant()
        await testRefreshWaitsForCanceledWorker()
        await testBlockedWorkerDoesNotMultiply()
        print("PASS: runtime access sampling, explicit regrant, serialized workers, timeouts, and cancellation")
    }

    @MainActor
    private static func waitUntil(
        _ message: String,
        condition: () -> Bool
    ) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition() {
            precondition(ProcessInfo.processInfo.systemUptime < deadline, message)
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    private static func testGrantAndSingleSample() async {
        let reader = FakeAccessReader(access: (true, true))
        let access = RuntimePermissionAccess(readAccess: { reader.read() })
        var completions = 0
        var duplicateCompletions = 0
        precondition(access.snapshot == nil)
        precondition(!access.isChecking)
        access.start { completions += 1 }
        precondition(access.isChecking)
        access.start { duplicateCompletions += 1 }
        await waitUntil("Runtime grant did not finish") { completions == 1 }
        precondition(access.snapshot?.allGranted == true)
        precondition(!access.isChecking)
        access.start { duplicateCompletions += 1 }
        try? await Task.sleep(nanoseconds: 30_000_000)
        precondition(reader.count == 1)
        precondition(completions == 1)
        precondition(duplicateCompletions == 0)
        access.invalidate()
        precondition(access.snapshot == nil)
    }

    @MainActor
    private static func testTimeoutRejectsLateGrant() async {
        let reader = FakeAccessReader(access: (true, true), delay: 250_000)
        let access = RuntimePermissionAccess(readAccess: { reader.read() }, timeout: 0.05)
        var completions = 0
        access.start { completions += 1 }
        await waitUntil("Runtime deadline did not fire") { completions == 1 }
        precondition(access.snapshot == nil)
        precondition(!access.isChecking)
        access.start { completions += 1 }
        await waitUntil("Fake delayed reader did not return") { reader.finishedCount == 1 }
        try? await Task.sleep(nanoseconds: 30_000_000)
        precondition(access.snapshot == nil)
        precondition(!access.isChecking)
        precondition(completions == 1)
        precondition(reader.count == 1)
        access.invalidate()
    }

    @MainActor
    private static func testInvalidationRejectsLateGrant() async {
        let reader = FakeAccessReader(access: (true, true), delay: 200_000)
        let access = RuntimePermissionAccess(readAccess: { reader.read() }, timeout: 0.3)
        var completions = 0
        access.start { completions += 1 }
        await waitUntil("Fake reader did not start") { reader.count == 1 }
        access.invalidate()
        precondition(access.snapshot == nil)
        precondition(!access.isChecking)
        access.start { completions += 1 }
        await waitUntil("Invalidated fake reader did not return") { reader.finishedCount == 1 }
        // Also pass the canceled deadline to check it cannot invoke completion.
        try? await Task.sleep(nanoseconds: 150_000_000)
        precondition(access.snapshot == nil)
        precondition(!access.isChecking)
        precondition(completions == 0)
        precondition(reader.count == 1)
    }

    @MainActor
    private static func testExplicitRefreshAfterGrant() async {
        let reader = FakeAccessReader(access: (false, false))
        let access = RuntimePermissionAccess(readAccess: { reader.read() })
        var completions = 0
        access.start { completions += 1 }
        await waitUntil("Initial denied read did not finish") { completions == 1 }
        precondition(access.snapshot?.allGranted == false)
        access.invalidate()
        reader.setAccess((true, true))
        access.refresh { completions += 1 }
        await waitUntil("In-process regrant was not sampled") { completions == 2 }
        precondition(access.snapshot?.allGranted == true)
        reader.setAccess((false, true))
        access.refresh { completions += 1 }
        await waitUntil("Runtime revoke was not sampled") { completions == 3 }
        precondition(access.snapshot?.accessibilityGranted == false)
        precondition(reader.maxConcurrentReads == 1)
    }

    @MainActor
    private static func testRefreshWaitsForCanceledWorker() async {
        let reader = FakeAccessReader(access: (false, false), delay: 100_000)
        let access = RuntimePermissionAccess(readAccess: { reader.read() }, timeout: 1)
        var staleCompletions = 0
        var newCompletions = 0
        access.start { staleCompletions += 1 }
        await waitUntil("Old sample did not start") { reader.count == 1 }
        access.invalidate()
        reader.setAccess((true, true))
        access.refresh { newCompletions += 1 }
        await waitUntil("Queued refresh did not finish") { newCompletions == 1 }
        precondition(staleCompletions == 0)
        precondition(access.snapshot?.allGranted == true)
        precondition(reader.count == 2 && reader.maxConcurrentReads == 1)
    }

    @MainActor
    private static func testBlockedWorkerDoesNotMultiply() async {
        let reader = FakeAccessReader(access: (true, true), delay: 300_000)
        let access = RuntimePermissionAccess(readAccess: { reader.read() }, timeout: 0.05)
        var completions = 0
        access.start { completions += 1 }
        await waitUntil("Initial timeout did not fire") { completions == 1 }
        access.refresh { completions += 1 }
        await waitUntil("Queued sample did not time out") { completions == 2 }
        precondition(reader.count == 1 && reader.maxConcurrentReads == 1)
        precondition(access.snapshot == nil)
        await waitUntil("Original worker did not finish") { reader.finishedCount == 1 }
        try? await Task.sleep(nanoseconds: 30_000_000)
        precondition(access.snapshot == nil && reader.count == 1)
        precondition(completions == 2)
    }

    @MainActor
    private static func testInvalidationBeforeStart() async {
        let reader = FakeAccessReader(access: (true, true))
        let access = RuntimePermissionAccess(readAccess: { reader.read() })
        var completions = 0
        access.invalidate()
        access.start { completions += 1 }
        try? await Task.sleep(nanoseconds: 30_000_000)
        precondition(access.snapshot == nil)
        precondition(!access.isChecking)
        precondition(completions == 0)
        precondition(reader.count == 0)
    }
}
