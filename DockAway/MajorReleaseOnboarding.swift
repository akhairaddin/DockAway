import Foundation

/// A one-time introduction to the major 2.0 release, not every app update.
enum MajorReleaseOnboarding {
    static let completionKey = "CompletedMajorReleaseOnboarding"
    static let currentRevision = 2

    static func needsPresentation(in defaults: UserDefaults = .standard) -> Bool {
        defaults.integer(forKey: completionKey) < currentRevision
    }

    static func markCompleted(in defaults: UserDefaults = .standard) {
        defaults.set(currentRevision, forKey: completionKey)
    }
}
