import Foundation

/// Keep the user-facing completion reason independent of process relaunches.
/// Onboarding remains a first start until its confirmation is actually shown.
@MainActor
final class PermissionCompletionConfirmation {
    enum Reason: String {
        case onboarding
        case permissionRecovery

        var title: String {
            switch self {
            case .onboarding: "DockAway has successfully started"
            case .permissionRecovery: "DockAway has successfully restarted"
            }
        }

        var accessibilityDescription: String {
            switch self {
            case .onboarding: "DockAway started"
            case .permissionRecovery: "DockAway restarted"
            }
        }
    }

    static let pendingReasonKey = "PendingPermissionCompletionConfirmation"
    private static let legacyStartedKey = "ShowStartedPopoverAfterPermissionRelaunch"
    private static let legacyRestartedKey = "ShowRestartedPopoverAfterPermissionRelaunch"
    private static let legacyRecoveryKey = "PermissionRecoveryPending"

    private let defaults: UserDefaults
    private(set) var presentationScheduled = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var pendingReason: Reason? {
        if let rawValue = defaults.string(forKey: Self.pendingReasonKey),
           let reason = Reason(rawValue: rawValue) {
            return reason
        }
        // Previous releases set both relaunch flags for genuine recovery.
        // Honor that combination only when no explicit reason has been saved.
        if defaults.bool(forKey: Self.legacyRestartedKey)
            || defaults.bool(forKey: Self.legacyRecoveryKey) {
            return .permissionRecovery
        }
        if defaults.bool(forKey: Self.legacyStartedKey) { return .onboarding }
        return nil
    }

    func request(_ reason: Reason) {
        // Permission acquisition during an onboarding handoff must not rename
        // its pending confirmation, including in the replacement process.
        let selectedReason = pendingReason == .onboarding ? Reason.onboarding : reason
        defaults.set(selectedReason.rawValue, forKey: Self.pendingReasonKey)
        clearLegacyState()
    }

    func beginPresentation() -> Bool {
        guard !presentationScheduled, pendingReason != nil else { return false }
        presentationScheduled = true
        return true
    }

    /// Permissions, session readiness, or the presentation anchor may change
    /// during the delay. Keep the reason for the next successful attempt.
    func deferPresentation() {
        presentationScheduled = false
    }

    @discardableResult
    func didPresent(_ reason: Reason) -> Bool {
        presentationScheduled = false
        guard pendingReason == reason else { return false }
        defaults.removeObject(forKey: Self.pendingReasonKey)
        clearLegacyState()
        return true
    }

    private func clearLegacyState() {
        defaults.removeObject(forKey: Self.legacyStartedKey)
        defaults.removeObject(forKey: Self.legacyRestartedKey)
        defaults.removeObject(forKey: Self.legacyRecoveryKey)
    }
}
