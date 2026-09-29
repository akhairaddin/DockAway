import AppKit
import QuartzCore

/// Cubic ease-in-out over 0...1; input outside that range is clamped.
nonisolated func easeInOutCubic(_ progress: Double) -> Double {
    let t = min(1, max(0, progress))
    return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
}

extension CAFrameRateRange {
    /// The full refresh rate of the display showing `view` (120 Hz on
    /// ProMotion), so animations are not held to 60 Hz.
    @MainActor static func fullRefresh(for view: NSView?) -> CAFrameRateRange {
        let maximum = Float(view?.window?.screen?.maximumFramesPerSecond
            ?? NSScreen.main?.maximumFramesPerSecond ?? 60)
        return CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
    }
}

/// An eased main-thread animation for geometry Core Animation cannot drive,
/// such as resizing menu-hosted views. It steps once per display refresh, in
/// sync with Core Animation, and keeps running during NSMenu event tracking.
/// `step` receives eased progress; the final call has `finished == true` and
/// progress 1. Call `invalidate()` to cancel early.
@MainActor
final class EasedAnimation: NSObject {
    private let startTime = CACurrentMediaTime()
    private let duration: TimeInterval
    private let step: (_ progress: CGFloat, _ finished: Bool) -> Void
    private var displayLink: CADisplayLink?
    private var fallbackTimer: Timer?
    private var deadlineTimer: Timer?

    init(view: NSView, duration: TimeInterval, step: @escaping (_ progress: CGFloat, _ finished: Bool) -> Void) {
        self.duration = duration
        self.step = step
        super.init()
        guard view.window?.isVisible == true else {
            // An off-screen view has no display to synchronize with.
            fallbackTimer = Self.scheduledTimer(interval: 1.0 / 60.0, repeats: true) { [weak self] in
                self?.advance(to: CACurrentMediaTime())
            }
            return
        }
        let link = view.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.preferredFrameRateRange = .fullRefresh(for: view)
        link.add(to: .main, forMode: .common)
        link.add(to: .main, forMode: .eventTracking)
        displayLink = link
        // A display link pauses if its window leaves the screen mid-animation.
        // Always land on the final frame on time.
        deadlineTimer = Self.scheduledTimer(interval: duration + 0.05, repeats: false) { [weak self] in
            self?.advance(to: CACurrentMediaTime())
        }
    }

    private static func scheduledTimer(interval: TimeInterval, repeats: Bool,
                                       _ block: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in
            MainActor.assumeIsolated { block() }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        return timer
    }

    func invalidate() {
        displayLink?.invalidate()
        displayLink = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        deadlineTimer?.invalidate()
        deadlineTimer = nil
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        // Position for the frame about to reach the screen, not the one
        // already there, so main-thread geometry matches Core Animation.
        advance(to: link.targetTimestamp)
    }

    private func advance(to time: CFTimeInterval) {
        guard displayLink != nil || fallbackTimer != nil else { return }
        // The owner may release this animation from inside its final step.
        withExtendedLifetime(self) {
            let rawProgress = min(max((time - startTime) / duration, 0), 1)
            let finished = rawProgress >= 1
            if finished { invalidate() }
            step(CGFloat(easeInOutCubic(rawProgress)), finished)
        }
    }
}
