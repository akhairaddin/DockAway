import AppKit

/// One session-level CGEvent tap whose source runs on the main run loop.
///
/// The handler returns `true` to consume an event. It also receives
/// `.tapDisabledByTimeout` / `.tapDisabledByUserInput`, so an owner can reset
/// per-gesture state; by default the tap is re-enabled before that call.
@MainActor
final class EventTap {
    typealias Handler = (CGEventType, CGEvent) -> Bool

    /// Marks a click DockAway held back and then sent on unchanged, so taps
    /// that skip synthetic clicks still treat it as the person's own.
    nonisolated static let replayedClickMarker: Int64 = 0x464F4345

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// The tap's place in the event stream, which macOS hands to every call.
    private var proxy: CGEventTapProxy?
    private let modes: [CFRunLoopMode]
    private let reenablesWhenDisabled: Bool
    private let handler: Handler

    /// Returns `nil` when macOS refuses the tap, usually because DockAway
    /// lacks Accessibility or Input Monitoring access.
    /// `rawEventTypes` adds event types with no `CGEventType` name, such as
    /// the trackpad's pressure reports.
    init?(
        events: [CGEventType],
        rawEventTypes: [UInt32] = [],
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

        let mask = (events.map(\.rawValue) + rawEventTypes).reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                // The source is only ever added to the main run loop. Handlers
                // may release their tap, so keep it alive through the dispatch.
                return MainActor.assumeIsolated {
                    let tap = Unmanaged<EventTap>.fromOpaque(context).takeUnretainedValue()
                    return withExtendedLifetime(tap) { tap.dispatch(type, event, from: proxy) }
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
        proxy = nil
    }

    /// Sends an event on from this tap's place in the event stream, such as a
    /// click it held back. Taps and listeners ahead of it, which already saw
    /// the original, don't see it a second time; a click-sound app listening
    /// to the hardware would otherwise play it twice. Before this tap has seen
    /// any event, it goes in at the session instead.
    func post(_ event: CGEvent) {
        if let proxy {
            event.tapPostEvent(proxy)
        } else {
            event.post(tap: .cgSessionEventTap)
        }
    }

    private func dispatch(_ type: CGEventType, _ event: CGEvent, from proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        self.proxy = proxy
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput,
           reenablesWhenDisabled, let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return handler(type, event) ? nil : Unmanaged.passUnretained(event)
    }
}
