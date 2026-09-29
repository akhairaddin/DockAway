import AppKit

enum DockAwayTheme: String, CaseIterable {
    case auto, light, dark

    static let preferenceKey = "dockAwayTheme"

    static var current: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .auto
    }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .auto: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    @MainActor func apply(to menu: NSMenu) {
        menu.appearance = appearance
        for item in menu.items {
            item.view?.appearance = appearance
            if let submenu = item.submenu { apply(to: submenu) }
        }
    }
}
