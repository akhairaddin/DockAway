import AppKit
import SwiftUI
import Observation

/// A native SwiftUI switch hosted in an AppKit menu.
final class DockMenuSwitch: NSControl {
    @MainActor @Observable fileprivate final class Model {
        var isOn = false
        var isEnabled = true
        var label = ""
        var detail = ""
        var showsLabel = false
        var controlSize: SwiftUI.ControlSize = .small
    }

    private let model = Model()
    private var hostingView: DockMenuSwitchHostingView!

    var state: NSControl.StateValue {
        get { model.isOn ? .on : .off }
        set {
            model.isOn = newValue == .on
            setAccessibilityValue(model.isOn ? 1 : 0)
        }
    }

    var swiftUIControlSize: SwiftUI.ControlSize {
        get { model.controlSize }
        set { model.controlSize = newValue }
    }

    var detailLabel: String {
        get { model.detail }
        set { model.detail = newValue }
    }

    var showsLabel: Bool {
        get { model.showsLabel }
        set { model.showsLabel = newValue }
    }

    override var isEnabled: Bool {
        didSet { model.isEnabled = isEnabled }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hostingView = DockMenuSwitchHostingView(rootView: MenuSwitchContent(model: model) { [weak self] value in
            guard let self, self.isEnabled else { return }
            self.state = value ? .on : .off
            self.sendAction(self.action, to: self.target)
        })
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        // Expose the AppKit wrapper so NSMenu includes the control in its AX tree.
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityValue(0)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { hostingView.fittingSize }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setAccessibilityLabel(_ accessibilityLabel: String?) {
        super.setAccessibilityLabel(accessibilityLabel)
        model.label = accessibilityLabel ?? ""
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }

    override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        state = model.isOn ? .off : .on
        sendAction(action, to: target)
    }
}

private struct MenuSwitchContent: View {
    let model: DockMenuSwitch.Model
    let onChange: (Bool) -> Void

    var body: some View {
        Group {
            if model.showsLabel {
                Toggle(isOn: binding) {
                    visibleLabel
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Toggle(model.label, isOn: binding)
                    .labelsHidden()
            }
        }
            .controlSize(model.controlSize)
            .toggleStyle(.switch)
            .disabled(!model.isEnabled)
            .fixedSize(horizontal: !model.showsLabel, vertical: true)
            .accessibilityHidden(true)
    }

    private var binding: Binding<Bool> {
        Binding(get: { model.isOn }, set: onChange)
    }

    @ViewBuilder
    private var visibleLabel: some View {
            if model.detail.isEmpty {
                Text(model.label)
                    .font(.system(size: 12.5, weight: .medium))
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.label)
                        .font(.system(size: 13, weight: .semibold))
                    Text(model.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
    }
}

/// Keeps a click on a hosted switch from being consumed by an inactive window's
/// initial activation click. SwiftUI still owns the switch's click and drag tracking.
private final class DockMenuSwitchHostingView: NSHostingView<MenuSwitchContent> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
