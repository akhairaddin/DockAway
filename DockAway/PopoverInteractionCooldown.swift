import AppKit

private final class PopoverAnchorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A status item's system-owned window can disappear or be replaced while
/// AppKit refreshes the menu bar. NSPopover closes when its anchor goes away,
/// independently of our idle deadline. Keep the same screen position using
/// an app-owned, invisible, non-interactive anchor instead.
@MainActor
final class PopoverPresentationAnchor {
    let view: NSView
    private let panel: NSPanel

    init?(positioningView: NSView) {
        guard let sourceWindow = positioningView.window,
              sourceWindow.isVisible else { return nil }
        let rect = sourceWindow.convertToScreen(positioningView.convert(positioningView.bounds, to: nil))
        guard rect.width > 0, rect.height > 0 else { return nil }
        panel = PopoverAnchorPanel(contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        view = NSView(frame: NSRect(origin: .zero, size: rect.size))
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.level = sourceWindow.level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.orderFrontRegardless()
    }

    func close() { panel.orderOut(nil) }
}

/// One idle deadline, restarted by each interaction rather than queued.
@MainActor
final class PopoverInteractionCooldown {
    typealias Scheduler = (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

    private let delay: TimeInterval
    private let schedule: Scheduler
    private let dismiss: () -> Void
    private var cancelPending: (() -> Void)?
    private var generation = 0
    private var active = false
    private var interacting = false

    init(delay: TimeInterval = 3.5, schedule: Scheduler? = nil,
         dismiss: @escaping () -> Void) {
        self.delay = delay
        self.dismiss = dismiss
        self.schedule = schedule ?? { delay, work in
            let timer = Timer(timeInterval: delay, repeats: false) { _ in
                MainActor.assumeIsolated { work() }
            }
            RunLoop.main.add(timer, forMode: .common)
            return { timer.invalidate() }
        }
    }

    func start() {
        cancel()
        active = true
        restartDeadline()
    }

    func interactionBegan() {
        guard active else { return }
        interacting = true
        invalidateDeadline()
    }

    func interactionEnded() {
        guard active else { return }
        interacting = false
        restartDeadline()
    }

    /// Also covers keyboard and accessibility activation of the native button.
    func interactionPerformed() {
        guard active, !interacting else { return }
        restartDeadline()
    }

    func cancel() {
        active = false
        interacting = false
        invalidateDeadline()
    }

    private func invalidateDeadline() {
        generation += 1
        cancelPending?()
        cancelPending = nil
    }

    private func restartDeadline() {
        invalidateDeadline()
        let requestedGeneration = generation
        cancelPending = schedule(delay) { [weak self] in
            guard let self, self.active, !self.interacting,
                  self.generation == requestedGeneration else { return }
            self.cancel()
            self.dismiss()
        }
    }
}

/// Preserve native button tracking, including a release outside the button.
/// A held click must not allow the popover's idle deadline to expire.
final class PopoverCelebrationButton: NSButton {
    var interactionBegan: (() -> Void)?
    var interactionEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        interactionBegan?()
        defer { interactionEnded?() }
        super.mouseDown(with: event)
    }
}
