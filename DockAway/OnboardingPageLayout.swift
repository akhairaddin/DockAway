import AppKit

enum OnboardingPageLayout {
    static let windowWidth: CGFloat = 540
    static let permissionsHeight: CGFloat = 744
    static let keyboardHeight: CGFloat = 665

    static func windowSize(for step: Int, visibleFrame: NSRect?) -> NSSize {
        let preferredHeight = step == 1 ? permissionsHeight : keyboardHeight
        let availableHeight = visibleFrame.map { max(1, $0.height - 24) } ?? preferredHeight
        return NSSize(width: windowWidth, height: min(preferredHeight, availableHeight))
    }

    static func needsCompactLayout(for step: Int, visibleFrame: NSRect?) -> Bool {
        guard let visibleFrame else { return false }
        let preferredHeight = step == 1 ? permissionsHeight : keyboardHeight
        return visibleFrame.height - 24 < preferredHeight
    }

    // Only the visible page's edges should constrain the shared window. A
    // hidden fixed-height page must not impose its minimum height on the other.
    static func edgeConstraints(for page: NSView, in container: NSView,
                                topInset: CGFloat, bottomInset: CGFloat) -> [NSLayoutConstraint] {
        page.translatesAutoresizingMaskIntoConstraints = false
        return [
            page.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 34),
            page.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -34),
            page.topAnchor.constraint(equalTo: container.topAnchor, constant: topInset),
            page.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -bottomInset)
        ]
    }
}

/// Both onboarding pages are fixed layouts, not scrollable documents. The
/// first page keeps its footer pinned while the body uses its natural height.
final class OnboardingPermissionsPageView: NSView {
    let bodyView: NSStackView

    init(body: NSStackView, footer: NSView, instructions: NSView, compact: Bool = false) {
        bodyView = body
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        instructions.translatesAutoresizingMaskIntoConstraints = false
        instructions.setContentCompressionResistancePriority(.required, for: .vertical)
        instructions.setContentHuggingPriority(.required, for: .vertical)
        addSubview(body)
        addSubview(footer)
        addSubview(instructions)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.topAnchor.constraint(equalTo: topAnchor),
            body.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: compact ? -8 : -14),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: instructions.topAnchor, constant: compact ? -8 : -12),
            instructions.leadingAnchor.constraint(equalTo: leadingAnchor),
            instructions.trailingAnchor.constraint(equalTo: trailingAnchor),
            instructions.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
}
