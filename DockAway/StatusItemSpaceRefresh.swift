import Foundation

/// A finite repaint burst after macOS replaces its menu-bar presentation for
/// a Space. Later transitions supersede earlier work; open menus keep their
/// anchor until tracking finishes. There is no idle polling or item recreation.
@MainActor
final class StatusItemSpaceRefresh {
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void

    private let schedule: Scheduler
    private let canRefresh: () -> Bool
    private let refresh: () -> Void
    private var generation = 0
    private var deferredForMenu = false

    init(schedule: Scheduler? = nil, canRefresh: @escaping () -> Bool,
         refresh: @escaping () -> Void) {
        self.schedule = schedule ?? { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { work() }
        }
        self.canRefresh = canRefresh
        self.refresh = refresh
    }

    func spaceDidChange() {
        generation += 1
        let requestedGeneration = generation
        deferredForMenu = false
        // The notification can arrive before the destination menu bar is
        // ready. Repaint once shortly afterward and once after a normal swipe.
        for delay in [0.15, 0.75] {
            schedule(delay) { [weak self] in
                guard let self, self.generation == requestedGeneration else { return }
                guard self.canRefresh() else {
                    self.deferredForMenu = true
                    return
                }
                self.deferredForMenu = false
                self.refresh()
            }
        }
    }

    func menuDidClose() {
        guard deferredForMenu else { return }
        spaceDidChange()
    }

    func cancel() {
        generation += 1
        deferredForMenu = false
    }
}
