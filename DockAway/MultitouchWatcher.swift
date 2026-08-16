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
    typealias FourFingerMotionHandler = (FourFingerMotion) -> Void

    enum FourFingerMotion {
        case horizontalLeft
        case horizontalRight
        case upward
        case downward
    }

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

    /// Finger-count changes fire on contact. Once four contacts move far enough
    /// to reject resting noise, their dominant direction is reported once.
    func start(
        onFingerCountChange handler: @escaping FingerCountHandler,
        onFourFingerMotion motionHandler: @escaping FourFingerMotionHandler
    ) {
        guard !isRunning else { return }

        let lib: UnsafeMutableRawPointer
        if let existingHandle = libHandle {
            lib = existingHandle
        } else {
            guard let loadedHandle = dlopen(Self.frameworkPath, RTLD_LAZY) else {
                print("⚠️ MultitouchSupport: dlopen failed — feature disabled")
                return
            }
            libHandle = loadedHandle
            lib = loadedHandle
        }

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

        // A stop/resume can happen while fingers are still resting on the
        // trackpad. Force the first fresh frame through after every restart.
        mtLastFingerCount = -1
        mtFourFingerOrigin = nil
        mtFourFingerMotionSent = false
        mtFingerHandler = handler
        mtMotionHandler = motionHandler
        registerCB(dev, mtContactCallback)
        startDevice(dev, 0)

        isRunning = true
        print("✅ MultitouchSupport running — watching raw trackpad contacts")
    }

    func stop() {
        if let dev = device { stopFn?(dev) }
        device = nil
        mtFingerHandler = nil
        mtMotionHandler = nil
        mtFourFingerOrigin = nil
        mtFourFingerMotionSent = false
        isRunning = false
    }

    deinit {
        stop()
        if let libHandle {
            dlclose(libHandle)
        }
    }
}

// MARK: - C callback bridge
//
// A @convention(c) function pointer cannot capture context, so the callback has
// to route through file scope. It is invoked on MultitouchSupport's own thread
// at trackpad scan rate, so it computes only a four-contact centroid and hops
// to main when the count changes or a direction crosses the noise threshold.

private struct MTPoint {
    var x: Float
    var y: Float
}

private struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

/// Runtime layout used by MultitouchSupport's contact-frame callback. DockAway
/// reads only `normalized.position`; the remaining fields preserve the native
/// stride so each contact begins at the correct address.
private struct MTContact {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var unknown3: Int32
    var unknown4: Int32
    var normalized: MTVector
    var size: Float
    var zero1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var millimeters: MTVector
    var zero2a: Int32
    var zero2b: Int32
    var unknown2: Float
}

private var mtFingerHandler: MultitouchWatcher.FingerCountHandler?
private var mtMotionHandler: MultitouchWatcher.FourFingerMotionHandler?
private var mtLastFingerCount: Int32 = -1
private var mtFourFingerOrigin: MTPoint?
private var mtFourFingerMotionSent = false
// 0.35% of the normalized trackpad surface: enough to reject resting noise,
// but early enough to hide before macOS visibly begins a Space transition.
private let mtMotionThreshold: Float = 0.0035
private let mtAmbiguousMotionThreshold: Float = 0.010
private let mtAxisDominance: Float = 1.35

private let mtContactCallback: @convention(c)
    (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32 = {
        _, contactBytes, nFingers, _, _ in
        let countChanged = nFingers != mtLastFingerCount
        let hadFourFingerContact = mtLastFingerCount >= 4
        let hasFourFingerContact = nFingers >= 4
        let crossedFourFingerBoundary =
            hadFourFingerContact != hasFourFingerContact
        var detectedMotion: MultitouchWatcher.FourFingerMotion?

        // MultitouchSupport still delivers hardware frames, but after the
        // gesture direction is known—or while fewer than four fingers remain
        // unchanged—there is no useful work for DockAway to perform.
        if !countChanged,
           !hasFourFingerContact || mtFourFingerMotionSent {
            return 0
        }

        if hasFourFingerContact, let contactBytes {
            let count = Int(nFingers)
            let contacts = contactBytes.assumingMemoryBound(to: MTContact.self)
            var x: Float = 0
            var y: Float = 0
            for index in 0..<count {
                x += contacts[index].normalized.position.x
                y += contacts[index].normalized.position.y
            }
            let centroid = MTPoint(x: x / Float(count), y: y / Float(count))

            if countChanged || mtFourFingerOrigin == nil {
                // Adding or removing a contact moves the centroid without a
                // gesture, so every stable finger-count begins a fresh sample.
                mtFourFingerOrigin = centroid
                if !hadFourFingerContact {
                    mtFourFingerMotionSent = false
                }
            } else if !mtFourFingerMotionSent, let origin = mtFourFingerOrigin {
                let deltaX = centroid.x - origin.x
                let deltaY = centroid.y - origin.y
                let dominantDelta = max(abs(deltaX), abs(deltaY))
                let secondaryDelta = min(abs(deltaX), abs(deltaY))
                let hasClearAxis = dominantDelta >= secondaryDelta * mtAxisDominance
                let crossedThreshold = dominantDelta >= mtMotionThreshold
                    && (hasClearAxis || dominantDelta >= mtAmbiguousMotionThreshold)
                if crossedThreshold {
                    if abs(deltaX) > abs(deltaY) {
                        detectedMotion = deltaX < 0
                            ? .horizontalLeft
                            : .horizontalRight
                    } else {
                        detectedMotion = deltaY > 0 ? .upward : .downward
                    }
                    mtFourFingerMotionSent = true
                }
            }
        } else {
            mtFourFingerOrigin = nil
            mtFourFingerMotionSent = false
        }

        mtLastFingerCount = nFingers
        if crossedFourFingerBoundary {
            let count = Int(nFingers)
            DispatchQueue.main.async { mtFingerHandler?(count) }
        }
        if let detectedMotion {
            DispatchQueue.main.async { mtMotionHandler?(detectedMotion) }
        }
        return 0
    }
