import AppKit
import QuartzCore

enum OnboardingPageLayout {
    static let windowWidth: CGFloat = 540
    /// Both pages share the welcome page's size, so the window keeps its size
    /// when moving between them. The keyboard page scrolls to fit.
    static let windowHeight: CGFloat = 744

    static func windowSize(visibleFrame: NSRect?) -> NSSize {
        let availableHeight = visibleFrame.map { max(1, $0.height - 24) } ?? windowHeight
        return NSSize(width: windowWidth, height: min(windowHeight, availableHeight))
    }

    static func needsCompactLayout(visibleFrame: NSRect?) -> Bool {
        guard let visibleFrame else { return false }
        return visibleFrame.height - 24 < windowHeight
    }

    /// Pushes one page out while the next glides in from the direction of
    /// travel, both at once. Reduce Motion gets a plain crossfade. `isCurrent`
    /// lets a newer transition supersede this one before it finishes.
    static func slide(
        from outgoing: NSView,
        to incoming: NSView,
        forward: Bool,
        reduceMotion: Bool,
        isCurrent: @escaping () -> Bool = { true },
        completion: @escaping () -> Void = {}
    ) {
        for page in [outgoing, incoming] {
            page.wantsLayer = true
            page.layer?.removeAllAnimations()
        }
        incoming.isHidden = false
        incoming.superview?.layoutSubtreeIfNeeded()

        let duration: CFTimeInterval = reduceMotion ? 0.22 : 0.46
        let distance: CGFloat = reduceMotion ? 0 : 56
        let direction: CGFloat = forward ? 1 : -1
        // A long, soft deceleration so the pages settle rather than stop.
        let glide = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)

        func animation(_ keyPath: String, from: CGFloat, to: CGFloat,
                       duration: CFTimeInterval, delay: CFTimeInterval = 0) -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = duration
            animation.timingFunction = glide
            if delay > 0 {
                animation.beginTime = CACurrentMediaTime() + delay
                animation.fillMode = .backwards
            }
            return animation
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outgoing.alphaValue = 0
        incoming.alphaValue = 1
        CATransaction.setCompletionBlock {
            guard isCurrent() else { return }
            outgoing.isHidden = true
            outgoing.layer?.removeAllAnimations()
            completion()
        }
        outgoing.layer?.add(animation("opacity", from: 1, to: 0, duration: duration * 0.55), forKey: "pageOpacity")
        if distance > 0 {
            let slideOut = animation("transform.translation.x", from: 0, to: -direction * distance, duration: duration)
            slideOut.fillMode = .forwards
            slideOut.isRemovedOnCompletion = false
            outgoing.layer?.add(slideOut, forKey: "pageSlide")
            incoming.layer?.add(animation("transform.translation.x", from: direction * distance, to: 0, duration: duration),
                                forKey: "pageSlide")
        }
        incoming.layer?.add(animation("opacity", from: 0, to: 1, duration: duration * 0.75, delay: duration * 0.1),
                            forKey: "pageOpacity")
        CATransaction.commit()
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

/// The first onboarding page is a fixed layout, not a scrollable document: it
/// keeps its footer pinned while the body uses its natural height. The keyboard
/// page scrolls instead, so its Extras section fits below the shortcuts.
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
