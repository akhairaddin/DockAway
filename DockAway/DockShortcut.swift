import Cocoa

// System Settings stores "Turn Dock hiding on/off" as symbolic hotkey 52.
// This is a read-only compatibility adapter, not a write to private settings.
// Unknown formats fail closed instead of posting an unrelated shortcut.
struct DockShortcut: Equatable {
    let keyCode: CGKeyCode
    let modifiers: CGEventFlags

    static let systemDefault = DockShortcut(
        keyCode: 2, modifiers: [.maskAlternate, .maskCommand]
    )

    static func current() -> DockShortcut? {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        let preferences = CFPreferencesCopyAppValue(
            "AppleSymbolicHotKeys" as CFString, domain
        )
        return decode(preferences)
    }

    static func decode(_ preferences: Any?) -> DockShortcut? {
        // macOS omits entries that still use the default binding.
        guard let preferences else { return systemDefault }
        guard let shortcuts = preferences as? [String: Any] else { return nil }
        guard let rawEntry = shortcuts["52"] else { return systemDefault }
        guard let entry = rawEntry as? [String: Any],
              let enabled = entry["enabled"] as? NSNumber,
              enabled.boolValue else { return nil }
        guard let rawValue = entry["value"] else { return systemDefault }
        guard let value = rawValue as? [String: Any],
              value["type"] as? String == "standard",
              let parameters = value["parameters"] as? [NSNumber],
              parameters.count == 3 else { return nil }
        let key = parameters[1].intValue
        let flags = parameters[2].int64Value
        // 65535 is an unassigned shortcut. Reject unknown modifier bits too.
        let allowed: CGEventFlags = [.maskShift, .maskControl, .maskAlternate,
                                     .maskCommand, .maskSecondaryFn]
        guard (0...127).contains(key), flags >= 0,
              UInt64(flags) & ~allowed.rawValue == 0 else { return nil }
        return DockShortcut(keyCode: CGKeyCode(key), modifiers: CGEventFlags(rawValue: UInt64(flags)))
    }
}
