import Foundation

/// The built-in keyboard's backlight timer, through CoreBrightness's private
/// KeyboardBrightnessClient: the same calls System Settings uses for "Turn
/// keyboard backlight off after inactivity". Every call fails quietly if a
/// future macOS removes it, and DockAway then hides the features that need it.
@MainActor
final class KeyboardBacklight {
    static let shared = KeyboardBacklight()

    private typealias BoolGetter = @convention(c) (AnyObject, Selector, UInt64) -> Bool
    private typealias TimeGetter = @convention(c) (AnyObject, Selector, UInt64) -> Double
    private typealias TimeSetter = @convention(c) (AnyObject, Selector, Double, UInt64) -> Bool
    private typealias DimmingSuspender = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool

    private static let requiredSelectors = [
        "copyKeyboardBacklightIDs", "isKeyboardBuiltIn:", "idleDimTimeForKeyboard:",
        "setIdleDimTime:forKeyboard:", "suspendIdleDimming:forKeyboard:"
    ]

    private let client: NSObject?
    private let keyboardID: UInt64?

    private init() {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        guard let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            client = nil
            keyboardID = nil
            return
        }
        let client = type.init()
        guard Self.requiredSelectors.allSatisfy({ client.responds(to: NSSelectorFromString($0)) }) else {
            self.client = nil
            keyboardID = nil
            return
        }
        self.client = client
        let identifiers = client.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?
            .takeRetainedValue() as? [NSNumber] ?? []
        let isBuiltIn = Self.function(client, "isKeyboardBuiltIn:", as: BoolGetter.self)
        keyboardID = identifiers.map(\.uint64Value).first {
            isBuiltIn(client, NSSelectorFromString("isKeyboardBuiltIn:"), $0)
        }
    }

    /// Whether this Mac has a built-in backlit keyboard DockAway can control.
    var isAvailable: Bool { keyboardID != nil }

    /// Seconds without input before macOS turns the light off. 0 means Never.
    var inactivityTimeout: TimeInterval? {
        guard let client, let keyboardID else { return nil }
        let name = "idleDimTimeForKeyboard:"
        return Self.function(client, name, as: TimeGetter.self)(client, NSSelectorFromString(name), keyboardID)
    }

    @discardableResult
    func setInactivityTimeout(_ seconds: TimeInterval) -> Bool {
        guard let client, let keyboardID else { return false }
        let name = "setIdleDimTime:forKeyboard:"
        return Self.function(client, name, as: TimeSetter.self)(client, NSSelectorFromString(name), seconds, keyboardID)
    }

    /// Ends a pause of macOS's inactivity timer. The pause is system-wide and
    /// outlives the app that set it.
    func resumeIdleDimming() {
        guard let client, let keyboardID else { return }
        let name = "suspendIdleDimming:forKeyboard:"
        _ = Self.function(client, name, as: DimmingSuspender.self)(client, NSSelectorFromString(name), false, keyboardID)
    }

    private static func function<Function>(_ client: NSObject, _ name: String, as type: Function.Type) -> Function {
        unsafeBitCast(client.method(for: NSSelectorFromString(name)), to: type)
    }
}
