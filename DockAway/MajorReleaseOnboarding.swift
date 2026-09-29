import Foundation

/// A one-time introduction to the major 2.0 release, not every app update.
enum MajorReleaseOnboarding {
    static let completionKey = "CompletedMajorReleaseOnboarding"
    // Keep this at 2 for 2.1 and later updates. It identifies the 2.0 tour,
    // not the app version; completing that tour must remain sufficient.
    static let currentRevision = 2

    static func needsPresentation(in defaults: UserDefaults = .standard) -> Bool {
        defaults.integer(forKey: completionKey) < currentRevision
    }

    static func markCompleted(in defaults: UserDefaults = .standard) {
        defaults.set(currentRevision, forKey: completionKey)
    }
}
