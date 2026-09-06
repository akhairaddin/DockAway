import Foundation

@main
struct PermissionCompletionDecisionTests {
    static func main() {
        let states: [PermissionSnapshot?] = [nil,
            PermissionSnapshot(accessibilityGranted: false, inputMonitoringGranted: false),
            PermissionSnapshot(accessibilityGranted: true, inputMonitoringGranted: false),
            PermissionSnapshot(accessibilityGranted: false, inputMonitoringGranted: true),
            PermissionSnapshot(accessibilityGranted: true, inputMonitoringGranted: true)
        ]
        for authorization in states {
            for runtime in states {
                let result = PermissionCompletionDecision.decide(authorization: authorization, runtime: runtime)
                if authorization?.allGranted != true {
                    precondition(result == .remainInSetup)
                } else if runtime?.allGranted == true {
                    precondition(result == .continueInPlace)
                } else {
                    precondition(result == .restart)
                }
            }
        }
        // A previously usable runtime does not override a newer denied or
        // failed authorization check after the local read has completed.
        let granted = states.last!
        precondition(PermissionCompletionDecision.decide(authorization: nil, runtime: granted) == .remainInSetup)
        precondition(PermissionCompletionDecision.decide(authorization: states[1], runtime: granted) == .remainInSetup)
        print("PASS: all 25 authorization/runtime combinations for conditional restart")
    }
}
