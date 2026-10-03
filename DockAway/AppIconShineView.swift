import AppKit

/// A sweep finishes uninterrupted; clicks during it are ignored, never queued.
final class AppIconShineView: NSView, CAAnimationDelegate {
    private let maskImage: NSImage
    private let iconMaskLayer = CALayer()
    private let shineLayer = CAGradientLayer()
    private var activeShineID: UUID?
    private var presentationID = UUID()

    init(maskImage: NSImage) {
        self.maskImage = maskImage
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        shineLayer.colors = [
            NSColor.clear.cgColor,
            NSColor.white.withAlphaComponent(0.42).cgColor,
            NSColor.clear.cgColor
        ]
        shineLayer.locations = [0, 0.5, 1]
        shineLayer.startPoint = CGPoint(x: 1, y: 1)
        shineLayer.endPoint = CGPoint(x: 2, y: 2)
        shineLayer.opacity = 0
        layer?.addSublayer(shineLayer)
        layer?.mask = iconMaskLayer
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            // A later presentation must not inherit old clicks or delayed work.
            presentationID = UUID()
            activeShineID = nil
            shineLayer.removeAnimation(forKey: "appIconShine")
        }
    }

    override func layout() {
        super.layout()
        var imageRect = bounds
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shineLayer.frame = bounds
        iconMaskLayer.frame = bounds
        iconMaskLayer.contents = maskImage.cgImage(forProposedRect: &imageRect, context: nil, hints: nil)
        iconMaskLayer.contentsGravity = .resizeAspect
        iconMaskLayer.contentsScale = scale
        CATransaction.commit()
    }

    func play(after delay: TimeInterval) {
        guard activeShineID == nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        if delay <= 0 {
            playShineIfIdle()
            return
        }
        let presentation = presentationID
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.presentationID == presentation, self.window?.isVisible == true,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            self.playShineIfIdle()
        }
    }

    private func playShineIfIdle() {
        guard activeShineID == nil else { return }
        guard window?.isVisible == true,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        layoutSubtreeIfNeeded()

        let startPoint = CABasicAnimation(keyPath: "startPoint")
        startPoint.fromValue = CGPoint(x: -1, y: -1)
        startPoint.toValue = CGPoint(x: 1, y: 1)
        let endPoint = CABasicAnimation(keyPath: "endPoint")
        endPoint.fromValue = CGPoint(x: 0, y: 0)
        endPoint.toValue = CGPoint(x: 2, y: 2)
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 1, 1, 0]
        opacity.keyTimes = [0, 0.12, 0.78, 1]

        let shine = CAAnimationGroup()
        shine.animations = [startPoint, endPoint, opacity]
        shine.duration = 1.28
        shine.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let id = UUID()
        activeShineID = id
        shine.setValue(id.uuidString, forKey: "shineID")
        shine.delegate = self
        shineLayer.add(shine, forKey: "appIconShine")
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        // Removal callbacks from an old presentation must not affect a new one.
        guard let id = activeShineID,
              anim.value(forKey: "shineID") as? String == id.uuidString else { return }
        activeShineID = nil
    }

    @objc func replay(_ sender: Any?) { play(after: 0) }
}
