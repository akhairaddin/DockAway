import ApplicationServices
import Foundation

nonisolated struct MissionControlProbeResult: Equatable, Sendable {
    let isActive: Bool
    let querySucceeded: Bool

    static let unknown = Self(isActive: false, querySucceeded: false)

    // A positive AX observation is sufficient on its own. For an absent or
    // unavailable AX marker, a fresh WindowServer snapshot can still confirm
    // entry or exit. If both sources are unknown, nil tells the owner to retain
    // its previous protection instead of publishing an unverified exit.
    func resolve(windowServer: Bool?) -> Bool? {
        if isActive { return true }
        if let windowServer { return windowServer }
        return querySucceeded ? false : nil
    }
}

// AX requests are synchronous IPC, even when used for read-only inspection.
// This sampler owns a separate worker so a slow ordinary application cannot
// delay Mission Control detection. Only value snapshots return to the main
// actor; no AX elements or observer registrations cross executors.
@MainActor
final class MissionControlProbe {
    private struct Request {
        let pid: pid_t
        let generation: UInt64
        let eventRevision: UInt64
        let onResult: (MissionControlProbeResult) -> Void
    }

    private let queue = DispatchQueue(
        label: "com.dockaway.mission-control-probe",
        qos: .utility
    )
    private let readState: @Sendable (pid_t) -> MissionControlProbeResult
    private var generation: UInt64 = 0
    private var eventRevision: UInt64 = 0
    private var currentPID: pid_t?
    private var inFlight: Request?
    private var pending: Request?

    // Describes the physical worker, including an invalidated call that cannot
    // be canceled while the target application is answering its AX request.
    var isChecking: Bool { inFlight != nil }

    init(
        readState: @escaping @Sendable (pid_t) -> MissionControlProbeResult = {
            MissionControlProbe.readSystemState(pid: $0)
        }
    ) {
        self.readState = readState
    }

    // Periodic requests never invalidate a running sample. They replace one
    // pending follow-up, so timer ticks cannot build a queue or starve results.
    // A real state edge may invalidate the running result explicitly. A Dock
    // PID change always does so. Only the latest pending request is delivered;
    // this is a sampler, not a completion guarantee for every individual tick.
    func request(
        pid: pid_t,
        invalidatingInFlightResult: Bool = false,
        onResult: @escaping (MissionControlProbeResult) -> Void
    ) {
        guard pid > 0 else {
            invalidate()
            onResult(.unknown)
            return
        }

        if currentPID != pid {
            generation &+= 1
            eventRevision = 0
            currentPID = pid
        }
        if invalidatingInFlightResult {
            eventRevision &+= 1
        }
        pending = Request(
            pid: pid,
            generation: generation,
            eventRevision: eventRevision,
            onResult: onResult
        )
        launchPendingRequest()
    }

    func invalidate() {
        generation &+= 1
        eventRevision = 0
        currentPID = nil
        pending = nil
        // Keep the worker slot occupied. Cancellation cannot stop synchronous
        // IPC, and a restart must not multiply blocked workers.
    }

    private func launchPendingRequest() {
        guard inFlight == nil, let request = pending else { return }
        pending = nil
        inFlight = request
        let pid = request.pid
        let readState = self.readState
        queue.async { [weak self] in
            let result = readState(pid)
            Task { @MainActor [weak self] in
                self?.finish(result)
            }
        }
    }

    private func finish(_ result: MissionControlProbeResult) {
        guard let request = inFlight else { return }
        inFlight = nil
        if request.generation == generation,
           request.eventRevision == eventRevision,
           request.pid == currentPID {
            request.onResult(result)
        }
        launchPendingRequest()
    }

    nonisolated static func readSystemState(pid: pid_t) -> MissionControlProbeResult {
        guard pid > 0 else { return .unknown }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.20
        let application = AXUIElementCreateApplication(pid)

        // The budget is shared by the whole hierarchy walk. AX timeouts are
        // per message, so use the remaining budget for each next call. This
        // bounds requested waits, not framework overhead or OS scheduling.
        func prepare(_ element: AXUIElement) -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            return AXUIElementSetMessagingTimeout(
                element,
                Float(min(0.10, remaining))
            ) == .success
        }

        guard prepare(application) else { return .unknown }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success,
        let children = value as? [AXUIElement],
        ProcessInfo.processInfo.systemUptime < deadline else {
            return .unknown
        }

        var hadTransientFailure = false
        for child in children {
            guard prepare(child) else { return .unknown }
            var identifier: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(
                child,
                kAXIdentifierAttribute as CFString,
                &identifier
            )
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                return .unknown
            }
            if status == .success, identifier as? String == "mc" {
                return MissionControlProbeResult(isActive: true, querySucceeded: true)
            }
            if status == .cannotComplete || status == .invalidUIElement
                || status == .apiDisabled || status == .failure {
                hadTransientFailure = true
            }
        }
        return MissionControlProbeResult(
            isActive: false,
            querySucceeded: !hadTransientFailure
        )
    }
}
