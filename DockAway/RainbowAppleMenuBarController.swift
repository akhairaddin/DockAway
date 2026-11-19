import AppKit
import CoreGraphics

@MainActor
final class RainbowAppleMenuBarController {
    static let preferenceKey = "rainbowAppleMenuBarLogo"

    private static let appleLogoSize = NSSize(width: 19, height: 22)
    private static let appleLogoLeadingOffset: CGFloat = 17.5
    private static let appleGlyphDrawOrigin = CGPoint(x: 2.5, y: 4.5)
    private static let appleMenuTitleFieldHeight: CGFloat = 14.091796875
    private static let pollInterval: TimeInterval = 0.25

    var isSuspended: () -> Bool = { false }
    var currentDesktopIsFullscreen: (CGDirectDisplayID) -> Bool = { _ in false }
    var restoreToEveryDesktop: (NSWindow) -> Void = { _ in }

    private var isEnabled = false
    private var panelsByDisplayID: [CGDirectDisplayID: RainbowAppleOverlayPanel] = [:]
    private var workspaceNotificationTokens: [NSObjectProtocol] = []
    private var appNotificationTokens: [NSObjectProtocol] = []
    private var distributedNotificationTokens: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var pollInFlight = false
    private var screenIsLocked = false
    private var displayIsAsleep = false
    private var systemIsAsleep = false
    private var sessionIsActive = true
    private lazy var rainbowAppleImage: NSImage = Self.makeRainbowAppleImage()

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else {
            if enabled {
                refreshOverlays()
            }
            return
        }
        isEnabled = enabled
        if enabled {
            startObserving()
            refreshOverlays()
        } else {
            stopObserving()
            hideAllOverlays()
        }
    }

    func stop() {
        isEnabled = false
        stopObserving()
        for panel in panelsByDisplayID.values {
            panel.orderOut(nil)
            panel.close()
        }
        panelsByDisplayID.removeAll()
    }

    private var shouldStepAside: Bool {
        screenIsLocked || displayIsAsleep || systemIsAsleep || !sessionIsActive || isSuspended()
    }

    private func startObserving() {
        guard workspaceNotificationTokens.isEmpty,
              appNotificationTokens.isEmpty,
              distributedNotificationTokens.isEmpty else { return }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let workspaceNames: [NSNotification.Name] = [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification
        ]
        workspaceNotificationTokens = workspaceNames.map { name in
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshOverlays()
                }
            }
        }

        let sleepWakeHandlers: [(NSNotification.Name, (RainbowAppleMenuBarController) -> Void)] = [
            (NSWorkspace.screensDidSleepNotification, { controller in
                controller.displayIsAsleep = true
                controller.hideAllOverlays()
            }),
            (NSWorkspace.screensDidWakeNotification, { controller in
                controller.displayIsAsleep = false
                controller.refreshOverlays()
            }),
            (NSWorkspace.willSleepNotification, { controller in
                controller.systemIsAsleep = true
                controller.hideAllOverlays()
            }),
            (NSWorkspace.didWakeNotification, { controller in
                controller.systemIsAsleep = false
                controller.refreshOverlays()
            }),
            (NSWorkspace.sessionDidResignActiveNotification, { controller in
                controller.sessionIsActive = false
                controller.hideAllOverlays()
            }),
            (NSWorkspace.sessionDidBecomeActiveNotification, { controller in
                controller.sessionIsActive = true
                controller.refreshOverlays()
            })
        ]
        for (name, handler) in sleepWakeHandlers {
            let token = workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self)
                }
            }
            workspaceNotificationTokens.append(token)
        }

        let appCenter = NotificationCenter.default
        appNotificationTokens = [
            appCenter.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshOverlays()
                }
            }
        ]

        let distributedCenter = DistributedNotificationCenter.default()
        let lockToken = distributedCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.screenIsLocked = true
                self.hideAllOverlays()
            }
        }
        let unlockToken = distributedCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.screenIsLocked = false
                self.refreshOverlays()
            }
        }
        distributedNotificationTokens = [lockToken, unlockToken]

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // Notifications still bring changes at once while scrolling.
                guard !ScrollActivity.isScrolling else { return }
                self?.pollOverlaysInBackground()
            }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .default)
        pollTimer = timer
    }

    private func pollOverlaysInBackground() {
        guard isEnabled, !pollInFlight, !ScrollActivity.isScrolling else { return }
        if shouldStepAside {
            hideAllOverlays()
            return
        }
        pollInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let rawWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            let windows = Self.parseWindows(from: rawWindows)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pollInFlight = false
                    guard self.isEnabled, !ScrollActivity.isScrolling else { return }
                    self.refreshOverlays(polledWindows: windows, restoreSpaces: false)
                }
            }
        }
    }

    private func stopObserving() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for token in workspaceNotificationTokens {
            workspaceCenter.removeObserver(token)
        }
        workspaceNotificationTokens.removeAll()

        let appCenter = NotificationCenter.default
        for token in appNotificationTokens {
            appCenter.removeObserver(token)
        }
        appNotificationTokens.removeAll()

        let distributedCenter = DistributedNotificationCenter.default()
        for token in distributedNotificationTokens {
            distributedCenter.removeObserver(token)
        }
        distributedNotificationTokens.removeAll()

        pollTimer?.invalidate()
        pollTimer = nil
        pollInFlight = false
    }

    func refreshOverlays(
        polledWindows: [MenuBarBlackoutWindow]? = nil,
        restoreSpaces: Bool = true
    ) {
        guard isEnabled, !shouldStepAside else {
            hideAllOverlays()
            return
        }

        let allWindows = polledWindows ?? Self.parseWindows(
            from: CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        )
        let displays = Self.currentDisplays()
        let displaysByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        let coveredDisplays = MenuBarBlackoutDecision.coveredDisplays(
            displays,
            windows: allWindows,
            excluding: getpid()
        )
        let menuBarLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let ownPID = getpid()

        var activeDisplayIDs = Set<CGDirectDisplayID>()

        for screen in NSScreen.screens {
            guard let displayID = screen.displayID,
                  let display = displaysByID[displayID] else { continue }
            activeDisplayIDs.insert(displayID)

            if currentDesktopIsFullscreen(displayID) || coveredDisplays.contains(displayID) {
                panelsByDisplayID[displayID]?.orderOut(nil)
                continue
            }

            guard let menuBarWindow = Self.visibleMenuBarWindow(
                for: display,
                in: allWindows,
                menuBarLevel: menuBarLevel,
                excludingPID: ownPID
            ) else {
                panelsByDisplayID[displayID]?.orderOut(nil)
                continue
            }

            let placement = Self.appleLogoPlacement(
                on: screen,
                display: display,
                menuBarBounds: menuBarWindow.bounds
            )
            let panel = panel(for: displayID)
            panel.updatePlacement(windowFrame: placement.windowFrame, subPointOffset: placement.subPointOffset)
            let targetAlpha = CGFloat(min(1.0, max(0.0, menuBarWindow.alpha)))
            if abs(panel.alphaValue - targetAlpha) > 0.01 {
                panel.alphaValue = targetAlpha
            }
            if !panel.isVisible || restoreSpaces {
                restoreToEveryDesktop(panel)
            }
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        }

        for (displayID, panel) in panelsByDisplayID where !activeDisplayIDs.contains(displayID) {
            panel.orderOut(nil)
            panel.close()
            panelsByDisplayID.removeValue(forKey: displayID)
        }
    }

    private func hideAllOverlays() {
        for panel in panelsByDisplayID.values {
            panel.orderOut(nil)
        }
    }

    private func panel(for displayID: CGDirectDisplayID) -> RainbowAppleOverlayPanel {
        if let existing = panelsByDisplayID[displayID] {
            return existing
        }
        let created = RainbowAppleOverlayPanel(image: rainbowAppleImage)
        panelsByDisplayID[displayID] = created
        return created
    }

    private static func currentDisplays() -> [MenuBarBlackoutDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            let bounds = CGDisplayBounds(id)
            let visible = screen.visibleFrame
            let usable = CGRect(
                x: bounds.minX + visible.minX - screen.frame.minX,
                y: bounds.minY + screen.frame.maxY - visible.maxY,
                width: visible.width,
                height: visible.height
            )
            return MenuBarBlackoutDisplay(id: id, frame: bounds, usableFrame: usable)
        }
    }

    nonisolated private static func parseWindows(from list: [[String: Any]]) -> [MenuBarBlackoutWindow] {
        list.compactMap { info in
            guard let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
            return MenuBarBlackoutWindow(
                bounds: bounds,
                layer: info[kCGWindowLayer as String] as? Int ?? 0,
                ownerPID: info[kCGWindowOwnerPID as String] as? pid_t ?? 0,
                alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
                id: info[kCGWindowNumber as String] as? CGWindowID ?? 0
            )
        }
    }

    private static func visibleMenuBarWindow(
        for display: MenuBarBlackoutDisplay,
        in windows: [MenuBarBlackoutWindow],
        menuBarLevel: Int,
        excludingPID: pid_t
    ) -> MenuBarBlackoutWindow? {
        let candidates = windows.filter { window in
            guard window.layer == menuBarLevel,
                  window.ownerPID != excludingPID,
                  window.alpha > 0.05,
                  window.bounds.height >= 20,
                  window.bounds.height <= 64 else { return false }
            let intersection = window.bounds.intersection(display.frame)
            guard !intersection.isNull,
                  intersection.width >= display.frame.width * 0.5,
                  intersection.height >= window.bounds.height * 0.5 else { return false }
            let topOffset = window.bounds.minY - display.frame.minY
            return topOffset >= -4 && topOffset <= 8
        }
        return candidates.max { lhs, rhs in
            let lhsWidth = lhs.bounds.intersection(display.frame).width
            let rhsWidth = rhs.bounds.intersection(display.frame).width
            return lhsWidth < rhsWidth
        }
    }

    /// WindowServer snaps NSWindow origins to integer points, while NSMenuBarItemView
    /// draws the Apple menu glyph ("\u{F8FF}" at menuBarFontOfSize: 20.0) relative to
    /// _titleFieldFrameRect. Keep the window origin on integer points and apply the
    /// fractional-point offset inside the view so the pixels line up 1:1 at 2x Retina.
    private static func appleLogoPlacement(
        on screen: NSScreen,
        display: MenuBarBlackoutDisplay,
        menuBarBounds: CGRect
    ) -> (windowFrame: NSRect, subPointOffset: NSPoint) {
        let exactX: CGFloat
        if NSApp.userInterfaceLayoutDirection == .rightToLeft {
            exactX = screen.frame.maxX - appleLogoLeadingOffset - appleLogoSize.width
        } else {
            exactX = screen.frame.minX + appleLogoLeadingOffset
        }
        let menuBarBottomInScreen = screen.frame.maxY - (menuBarBounds.maxY - display.frame.minY)
        let titleOriginY = round((menuBarBounds.height - appleMenuTitleFieldHeight) / 2.0 + 0.5)
        let exactY = menuBarBottomInScreen + titleOriginY - appleGlyphDrawOrigin.y

        let windowX = floor(exactX)
        let windowY = floor(exactY)
        let offsetX = exactX - windowX
        let offsetY = exactY - windowY
        let windowWidth = ceil(appleLogoSize.width + offsetX)
        let windowHeight = ceil(appleLogoSize.height + offsetY)

        return (
            windowFrame: NSRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight),
            subPointOffset: NSPoint(x: offsetX, y: offsetY)
        )
    }

    private static func makeRainbowAppleImage() -> NSImage {
        let canvasSize = appleLogoSize
        let finalImage = NSImage(size: canvasSize)
        for scale in [1, 2, 3] {
            if let rep = makeRainbowAppleBitmapRep(size: canvasSize, scale: scale) {
                finalImage.addRepresentation(rep)
            }
        }
        finalImage.isTemplate = false
        return finalImage
    }

    private static func makeRainbowAppleBitmapRep(size: NSSize, scale: Int) -> NSBitmapImageRep? {
        let pixelsWide = Int(round(size.width)) * scale
        let pixelsHigh = Int(round(size.height)) * scale
        guard let maskRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        maskRep.size = size

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let maskContext = NSGraphicsContext(bitmapImageRep: maskRep) else {
            return nil
        }
        NSGraphicsContext.current = maskContext
        let attributedGlyph = NSAttributedString(
            string: "\u{F8FF}",
            attributes: [
                .font: NSFont.menuBarFont(ofSize: 20.0),
                .foregroundColor: NSColor.white
            ]
        )
        let line = CTLineCreateWithAttributedString(attributedGlyph)
        maskContext.cgContext.textMatrix = .identity
        maskContext.cgContext.textPosition = appleGlyphDrawOrigin
        CTLineDraw(line, maskContext.cgContext)

        guard let baseOutRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        let outRep = baseOutRep.retagging(with: .sRGB) ?? baseOutRep
        outRep.size = size

        // In the 19x22pt canvas, the leaf spans y = 2..<6pt from the top and the
        // apple body spans y = 6..<18pt (12pt tall), so each of the six classic
        // rainbow body bands is an exact 2pt horizontal stripe.
        let topDownBands: [(y0: Int, y1: Int, r: Double, g: Double, b: Double)] = [
            (0,          8 * scale,   97.0, 187.0,  70.0), // Green (#61BB46)
            (8 * scale,  10 * scale, 253.0, 184.0,  39.0), // Yellow (#FDB827)
            (10 * scale, 12 * scale, 245.0, 130.0,  31.0), // Orange (#F5821F)
            (12 * scale, 14 * scale, 224.0,  58.0,  62.0), // Red (#E03A3E)
            (14 * scale, 16 * scale, 150.0,  61.0, 151.0), // Purple (#963D97)
            (16 * scale, pixelsHigh,   0.0, 157.0, 220.0)  // Blue (#009DDC)
        ]

        for y in 0..<pixelsHigh {
            let band = topDownBands.first { y >= $0.y0 && y < $0.y1 } ?? topDownBands[topDownBands.count - 1]
            for x in 0..<pixelsWide {
                var maskPixel: [Int] = [0, 0, 0, 0]
                maskRep.getPixel(&maskPixel, atX: x, y: y)
                let a = Double(maskPixel[3]) / 255.0
                guard a > 0 else {
                    var clearPixel: [Int] = [0, 0, 0, 0]
                    outRep.setPixel(&clearPixel, atX: x, y: y)
                    continue
                }

                // Edge pixels keep the glyph's own anti-aliasing, so the logo
                // has the real one's soft edges, narrow leaf and gap above the
                // body. They're only a little more opaque than the glyph covers
                // them, and most of the system's white glyph that shows through
                // is taken back out of their color. Taking out all of it
                // outlines the logo on colored menu bars; much more opacity
                // makes the edges hard and stair-stepped and fills the gap.
                // Simulated on black, gray, purple and blue menu bars, this is
                // the closest to the real glyph's edges on all of them.
                let overlayAlpha = min(1.0, a * 1.2)
                let maxPremult = overlayAlpha * 255.0
                let whiteShowingThrough = (1.0 - overlayAlpha) * a * 255.0 * 0.7
                let rPremult = Int(round(max(0.0, a * band.r - whiteShowingThrough)))
                let gPremult = Int(round(max(0.0, a * band.g - whiteShowingThrough)))
                let bPremult = Int(round(max(0.0, a * band.b - whiteShowingThrough)))
                let aInt = Int(round(maxPremult))
                var outPixel: [Int] = [
                    min(aInt, rPremult),
                    min(aInt, gPremult),
                    min(aInt, bPremult),
                    aInt
                ]
                outRep.setPixel(&outPixel, atX: x, y: y)
            }
        }

        return outRep
    }
}

private final class RainbowAppleOverlayPanel: NSWindow {
    private let overlayView: RainbowAppleOverlayView

    init(image: NSImage) {
        let content = RainbowAppleOverlayView(image: image)
        self.overlayView = content
        super.init(
            contentRect: NSRect(origin: .zero, size: image.size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = content
    }

    func updatePlacement(windowFrame: NSRect, subPointOffset: NSPoint) {
        overlayView.subPointOffset = subPointOffset
        if frame != windowFrame {
            setFrame(windowFrame, display: true)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

private final class RainbowAppleOverlayView: NSView {
    private let image: NSImage
    var subPointOffset: NSPoint = .zero {
        didSet {
            if subPointOffset != oldValue {
                needsDisplay = true
            }
        }
    }

    init(image: NSImage) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: image.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let drawRect = NSRect(origin: subPointOffset, size: image.size)
        image.draw(
            in: drawRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )
    }
}
