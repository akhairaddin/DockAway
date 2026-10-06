import Foundation

/// Hides macOS's floating screenshot thumbnail while Copy Instantly is on.
/// macOS keeps a screenshot unsaved, in memory, until its thumbnail goes away,
/// so with the thumbnail showing DockAway can only copy it seconds later.
@MainActor
final class ScreenshotThumbnailSuppression {
    static let preferenceKey = "CopyScreenshotsInstantly"
    /// The thumbnail setting found before DockAway hid it: "true", "false", or "unset".
    static let savedSettingKey = "ScreenshotThumbnailSettingBeforeInstantCopy"
    private static let thumbnailKey = "show-thumbnail" as CFString

    private let domain: CFString
    private let defaults: UserDefaults

    /// Tests pass an isolated domain and defaults instead of the user's real settings.
    init(domain: String = "com.apple.screencapture", defaults: UserDefaults = .standard) {
        self.domain = domain as CFString
        self.defaults = defaults
    }

    /// Whether the user asked for instant copies.
    var isRequested: Bool {
        get { defaults.bool(forKey: Self.preferenceKey) }
        set { defaults.set(newValue, forKey: Self.preferenceKey) }
    }

    /// Whether DockAway currently has the thumbnail hidden.
    var isHiding: Bool { defaults.string(forKey: Self.savedSettingKey) != nil }

    /// Hides or restores the thumbnail to match the request. If the user turned
    /// the thumbnail back on while DockAway had it hidden, Copy Instantly turns
    /// off instead, leaving their choice in place.
    func update(clipboardEnabled: Bool) {
        if isHiding, showsThumbnail() != false {
            defaults.removeObject(forKey: Self.savedSettingKey)
            isRequested = false
            return
        }
        if isRequested && clipboardEnabled {
            hide()
        } else {
            restore()
        }
    }

    /// Puts back the thumbnail setting found before DockAway hid it.
    func restore() {
        guard let saved = defaults.string(forKey: Self.savedSettingKey) else { return }
        defaults.removeObject(forKey: Self.savedSettingKey)
        // A setting the user has changed since stays as they left it.
        guard showsThumbnail() == false else { return }
        setShowsThumbnail(saved == "unset" ? nil : saved == "true")
    }

    private func hide() {
        let current = showsThumbnail()
        if !isHiding {
            defaults.set(current.map { $0 ? "true" : "false" } ?? "unset", forKey: Self.savedSettingKey)
        }
        if current != false { setShowsThumbnail(false) }
    }

    /// nil when unset; macOS shows the thumbnail by default.
    private func showsThumbnail() -> Bool? {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(Self.thumbnailKey, domain) as? Bool
    }

    private func setShowsThumbnail(_ value: Bool?) {
        CFPreferencesSetAppValue(Self.thumbnailKey, value.map { $0 as CFBoolean }, domain)
        CFPreferencesAppSynchronize(domain)
    }
}
