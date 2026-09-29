import AppKit

/// One session-level CGEvent tap whose source runs on the main run loop.
///
/// The handler returns `true` to consume an event. It also receives
/// `.tapDisabledByTimeout` / `.tapDisabledByUserInput`, so an owner can reset
/// per-gesture state; by default the tap is re-enabled before that call.
@MainActor
final class EventTap {
    typealias Handler = (CGEventType, CGEvent) -> Bool

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let modes: [CFRunLoopMode]
    private let reenablesWhenDisabled: Bool
    private let handler: Handler

    /// Returns `nil` when macOS refuses the tap, usually because DockAway
    /// lacks Accessibility or Input Monitoring access.
    init?(
        events: [CGEventType],
        includeEventTracking: Bool = false,
        reenablesWhenDisabled: Bool = true,
        handler: @escaping Handler
    ) {
        self.handler = handler
        self.reenablesWhenDisabled = reenablesWhenDisabled
        var modes: [CFRunLoopMode] = [.commonModes]
        if includeEventTracking {
            // NSMenu and popover tracking loops do not always run common modes.
            modes.append(CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
        }
        self.modes = modes

        let mask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                // The source is only ever added to the main run loop. Handlers
                // may release their tap, so keep it alive through the dispatch.
                return MainActor.assumeIsolated {
                    let tap = Unmanaged<EventTap>.fromOpaque(context).takeUnretainedValue()
                    return withExtendedLifetime(tap) { tap.dispatch(type, event) }
                }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        for mode in modes {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, mode)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    isolated deinit {
        invalidate()
    }

    func invalidate() {
        if let source {
            for mode in modes {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, mode)
            }
        }
        source = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
    }

    private func dispatch(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput,
           reenablesWhenDisabled, let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return handler(type, event) ? nil : Unmanaged.passUnretained(event)
    }
}
