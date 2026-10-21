import Foundation

// Reads raw trackpad contacts from the private MultitouchSupport framework —
// the only way to know fingers are resting on the trackpad before any motion
// has happened. AppKit does not emit a gesture event until a swipe starts.
//
// Everything is resolved with dlopen/dlsym at runtime rather than linked at
// build time. If Apple moves the framework or renames a symbol, `start` fails,
// logs, and the app carries on without the feature instead of refusing to
// launch. That matters on a beta OS.
//
// This is private API. It is not reviewed, not documented, and not promised to
// exist in the next build of macOS.
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
    private typealias MTDeviceReleaseFn = @convention(c) (MTDeviceRef) -> Void

    private(set) var isRunning = false
    private(set) var failureReason: String?
    // A missing trackpad is normal on mouse-only Macs. Only framework-level
    // failures should produce a user-facing degraded-support warning.
    private(set) var shouldWarnUser = false
    private var libHandle: UnsafeMutableRawPointer?
    private var device: MTDeviceRef?
    private var stopFn: MTDeviceStopFn?
    private var unregisterFn: MTRegisterFn?
    private var releaseFn: MTDeviceReleaseFn?

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    // Finger-count changes fire on contact. Once four contacts move far enough
    // to reject resting noise, their dominant direction is reported once.
    // `onHorizontalSwipe` follows the whole gesture instead: it reports which
    // way the fingers have travelled sideways each time that changes, and at
    // the latest as they lift.
    @discardableResult
    func start(
        onFingerCountChange handler: @escaping FingerCountHandler,
        onFourFingerMotion motionHandler: @escaping FourFingerMotionHandler,
        onHorizontalSwipe swipeHandler: FourFingerMotionHandler? = nil
    ) -> Bool {
        guard !isRunning else { return true }

        let lib: UnsafeMutableRawPointer
        if let existingHandle = libHandle {
            lib = existingHandle
        } else {
            guard let loadedHandle = dlopen(Self.frameworkPath, RTLD_LAZY) else {
                failureReason = "MultitouchSupport could not be loaded"
                shouldWarnUser = true
                dockAwayDebugLog("⚠️ MultitouchSupport: dlopen failed — feature disabled")
                return false
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
            failureReason = "MultitouchSupport symbols are unavailable"
            shouldWarnUser = true
            dockAwayDebugLog("⚠️ MultitouchSupport: symbols missing — feature disabled")
            return false
        }

        let createDevice = unsafeBitCast(createSym,   to: MTDeviceCreateDefaultFn.self)
        let registerCB   = unsafeBitCast(registerSym, to: MTRegisterFn.self)
        let startDevice  = unsafeBitCast(startSym,    to: MTDeviceStartFn.self)
        stopFn           = unsafeBitCast(stopSym,     to: MTDeviceStopFn.self)
        // Each start creates the device afresh, so each stop hands it back.
        unregisterFn = dlsym(lib, "MTUnregisterContactFrameCallback").map { unsafeBitCast($0, to: MTRegisterFn.self) }
        releaseFn = dlsym(lib, "MTDeviceRelease").map { unsafeBitCast($0, to: MTDeviceReleaseFn.self) }

        guard let dev = createDevice() else {
            failureReason = "No trackpad was found"
            shouldWarnUser = false
            dockAwayDebugLog("⚠️ MultitouchSupport: no trackpad found — feature disabled")
            return false
        }
        device = dev

        // A stop/resume can happen while fingers are still resting on the
        // trackpad. Force the first fresh frame through after every restart.
        mtLastFingerCount = -1
        mtFourFingerOrigin = nil
        mtFourFingerMotionSent = false
        mtResetSwipe()
        mtFingerHandler = handler
        mtMotionHandler = motionHandler
        mtSwipeHandler = swipeHandler
        registerCB(dev, mtContactCallback)
        startDevice(dev, 0)

        isRunning = true
        failureReason = nil
        shouldWarnUser = false
        dockAwayDebugLog("✅ MultitouchSupport running — watching raw trackpad contacts")
        return true
    }

    func stop() {
        if let dev = device {
            unregisterFn?(dev, mtContactCallback)
            stopFn?(dev)
            releaseFn?(dev)
        }
        device = nil
        mtFingerHandler = nil
        mtMotionHandler = nil
        mtSwipeHandler = nil
        mtFourFingerOrigin = nil
        mtFourFingerMotionSent = false
        mtResetSwipe()
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

// Runtime layout used by MultitouchSupport's contact-frame callback. DockAway
// reads only `identifier` and `normalized.position`; the remaining fields
// preserve the native stride so each contact begins at the correct address.
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

// Sideways travel for `onHorizontalSwipe`. Each frame adds the average move of
// the contacts that were also down in the previous frame, so a finger landing
// or lifting mid-gesture never counts as travel, and an early wobble up or
// down as the fingers land doesn't hide the sideways swipe that follows.
private var mtSwipeHandler: MultitouchWatcher.FourFingerMotionHandler?
private var mtSwipeContacts: [(id: Int32, position: MTPoint)] = []
private var mtSwipeFrameContacts: [(id: Int32, position: MTPoint)] = []
private var mtSwipeTravel = MTPoint(x: 0, y: 0)
// -1 after reporting left, 1 after reporting right, 0 before either.
private var mtSwipeReported: Int8 = 0
private let mtSwipeThreshold: Float = 0.004
// Any clearly sideways travel at all is reported as the fingers lift.
private let mtSwipeLiftThreshold: Float = 0.0015

private func mtResetSwipe() {
    mtSwipeContacts.removeAll(keepingCapacity: true)
    mtSwipeTravel = MTPoint(x: 0, y: 0)
    mtSwipeReported = 0
}

private func mtSwipeDirection(threshold: Float) -> MultitouchWatcher.FourFingerMotion? {
    let sideways = abs(mtSwipeTravel.x)
    guard sideways >= threshold, sideways >= abs(mtSwipeTravel.y) else { return nil }
    let direction: Int8 = mtSwipeTravel.x < 0 ? -1 : 1
    guard direction != mtSwipeReported else { return nil }
    mtSwipeReported = direction
    return direction < 0 ? .horizontalLeft : .horizontalRight
}

private func mtFollowSwipe(
    _ contacts: UnsafeMutablePointer<MTContact>,
    count: Int
) -> MultitouchWatcher.FourFingerMotion? {
    var deltaX: Float = 0
    var deltaY: Float = 0
    var matched: Float = 0
    mtSwipeFrameContacts.removeAll(keepingCapacity: true)
    for index in 0..<count {
        let identifier = contacts[index].identifier
        let position = contacts[index].normalized.position
        if let previous = mtSwipeContacts.first(where: { $0.id == identifier }) {
            deltaX += position.x - previous.position.x
            deltaY += position.y - previous.position.y
            matched += 1
        }
        mtSwipeFrameContacts.append((identifier, position))
    }
    swap(&mtSwipeContacts, &mtSwipeFrameContacts)
    guard matched > 0 else { return nil }
    mtSwipeTravel.x += deltaX / matched
    mtSwipeTravel.y += deltaY / matched
    return mtSwipeDirection(threshold: mtSwipeThreshold)
}

private let mtContactCallback: @convention(c)
    (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32 = {
        _, contactBytes, nFingers, _, _ in
        let countChanged = nFingers != mtLastFingerCount
        let hadGestureContact = mtLastFingerCount >= 3
        let hasGestureContact = nFingers >= 3
        var detectedMotion: MultitouchWatcher.FourFingerMotion?
        var swipe: MultitouchWatcher.FourFingerMotion?

        // MultitouchSupport still delivers hardware frames, but while fewer
        // than three fingers remain unchanged there is no useful work for
        // DockAway to perform.
        if !countChanged, !hasGestureContact {
            return 0
        }

        if hasGestureContact, let contactBytes {
            let count = Int(nFingers)
            let contacts = contactBytes.assumingMemoryBound(to: MTContact.self)
            if !hadGestureContact { mtResetSwipe() }
            if mtSwipeHandler != nil {
                swipe = mtFollowSwipe(contacts, count: count)
            }
        }

        // After the gesture direction is known, only the sideways travel
        // above still needs each frame.
        if hasGestureContact, !countChanged, mtFourFingerMotionSent {
            if let swipe {
                DispatchQueue.main.async { mtSwipeHandler?(swipe) }
            }
            return 0
        }

        if hasGestureContact, let contactBytes {
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
                // A finger joining, such as the fourth landing just after three
                // moved, makes a new gesture whose direction is reported too.
                if !hadGestureContact || nFingers > mtLastFingerCount {
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
            if hadGestureContact {
                // A short flick can lift before crossing the usual threshold.
                swipe = mtSwipeDirection(threshold: mtSwipeLiftThreshold)
            }
            mtResetSwipe()
            mtFourFingerOrigin = nil
            mtFourFingerMotionSent = false
        }

        mtLastFingerCount = nFingers
        // The direction goes first, so it arrives before a lift's count.
        if let swipe {
            DispatchQueue.main.async { mtSwipeHandler?(swipe) }
        }
        // Also report three-finger Mission Control gestures and their release.
        if countChanged {
            let count = Int(nFingers)
            DispatchQueue.main.async { mtFingerHandler?(count) }
        }
        if let detectedMotion {
            DispatchQueue.main.async { mtMotionHandler?(detectedMotion) }
        }
        return 0
    }
