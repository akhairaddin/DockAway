import Foundation

@main
struct PermissionProbeStateTests {
    static func main() {
        let denied = PermissionSnapshot(
            accessibilityGranted: false,
            inputMonitoringGranted: false
        )
        let accessibilityOnly = PermissionSnapshot(
            accessibilityGranted: true,
            inputMonitoringGranted: false
        )
        let inputMonitoringOnly = PermissionSnapshot(
            accessibilityGranted: false,
            inputMonitoringGranted: true
        )
        let granted = PermissionSnapshot(
            accessibilityGranted: true,
            inputMonitoringGranted: true
        )

        precondition(!denied.allGranted)
        precondition(!accessibilityOnly.allGranted)
        precondition(!inputMonitoringOnly.allGranted)
        precondition(granted.allGranted)

        for (code, expected) in zip(Int32(20)...Int32(23), [
            denied, accessibilityOnly, inputMonitoringOnly, granted
        ]) {
            precondition(PermissionProbeState.decode(exitCode: code, normalExit: true) == expected)
            precondition(PermissionProbeState.decode(exitCode: code, normalExit: false) == nil)
        }
        for code: Int32 in [Int32.min, -1, 0, 1, 19, 24, 127, Int32.max] {
            precondition(PermissionProbeState.decode(exitCode: code, normalExit: true) == nil)
        }

        var state = PermissionProbeState()
        precondition(state.generation == 0)
        precondition(state.snapshot == nil)
        precondition(!state.isChecking)

        let initial = state.begin(now: 10, timeout: 2)
        precondition(state.isChecking)
        precondition(state.complete(generation: initial, snapshot: granted, now: 11))
        precondition(state.snapshot == granted)
        precondition(!state.isChecking)
        precondition(!state.complete(generation: initial, snapshot: denied, now: 11.1))
        precondition(state.snapshot == granted)

        // Starting a refresh retains the displayed observation until the new
        // result arrives, but a revoke must replace even an earlier full grant.
        let revoke = state.begin(now: 20, timeout: 2)
        precondition(revoke > initial)
        precondition(state.isChecking)
        precondition(state.snapshot == granted)
        precondition(state.complete(generation: revoke, snapshot: denied, now: 20.5))
        precondition(state.snapshot == denied)

        let old = state.begin(now: 30, timeout: 2)
        let current = state.begin(now: 30.5, timeout: 2)
        precondition(!state.complete(generation: old, snapshot: granted, now: 31))
        precondition(state.generation == current)
        precondition(state.isChecking)
        precondition(state.snapshot == denied)
        precondition(state.complete(generation: current, snapshot: granted, now: 31.5))
        precondition(state.snapshot == granted)

        // An invalid payload or launch failure clears any previous grant.
        let failed = state.begin(now: 40, timeout: 2)
        precondition(state.complete(generation: failed, snapshot: nil, now: 40.5))
        precondition(state.snapshot == nil)
        precondition(!state.isChecking)

        // Deadline equality is expired, not one final opportunity to grant.
        let recovered = state.begin(now: 49, timeout: 2)
        precondition(state.complete(generation: recovered, snapshot: granted, now: 49.5))
        let expired = state.begin(now: 50, timeout: 2)
        precondition(state.snapshot == granted)
        precondition(state.complete(generation: expired, snapshot: granted, now: 52))
        precondition(state.snapshot == nil)
        precondition(!state.isChecking)
        precondition(!state.complete(generation: expired, snapshot: granted, now: 52.1))

        let late = state.begin(now: 60, timeout: 2)
        precondition(state.complete(generation: late, snapshot: granted, now: 62.1))
        precondition(state.snapshot == nil)
        let retry = state.begin(now: 63, timeout: 2)
        precondition(!state.complete(generation: late, snapshot: granted, now: 63.1))
        precondition(state.isChecking)
        precondition(state.complete(generation: retry, snapshot: granted, now: 63.2))

        let canceled = state.begin(now: 70, timeout: 2)
        state.invalidate()
        precondition(state.generation > canceled)
        precondition(state.snapshot == nil)
        precondition(!state.isChecking)
        precondition(!state.complete(generation: canceled, snapshot: granted, now: 70.1))
        let newSession = state.begin(now: 71, timeout: 2)
        precondition(!state.complete(generation: canceled, snapshot: granted, now: 71.1))
        precondition(state.isChecking)
        precondition(state.snapshot == nil)
        precondition(state.complete(generation: newSession, snapshot: accessibilityOnly, now: 71.2))
        precondition(state.snapshot == accessibilityOnly)

        for timeout: TimeInterval in [0, -1] {
            let immediateExpiry = state.begin(now: 80, timeout: timeout)
            precondition(state.complete(generation: immediateExpiry, snapshot: granted, now: 80))
            precondition(state.snapshot == nil)
        }

        print("PASS: permission probe decoding, deadlines, revokes, generations, failures, and cancellation")
    }
}
