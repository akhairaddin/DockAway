import AppKit

/// When the person last scrolled, anywhere. Timers that ask the window server
/// for its window list skip their turn while scrolling: the window server is
/// busy drawing then, and on slower graphics, such as a virtual machine, each
/// answer can take long enough that DockAway stops responding. Changes macOS
/// reports itself, such as desktop switches and app launches, are still
/// handled at once.
@MainActor
enum ScrollActivity {
    /// How long after the last scroll timers start asking again.
    static let rest: TimeInterval = 0.5

    private static var lastScrollAt: TimeInterval = -.infinity
    private static let activeScrollViews = NSHashTable<AnyObject>.weakObjects()
    private static var monitors: [Any] = []
    private static var observers: [NSObjectProtocol] = []

    /// Whether the person is scrolling now or scrolled within the last moment.
    static var isScrolling: Bool {
        startWatching()
        if !activeScrollViews.allObjects.isEmpty {
            lastScrollAt = ProcessInfo.processInfo.systemUptime
            return true
        }
        return ProcessInfo.processInfo.systemUptime - lastScrollAt < rest
    }

    /// Watches scrolls in other apps and in DockAway's own windows, including
    /// AppKit live-scroll sessions driven by the concurrent VBL scroll thread
    /// where `.scrollWheel` events bypass `NSApplication.sendEvent(_:)`.
    static func startWatching() {
        guard monitors.isEmpty, observers.isEmpty else { return }
        let note: @MainActor () -> Void = { lastScrollAt = ProcessInfo.processInfo.systemUptime }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { _ in
                MainActor.assumeIsolated { note() }
            },
            NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                MainActor.assumeIsolated { note() }
                return event
            }
        ].compactMap { $0 }

        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: nil,
                queue: .main
            ) { notification in
                let scrollView = notification.object as AnyObject?
                MainActor.assumeIsolated {
                    if let scrollView {
                        activeScrollViews.add(scrollView)
                    }
                    note()
                }
            },
            center.addObserver(
                forName: NSScrollView.didLiveScrollNotification,
                object: nil,
                queue: .main
            ) { notification in
                let scrollView = notification.object as AnyObject?
                MainActor.assumeIsolated {
                    if let scrollView {
                        activeScrollViews.add(scrollView)
                    }
                    note()
                }
            },
            center.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: nil,
                queue: .main
            ) { notification in
                let scrollView = notification.object as AnyObject?
                MainActor.assumeIsolated {
                    if let scrollView {
                        activeScrollViews.remove(scrollView)
                    }
                    note()
                }
            }
        ]
    }
}
