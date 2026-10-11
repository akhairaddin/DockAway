import Foundation

/// The menu bar shows one desktop count, or one per display. Each layout
/// remembers its own indicator look and switches.
enum MenuBarIndicatorLayout {
    case singleDisplay
    case multipleDisplays

    init(indicatorCount: Int) {
        self = indicatorCount > 1 ? .multipleDisplays : .singleDisplay
    }
}

enum DesktopIndicatorPreference {
    /// Two or more displays, and every layout before they were separate.
    static let enabledKey = "desktopIndicatorEnabled"
    static let singleDisplayEnabledKey = "singleDisplayDesktopIndicatorEnabled"

    static func isEnabled(for layout: MenuBarIndicatorLayout = .multipleDisplays,
                          in defaults: UserDefaults = .standard) -> Bool {
        if layout == .singleDisplay {
            return defaults.object(forKey: singleDisplayEnabledKey) as? Bool ?? isEnabled(in: defaults)
        }
        if let saved = defaults.object(forKey: enabledKey) as? Bool { return saved }
        // Preserve the former None choice when migrating to the explicit toggle.
        return (defaults.object(forKey: "DesktopIndicatorAppearance") as? Int) != 0
    }

    static func setEnabled(_ enabled: Bool, for layout: MenuBarIndicatorLayout = .multipleDisplays,
                           in defaults: UserDefaults = .standard) {
        if layout == .singleDisplay {
            defaults.set(enabled, forKey: singleDisplayEnabledKey)
            return
        }
        defaults.set(enabled, forKey: enabledKey)
        defaults.set(enabled ? 1 : 0, forKey: "DesktopIndicatorAppearance")
    }
}

/// The menu bar item shows the desktop indicator, the Dock arrows, or both,
/// never neither, so there's always something to click. Turning one off while
/// the other is already off turns the other back on, within each layout.
enum MenuBarIndicatorPreference {
    /// Two or more displays, and every layout before they were separate.
    static let dockIndicatorKey = "showMenuBarDockIndicator"
    static let singleDisplayDockIndicatorKey = "singleDisplayDockIndicatorEnabled"

    static func isDockIndicatorEnabled(for layout: MenuBarIndicatorLayout = .multipleDisplays,
                                       in defaults: UserDefaults = .standard) -> Bool {
        if layout == .singleDisplay {
            return defaults.object(forKey: singleDisplayDockIndicatorKey) as? Bool
                ?? isDockIndicatorEnabled(in: defaults)
        }
        return defaults.object(forKey: dockIndicatorKey) as? Bool ?? true
    }

    static func setDesktopIndicatorEnabled(_ enabled: Bool, for layout: MenuBarIndicatorLayout = .multipleDisplays,
                                           in defaults: UserDefaults = .standard) {
        DesktopIndicatorPreference.setEnabled(enabled, for: layout, in: defaults)
        if !enabled, !isDockIndicatorEnabled(for: layout, in: defaults) {
            setDockIndicator(true, for: layout, in: defaults)
        }
    }

    static func setDockIndicatorEnabled(_ enabled: Bool, for layout: MenuBarIndicatorLayout = .multipleDisplays,
                                        in defaults: UserDefaults = .standard) {
        setDockIndicator(enabled, for: layout, in: defaults)
        if !enabled, !DesktopIndicatorPreference.isEnabled(for: layout, in: defaults) {
            DesktopIndicatorPreference.setEnabled(true, for: layout, in: defaults)
        }
    }

    private static func setDockIndicator(_ enabled: Bool, for layout: MenuBarIndicatorLayout,
                                         in defaults: UserDefaults) {
        defaults.set(enabled, forKey: layout == .singleDisplay ? singleDisplayDockIndicatorKey : dockIndicatorKey)
    }

    /// Repairs a saved state with both indicators off, in either layout.
    static func ensureOneIsShown(in defaults: UserDefaults = .standard) {
        for layout in [MenuBarIndicatorLayout.singleDisplay, .multipleDisplays]
        where !DesktopIndicatorPreference.isEnabled(for: layout, in: defaults)
            && !isDockIndicatorEnabled(for: layout, in: defaults) {
            setDockIndicator(true, for: layout, in: defaults)
        }
    }

    /// Gives the one-display layout its own switches, starting from the ones
    /// shared by every layout before. Saved switches are never overwritten.
    static func separateSingleDisplayLayout(in defaults: UserDefaults = .standard) {
        if defaults.object(forKey: DesktopIndicatorPreference.singleDisplayEnabledKey) == nil {
            DesktopIndicatorPreference.setEnabled(DesktopIndicatorPreference.isEnabled(in: defaults),
                                                  for: .singleDisplay, in: defaults)
        }
        if defaults.object(forKey: singleDisplayDockIndicatorKey) == nil {
            setDockIndicator(isDockIndicatorEnabled(in: defaults), for: .singleDisplay, in: defaults)
        }
    }
}

/// The one-display layout's indicator look, kept apart from the All Displays
/// style and per-display styles used with two or more displays.
enum SingleDisplayIndicatorStyle {
    /// A JSON-encoded DesktopIndicatorTextStyle, like displayIndicatorStyles.
    static let key = "singleDisplayIndicatorStyle"

    /// Which per-display style the one-display look starts from when it's
    /// first separated: the built-in display's, else the only connected
    /// display's. Nil means the All Displays style.
    static func startingOverrideKey(overrideKeys: Set<String>, builtInKey: String?,
                                    onlineKeys: [String]) -> String? {
        if let builtInKey, overrideKeys.contains(builtInKey) { return builtInKey }
        if onlineKeys.count == 1, let only = onlineKeys.first, overrideKeys.contains(only) { return only }
        return nil
    }
}

/// Defaults for the Menubar Dock/Desktop Indicator menu, including its Desktop
/// Change Pill and Desktop Manager number style. A fresh install starts with
/// these. An install that was set up with an earlier version keeps the look
/// it already had for anything it never changed.
enum MenuBarIndicatorDefaults {
    static let revisionKey = "menuBarIndicatorDefaultsRevision"
    static let currentRevision = 1

    // Read by AppDelegate's desktop indicator style, DesktopNumberStylePreference
    // and DesktopChangeTooltip.
    static let badgeKey = "DesktopIndicatorTextBadge"
    static let accentKey = "DesktopIndicatorTextAccent"
    static let fillActiveDisplayCountKey = "fillActiveDisplayCount"
    static let numberStyleKey = "desktopNumberIndicatorStyle"
    static let desktopChangePillKey = "showDesktopChangeTooltip"
    static let desktopChangePillAppIconsKey = "desktopChangeTooltipShowsAppIcons"

    /// A filled desktop count without the accent color, filled only on the
    /// active display; accent pill numbers in Desktop Manager; and the Desktop
    /// Change Pill with app icons.
    static var values: [String: Any] {
        [
            badgeKey: 1, // Filled
            accentKey: false,
            fillActiveDisplayCountKey: true,
            numberStyleKey: "accentPill",
            desktopChangePillKey: true,
            desktopChangePillAppIconsKey: true
        ]
    }

    /// What earlier versions showed for each of these when left unchanged.
    static func previousValues(in defaults: UserDefaults) -> [String: Any] {
        [
            // Before the badge had its own setting, it followed the old
            // appearance menu, where 4 was the badge.
            badgeKey: defaults.integer(forKey: "DesktopIndicatorAppearance") == 4 ? 1 : 0,
            accentKey: true,
            fillActiveDisplayCountKey: false,
            numberStyleKey: "subtleShadow",
            desktopChangePillKey: false,
            desktopChangePillAppIconsKey: false
        ]
    }

    /// Call once at launch, before anything reads these settings.
    static func prepare(in defaults: UserDefaults = .standard) {
        keepEarlierLook(in: defaults)
        defaults.register(defaults: values)
    }

    /// Saves the earlier look for each setting an earlier install never
    /// changed, once. It must run before the new values are registered, which
    /// would make every setting look changed.
    static func keepEarlierLook(in defaults: UserDefaults) {
        guard defaults.integer(forKey: revisionKey) < currentRevision else { return }
        if isExistingInstall(defaults) {
            for (key, value) in previousValues(in: defaults) where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(currentRevision, forKey: revisionKey)
    }

    /// Someone who finished setting up an earlier version.
    static func isExistingInstall(_ defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: "PermissionSetupCompleted")
            || defaults.object(forKey: "CompletedMajorReleaseOnboarding") != nil
    }
}
