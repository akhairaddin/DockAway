import AppKit
import ApplicationServices
import Foundation
import IOKit.hid

// MARK: - Permission snapshots and probe state

struct PermissionSnapshot: Equatable {
    let accessibilityGranted: Bool
    let inputMonitoringGranted: Bool

    var allGranted: Bool {
        accessibilityGranted && inputMonitoringGranted
    }
}

// Records only what a fresh probe observed. Whether the running application can
// use a permission is tracked separately, since a grant can require a restart.
struct PermissionProbeState {
    private(set) var generation = 0
    private(set) var snapshot: PermissionSnapshot?
    private(set) var isChecking = false
    private var deadline: TimeInterval = -.infinity

    mutating func begin(now: TimeInterval, timeout: TimeInterval) -> Int {
        generation += 1
        isChecking = true
        deadline = now + max(0, timeout)
        return generation
    }

    // A current failure is still an accepted completion and clears any earlier
    // observation. A stale completion must not modify a newer probe's state.
    @discardableResult
    mutating func complete(
        generation: Int,
        snapshot: PermissionSnapshot?,
        now: TimeInterval
    ) -> Bool {
        guard generation == self.generation, isChecking else { return false }
        isChecking = false
        self.snapshot = now < deadline ? snapshot : nil
        return true
    }

    mutating func invalidate() {
        generation += 1
        snapshot = nil
        isChecking = false
        deadline = -.infinity
    }

    // Dedicated normal exit codes distinguish denied permissions from launch,
    // signal, and unexpected-process failures. Bits are AX first, IOHID second.
    static func decode(exitCode: Int32, normalExit: Bool) -> PermissionSnapshot? {
        guard normalExit, (20...23).contains(exitCode) else { return nil }
        let permissions = exitCode - 20
        return PermissionSnapshot(
            accessibilityGranted: permissions & 1 != 0,
            inputMonitoringGranted: permissions & 2 != 0
        )
    }
}

// MARK: - Completion decision

// An unavailable local capability can justify a restart only when a fresh
// authorization check still confirms access. Never restart to bypass denial.
enum PermissionCompletionDecision: Equatable {
    case remainInSetup
    case continueInPlace
    case restart

    static func decide(
        authorization: PermissionSnapshot?,
        runtime: PermissionSnapshot?
    ) -> Self {
        guard authorization?.allGranted == true else { return .remainInSetup }
        return runtime?.allGranted == true ? .continueInPlace : .restart
    }
}

// MARK: - Current-process access

// Current-process permission checks can block inside the system framework.
// Sample off the main thread, separately from fresh-process observations.
// Continue can explicitly resample, but system calls never overlap, even after
// a timeout or cancellation. Background polling never invokes this sampler.
@MainActor
final class RuntimePermissionAccess {
    private var state = PermissionProbeState()
    private var hasStarted = false
    private var workerGeneration: Int?
    private var pendingSample = false
    private var timeoutWork: DispatchWorkItem?
    private var completion: (() -> Void)?
    private let readAccess: @Sendable () -> (Bool, Bool)
    private let timeout: TimeInterval

    var snapshot: PermissionSnapshot? { state.snapshot }
    var isChecking: Bool { state.isChecking }

    init(
        readAccess: @escaping @Sendable () -> (Bool, Bool) = {
            RuntimePermissionAccess.readSystemAccess()
        },
        timeout: TimeInterval = 2
    ) {
        self.readAccess = readAccess
        self.timeout = timeout
    }

    func start(onCompletion: @escaping () -> Void) {
        guard !hasStarted else { return }
        hasStarted = true
        refresh(onCompletion: onCompletion)
    }

    func refresh(onCompletion: @escaping () -> Void) {
        invalidate()
        completion = onCompletion
        let generation = state.begin(
            now: ProcessInfo.processInfo.systemUptime, timeout: timeout
        )
        let work = DispatchWorkItem { [weak self] in
            self?.finish(generation: generation, snapshot: nil)
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, timeout), execute: work)
        pendingSample = true
        launchPendingSample()
    }

    private func launchPendingSample() {
        guard pendingSample, workerGeneration == nil, state.isChecking else { return }
        pendingSample = false
        let generation = state.generation
        workerGeneration = generation
        let readAccess = self.readAccess
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let access = readAccess()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.workerGeneration = nil
                let snapshot = PermissionSnapshot(
                    accessibilityGranted: access.0,
                    inputMonitoringGranted: access.1
                )
                self.finish(generation: generation, snapshot: snapshot)
                self.launchPendingSample()
            }
        }
    }

    func invalidate() {
        // Invalidate the observation, not the worker slot. A blocked system
        // call cannot safely be canceled; a refresh waits for it or times out.
        hasStarted = true
        pendingSample = false
        state.invalidate()
        timeoutWork?.cancel()
        timeoutWork = nil
        completion = nil
    }

    private func finish(generation: Int, snapshot: PermissionSnapshot?) {
        guard state.complete(
            generation: generation,
            snapshot: snapshot,
            now: ProcessInfo.processInfo.systemUptime
        ) else { return }
        timeoutWork?.cancel()
        timeoutWork = nil
        pendingSample = false
        let callback = completion
        completion = nil
        callback?()
    }

    nonisolated static func readSystemAccess() -> (Bool, Bool) {
        let trusted = AXIsProcessTrusted()
        let canPost = IOHIDCheckAccess(kIOHIDRequestTypePostEvent) == kIOHIDAccessTypeGranted
        let canListen = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        // Exercise a read-only Accessibility operation in this process as well
        // as checking trust. No synthetic key events or permission prompts.
        var attributes: CFArray?
        let canReadAccessibility = trusted && canPost
            && AXUIElementCopyAttributeNames(AXUIElementCreateSystemWide(), &attributes) == .success
        return (canReadAccessibility, canListen)
    }
}

// MARK: - Fresh-process authorization

/// Uses only public, no-prompt APIs in a fresh copy of this same executable.
/// No TCC database access, private notifications, or copied helper identity.
@MainActor
final class PermissionMonitor {
    private(set) var state = PermissionProbeState()
    var onChange: ((PermissionSnapshot?) -> Void)?
    private var process: Process?
    private var timeoutWork: DispatchWorkItem?
    private var confirmation: ((PermissionSnapshot?) -> Void)?
    private var lastStarted = -Double.infinity
    private let executableURL: URL?
    private let timeout: TimeInterval

    init(executableURL: URL? = Bundle.main.executableURL, timeout: TimeInterval = 2) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    var snapshot: PermissionSnapshot? { state.snapshot }

    func refresh(
        minimumInterval: TimeInterval = 0.4,
        force: Bool = false,
        completion: ((PermissionSnapshot?) -> Void)? = nil
    ) {
        // Ordinary refresh events must not supersede an explicit Continue
        // confirmation. Lifecycle stop() can still cancel it deliberately.
        guard confirmation == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if force || completion != nil {
            cancelProcess()
            // begin() advances the generation while keeping the last observed
            // state visible. A refresh itself is not a permission revocation.
        } else {
            guard process == nil, now - lastStarted >= minimumInterval else { return }
        }
        let generation = state.begin(now: now, timeout: timeout)
        lastStarted = now
        confirmation = completion
        guard let executable = executableURL else {
            finish(generation: generation, snapshot: nil)
            return
        }

        let probe = Process()
        probe.executableURL = executable
        probe.arguments = ["--dockaway-permission-probe"]
        probe.standardInput = FileHandle.nullDevice
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        probe.terminationHandler = { [weak self] result in
            let exitCode = result.terminationStatus
            let normalExit = result.terminationReason == .exit
            Task { @MainActor [weak self] in
                let snapshot = PermissionProbeState.decode(
                    exitCode: exitCode, normalExit: normalExit
                )
                self?.finish(generation: generation, snapshot: snapshot)
            }
        }
        process = probe
        do {
            try probe.run()
            let work = DispatchWorkItem { [weak self] in
                self?.finish(generation: generation, snapshot: nil)
            }
            timeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        } catch {
            finish(generation: generation, snapshot: nil)
        }
    }

    func stop() {
        state.invalidate()
        cancelProcess()
    }

    private func finish(generation: Int, snapshot: PermissionSnapshot?) {
        // Check the token before touching the Process slot or any callbacks.
        guard state.complete(generation: generation, snapshot: snapshot,
                             now: ProcessInfo.processInfo.systemUptime) else { return }
        let callback = confirmation
        let result = state.snapshot
        cancelProcess()
        onChange?(result)
        callback?(state.generation == generation ? result : nil)
    }

    private func cancelProcess() {
        timeoutWork?.cancel()
        timeoutWork = nil
        confirmation = nil
        if let process {
            process.terminationHandler = nil
            if process.isRunning {
                // This is our own short-lived preflight child, never DockAway's
                // main process or System Settings. Bound its lifetime strictly.
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process = nil
    }
}
