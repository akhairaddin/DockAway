import AppKit
@preconcurrency import ApplicationServices

// Typed readers for Accessibility attributes. Each read is a synchronous IPC
// round trip to the element's application, so set a messaging timeout on the
// application (or system-wide) element before walking its hierarchy.
extension AXUIElement {
    nonisolated func attributeValue(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    nonisolated func string(_ attribute: String) -> String? {
        attributeValue(attribute) as? String
    }

    nonisolated func bool(_ attribute: String) -> Bool? {
        (attributeValue(attribute) as? NSNumber)?.boolValue
    }

    nonisolated func url(_ attribute: String) -> URL? {
        attributeValue(attribute) as? URL
    }

    nonisolated func element(_ attribute: String) -> AXUIElement? {
        guard let value = attributeValue(attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    nonisolated func elements(_ attribute: String) -> [AXUIElement]? {
        guard let values = attributeValue(attribute) as? [AnyObject] else { return nil }
        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
    }

    nonisolated func point(_ attribute: String = kAXPositionAttribute) -> CGPoint? {
        guard let value = axValue(attribute) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    nonisolated func size(_ attribute: String = kAXSizeAttribute) -> CGSize? {
        guard let value = axValue(attribute) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    /// Position and size in global top-left-origin coordinates.
    nonisolated var frame: CGRect? {
        guard let position = point(), let size = size() else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// The WindowServer window number behind an AXWindow, or `nil` when the
    /// private lookup is unavailable or the element is not backed by a window.
    nonisolated var windowID: CGWindowID? {
        guard let getWindow = axGetWindowFunction else { return nil }
        var windowID: CGWindowID = 0
        guard getWindow(self, &windowID) == .success, windowID != 0 else { return nil }
        return windowID
    }

    nonisolated private func axValue(_ attribute: String) -> AXValue? {
        guard let value = attributeValue(attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXValue.self)
    }
}

private typealias AXGetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

// Resolved once; the symbol lives in HIServices, which AppKit already loads.
nonisolated private let axGetWindowFunction: AXGetWindowFunction? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
        return nil
    }
    return unsafeBitCast(symbol, to: AXGetWindowFunction.self)
}()

/// Cheap pre-checks shared by the event taps that react to Dock clicks.
@MainActor
enum DockHitTesting {
    private static var cachedProcessIdentifier: pid_t?

    /// True when `point` (global top-left coordinates) is within the Dock's
    /// edge band on any display. Use it before any Accessibility hit-test.
    static func pointIsNearDock(_ point: CGPoint) -> Bool {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let orientation = CFPreferencesCopyAppValue(
            "orientation" as CFString,
            "com.apple.dock" as CFString
        ) as? String ?? "bottom"

        for screen in NSScreen.screens {
            let frame = CGRect(
                x: screen.frame.minX,
                y: primaryTop - screen.frame.maxY,
                width: screen.frame.width,
                height: screen.frame.height
            )
            guard frame.insetBy(dx: -4, dy: -4).contains(point) else { continue }
            let margin: CGFloat = 140
            switch orientation {
            case "left":
                if point.x <= frame.minX + margin { return true }
            case "right":
                if point.x >= frame.maxX - margin { return true }
            default:
                if point.y >= frame.maxY - margin { return true }
            }
        }
        return false
    }

    static func dockProcessIdentifier() -> pid_t? {
        if let cachedProcessIdentifier,
           NSRunningApplication(processIdentifier: cachedProcessIdentifier)?.isTerminated == false {
            return cachedProcessIdentifier
        }
        let processIdentifier = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.apple.dock" && !$0.isTerminated
        }?.processIdentifier
        cachedProcessIdentifier = processIdentifier
        return processIdentifier
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func screen(withDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == displayID }
    }
}
