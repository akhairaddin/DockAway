import AppKit
import SwiftUI

// Preserve the borderless onboarding appearance while allowing AppKit to
// route keyboard focus, Return, Escape, and accessibility interactions.
final class PermissionSetupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Whether DockAway is running in a virtual machine. There, the
    /// see-through onboarding background is too much for the emulated
    /// graphics: scrolling it froze the whole machine, even with "Reduce
    /// transparency" on, so the onboarding uses a solid one instead.
    static let isVirtualMachine: Bool = {
        var present: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.hv_vmm_present", &present, &size, nil, 0) == 0 && present == 1
    }()

    /// The panel's rounded shape for a visual effect view's mask image,
    /// stretchable to any size, with the same continuous corners as the
    /// panel's border.
    static func roundedMask(radius: CGFloat) -> NSImage {
        // Continuous corners curve over about 1.53 times their radius.
        let corner = ceil(radius * 1.6)
        let edge = corner * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: corner, left: corner, bottom: corner, right: corner)
        image.resizingMode = .stretch
        return image
    }
}

/// A solid onboarding background in the window's own color, with the same
/// rounded corners and thin border as the see-through one, following light
/// and dark mode.
final class OnboardingSolidBackgroundView: NSView {
    private let cornerRadius: CGFloat

    init(frame: NSRect, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
    }
}
