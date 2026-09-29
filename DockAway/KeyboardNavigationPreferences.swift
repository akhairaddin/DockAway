import Cocoa
import Carbon

enum NavigationAction: String, CaseIterable, Codable {
    case openMenu = "openMenu"
    case moveUp = "up"
    case moveDown = "down"
    case moveLeft = "left"
    case moveRight = "right"
    case select = "select"
    case close = "close"

    var title: String {
        switch self {
        case .openMenu: return "Open DockAway Menu"
        case .moveUp: return "Move Up"
        case .moveDown: return "Move Down"
        case .moveLeft: return "Move Left"
        case .moveRight: return "Move Right"
        case .select: return "Select Desktop"
        case .close: return "Close Desktop"
        }
    }
}

enum NavigationHand: String, CaseIterable, Codable {
    case rightHand = "right"
    case leftHand = "left"

    var title: String {
        switch self {
        case .rightHand: return "Right Hand"
        case .leftHand: return "Left Hand"
        }
    }
}

struct KeyboardNavigationSettings: Codable, Equatable {
    private(set) var schemaVersion = 1
    // Right Hand Defaults: Open = Option + Up Arrow (⌥↑), Up = ↑, Down = ↓, Left = ←, Right = →, Select = Option (⌥) and Return, Close = / and Delete
    var rightOpenKey: UInt16 = 126
    var rightOpenModifiers: UInt32 = UInt32(optionKey)
    var rightUp: UInt16 = 126
    var rightDown: UInt16 = 125
    var rightLeft: UInt16 = 123
    var rightRight: UInt16 = 124
    var rightSelect: UInt16 = 61
    var rightSelectSecondary: UInt16 = 36
    var rightClose: UInt16 = 44
    var rightCloseSecondary: UInt16 = 51
    var rightCloseSecondaryModifiers: UInt32 = 0

    // Left Hand Defaults: Open = Option + Shift + W (⌥⇧W), Up = W, Down = S, Left = A, Right = D, Select = E, Close = Q
    var leftOpenKey: UInt16 = 13
    var leftOpenModifiers: UInt32 = UInt32(optionKey | shiftKey)
    var leftUp: UInt16 = 13
    var leftDown: UInt16 = 1
    var leftLeft: UInt16 = 0
    var leftRight: UInt16 = 2
    var leftSelect: UInt16 = 14
    var leftClose: UInt16 = 12

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rightOpenKey = try container.decodeIfPresent(UInt16.self, forKey: .rightOpenKey) ?? 126
        rightOpenModifiers = try container.decodeIfPresent(UInt32.self, forKey: .rightOpenModifiers) ?? UInt32(optionKey)
        rightUp = try container.decodeIfPresent(UInt16.self, forKey: .rightUp) ?? 126
        rightDown = try container.decodeIfPresent(UInt16.self, forKey: .rightDown) ?? 125
        rightLeft = try container.decodeIfPresent(UInt16.self, forKey: .rightLeft) ?? 123
        rightRight = try container.decodeIfPresent(UInt16.self, forKey: .rightRight) ?? 124
        rightSelect = try container.decodeIfPresent(UInt16.self, forKey: .rightSelect) ?? 61
        rightSelectSecondary = try container.decodeIfPresent(UInt16.self, forKey: .rightSelectSecondary) ?? 36
        let savedVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        rightClose = try container.decodeIfPresent(UInt16.self, forKey: .rightClose) ?? 44
        // Only the original, single-close-slot schema used Delete as a legacy
        // default. Modern explicit bindings, including Delete, must round-trip.
        if savedVersion == 0 && !container.contains(.rightCloseSecondary) && rightClose == 51 {
            rightClose = 44
        }
        rightCloseSecondary = try container.decodeIfPresent(UInt16.self, forKey: .rightCloseSecondary) ?? 51
        rightCloseSecondaryModifiers = try container.decodeIfPresent(UInt32.self, forKey: .rightCloseSecondaryModifiers) ?? 0

        leftOpenKey = try container.decodeIfPresent(UInt16.self, forKey: .leftOpenKey) ?? 13
        leftOpenModifiers = try container.decodeIfPresent(UInt32.self, forKey: .leftOpenModifiers) ?? UInt32(optionKey | shiftKey)
        leftUp = try container.decodeIfPresent(UInt16.self, forKey: .leftUp) ?? 13
        leftDown = try container.decodeIfPresent(UInt16.self, forKey: .leftDown) ?? 1
        leftLeft = try container.decodeIfPresent(UInt16.self, forKey: .leftLeft) ?? 0
        leftRight = try container.decodeIfPresent(UInt16.self, forKey: .leftRight) ?? 2
        leftSelect = try container.decodeIfPresent(UInt16.self, forKey: .leftSelect) ?? 14
        leftClose = try container.decodeIfPresent(UInt16.self, forKey: .leftClose) ?? 12
    }

    func shortcut(for hand: NavigationHand, action: NavigationAction, slot: Int = 1) -> (keyCode: UInt16, modifiers: UInt32) {
        if hand == .rightHand && action == .select && slot == 2 {
            return (rightSelectSecondary, 0)
        }
        if hand == .rightHand && action == .close && slot == 2 {
            return (rightCloseSecondary, rightCloseSecondaryModifiers)
        }
        switch (hand, action) {
        case (.rightHand, .openMenu): return (rightOpenKey, rightOpenModifiers)
        case (.rightHand, .moveUp): return (rightUp, 0)
        case (.rightHand, .moveDown): return (rightDown, 0)
        case (.rightHand, .moveLeft): return (rightLeft, 0)
        case (.rightHand, .moveRight): return (rightRight, 0)
        case (.rightHand, .select): return (rightSelect, 0)
        case (.rightHand, .close): return (rightClose, 0)

        case (.leftHand, .openMenu): return (leftOpenKey, leftOpenModifiers)
        case (.leftHand, .moveUp): return (leftUp, 0)
        case (.leftHand, .moveDown): return (leftDown, 0)
        case (.leftHand, .moveLeft): return (leftLeft, 0)
        case (.leftHand, .moveRight): return (leftRight, 0)
        case (.leftHand, .select): return (leftSelect, 0)
        case (.leftHand, .close): return (leftClose, 0)
        }
    }

    mutating func setShortcut(keyCode: UInt16, modifiers: UInt32, for hand: NavigationHand, action: NavigationAction, slot: Int = 1) {
        if hand == .rightHand && action == .select && slot == 2 {
            rightSelectSecondary = keyCode
            return
        }
        if hand == .rightHand && action == .close && slot == 2 {
            rightCloseSecondary = keyCode
            rightCloseSecondaryModifiers = modifiers
            return
        }
        switch (hand, action) {
        case (.rightHand, .openMenu):
            rightOpenKey = keyCode
            rightOpenModifiers = modifiers
        case (.rightHand, .moveUp): rightUp = keyCode
        case (.rightHand, .moveDown): rightDown = keyCode
        case (.rightHand, .moveLeft): rightLeft = keyCode
        case (.rightHand, .moveRight): rightRight = keyCode
        case (.rightHand, .select): rightSelect = keyCode
        case (.rightHand, .close): rightClose = keyCode

        case (.leftHand, .openMenu):
            leftOpenKey = keyCode
            leftOpenModifiers = modifiers
        case (.leftHand, .moveUp): leftUp = keyCode
        case (.leftHand, .moveDown): leftDown = keyCode
        case (.leftHand, .moveLeft): leftLeft = keyCode
        case (.leftHand, .moveRight): leftRight = keyCode
        case (.leftHand, .select): leftSelect = keyCode
        case (.leftHand, .close): leftClose = keyCode
        }
    }

    func keyCode(for hand: NavigationHand, action: NavigationAction, slot: Int = 1) -> UInt16 {
        shortcut(for: hand, action: action, slot: slot).keyCode
    }

    mutating func setKeyCode(_ code: UInt16, for hand: NavigationHand, action: NavigationAction, slot: Int = 1) {
        setShortcut(
            keyCode: code,
            modifiers: action == .openMenu ? (hand == .rightHand ? rightOpenModifiers : leftOpenModifiers) : 0,
            for: hand,
            action: action,
            slot: slot
        )
    }

    func isUp(_ code: UInt16) -> Bool {
        (KeyboardNavigationPreferences.isRightHandEnabled && rightUp != KeyboardNavigationPreferences.unboundKeyCode && code == rightUp) ||
        (KeyboardNavigationPreferences.isLeftHandEnabled && leftUp != KeyboardNavigationPreferences.unboundKeyCode && code == leftUp)
    }
    func isDown(_ code: UInt16) -> Bool {
        (KeyboardNavigationPreferences.isRightHandEnabled && rightDown != KeyboardNavigationPreferences.unboundKeyCode && code == rightDown) ||
        (KeyboardNavigationPreferences.isLeftHandEnabled && leftDown != KeyboardNavigationPreferences.unboundKeyCode && code == leftDown)
    }
    func isLeft(_ code: UInt16) -> Bool {
        (KeyboardNavigationPreferences.isRightHandEnabled && rightLeft != KeyboardNavigationPreferences.unboundKeyCode && code == rightLeft) ||
        (KeyboardNavigationPreferences.isLeftHandEnabled && leftLeft != KeyboardNavigationPreferences.unboundKeyCode && code == leftLeft)
    }
    func isRight(_ code: UInt16) -> Bool {
        (KeyboardNavigationPreferences.isRightHandEnabled && rightRight != KeyboardNavigationPreferences.unboundKeyCode && code == rightRight) ||
        (KeyboardNavigationPreferences.isLeftHandEnabled && leftRight != KeyboardNavigationPreferences.unboundKeyCode && code == leftRight)
    }
    func isSelect(_ code: UInt16) -> Bool {
        (KeyboardNavigationPreferences.isRightHandEnabled && rightSelect != KeyboardNavigationPreferences.unboundKeyCode && code == rightSelect) ||
        (KeyboardNavigationPreferences.isRightHandEnabled && rightSelectSecondary != KeyboardNavigationPreferences.unboundKeyCode && code == rightSelectSecondary) ||
        (KeyboardNavigationPreferences.isLeftHandEnabled && leftSelect != KeyboardNavigationPreferences.unboundKeyCode && code == leftSelect)
    }
    func isClose(_ code: UInt16) -> Bool {
        (KeyboardNavigationPreferences.isRightHandEnabled && rightClose != KeyboardNavigationPreferences.unboundKeyCode && code == rightClose) ||
        (KeyboardNavigationPreferences.isRightHandEnabled && rightCloseSecondary != KeyboardNavigationPreferences.unboundKeyCode && code == rightCloseSecondary) ||
        (KeyboardNavigationPreferences.isLeftHandEnabled && leftClose != KeyboardNavigationPreferences.unboundKeyCode && code == leftClose)
    }

    var allKeyCodes: Set<Int64> {
        var keys: Set<Int64> = []
        var raw: [UInt16] = []
        if KeyboardNavigationPreferences.isRightHandEnabled {
            raw += [rightOpenKey, rightUp, rightDown, rightLeft, rightRight, rightSelect, rightSelectSecondary, rightClose, rightCloseSecondary]
        }
        if KeyboardNavigationPreferences.isLeftHandEnabled {
            raw += [leftOpenKey, leftUp, leftDown, leftLeft, leftRight, leftSelect, leftClose]
        }
        for k in raw where k != KeyboardNavigationPreferences.unboundKeyCode {
            keys.insert(Int64(k))
        }
        return keys
    }

    var closeKeyCodes: Set<Int64> {
        var keys: Set<Int64> = []
        let raw = (KeyboardNavigationPreferences.isRightHandEnabled ? [rightClose, rightCloseSecondary] : [])
            + (KeyboardNavigationPreferences.isLeftHandEnabled ? [leftClose] : [])
        for k in raw where k != KeyboardNavigationPreferences.unboundKeyCode {
            keys.insert(Int64(k))
        }
        return keys
    }

    var selectKeyCodes: Set<Int64> {
        var keys: Set<Int64> = []
        let raw = (KeyboardNavigationPreferences.isRightHandEnabled ? [rightSelect, rightSelectSecondary] : [])
            + (KeyboardNavigationPreferences.isLeftHandEnabled ? [leftSelect] : [])
        for k in raw where k != KeyboardNavigationPreferences.unboundKeyCode {
            keys.insert(Int64(k))
        }
        return keys
    }
}

final class KeyboardNavigationPreferences {
    static let unboundKeyCode: UInt16 = 65535
    static let settingsKey = "desktopKeyboardNavigationSettings"
    static let enabledKey = "desktopKeyboardNavigationEnabled"
    static let rightHandEnabledKey = "desktopKeyboardNavigationRightHandEnabled"
    static let leftHandEnabledKey = "desktopKeyboardNavigationLeftHandEnabled"

    static var isEnabled: Bool {
        get {
            let masterEnabled = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
            return masterEnabled && (isRightHandEnabled || isLeftHandEnabled)
        }
        set {
            isRightHandEnabled = newValue
            isLeftHandEnabled = newValue
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    static func setHandEnabled(_ hand: NavigationHand, enabled: Bool) {
        switch hand {
        case .rightHand: isRightHandEnabled = enabled
        case .leftHand: isLeftHandEnabled = enabled
        }
        UserDefaults.standard.set(isRightHandEnabled || isLeftHandEnabled, forKey: enabledKey)
    }

    // Keep both hands enabled for existing installs so adding the per-hand
    // controls does not silently change anyone's current keyboard workflow.
    static var isRightHandEnabled: Bool {
        get { UserDefaults.standard.object(forKey: rightHandEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: rightHandEnabledKey) }
    }

    static var isLeftHandEnabled: Bool {
        get { UserDefaults.standard.object(forKey: leftHandEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: leftHandEnabledKey) }
    }

    static func isHandEnabled(_ hand: NavigationHand) -> Bool {
        switch hand {
        case .rightHand: return isRightHandEnabled
        case .leftHand: return isLeftHandEnabled
        }
    }

    // Key handlers read the settings on every keystroke. Decode only when the
    // stored bytes change, so any writer of the defaults key is still honored.
    private static var cachedCurrent: (data: Data?, settings: KeyboardNavigationSettings)?

    static var current: KeyboardNavigationSettings {
        get {
            let data = UserDefaults.standard.data(forKey: settingsKey)
            if let cachedCurrent, cachedCurrent.data == data {
                return cachedCurrent.settings
            }
            let settings = data.flatMap {
                try? JSONDecoder().decode(KeyboardNavigationSettings.self, from: $0)
            } ?? KeyboardNavigationSettings()
            cachedCurrent = (data, settings)
            return settings
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: settingsKey)
            }
        }
    }

    static func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: settingsKey)
    }

    static func displayName(for keyCode: UInt16, modifiers: UInt32 = 0) -> String {
        if keyCode == unboundKeyCode {
            return "None"
        }
        var modString = ""
        if (modifiers & UInt32(controlKey)) != 0 { modString += "⌃" }
        if (modifiers & UInt32(optionKey)) != 0 { modString += "⌥" }
        if (modifiers & UInt32(shiftKey)) != 0 { modString += "⇧" }
        if (modifiers & UInt32(cmdKey)) != 0 { modString += "⌘" }

        return modString + keySymbolName(for: keyCode)
    }

    private static func keySymbolName(for keyCode: UInt16) -> String {
        switch keyCode {
        // Arrows
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        // Return / Enter
        case 36: return "↩ Return"
        case 76: return "⌤ Enter"
        // Standalone Option keys
        case 58, 61: return "⌥ Option"
        // Deletion
        case 51: return "⌫ Delete"
        case 117: return "⌦ Fwd Del"
        // Whitespace & navigation
        case 49: return "Space"
        case 48: return "⇥ Tab"
        case 53: return "⎋ Esc"
        // Letters (QWERTY keycodes)
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 31: return "O"
        case 32: return "U"
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 40: return "K"
        case 45: return "N"
        case 46: return "M"
        // Numbers
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 23: return "5"
        case 22: return "6"
        case 26: return "7"
        case 28: return "8"
        case 25: return "9"
        case 29: return "0"
        // Symbols
        case 24: return "="
        case 27: return "-"
        case 30: return "]"
        case 33: return "["
        case 39: return "'"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 47: return "."
        case 50: return "`"
        default:
            return "Key \(keyCode)"
        }
    }
}
