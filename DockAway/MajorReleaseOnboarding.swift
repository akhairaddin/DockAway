import Foundation

/// A one-time introduction to the major 2.0 release, not every app update.
enum MajorReleaseOnboarding {
    static let completionKey = "CompletedMajorReleaseOnboarding"
    static let inProgressKey = "PermissionOnboardingInProgress"
    // Keep this at 2 for 2.1 and later updates. It identifies the 2.0 tour,
    // not the app version; completing that tour must remain sufficient.
    static let currentRevision = 2

    static func needsPresentation(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: inProgressKey)
            || defaults.integer(forKey: completionKey) < currentRevision
    }

    static func markStarted(in defaults: UserDefaults = .standard) {
        // System Settings can quit and reopen DockAway while granting access.
        // Keep that handoff from consuming an unfinished interactive tour.
        defaults.set(true, forKey: inProgressKey)
    }

    /// The user closed or quit the tour without finishing it. Someone who
    /// already completed it before is not held to it again; a first tour
    /// stays due because its completion revision is still missing.
    static func markDismissed(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: inProgressKey)
    }

    static func markCompleted(in defaults: UserDefaults = .standard) {
        defaults.set(currentRevision, forKey: completionKey)
        defaults.removeObject(forKey: inProgressKey)
    }
}
