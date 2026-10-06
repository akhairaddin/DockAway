import Foundation

/// UserDefaults KVO also reports changes made by another process. Its
/// didChangeNotification only reports writes made by this process.
@MainActor
final class SeparateSpacesPreferenceObservation: NSObject {
    private let defaults: UserDefaults
    private let onChange: @MainActor () -> Void
    private var isObserving = false

    init?(domain: String, onChange: @escaping @MainActor () -> Void) {
        guard let defaults = UserDefaults(suiteName: domain) else { return nil }
        self.defaults = defaults
        self.onChange = onChange
        super.init()
        defaults.addObserver(self, forKeyPath: "spans-displays", options: [], context: nil)
        isObserving = true
    }

    func invalidate() {
        guard isObserving else { return }
        isObserving = false
        defaults.removeObserver(self, forKeyPath: "spans-displays")
    }

    nonisolated override func observeValue(
        forKeyPath keyPath: String?, of object: Any?,
        change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == "spans-displays" else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        // External notifications can arrive off the main thread. Re-read the
        // verified preference on the main actor instead of trusting a KVO
        // payload, and discard callbacks queued before onboarding closed.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isObserving else { return }
            self.onChange()
        }
    }

    deinit {
        if isObserving {
            defaults.removeObserver(self, forKeyPath: "spans-displays")
        }
    }
}
