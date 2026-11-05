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
    /// How much the moving pill stretches along the track, from 0 at rest
    /// to 1 at full speed. Just below 0 as it settles, it bulges a little
    /// taller instead. The row steps it frame by frame too.
    var stretch = 0.0
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

    static let rowHeight = 40.0
    static let trackHeight = 28.0
    static let pillHeight = 28.0
    /// How much the held pill grows, across and up, still within the row.
    static let liftScale = CGSize(width: 1.16, height: 1.36)
    static let restingRefractionAmount = -7.0
    static let restingRefractionHeight = 6.0
    static let liftedRefractionAmount = -9.2
    static let liftedRefractionHeight = 7.8
    /// How much the moving pill stretches at full speed: longer by this
    /// share of its width. It keeps its full held height while it moves.
    static let stretchWidth = 0.22
    /// How far the pill may reach past either end of the track.
    static let endOverhang = 7.0
    /// How much taller it bulges for a moment as it settles.
    static let settleBulge = 0.18
    static let restingRimWidth = restingRefractionHeight + 1
    static let liftedRimWidth = liftedRefractionHeight + 1
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
            // Moving, it stretches along the track; settling, it bulges a
            // little taller for a moment.
            // Never more than a few points past either end of the track,
            // where the menu's edge could clip the glass.
            let pillCenter = pillX + segment / 2
            let pillWidth = min(
                segment * lift.width * (1 + Self.stretchWidth * model.stretch),
                2 * (min(pillCenter, width - pillCenter) + Self.endOverhang)
            )
            let pillHeight = min(
                Self.rowHeight - 1,
                Self.pillHeight * lift.height * (1 + Self.settleBulge * max(-model.stretch, 0))
            )
            // Dimmed while the Dock can't move. Never the glass: inside a
            // dimmed layer, macOS rebuilds it in its own gray. Never exactly 1
            // either: going to or from 1 adds or removes a layer beside the
            // glass, which can make SwiftUI rebuild the glass too.
            let dim = model.isEnabled ? 0.999 : 0.45
            // How far in from each end the rim bends the names: just past
            // where the glass's refraction fades out.
            let rim = Self.restingRimWidth
                + (Self.liftedRimWidth - Self.restingRimWidth) * model.liftProgress

            ZStack(alignment: .topLeading) {
                // The outline stops at the pill, so it never shows through
                // the clear glass. The gap is never smaller than a resting
                // pill, so it stays hidden while the pill dips under that
                // size as it bounces.
                let cutWidth = max(pillWidth, segment)
                let cutHeight = max(pillHeight, Self.trackHeight)
                track(cutout: CGRect(
                    x: pillCenter - cutWidth / 2,
                    y: Self.trackHeight / 2 - cutHeight / 2,
                    width: cutWidth,
                    height: cutHeight
                ))
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

                    // Behind the glass, the names are cut away under the middle of
                    // the pill, so it never blurs or mirrors them. Under its left
                    // and right rims they stay, so the rims bend each name as the
                    // pill slides over it.
                    names(segment: segment, size: proxy.size)
                        .mask {
                            Rectangle()
                                .overlay {
                                    pillInterior(width: pillWidth, height: pillHeight, rim: rim, centerX: pillX + segment / 2, midY: midY)
                                        .blendMode(.destinationOut)
                                }
                                .compositingGroup()
                        }
                        .opacity(dim)

                    pillGlass
                        .frame(width: pillWidth, height: pillHeight)
                        .position(x: pillX + segment / 2, y: midY)

                    // In the middle of the pill, the name sits on top of the glass:
                    // sharp, with no refraction. It fades into the rims, where
                    // the refraction has fallen to nothing, so there's no seam.
                    names(segment: segment, size: proxy.size)
                        .mask { pillInterior(width: pillWidth, height: pillHeight, rim: rim, centerX: pillX + segment / 2, midY: midY) }
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

    /// The pill without its left and right rims, where the sharp name shows
    /// instead of the refracted one. Its edges fade over a couple of points.
    private func pillInterior(width: Double, height: Double, rim: Double, centerX: Double, midY: Double) -> some View {
        let inner = min(0.5, rim / max(width, 1))
        let fade = min(inner, 2.5 / max(width, 1))
        return Capsule()
            .fill(LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: inner - fade),
                    .init(color: .black, location: inner),
                    .init(color: .black, location: 1 - inner),
                    .init(color: .clear, location: 1 - inner + fade),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            ))
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

    /// How thick the track's outline is.
    static let trackOutlineWidth = 1.1

    /// Outline only, with no gray fill behind the names or the pill, and cut
    /// away where the pill is.
    private func track(cutout: CGRect) -> some View {
        TrackRing(lineWidth: Self.trackOutlineWidth, cutout: cutout)
            .fill(colorScheme == .dark ? Color.white.opacity(0.2) : Color.black.opacity(0.08))
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

/// A capsule's outline, as a shape that can be filled: the band between the
/// capsule and the same capsule inset by the line width, minus the pill.
private struct TrackRing: Shape {
    var lineWidth: Double
    /// Where the pill is, in the track's own coordinates.
    var cutout: CGRect

    func path(in rect: CGRect) -> Path {
        let inset = lineWidth / 2
        let ring = Capsule()
            .path(in: rect.insetBy(dx: inset, dy: inset))
            .strokedPath(StrokeStyle(lineWidth: lineWidth))
        return ring.subtracting(Capsule().path(in: cutout))
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
        // A choice still waiting to be sent wins over a refresh from before it;
        // the refresh after the Dock moves brings the two back in step.
        if let pending = pendingChangeTag, pending != selectedTag { return }
        changeInFlight = false
        if index != model.selectedIndex {
            // Changed from elsewhere: no slide toward the old choice.
            isSliding = false
            velocity = 0
            draw { model.dragX = nil }
        }
        model.selectedIndex = index
        model.highlightedIndex = index
        retuneGlassNow()
    }

    func setControlsEnabled(_ enabled: Bool) {
        model.isEnabled = enabled
    }

    /// Set from sending a change until Dock Settings refreshes the row after
    /// the Dock restarts. Meanwhile the pill neither grows under the pointer
    /// nor can be picked up, so its size never changes while the Dock restarts.
    private var changeInFlight = false {
        didSet {
            guard changeInFlight else { return }
            // In case no refresh ever comes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.changeInFlight = false
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopGlassTuning()
            finishMotion()
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

    /// The width of one side's slot, the same as the SwiftUI view works out.
    private var segmentWidth: Double {
        hostingView.frame.width / Double(max(1, tags.count))
    }

    /// Sets the pill down on a side, at its normal size. It slides there on a
    /// spring, carrying on with the speed it was let go at.
    private func select(_ index: Int) {
        guard model.isEnabled else { return }
        let changed = index != model.selectedIndex
        let from = model.dragX ?? segmentWidth * Double(model.selectedIndex)
        let to = segmentWidth * Double(index)
        let slides = !reduceMotion && window != nil
            && (abs(to - from) >= Self.settleDistance || abs(velocity) >= Self.settleSpeed)
        draw {
            model.selectedIndex = index
            model.highlightedIndex = index
            model.dragX = slides ? from : nil
        }
        velocity = min(max(velocity, -Self.maxCarriedSpeed), Self.maxCarriedSpeed)
        if slides {
            slideTarget = to
            isSliding = true
            startFrameLink()
        } else {
            isSliding = false
            velocity = 0
        }
        // After the new side is set, so a pointer over where the pill lands
        // keeps it at its hover size.
        setLifted(false)
        guard changed, tags.indices.contains(index) else { return }
        // The Dock moves once the pill has stopped moving and changing size.
        // While its size changes, SwiftUI resets the glass to gray every frame
        // and the tuning puts it back before each frame, but the Dock restart
        // can force a redraw in between, which showed as a gray flash.
        pendingChangeTag = tags[index]
        if frameLink == nil { firePendingChange() }
    }

    private var pendingChangeTag: Int?

    private func firePendingChange() {
        guard let tag = pendingChangeTag else { return }
        pendingChangeTag = nil
        // A beat later, so the settled pill is on screen before the Dock restarts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self else { return }
            // Moving again since: it goes once the pill next comes to rest.
            if self.frameLink != nil || self.isTracking {
                if self.pendingChangeTag == nil { self.pendingChangeTag = tag }
                return
            }
            self.changeInFlight = true
            self.changeHandler(tag)
        }
    }

    /// Makes changes to the pill with no SwiftUI animation, has SwiftUI draw
    /// them right away and tunes the glass, all before the frame goes out.
    /// Left to SwiftUI's own animation, the size changes between tunings, and
    /// the glass shows macOS's gray for a frame.
    private func draw(_ changes: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
        retuneGlassNow()
    }

    // MARK: Motion

    /// How long the pill takes to grow when picked up or shrink when let go.
    private static let liftDuration = 0.18
    /// Picked up or let go, it takes a little longer and bounces: past its
    /// held size as it pops up, and a touch under its resting size as it
    /// drops back.
    private static let bouncyLiftDuration = 0.3
    /// How far a bounce carries past the end: about 8%.
    private static let liftBounce = 1.5
    /// The slide to a side: a spring with response 0.36 s and damping 0.6,
    /// bouncy enough to land a little past the side and spring back, as
    /// stiffness and damping per unit of mass.
    private static let slideStiffness = pow(2 * Double.pi / 0.36, 2)
    private static let slideDamping = 4 * Double.pi * 0.6 / 0.36
    /// How far past either end a slide can carry the pill: room for the
    /// spring's own overshoot, the same as the glass may reach past the end.
    private static let overshootRoom = DockPositionPicker.endOverhang
    /// Close enough to call the slide finished, in points and points a second.
    private static let settleDistance = 0.3
    private static let settleSpeed = 12.0
    /// The speed, in points a second, at which the pill is stretched fully.
    private static let fullStretchSpeed = 900.0
    /// The stretch follows the speed on a loose spring, so it overshoots when
    /// the pill stops: it bulges a little taller, then settles, like a drop.
    private static let stretchStiffness = 400.0
    private static let stretchDamping = 15.0
    /// How far ahead a flick is projected to pick where it lands, in seconds.
    private static let flickProjection = 0.1
    /// The most speed a let-go carries into the slide, in points a second,
    /// so it overshoots its side by a few points at most.
    private static let maxCarriedSpeed = 600.0
    /// How quickly the measured speed follows the pointer, in seconds.
    private static let speedSmoothing = 0.035

    /// One display link steps every change to the pill's size and position:
    /// growing, shrinking, sliding and stretching. Each frame it works out
    /// the new values, draws them and tunes the glass, in that order.
    private var frameLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0

    private var isLifting = false
    private var liftStart: CFTimeInterval = 0
    private var liftFrom = 0.0
    private var liftTo = 0.0

    private var isSliding = false
    private var slideTarget = 0.0
    /// How fast the pill is moving across, in points a second.
    private var velocity = 0.0
    private var lastPillX: Double?
    private var stretchVelocity = 0.0

    private func startFrameLink() {
        guard frameLink == nil, window != nil else { return }
        lastFrameTime = CACurrentMediaTime()
        lastPillX = model.dragX
        let link = displayLink(target: self, selector: #selector(frameTick(_:)))
        link.add(to: .main, forMode: .common)
        frameLink = link
    }

    /// Stops all motion where it should end, as when the menu closes.
    private func finishMotion() {
        frameLink?.invalidate()
        frameLink = nil
        isLifting = false
        isSliding = false
        velocity = 0
        stretchVelocity = 0
        draw {
            model.dragX = nil
            model.stretch = 0
            model.liftProgress = model.isLifted ? 1 : 0
        }
        liftTo = model.liftProgress
        firePendingChange()
    }

    /// Grows or shrinks the pill.
    private func setLifted(_ lifted: Bool) {
        guard model.isLifted != lifted else { return }
        draw { model.isLifted = lifted }
        // Let go with the pointer still over it, it settles at its hover size.
        animateLift(to: lifted ? 1 : (pointerIsOverPill() ? Self.hoverProgress : 0), bouncy: true)
    }

    /// How far toward its held size the pill grows under the pointer: about
    /// 4% bigger, a hint that it can be picked up.
    private static let hoverProgress = 0.25

    private var liftBounces = false

    private func animateLift(to target: Double, bouncy: Bool = false) {
        guard liftTo != target || !isLifting && model.liftProgress != target else { return }
        liftBounces = bouncy
        liftFrom = model.liftProgress
        liftTo = target
        liftStart = CACurrentMediaTime()
        guard !reduceMotion, window != nil else {
            isLifting = false
            draw { model.liftProgress = target }
            return
        }
        isLifting = true
        startFrameLink()
    }

    /// How hard hitting an end of the track squishes the pill, at full speed.
    private static let wallKick = 20.0
    private var splatScale = 1.0

    /// The pill hits an end of the track: like a drop, it gives up half its
    /// stretch at once and springs into a narrower, taller squish.
    private func splatAgainstWall(speed: Double) {
        guard !reduceMotion, abs(speed) > 150 else { return }
        let impact = min(1, abs(speed) / Self.fullStretchSpeed)
        // Drawn with the rest of this frame, never on its own.
        splatScale = 0.5
        stretchVelocity = min(stretchVelocity, -impact * Self.wallKick)
    }

    @objc private func frameTick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastFrameTime, 1.0 / 480), 1.0 / 30)
        lastFrameTime = now

        var lift = model.liftProgress
        if isLifting {
            let duration = liftBounces ? Self.bouncyLiftDuration : Self.liftDuration
            let t = min(1, (now - liftStart) / duration)
            let eased: Double
            if liftBounces {
                // Eases out past the end, then back to it.
                let s = Self.liftBounce
                eased = 1 + (s + 1) * pow(t - 1, 3) + s * pow(t - 1, 2)
            } else {
                eased = 1 - pow(1 - t, 3)
            }
            lift = liftFrom + (liftTo - liftFrom) * eased
            if t >= 1 { isLifting = false }
        }

        var x = model.dragX
        if isSliding, let start = x {
            var position = start
            var speed = velocity
            // Small steps keep the spring steady whatever the frame rate.
            var remaining = dt
            while remaining > 0 {
                let step = min(remaining, 1.0 / 480)
                let force = Self.slideStiffness * (slideTarget - position) - Self.slideDamping * speed
                speed += force * step
                position += speed * step
                remaining -= step
            }
            let maxX = hostingView.frame.width - segmentWidth
            if position < -Self.overshootRoom || position > maxX + Self.overshootRoom {
                // It meets the end of the track and bounces off softly.
                position = min(max(position, -Self.overshootRoom), maxX + Self.overshootRoom)
                splatAgainstWall(speed: speed)
                speed *= -0.2
            }
            if abs(slideTarget - position) < Self.settleDistance, abs(speed) < Self.settleSpeed {
                isSliding = false
                velocity = 0
                x = nil
            } else {
                velocity = speed
                x = position
            }
        } else if isTracking, let current = x {
            // Following the pointer: measure its speed, smoothed, since the
            // pointer and the screen don't update in step.
            let measured = lastPillX.map { (current - $0) / dt } ?? 0
            velocity += (measured - velocity) * (1 - exp(-dt / Self.speedSmoothing))
            if abs(velocity) < 5 { velocity = 0 }
            // Slammed into an end: it reacts on that frame, rather than once
            // the smoothed speed and the stretch have caught up.
            let maxX = hostingView.frame.width - segmentWidth
            let atWall = current <= 0.01 || current >= maxX - 0.01
            if atWall, let last = lastPillX, abs(last - current) > 0.01 {
                splatAgainstWall(speed: velocity)
                velocity = 0
            }
        } else {
            velocity = 0
        }
        lastPillX = x

        let moving = isTracking || isSliding
        let target = reduceMotion || !moving ? 0 : min(1, abs(velocity) / Self.fullStretchSpeed)
        var stretch = model.stretch * splatScale
        splatScale = 1
        var remaining = dt
        while remaining > 0 {
            let step = min(remaining, 1.0 / 480)
            let force = Self.stretchStiffness * (target - stretch) - Self.stretchDamping * stretchVelocity
            stretchVelocity += force * step
            stretch += stretchVelocity * step
            remaining -= step
        }
        stretch = min(max(stretch, -0.5), 1.2)
        // Settled once what's left is too small to see, well under a point.
        let stretchSettled = target == 0 && abs(stretch) < 0.01 && abs(stretchVelocity) < 0.3
        if stretchSettled {
            stretch = 0
            stretchVelocity = 0
        }

        if lift != model.liftProgress || x != model.dragX || abs(stretch - model.stretch) > 0.0001 {
            draw {
                model.liftProgress = lift
                model.dragX = x
                model.stretch = stretch
            }
        }

        if !isLifting, !isSliding, !isTracking, stretchSettled {
            link.invalidate()
            frameLink = nil
            firePendingChange()
        }
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
        guard !isTracking, !model.isLifted, !changeInFlight else { return }
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

    // MARK: Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard model.isEnabled, !changeInFlight, let window, !tags.isEmpty else { return }
        let track = hostingView.frame
        let start = convert(event.locationInWindow, from: nil)
        let trackHeight = DockPositionPicker.trackHeight
        let trackBand = NSRect(x: track.minX, y: track.midY - trackHeight / 2 - 4,
                               width: track.width, height: trackHeight + 8)
        guard trackBand.contains(start) else { return }

        let segment = track.width / Double(tags.count)
        // Where the pill is now, which is still on its way to a side if it's
        // caught mid-slide.
        let pillStartX = model.dragX ?? segment * Double(model.selectedIndex)
        let grabbedPill = (start.x - track.minX) >= pillStartX - 2
            && (start.x - track.minX) <= pillStartX + segment + 2
        var moved = false
        var tickedIndex = model.highlightedIndex

        if grabbedPill {
            // Picked up: the pill grows as soon as it's pressed, and stops
            // where it is if it was still sliding.
            isSliding = false
            isTracking = true
            setLifted(true)
            startFrameLink()
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
            draw {
                model.dragX = x
                model.highlightedIndex = nearest
            }
            // A tick each time the pill crosses onto another side.
            if nearest != tickedIndex {
                tickedIndex = nearest
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
        isTracking = false
        // The pointer ends a drag wherever it likes, often on the "?" beside
        // "Animation Speed" just below; that's no reason to open its help.
        DockSettingHelpButton.holdOffHover()

        if grabbedPill, moved || model.dragX != nil {
            // Let go while moving, it lands where it was headed: one side on
            // at most, so a flick carries it on rather than pulling it back.
            let x = model.dragX ?? pillStartX
            let maxX = track.width - segment
            let projected = min(max(x + velocity * Self.flickProjection, 0), maxX)
            let headed = min(max(Int((projected + segment / 2) / segment), 0), tags.count - 1)
            let index = min(max(headed, model.highlightedIndex - 1), model.highlightedIndex + 1)
            if index != model.highlightedIndex {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            select(index)
        } else if grabbedPill {
            select(model.selectedIndex)
        } else {
            let tapped = Int((start.x - track.minX) / segment)
            select(min(max(tapped, 0), tags.count - 1))
        }
    }

}
