import AppKit
import IOKit.ps
import QuartzCore

struct DesktopChangeDestination: Equatable {
    let displayID: CGDirectDisplayID
    let spaceID: UInt64
    let title: String
    let displayName: String
    let isFullscreen: Bool
}

enum DesktopSwipePreview {
    static func adjacentSpace(in order: [UInt64], from current: UInt64, forward: Bool) -> UInt64? {
        guard let index = order.firstIndex(of: current) else { return nil }
        let next = index + (forward ? 1 : -1)
        return order.indices.contains(next) ? order[next] : nil
    }
}

// Track Space identities, not desktop numbers: renumbering after deletion or
// reordering must not announce a switch when the current Space stayed the same.
struct DesktopChangeTracker {
    private var previous: [CGDirectDisplayID: UInt64] = [:]

    mutating func update(_ destinations: [DesktopChangeDestination]) -> [DesktopChangeDestination] {
        let changed = destinations.filter {
            guard let old = previous[$0.displayID] else { return false }
            return old != $0.spaceID
        }
        previous = Dictionary(uniqueKeysWithValues: destinations.map { ($0.displayID, $0.spaceID) })
        return changed
    }
}

// Require a short uninterrupted ready interval, rather than presenting on
// whichever notification happens to arrive first during a Space transition.
struct DesktopTooltipReadiness {
    private var readySince: TimeInterval?

    mutating func update(isReady: Bool, now: TimeInterval, settlingDuration: TimeInterval = 0.1) -> Bool {
        guard isReady else {
            readySince = nil
            return false
        }
        if readySince == nil { readySince = now }
        return now - (readySince ?? now) >= settlingDuration
    }
}

struct DesktopTooltipPlacement {
    static func centeredMenuBarAnchor(
        screenFrame: NSRect,
        visibleFrame: NSRect
    ) -> NSRect {
        let anchorY = min(screenFrame.maxY - 1, visibleFrame.maxY)
        return NSRect(x: screenFrame.midX - 1, y: anchorY, width: 2, height: 1)
    }
}

// Compatibility surface for systems that predate native Liquid Glass.
@MainActor
private final class DesktopPillMaterialView: NSVisualEffectView {
    private var maskedSize: NSSize = .zero

    override func layout() {
        super.layout()
        guard bounds.size != maskedSize, bounds.width > 0, bounds.height > 0 else { return }
        maskedSize = bounds.size
        maskImage = NSImage(size: bounds.size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2,
                         yRadius: rect.height / 2).fill()
            return true
        }
    }
}

@MainActor
private final class DesktopTooltipAnchorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DesktopChangeTooltip: NSObject {
    // Native glass draws its rim and optical effects beyond its layout bounds.
    private static let glassOverflowInset: CGFloat = 10
    private static let hostHasInternalBattery: Bool = {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return sources.contains { source in
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { return false }
            return description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }()

    private func symbolName(for destination: DesktopChangeDestination) -> String {
        if destination.isFullscreen { return "arrow.up.left.and.arrow.down.right" }
        return CGDisplayIsBuiltin(destination.displayID) != 0 && Self.hostHasInternalBattery
            ? "laptopcomputer" : "display"
    }
    static let preferenceKey = "showDesktopChangeTooltip"
    static let durationPreferenceKey = "desktopChangeTooltipDuration"
    static let displayUnderneathPreferenceKey = "desktopChangeTooltipDisplayUnderneath"
    static let defaultDuration: TimeInterval = 4.0
    static let minDuration: TimeInterval = 1.0
    static let maxDuration: TimeInterval = 10.0

    static var duration: TimeInterval {
        get {
            let saved = UserDefaults.standard.double(forKey: durationPreferenceKey)
            if saved >= minDuration && saved <= maxDuration {
                return saved
            }
            return defaultDuration
        }
        set {
            let clamped = min(maxDuration, max(minDuration, newValue))
            UserDefaults.standard.set(clamped, forKey: durationPreferenceKey)
        }
    }

    static var isDisplayUnderneath: Bool {
        get {
            UserDefaults.standard.bool(forKey: displayUnderneathPreferenceKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: displayUnderneathPreferenceKey)
        }
    }

    private var tracker = DesktopChangeTracker()
    private var presentation: DispatchWorkItem?
    private var dismissal: DispatchWorkItem?
    private var activePanel: DesktopTooltipAnchorPanel?
    private var activePanelIsStacked: Bool?
    private var gestureContactsActive = false
    private var presentationActive = false
    private var readingDuration: TimeInterval { Self.duration }
    private var currentPillHeight: CGFloat { Self.isDisplayUnderneath ? 44 : 34 }
    private var contentWidth: CGFloat = 220
    private var generation = 0
    private var latestDestinations: [DesktopChangeDestination] = []
    private var displayedDestination: DesktopChangeDestination?
    private weak var titleLabel: NSTextField?
    private weak var subtitleLabel: NSTextField?
    private weak var destinationIcon: NSImageView?
    private weak var dotLabel: NSTextField?
    private var canRemainVisible: (@MainActor () -> Bool)?
    private var dismissalDeadline: TimeInterval = 0

    func applyTheme(_ theme: DockAwayTheme) {
        // Nonactivating panels can retain their resolved window appearance.
        // Update the window explicitly without replacing or flashing its glass.
        activePanel?.appearance = theme.appearance
    }

    func resetPanel() {
        dismiss(animated: false)
        activePanel = nil
        titleLabel = nil
        subtitleLabel = nil
        destinationIcon = nil
        dotLabel = nil
        activePanelIsStacked = nil
    }

    private var isPresented: Bool {
        presentationActive
    }

    func desktopGestureContactsChanged(_ fingers: Int) {
        gestureContactsActive = fingers >= 3
        if gestureContactsActive {
            dismissalDeadline = ProcessInfo.processInfo.systemUptime + readingDuration
        }
    }

    func update(_ destinations: [DesktopChangeDestination], preferredDisplayID: CGDirectDisplayID,
                canPresent: @escaping @MainActor () -> Bool) {
        latestDestinations = destinations
        canRemainVisible = canPresent
        let changed = tracker.update(destinations)
        guard UserDefaults.standard.bool(forKey: Self.preferenceKey) else {
            dismiss()
            return
        }
        guard let destination = changed.first(where: { $0.displayID == preferredDisplayID }) ?? changed.first else {
            if let displayedDestination,
               let current = destinations.first(where: { $0.displayID == displayedDestination.displayID }),
               current != displayedDestination, isPresented {
                updateContent(current)
            }
            return
        }
        generation += 1
        presentation?.cancel()
        presentation = nil
        if isPresented {
            updateContent(destination)
            scheduleDismissal()
            return
        }
        guard canPresent() else {
            schedule(destination, generation: generation,
                     readiness: DesktopTooltipReadiness(), attemptsRemaining: 100, canPresent: canPresent)
            return
        }
        show(destination)
    }

    private func schedule(_ destination: DesktopChangeDestination, generation: Int,
                          readiness: DesktopTooltipReadiness,
                          attemptsRemaining: Int, canPresent: @escaping @MainActor () -> Bool) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation,
                  let current = self.latestDestinations.first(where: {
                      $0.displayID == destination.displayID && $0.spaceID == destination.spaceID
                  }),
                  UserDefaults.standard.bool(forKey: Self.preferenceKey) else { return }
            var readiness = readiness
            guard readiness.update(isReady: canPresent(),
                                   now: ProcessInfo.processInfo.systemUptime,
                                   settlingDuration: 0.05) else {
                if attemptsRemaining > 0 {
                    self.schedule(destination, generation: generation, readiness: readiness,
                                  attemptsRemaining: attemptsRemaining - 1, canPresent: canPresent)
                }
                return
            }
            self.presentation = nil
            self.show(current)
        }
        presentation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)
    }

    func dismiss(animated: Bool = false) {
        generation += 1
        let closingGeneration = generation
        presentation?.cancel()
        presentation = nil
        dismissal?.cancel()
        dismissal = nil
        presentationActive = false
        guard let panel = activePanel else { return }
        // Keep the window and native glass alive for the next presentation.
        // A late fade completion must never hide a newly refreshed capsule.
        if animated && panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self, weak panel] in
                Task { @MainActor in
                    guard let self, self.generation == closingGeneration,
                          !self.presentationActive else { return }
                    panel?.orderOut(nil)
                }
            }
        } else {
            panel.orderOut(nil)
        }
    }

    private func formatLabels(for destination: DesktopChangeDestination) -> (title: String, subtitle: String) {
        if destination.isFullscreen {
            let isGenericFullscreen = destination.title.caseInsensitiveCompare("fullscreen") == .orderedSame
            let title = isGenericFullscreen ? "Fullscreen" : destination.title
            return (title, destination.displayName)
        } else {
            return (destination.title, destination.displayName)
        }
    }

    private func calculateContentWidth(titleText: String, subtitleText: String) -> CGFloat {
        if Self.isDisplayUnderneath {
            let iconWidth: CGFloat = 18
            let titleWidth = ceil((titleText as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)]).width)
            let subtitleWidth = ceil((subtitleText as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .regular)]).width)
            let leadingPadding: CGFloat = 14
            let spacingAfterIcon: CGFloat = 9
            let textWidth = max(titleWidth, subtitleWidth)
            let trailingPadding: CGFloat = 16
            let calculated = leadingPadding + iconWidth + spacingAfterIcon + textWidth + trailingPadding
            return max(160, min(380, calculated))
        } else {
            let iconWidth: CGFloat = 16
            let titleWidth = ceil((titleText as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)]).width)
            let dotWidth = ceil(("·" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width)
            let subtitleWidth = ceil((subtitleText as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .regular)]).width)
            let leadingPadding: CGFloat = 13
            let trailingPadding: CGFloat = 14
            let spacingAfterIcon: CGFloat = 7
            let spacingAfterTitle: CGFloat = 6
            let spacingAfterDot: CGFloat = 6
            let calculated = leadingPadding + iconWidth + spacingAfterIcon + titleWidth + spacingAfterTitle + dotWidth + spacingAfterDot + subtitleWidth + trailingPadding
            return max(180, min(380, calculated))
        }
    }

    private func panelFrame(for width: CGFloat, destination: DesktopChangeDestination) -> NSRect {
        let pillHeight = currentPillHeight
        let gapBelowMenuBar: CGFloat = 6
        let screen = NSScreen.screen(withDisplayID: destination.displayID)
            ?? NSScreen.main ?? NSScreen.screens.first

        guard let screen else {
            return NSRect(x: 0, y: 0, width: width, height: pillHeight)
                .insetBy(dx: -Self.glassOverflowInset, dy: -Self.glassOverflowInset)
        }

        let anchor = DesktopTooltipPlacement.centeredMenuBarAnchor(
            screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        var panelX = anchor.midX - width / 2
        let panelY = anchor.minY - pillHeight - gapBelowMenuBar
        let minX = screen.visibleFrame.minX + 8
        let maxX = screen.visibleFrame.maxX - width - 8
        if minX <= maxX {
            panelX = min(max(panelX, minX), maxX)
        }
        return NSRect(x: panelX, y: panelY, width: width, height: pillHeight)
            .insetBy(dx: -Self.glassOverflowInset, dy: -Self.glassOverflowInset)
    }

    private func updateContent(_ destination: DesktopChangeDestination) {
        let shouldAnimate = presentationActive && activePanel?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shouldAnimate, displayedDestination != destination {
            for label in [titleLabel, subtitleLabel].compactMap({ $0 }) {
                label.wantsLayer = true
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.16
                label.layer?.add(fade, forKey: "desktopNumberChange")
            }
        }
        displayedDestination = destination
        let labels = formatLabels(for: destination)
        titleLabel?.stringValue = labels.title
        subtitleLabel?.stringValue = labels.subtitle
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: Self.isDisplayUnderneath ? 15 : 13, weight: .semibold)
        destinationIcon?.image = NSImage(systemSymbolName: symbolName(for: destination), accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        destinationIcon?.contentTintColor = destination.isFullscreen ? .systemGreen : .systemBlue

        let newWidth = calculateContentWidth(titleText: labels.title, subtitleText: labels.subtitle)
        contentWidth = newWidth
        if let panel = activePanel {
            let newFrame = panelFrame(for: newWidth, destination: destination)
            if shouldAnimate {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrame(newFrame, display: true)
                }
            } else {
                panel.setFrame(newFrame, display: true)
            }
            panel.invalidateShadow()
        }
    }

    private func scheduleDismissal() {
        dismissal?.cancel()
        dismissalDeadline = ProcessInfo.processInfo.systemUptime + readingDuration
        checkDismissal(generation: generation)
    }

    private func checkDismissal(generation: Int) {
        let close = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation, self.isPresented else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let ready = self.canRemainVisible?() != false
            if !ready || self.gestureContactsActive {
                self.dismissalDeadline = now + self.readingDuration
            }
            if now >= self.dismissalDeadline {
                self.dismiss(animated: true)
            } else {
                self.checkDismissal(generation: generation)
            }
        }
        dismissal = close
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: close)
    }

    private func show(_ destination: DesktopChangeDestination) {
        if let panel = activePanel {
            if activePanelIsStacked == Self.isDisplayUnderneath {
                updateContent(destination)
                presentationActive = true
                reveal(panel)
                scheduleDismissal()
                return
            } else {
                resetPanel()
            }
        }

        let isStacked = Self.isDisplayUnderneath
        let pillHeight = currentPillHeight
        let leadingPadding: CGFloat = isStacked ? 14 : 13
        let trailingPadding: CGFloat = isStacked ? 16 : 14
        let spacingAfterIcon: CGFloat = isStacked ? 9 : 7
        let iconSize: CGFloat = isStacked ? 18 : 16

        let labels = formatLabels(for: destination)
        contentWidth = calculateContentWidth(titleText: labels.title, subtitleText: labels.subtitle)
        let frame = panelFrame(for: contentWidth, destination: destination)

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: symbolName(for: destination),
            accessibilityDescription: nil
        )
        icon.symbolConfiguration = .init(pointSize: isStacked ? 15 : 13, weight: .semibold)
        icon.contentTintColor = destination.isFullscreen ? .systemGreen : .systemBlue
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: labels.title)
        title.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .left
        title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.required, for: .horizontal)

        let subtitle = NSTextField(labelWithString: labels.subtitle)
        subtitle.font = isStacked
            ? .systemFont(ofSize: 11, weight: .regular)
            : .systemFont(ofSize: 12, weight: .regular)
        subtitle.textColor = isStacked ? .secondaryLabelColor : .labelColor
        subtitle.alignment = .left
        subtitle.maximumNumberOfLines = 1
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        titleLabel = title
        subtitleLabel = subtitle
        destinationIcon = icon
        displayedDestination = destination

        let containerRow: NSView
        if isStacked {
            let textColumn = NSStackView(views: [title, subtitle])
            textColumn.orientation = .vertical
            textColumn.alignment = .leading
            textColumn.spacing = 1
            textColumn.translatesAutoresizingMaskIntoConstraints = false

            let mainRow = NSStackView(views: [icon, textColumn])
            mainRow.orientation = .horizontal
            mainRow.alignment = .centerY
            mainRow.spacing = spacingAfterIcon
            mainRow.translatesAutoresizingMaskIntoConstraints = false
            containerRow = mainRow
        } else {
            let dot = NSTextField(labelWithString: "·")
            dot.font = .systemFont(ofSize: 12, weight: .medium)
            dot.textColor = .secondaryLabelColor
            dot.setContentCompressionResistancePriority(.required, for: .horizontal)
            dotLabel = dot

            let row = NSStackView(views: [icon, title, dot, subtitle])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            row.setCustomSpacing(spacingAfterIcon, after: icon)
            row.setCustomSpacing(6, after: title)
            row.setCustomSpacing(6, after: dot)
            row.translatesAutoresizingMaskIntoConstraints = false
            containerRow = row
        }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: pillHeight))
        content.autoresizingMask = [.width, .height]
        content.addSubview(containerRow)
        let surface: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: content.bounds)
            glass.style = .clear
            glass.cornerRadius = pillHeight / 2
            glass.contentView = content
            surface = glass
        } else {
            let material = DesktopPillMaterialView(frame: content.bounds)
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.addSubview(content)
            surface = material
        }
        surface.autoresizingMask = [.width, .height]
        // Inherit NSApp.appearance so a retained pill follows theme changes.
        surface.appearance = nil

        NSLayoutConstraint.activate([
            containerRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: leadingPadding),
            containerRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -trailingPadding),
            containerRow.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: iconSize),
            icon.heightAnchor.constraint(equalToConstant: iconSize)
        ])

        let panel = DesktopTooltipAnchorPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.appearance = DockAwayTheme.current.appearance
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        surface.frame = container.bounds.insetBy(
            dx: Self.glassOverflowInset, dy: Self.glassOverflowInset)
        container.addSubview(surface)
        panel.contentView = container
        container.layoutSubtreeIfNeeded()
        activePanel = panel
        activePanelIsStacked = isStacked
        presentationActive = true
        reveal(panel)
        scheduleDismissal()
    }

    private func reveal(_ panel: NSPanel) {
        panel.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        if panel.alphaValue == 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 1
            }
        }
    }
}
