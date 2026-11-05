import AppKit
import SwiftUI

/// What the "Dock Position" control shows. Changes come from the AppKit row,
/// which follows the pointer; SwiftUI draws and animates the result.
@Observable
final class DockPositionPickerModel {
    var titles: [String] = []
    var selectedIndex = 0
    /// The side the pill is over, which differs from the selection mid-drag.
    var highlightedIndex = 0
    /// The pill's leading edge while it's dragged, from the track's leading edge.
    var dragX: Double?
    var isLifted = false
    /// How far the pill has grown, from 0 at rest to 1 held. The row steps
    /// it frame by frame, never SwiftUI's animation; see setLifted.
    var liftProgress = 0.0
    var isEnabled = true
    @ObservationIgnored var onSelect: (Int) -> Void = { _ in }
}

/// Left, Bottom and Right in an outlined track, with a pill over the choice. On macOS 26
/// and later the pill is Liquid Glass. The name under it is drawn on top of the glass, so
/// it stays sharp; only names beside the pill bend at its left and right rims. Held, it
/// grows.
struct DockPositionPicker: View {
    let model: DockPositionPickerModel
    @Environment(\.colorScheme) private var colorScheme

    static let rowHeight = 36.0
    static let trackHeight = 28.0
    static let pillHeight = 28.0
    /// How much the held pill grows, across and up, still within the row.
    static let liftScale = CGSize(width: 1.16, height: 1.22)
    static let restingRefractionAmount = -7.0
    static let restingRefractionHeight = 6.0
    static let liftedRefractionAmount = -9.2
    static let liftedRefractionHeight = 7.8
    private static let glassRefracts: Bool = {
        if #available(macOS 26.0, *) { return true }
        return false
    }()

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let midY = proxy.size.height / 2
            let segment = width / Double(max(1, model.titles.count))
            let pillX = model.dragX ?? segment * Double(model.selectedIndex)
            let lift = CGSize(
                width: 1 + (Self.liftScale.width - 1) * model.liftProgress,
                height: 1 + (Self.liftScale.height - 1) * model.liftProgress
            )
            // Grown by its frame, never a scale effect: turning a scale on or
            // off rebuilds the glass, which flashes gray before it's tuned.
            let pillWidth = segment * lift.width
            let pillHeight = Self.pillHeight * lift.height
            // Dimmed while the Dock can't move. Never the glass: inside a
            // dimmed layer, macOS rebuilds it in its own gray. Never exactly 1
            // either: going to or from 1 adds or removes a layer beside the
            // glass, which can make SwiftUI rebuild the glass too.
            let dim = model.isEnabled ? 0.999 : 0.45

            ZStack(alignment: .topLeading) {
                track
                    .frame(width: width, height: Self.trackHeight)
                    .position(x: width / 2, y: midY)
                    .opacity(dim)

                if Self.glassRefracts {
                    // Backing behind the text gives the pill its crisp body and rim
                    // without washing out or dimming the labels.
                    pillBacking(lifted: model.isLifted, clear: true)
                        .frame(width: pillWidth, height: pillHeight)
                        .position(x: pillX + segment / 2, y: midY)
                        .opacity(dim)

                    // Behind the glass, the names are cut away under the pill, so
                    // the glass never has text under it to blur or mirror. Its
                    // left and right rims still bend the names beside it.
                    names(segment: segment, size: proxy.size)
                        .mask {
                            Rectangle()
                                .overlay {
                                    pillShape(width: pillWidth, height: pillHeight, centerX: pillX + segment / 2, midY: midY)
                                        .blendMode(.destinationOut)
                                }
                                .compositingGroup()
                        }
                        .opacity(dim)

                    pillGlass
                        .frame(width: pillWidth, height: pillHeight)
                        .position(x: pillX + segment / 2, y: midY)

                    // The name under the pill sits on top of the glass: sharp,
                    // with no refraction.
                    names(segment: segment, size: proxy.size)
                        .mask { pillShape(width: pillWidth, height: pillHeight, centerX: pillX + segment / 2, midY: midY) }
                        .opacity(dim)
                } else {
                    // Before macOS 26 the plain pill sits under the names.
                    pillBacking(lifted: model.isLifted)
                        .frame(width: pillWidth, height: pillHeight)
                        .position(x: pillX + segment / 2, y: midY)
                        .opacity(dim)
                    names(segment: segment, size: proxy.size)
                        .opacity(dim)
                }
            }
        }
        .accessibilityRepresentation {
            Picker("Dock Position", selection: Binding(
                get: { model.selectedIndex },
                set: { model.onSelect($0) }
            )) {
                ForEach(model.titles.indices, id: \.self) { index in
                    Text(model.titles[index]).tag(index)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!model.isEnabled)
        }
    }

    /// Where the pill is, for cutting the names around it.
    private func pillShape(width: Double, height: Double, centerX: Double, midY: Double) -> some View {
        Capsule()
            .frame(width: width, height: height)
            .position(x: centerX, y: midY)
    }

    /// Left, Bottom and Right, one per side.
    private func names(segment: Double, size: CGSize) -> some View {
        HStack(spacing: 0) {
            ForEach(model.titles.indices, id: \.self) { index in
                let chosen = index == model.highlightedIndex
                Text(model.titles[index])
                    .font(.system(size: 12.5, weight: chosen ? .semibold : .regular))
                    .foregroundStyle(chosen ? .primary : .secondary)
                    .frame(width: segment, height: Self.trackHeight)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// Outline only, with no gray fill behind the names or the pill.
    private var track: some View {
        Capsule()
            .strokeBorder(
                colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08),
                lineWidth: 1
            )
    }

    /// The pill's body. Under Liquid Glass it's totally clear, resting or held:
    /// no fill, no shadow and the same rim, so nothing fades in or out when it's
    /// picked up. The plain pill before macOS 26 keeps its fill and shadow.
    private func pillBacking(lifted: Bool, clear: Bool = false) -> some View {
        let lifted = clear ? false : lifted
        return Capsule()
            .fill(
                clear ? Color.clear
                    : colorScheme == .dark
                    ? Color.white.opacity(lifted ? 0.10 : 0.15)
                    : Color.white.opacity(lifted ? 0.52 : 0.92)
            )
            .overlay {
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [
                                    .white.opacity(lifted ? 0.32 : 0.20),
                                    .white.opacity(0.06),
                                    .white.opacity(lifted ? 0.22 : 0.12)
                                ]
                                : [
                                    .white.opacity(lifted ? 0.95 : 0.75),
                                    .white.opacity(lifted ? 0.45 : 0.30),
                                    .white.opacity(lifted ? 0.90 : 0.65)
                                ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: lifted ? 1.2 : 0.8
                    )
            }
            .shadow(
                color: clear ? .clear
                    : .black.opacity(colorScheme == .dark ? (lifted ? 0.35 : 0.20) : (lifted ? 0.12 : 0.07)),
                radius: lifted ? 6 : 1.5,
                y: lifted ? 2 : 0.5
            )
    }

    @ViewBuilder private var pillGlass: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.clear, in: .capsule)
        }
    }
}

/// The "Dock Position" row in Dock Settings. It follows the pointer itself,
/// like a slider in a menu, so the menu doesn't take the drag.
final class DockPositionRowView: NSView {
    private let model = DockPositionPickerModel()
    private let hostingView: NSHostingView<DockPositionPicker>
    private let tags: [Int]
    private let changeHandler: (Int) -> Void
    private var isTracking = false
    private var glassTuningObserver: CFRunLoopObserver?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: DockPositionPicker.rowHeight)
    }

    init(
        options: [(title: String, tag: Int)],
        selectedTag: Int,
        changeHandler: @escaping (Int) -> Void
    ) {
        tags = options.map(\.tag)
        self.changeHandler = changeHandler
        model.titles = options.map(\.title)
        hostingView = NSHostingView(rootView: DockPositionPicker(model: model))
        super.init(frame: NSRect(x: 0, y: 0, width: 232, height: DockPositionPicker.rowHeight))
        autoresizingMask = [.width]

        model.onSelect = { [weak self] index in self?.select(index) }
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        // Spans the same width as the sliders below it.
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10.5),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setSelectedTag(selectedTag)
    }

    required init?(coder: NSCoder) { nil }

    func setSelectedTag(_ selectedTag: Int) {
        guard !isTracking, let index = tags.firstIndex(of: selectedTag) else { return }
        model.selectedIndex = index
        model.highlightedIndex = index
        retuneGlassNow()
    }

    func setControlsEnabled(_ enabled: Bool) {
        model.isEnabled = enabled
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopGlassTuning()
            liftLink?.invalidate()
            liftLink = nil
        } else {
            startGlassTuning()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        retuneGlassNow()
    }

    /// Has SwiftUI draw a change right away and tunes it before it's on screen.
    private func retuneGlassNow() {
        hostingView.layoutSubtreeIfNeeded()
        applyGlassTuning()
    }

    /// SwiftUI can put back the glass's own gray settings whenever it updates
    /// it, up to the last frame of a spring. While the menu shows, the tuning
    /// runs after SwiftUI and AppKit update the layers and just before Core
    /// Animation (order 2,000,000) sends each frame to the screen.
    private func startGlassTuning() {
        retuneGlassNow()
        guard #available(macOS 26.0, *), glassTuningObserver == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            true,
            1_999_999
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else { return }
                self.applyGlassTuning()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        glassTuningObserver = observer
    }

    private func stopGlassTuning() {
        guard let observer = glassTuningObserver else { return }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        CFRunLoopObserverInvalidate(observer)
        glassTuningObserver = nil
    }

    override func layout() {
        super.layout()
        applyGlassTuning()
    }

    /// Configures the Liquid Glass backdrop layer to render at full Retina resolution
    /// with zero blur and a refraction profile that bends text horizontally along the
    /// left and right rims without reaching the text from the top and bottom edges.
    private func applyGlassTuning() {
        guard #available(macOS 26.0, *), let rootLayer = hostingView.layer else { return }
        let refractAmount = model.isLifted
            ? DockPositionPicker.liftedRefractionAmount
            : DockPositionPicker.restingRefractionAmount
        let refractHeight = model.isLifted
            ? DockPositionPicker.liftedRefractionHeight
            : DockPositionPicker.restingRefractionHeight
        Self.tuneGlassLayerTree(
            rootLayer,
            refractAmount: refractAmount,
            refractHeight: refractHeight
        )
    }

    private static func tuneGlassLayerTree(
        _ layer: CALayer,
        refractAmount: Double,
        refractHeight: Double
    ) {
        if String(describing: type(of: layer)).contains("Backdrop"),
           (layer.value(forKey: "scale") as? NSNumber)?.doubleValue != 2.0 {
            layer.setValue(2.0, forKey: "scale")
        }
        if let filters = layer.filters {
            for filter in filters {
                // Only a named glass filter that has these inputs; anything
                // else, as after a macOS change, is left as macOS draws it.
                guard let object = filter as? NSObject,
                      let name = object.value(forKey: "name") as? String,
                      let keys = object.value(forKey: "inputKeys") as? [String],
                      keys.contains("inputBlurRadius") else { continue }
                let path = "filters.\(name)."
                func set(_ value: Any, _ key: String) {
                    guard keys.contains(key) else { return }
                    // Only when it differs, so tuning before every frame
                    // doesn't make Core Animation redraw anything.
                    if let current = layer.value(forKeyPath: path + key),
                       CFEqual(current as AnyObject, value as AnyObject) {
                        return
                    }
                    layer.setValue(value, forKeyPath: path + key)
                }
                set(0.0, "inputBlurRadius")
                set(1.0, "inputFaceColorMatrixWhite")
                set(0.0, "inputFaceColorMatrixBlack")
                set(CGColor(gray: 1.0, alpha: 0.0), "inputFaceColorMatrixFillColor")
                set(refractAmount, "inputInnerRefractionAmount")
                set(refractHeight, "inputInnerRefractionHeight")
            }
        }
        for sublayer in layer.sublayers ?? [] {
            tuneGlassLayerTree(
                sublayer,
                refractAmount: refractAmount,
                refractHeight: refractHeight
            )
        }
    }

    // MARK: Selecting

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func animate(_ animation: Animation, _ changes: () -> Void) {
        withAnimation(reduceMotion ? nil : animation, changes)
    }

    /// Sets the pill down on a side, at its normal size.
    private func select(_ index: Int) {
        guard model.isEnabled else { return }
        let changed = index != model.selectedIndex
        animate(.spring(response: 0.36, dampingFraction: 0.68)) {
            model.dragX = nil
            model.selectedIndex = index
            model.highlightedIndex = index
        }
        // After the new side is set, so a pointer over where the pill lands
        // keeps it at its hover size.
        setLifted(false)
        retuneGlassNow()
        guard changed, tags.indices.contains(index) else { return }
        // The Dock moves once the pill has shrunk. While its size animates,
        // SwiftUI resets the glass to gray every frame and the tuning puts it
        // back before each frame, but the Dock restart can force a redraw in
        // between, which showed as a gray flash.
        let tag = tags[index]
        let changeHandler = changeHandler
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.liftDuration + 0.04) {
            changeHandler(tag)
        }
    }

    /// How long the pill takes to grow when picked up or shrink when let go.
    private static let liftDuration = 0.18

    private var liftLink: CADisplayLink?
    private var liftStart: CFTimeInterval = 0
    private var liftFrom = 0.0
    private var liftTo = 0.0

    /// Grows or shrinks the pill. Each frame, the row sets the size, has
    /// SwiftUI draw it and tunes the glass, all before the frame goes out.
    /// Left to SwiftUI's own animation, the size changes between tunings,
    /// and the glass shows macOS's gray for a frame.
    private func setLifted(_ lifted: Bool) {
        guard model.isLifted != lifted else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.isLifted = lifted }
        // Let go with the pointer still over it, it settles at its hover size.
        animateLift(to: lifted ? 1 : (pointerIsOverPill() ? Self.hoverProgress : 0))
    }

    /// How far toward its held size the pill grows under the pointer: about
    /// 4% bigger, a hint that it can be picked up.
    private static let hoverProgress = 0.25

    private func animateLift(to target: Double) {
        guard liftTo != target || liftLink == nil && model.liftProgress != target else { return }
        liftFrom = model.liftProgress
        liftTo = target
        liftStart = CACurrentMediaTime()
        guard !reduceMotion, window != nil else {
            stepLift(to: liftTo)
            return
        }
        stepLift(to: liftFrom)
        guard liftLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(liftTick(_:)))
        link.add(to: .main, forMode: .common)
        liftLink = link
    }

    // MARK: Hover

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) { updateHover() }
    override func mouseEntered(with event: NSEvent) { updateHover() }
    override func mouseExited(with event: NSEvent) { updateHover() }

    /// Grows the resting pill slightly while the pointer is over it.
    private func updateHover() {
        guard !isTracking, !model.isLifted else { return }
        let over = model.isEnabled && pointerIsOverPill()
        animateLift(to: over ? Self.hoverProgress : 0)
    }

    /// Whether the pointer is over the resting pill, not just the row.
    private func pointerIsOverPill() -> Bool {
        guard let window, !tags.isEmpty else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let track = hostingView.frame
        let segment = track.width / Double(tags.count)
        let pill = NSRect(
            x: track.minX + segment * Double(model.selectedIndex),
            y: track.midY - DockPositionPicker.pillHeight / 2,
            width: segment,
            height: DockPositionPicker.pillHeight
        )
        return pill.contains(point)
    }

    @objc private func liftTick(_ link: CADisplayLink) {
        let t = min(1, (CACurrentMediaTime() - liftStart) / Self.liftDuration)
        let eased = 1 - pow(1 - t, 3)
        stepLift(to: liftFrom + (liftTo - liftFrom) * eased)
        if t >= 1 {
            link.invalidate()
            liftLink = nil
        }
    }

    private func stepLift(to progress: Double) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.liftProgress = progress }
        retuneGlassNow()
    }

    // MARK: Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard model.isEnabled, let window, !tags.isEmpty else { return }
        let track = hostingView.frame
        let start = convert(event.locationInWindow, from: nil)
        let trackHeight = DockPositionPicker.trackHeight
        let trackBand = NSRect(x: track.minX, y: track.midY - trackHeight / 2 - 4,
                               width: track.width, height: trackHeight + 8)
        guard trackBand.contains(start) else { return }

        let segment = track.width / Double(tags.count)
        let pillStartX = segment * Double(model.selectedIndex)
        let grabbedPill = (start.x - track.minX) >= pillStartX - 2
            && (start.x - track.minX) <= pillStartX + segment + 2
        var moved = false
        var tickedIndex = model.selectedIndex

        if grabbedPill {
            // Picked up: the pill grows as soon as it's pressed.
            isTracking = true
            setLifted(true)
        }

        while true {
            let next = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: Date(timeIntervalSinceNow: 0.1),
                inMode: .eventTracking,
                dequeue: true
            )
            applyGlassTuning()
            // A release can go missing; never hold on once the button is up.
            if next?.type == .leftMouseUp || (next == nil && NSEvent.pressedMouseButtons & 1 == 0) {
                break
            }
            guard grabbedPill, let next, next.type == .leftMouseDragged else { continue }
            let point = convert(next.locationInWindow, from: nil)
            if !moved, abs(point.x - start.x) < 3 { continue }
            moved = true
            let x = min(max(pillStartX + point.x - start.x, 0), track.width - segment)
            let nearest = min(max(Int((x + segment / 2) / segment), 0), tags.count - 1)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                model.dragX = x
                model.highlightedIndex = nearest
            }
            retuneGlassNow()
            // A tick each time the pill crosses onto another side.
            if nearest != tickedIndex {
                tickedIndex = nearest
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
        isTracking = false

        if grabbedPill {
            select(moved ? model.highlightedIndex : model.selectedIndex)
        } else {
            let tapped = Int((start.x - track.minX) / segment)
            select(min(max(tapped, 0), tags.count - 1))
        }
    }

}
