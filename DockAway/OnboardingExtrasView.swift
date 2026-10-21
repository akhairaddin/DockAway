import AppKit
import SwiftUI

/// One Extras setting as onboarding shows it. The actions are the same ones
/// the Extras menu uses.
struct OnboardingExtrasOption {
    enum Control {
        case toggle(isOn: () -> Bool, setOn: (Bool) -> Void)
        case choice(choices: [(value: Double, title: String)], current: () -> Double?, select: (Double) -> Void)
    }

    let title: String
    let detail: String
    /// Shown beneath the previous option with the down-and-right arrow.
    var isNested = false
    var isEnabled: () -> Bool = { true }
    let control: Control
    /// Plays a preview, such as a sound, shown as a play button by the switch.
    var preview: (() -> Void)?
}

/// The Extras card on onboarding's keyboard page.
final class OnboardingExtrasView: NSView {
    private struct Row {
        let option: OnboardingExtrasOption
        let toggle: DockMenuSwitch?
        let popUp: NSPopUpButton?
        let labels: NSView?
    }

    private var rows: [Row] = []
    private var separators: [NSView] = []
    private let stack = NSStackView()
    private let compact: Bool

    init(options: [OnboardingExtrasOption], compact: Bool = false) {
        self.compact = compact
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 0.5

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)
        ])

        for (index, option) in options.enumerated() {
            if index > 0, !option.isNested {
                addFullWidth(makeSeparator())
            }
            addFullWidth(makeRow(for: option))
        }
        updateColors()
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    /// Re-reads every setting, including changes made from the Extras menu.
    func refresh() {
        for row in rows {
            let enabled = row.option.isEnabled()
            switch row.option.control {
            case .toggle(let isOn, _):
                row.toggle?.state = isOn() ? .on : .off
                row.toggle?.isEnabled = enabled
            case .choice(let choices, let current, _):
                let index = current().flatMap { value in choices.firstIndex { $0.value == value } }
                row.popUp?.selectItem(at: index ?? -1)
                row.popUp?.isEnabled = enabled
            }
            row.labels?.alphaValue = enabled ? 1 : 0.45
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        // Matches the keyboard page's cards. The lines take the text color,
        // so they show in Light Mode as well as Dark.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.38).cgColor
            separators.forEach { $0.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor }
        }
    }

    private func addFullWidth(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func makeSeparator() -> NSView {
        let separator = NSView()
        separator.wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        separators.append(separator)
        return separator
    }

    private func makeRow(for option: OnboardingExtrasOption) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let verticalInset: CGFloat = compact ? 5 : 7
        var leadingAnchor = container.leadingAnchor
        var leadingInset: CGFloat = 0

        if option.isNested {
            let arrow = NSImageView()
            arrow.image = NSImage(systemSymbolName: "arrow.turn.down.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
            arrow.contentTintColor = .secondaryLabelColor
            arrow.translatesAutoresizingMaskIntoConstraints = false
            arrow.setAccessibilityElement(false)
            container.addSubview(arrow)
            NSLayoutConstraint.activate([
                arrow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                arrow.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: 2),
                arrow.widthAnchor.constraint(equalToConstant: 18),
                arrow.heightAnchor.constraint(equalToConstant: 18)
            ])
            leadingAnchor = arrow.trailingAnchor
            leadingInset = 8
        }

        switch option.control {
        case .toggle where option.preview != nil:
            let labels = makeLabels(for: option)
            let toggle = DockMenuSwitch()
            toggle.translatesAutoresizingMaskIntoConstraints = false
            toggle.swiftUIControlSize = .regular
            toggle.setAccessibilityLabel(option.title)
            toggle.target = self
            toggle.action = #selector(toggleChanged(_:))
            container.addSubview(labels)
            container.addSubview(toggle)
            NSLayoutConstraint.activate([
                labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
                labels.topAnchor.constraint(equalTo: container.topAnchor, constant: verticalInset),
                labels.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -verticalInset),
                labels.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -10),
                toggle.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                toggle.centerYAnchor.constraint(equalTo: container.centerYAnchor)
            ])
            rows.append(Row(option: option, toggle: toggle, popUp: nil, labels: labels))

        case .toggle:
            let toggle = DockMenuSwitch()
            toggle.translatesAutoresizingMaskIntoConstraints = false
            toggle.swiftUIControlSize = .regular
            toggle.showsLabel = true
            toggle.detailLabel = option.detail
            toggle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            toggle.setAccessibilityLabel(option.title)
            toggle.target = self
            toggle.action = #selector(toggleChanged(_:))
            container.addSubview(toggle)
            NSLayoutConstraint.activate([
                toggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
                toggle.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                toggle.topAnchor.constraint(equalTo: container.topAnchor, constant: verticalInset),
                toggle.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -verticalInset)
            ])
            rows.append(Row(option: option, toggle: toggle, popUp: nil, labels: nil))

        case .choice(let choices, _, _):
            let labels = makeLabels(for: option)
            let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
            popUp.addItems(withTitles: choices.map(\.title))
            popUp.controlSize = .regular
            popUp.translatesAutoresizingMaskIntoConstraints = false
            popUp.setAccessibilityLabel(option.title)
            popUp.target = self
            popUp.action = #selector(choiceChanged(_:))
            popUp.setContentCompressionResistancePriority(.required, for: .horizontal)
            popUp.setContentHuggingPriority(.required, for: .horizontal)

            container.addSubview(labels)
            container.addSubview(popUp)
            NSLayoutConstraint.activate([
                labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
                labels.topAnchor.constraint(equalTo: container.topAnchor, constant: verticalInset),
                labels.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -verticalInset),
                labels.trailingAnchor.constraint(lessThanOrEqualTo: popUp.leadingAnchor, constant: -10),
                popUp.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                popUp.centerYAnchor.constraint(equalTo: container.centerYAnchor)
            ])
            rows.append(Row(option: option, toggle: nil, popUp: popUp, labels: labels))
        }
        return container
    }

    /// A title and description drawn by SwiftUI exactly like DockMenuSwitch's
    /// label, so every row's text renders the same. A play button, when the
    /// option has a preview, follows the title.
    private func makeLabels(for option: OnboardingExtrasOption) -> NSView {
        let labels = OnboardingOptionLabelHostingView(rootView: OnboardingOptionLabel(
            title: option.title, detail: option.detail, play: option.preview))
        labels.translatesAutoresizingMaskIntoConstraints = false
        // Truncate rather than widen the onboarding window.
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return labels
    }

    @objc private func toggleChanged(_ sender: DockMenuSwitch) {
        guard let row = rows.first(where: { $0.toggle === sender }),
              case .toggle(_, let setOn) = row.option.control else { return }
        setOn(sender.state == .on)
        refresh()
    }

    @objc private func choiceChanged(_ sender: NSPopUpButton) {
        guard let row = rows.first(where: { $0.popUp === sender }),
              case .choice(let choices, _, let select) = row.option.control,
              choices.indices.contains(sender.indexOfSelectedItem) else { return }
        select(choices[sender.indexOfSelectedItem].value)
        refresh()
    }
}

private struct OnboardingOptionLabel: View {
    let title: String
    let detail: String
    let play: (() -> Void)?

    var body: some View {
        // Matches DockMenuSwitch's label fonts and spacing.
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let play {
                    Button(action: play) {
                        Image(systemName: "play.circle")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play \(title)")
                }
            }
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Lets the play button respond to the first click, like DockMenuSwitch.
private final class OnboardingOptionLabelHostingView: NSHostingView<OnboardingOptionLabel> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
