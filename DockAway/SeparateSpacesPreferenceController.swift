import AppKit
import CoreFoundation

/// Controls the current user's macOS setting, not a DockAway preference.
/// The preference key is undocumented; changing it takes effect after logout.
@MainActor
final class SeparateSpacesPreferenceController {
    enum PreferenceRead: Equatable {
        case value(Bool)
        case missing
        case unavailable
    }

    struct Snapshot: Equatable {
        let configuredEnabled: Bool
        let appliedEnabled: Bool
        let isAvailable: Bool
        let isManaged: Bool

        var canEdit: Bool { isAvailable && !isManaged }
        var requiresLogon: Bool { isAvailable && configuredEnabled != appliedEnabled }
    }

    enum ChangeResult: Equatable {
        case changed
        case unchanged
        case managed
        case unavailable
        case failed
    }

    struct Environment {
        var readSpansDisplays: () -> PreferenceRead
        var writeSpansDisplays: (Bool) -> Bool
        var readAppliedSeparateSpaces: () -> Bool
        var isManaged: () -> Bool
        var publishChange: () -> Void = {}
        var observeChanges: @MainActor (@escaping @MainActor () -> Void) -> SeparateSpacesPreferenceObservation? = { _ in nil }

        static var live: Self {
            preferences(domain: "com.apple.spaces", readAppliedSeparateSpaces: {
                NSScreen.screensHaveSeparateSpaces
            }, publishChange: {
                // The Desktop & Dock pane listens for this preference-change
                // notification. Flushing a CFPreferences domain alone does
                // not invalidate its already-open settings model.
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("com.apple.dock.prefchanged"),
                    object: nil, userInfo: nil, deliverImmediately: true
                )
            })
        }

        // An isolated domain lets tests verify the real CFPreferences backend
        // and persistence without writing the user's actual Spaces setting.
        static func preferences(domain preferenceDomain: String,
                                readAppliedSeparateSpaces: @escaping () -> Bool,
                                publishChange: @escaping () -> Void = {}) -> Self {
            let domain = preferenceDomain as CFString
            let key = "spans-displays" as CFString
            return Self(
                readSpansDisplays: {
                    // CopyAppValue searches the application's full domain
                    // list. Refresh that same list, not just one storage domain.
                    guard CFPreferencesAppSynchronize(domain) else { return .unavailable }
                    guard let value = CFPreferencesCopyAppValue(key, domain) else { return .missing }
                    guard CFGetTypeID(value) == CFBooleanGetTypeID(),
                          let spansDisplays = value as? Bool else { return .unavailable }
                    return .value(spansDisplays)
                },
                writeSpansDisplays: { spansDisplays in
                    guard !CFPreferencesAppValueIsForced(key, domain) else { return false }
                    let previousValue = CFPreferencesCopyValue(key, domain,
                                                              kCFPreferencesCurrentUser,
                                                              kCFPreferencesAnyHost)
                    CFPreferencesSetAppValue(key, spansDisplays ? kCFBooleanTrue : kCFBooleanFalse, domain)
                    guard CFPreferencesAppSynchronize(domain) else {
                        // Do not leave an unsaved, dirty value queued in our
                        // preferences cache after reporting a failed write.
                        CFPreferencesSetAppValue(key, previousValue, domain)
                        CFPreferencesAppSynchronize(domain)
                        return false
                    }
                    return true
                },
                readAppliedSeparateSpaces: readAppliedSeparateSpaces,
                isManaged: { CFPreferencesAppValueIsForced(key, domain) },
                publishChange: publishChange,
                observeChanges: { onChange in
                    SeparateSpacesPreferenceObservation(domain: preferenceDomain, onChange: onChange)
                }
            )
        }
    }

    private let environment: Environment
    private var observation: SeparateSpacesPreferenceObservation?
    private var lastConfirmedEnabled: Bool?
    private(set) var snapshot: Snapshot

    init(environment: Environment? = nil) {
        let environment = environment ?? .live
        self.environment = environment
        let applied = environment.readAppliedSeparateSpaces()
        snapshot = Snapshot(configuredEnabled: applied, appliedEnabled: applied,
                            isAvailable: false, isManaged: false)
        refresh()
    }

    func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        stopObserving()
        observation = environment.observeChanges(onChange)
    }

    func stopObserving() {
        observation?.invalidate()
        observation = nil
    }

    @discardableResult
    func refresh() -> Snapshot {
        updateSnapshot(from: environment.readSpansDisplays())
        return snapshot
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> ChangeResult {
        // Recheck before each click: a profile or System Settings may have
        // changed since this row was last presented.
        refresh()
        guard !snapshot.isManaged else { return .managed }
        guard snapshot.isAvailable else { return .unavailable }
        guard snapshot.configuredEnabled != enabled else { return .unchanged }

        let synchronized = environment.writeSpansDisplays(!enabled)
        let observed = environment.readSpansDisplays()
        updateSnapshot(from: observed)
        // A fallback to the applied-session value is not proof of a saved
        // write. Require the actual stored Boolean to match the request.
        guard synchronized, observed == .value(!enabled) else { return .failed }
        environment.publishChange()
        return .changed
    }

    private func updateSnapshot(from observed: PreferenceRead) {
        let applied = environment.readAppliedSeparateSpaces()
        let configured: Bool
        let available: Bool
        switch observed {
        case .value(let spansDisplays):
            configured = !spansDisplays
            available = true
        case .missing:
            // A missing default must not become a false-looking switch or
            // cause onboarding to write a preference without a user's click.
            configured = applied
            available = true
        case .unavailable:
            configured = lastConfirmedEnabled ?? applied
            available = false
        }
        if available { lastConfirmedEnabled = configured }
        snapshot = Snapshot(configuredEnabled: configured, appliedEnabled: applied,
                            isAvailable: available, isManaged: environment.isManaged())
    }
}
