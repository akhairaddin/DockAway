import Foundation

/// Reads raw trackpad contacts from the private MultitouchSupport framework —
/// the only way to know fingers are resting on the trackpad before any motion
/// has happened. AppKit does not emit a gesture event until a swipe starts.
///
/// Everything is resolved with dlopen/dlsym at runtime rather than linked at
/// build time. If Apple moves the framework or renames a symbol, `start` fails,
/// logs, and the app carries on without the feature instead of refusing to
/// launch. That matters on a beta OS.
///
/// This is private API. It is not reviewed, not documented, and not promised to
/// exist in the next build of macOS.
final class MultitouchWatcher {

    typealias FingerCountHandler = (Int) -> Void

    private typealias MTDeviceRef = UnsafeMutableRawPointer
    private typealias MTContactCallback =
        @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias MTDeviceCreateDefaultFn = @convention(c) () -> MTDeviceRef?
    private typealias MTRegisterFn = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
    private typealias MTDeviceStartFn = @convention(c) (MTDeviceRef, Int32) -> Void
    private typealias MTDeviceStopFn = @convention(c) (MTDeviceRef) -> Void

    private(set) var isRunning = false
    private var libHandle: UnsafeMutableRawPointer?
    private var device: MTDeviceRef?
    private var stopFn: MTDeviceStopFn?

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    /// Calls back on the main queue whenever the number of fingers on the
    /// trackpad changes. Fires on contact, before any movement.
    func start(onFingerCountChange handler: @escaping FingerCountHandler) {
        guard !isRunning else { return }

        guard let lib = dlopen(Self.frameworkPath, RTLD_LAZY) else {
            print("⚠️ MultitouchSupport: dlopen failed — feature disabled")
            return
        }
        libHandle = lib

        guard
            let createSym   = dlsym(lib, "MTDeviceCreateDefault"),
            let registerSym = dlsym(lib, "MTRegisterContactFrameCallback"),
            let startSym    = dlsym(lib, "MTDeviceStart"),
            let stopSym     = dlsym(lib, "MTDeviceStop")
        else {
            print("⚠️ MultitouchSupport: symbols missing — feature disabled")
            return
        }

        let createDevice = unsafeBitCast(createSym,   to: MTDeviceCreateDefaultFn.self)
        let registerCB   = unsafeBitCast(registerSym, to: MTRegisterFn.self)
        let startDevice  = unsafeBitCast(startSym,    to: MTDeviceStartFn.self)
        stopFn           = unsafeBitCast(stopSym,     to: MTDeviceStopFn.self)

        guard let dev = createDevice() else {
            print("⚠️ MultitouchSupport: no trackpad found — feature disabled")
            return
        }
        device = dev

        mtFingerHandler = handler
        registerCB(dev, mtContactCallback)
        startDevice(dev, 0)

        isRunning = true
        print("✅ MultitouchSupport running — watching raw trackpad contacts")
    }

    func stop() {
        if let dev = device { stopFn?(dev) }
        device = nil
        mtFingerHandler = nil
        isRunning = false
    }

    deinit { stop() }
}

// MARK: - C callback bridge
//
// A @convention(c) function pointer cannot capture context, so the callback has
// to route through file scope. It is invoked on MultitouchSupport's own thread
// at trackpad scan rate, so it does the minimum possible: reject frames where
// the count hasn't changed, then hop to main.

private var mtFingerHandler: MultitouchWatcher.FingerCountHandler?
private var mtLastFingerCount: Int32 = -1

private let mtContactCallback: @convention(c)
    (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32 = { _, _, nFingers, _, _ in
        guard nFingers != mtLastFingerCount else { return 0 }
        mtLastFingerCount = nFingers
        let count = Int(nFingers)
        DispatchQueue.main.async { mtFingerHandler?(count) }
        return 0
    }
