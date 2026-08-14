import Cocoa
import QuartzCore
import ServiceManagement
import Sparkle
import UniformTypeIdentifiers

private final class PulsingStatusDotView: NSView {
    private let coreLayer = CALayer()
    private let pulseLayers = (0..<3).map { _ in CALayer() }
    private var isActive = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        for pulseLayer in pulseLayers {
            pulseLayer.backgroundColor = NSColor.clear.cgColor
            pulseLayer.borderWidth = 1
            pulseLayer.opacity = 0
            layer?.addSublayer(pulseLayer)
        }

        layer?.addSublayer(coreLayer)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 24, height: 24)
    }

    override func layout() {
        super.layout()

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        coreLayer.bounds = CGRect(x: 0, y: 0, width: 5, height: 5)
        coreLayer.position = center
        coreLayer.cornerRadius = 2.5

        for pulseLayer in pulseLayers {
            pulseLayer.bounds = CGRect(x: 0, y: 0, width: 7, height: 7)
            pulseLayer.position = center
            pulseLayer.cornerRadius = 3.5
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePulseAnimation()
    }

    func setActive(_ active: Bool) {
        guard isActive != active else {
            updatePulseAnimation()
            return
        }

        isActive = active
        updateAppearance()
    }

    private func updateAppearance() {
        let color = isActive ? NSColor.systemGreen : NSColor.systemRed

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        coreLayer.backgroundColor = color.cgColor
        coreLayer.shadowColor = color.cgColor
        coreLayer.shadowOpacity = isActive ? 0.9 : 0.45
        coreLayer.shadowRadius = isActive ? 4 : 2
        coreLayer.shadowOffset = .zero
        for pulseLayer in pulseLayers {
            pulseLayer.borderColor = color.withAlphaComponent(0.65).cgColor
        }
        CATransaction.commit()

        updatePulseAnimation()
    }

    private func updatePulseAnimation() {
        for pulseLayer in pulseLayers {
            pulseLayer.removeAnimation(forKey: "outwardPulse")
            pulseLayer.opacity = 0
        }

        guard
            isActive,
            window != nil,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else { return }

        for (index, pulseLayer) in pulseLayers.enumerated() {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.9
            scale.toValue = 3.1

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.58
            fade.toValue = 0

            let pulse = CAAnimationGroup()
            pulse.animations = [scale, fade]
            pulse.duration = 2.1
            pulse.beginTime = CACurrentMediaTime() + (Double(index) * 0.62)
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pulseLayer.add(pulse, forKey: "outwardPulse")
        }
    }
}

private final class DockAwayStatusView: NSVisualEffectView {
    private let statusDot = PulsingStatusDotView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let labelStack = NSStackView()
    let pauseResumeButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor

        statusDot.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        detailLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        labelStack.translatesAutoresizingMaskIntoConstraints = false
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = -1
        labelStack.addArrangedSubview(titleLabel)
        labelStack.addArrangedSubview(detailLabel)

        pauseResumeButton.translatesAutoresizingMaskIntoConstraints = false
        pauseResumeButton.title = ""
        pauseResumeButton.imagePosition = .imageOnly
        pauseResumeButton.imageScaling = .scaleProportionallyDown
        pauseResumeButton.bezelStyle = .circular
        pauseResumeButton.setButtonType(.momentaryPushIn)

        addSubview(statusDot)
        addSubview(labelStack)
        addSubview(pauseResumeButton)

        NSLayoutConstraint.activate([
            statusDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            statusDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 24),
            statusDot.heightAnchor.constraint(equalToConstant: 24),

            labelStack.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 3),
            labelStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelStack.trailingAnchor.constraint(lessThanOrEqualTo: pauseResumeButton.leadingAnchor, constant: -8),

            pauseResumeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            pauseResumeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pauseResumeButton.widthAnchor.constraint(equalToConstant: 24),
            pauseResumeButton.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(active: Bool, status: String) {
        statusDot.setActive(active)
        titleLabel.stringValue = active ? "DockAway Active" : "DockAway Stopped"
        titleLabel.textColor = active ? .labelColor : .secondaryLabelColor
        detailLabel.stringValue = active ? "App: \(status)" : "Detection paused"

        let symbolName = active ? "pause.fill" : "play.fill"
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        pauseResumeButton.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: active ? "Stop DockAway" : "Resume DockAway"
        )?.withSymbolConfiguration(symbolConfiguration)
        pauseResumeButton.contentTintColor = active ? .secondaryLabelColor : .systemGreen
        pauseResumeButton.toolTip = active ? "Stop DockAway" : "Resume DockAway"
        pauseResumeButton.setAccessibilityLabel(pauseResumeButton.toolTip ?? "Toggle DockAway")
    }
}


@objc class AppDelegate: NSObject, NSApplicationDelegate {
    private static let ignoredWindowBundleIdentifiersKey = "IgnoredWindowBundleIdentifiers"

    private struct BlacklistApplication {
        let bundleIdentifier: String
        let name: String
        let icon: NSImage?
    }

    var isQuitting = false
    private var statusItem: NSStatusItem!
    private var dockWatcher: DockWatcher!
    private var updaterController: SPUStandardUpdaterController!
    private var blacklistMenu: NSMenu!
    private var dockAwayStatusView: DockAwayStatusView!
    private var dockAwayEnabled = true
    private var activeStatusText = "Detecting…"
    
    // The Unix signal trapper
    private var sigtermSource: DispatchSourceSignal?

    // Menu bar glyph. Deliberately self-contained: DockWatcher knows nothing
    // about any of this and is never called from it.
    private var glyphTimer: Timer?
    private var glyphShowsDockVisible: Bool?

    // Four-finger pre-hide via private MultitouchSupport.
    // Set to false to keep the finger-count logging without acting on it.
    private let hideOnFourFingerTouch = true
    private let fourFingerThreshold = 4
    // Grace period after the fingers lift, so a swipe that is still landing
    // isn't undone. The Dock stays down for as long as the fingers are on the
    // trackpad regardless of what's on screen.
    private let preHideRelease: TimeInterval = 0.6
    private var fourFingersDown = false
    private let multitouch = MultitouchWatcher()


    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 APP LAUNCHED")
        NSApp.setActivationPolicy(.accessory)
        
        //Initialize Sparkle
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        setupMenuBar()
        startMultitouchPreHide()
        requestAccessibilityPermission()
        
        // Arm the signal trapper
        setupSignalHandler()
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        // variableLength, not squareLength: the glyph is 22x16pt, so a square
        // status item clips the wider chevron lockup.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyStatusIcon(dockVisible: isDockCurrentlyVisible())
        buildMenu()
        startGlyphTimer()
    }

    // MARK: - Four-Finger Pre-Hide

    /// Hides the Dock the moment four fingers land, before the swipe begins.
    /// Degrades to a no-op if MultitouchSupport can't be loaded.
    private func startMultitouchPreHide() {
        multitouch.start { [weak self] fingers in
            guard let self, !self.isQuitting, self.dockAwayEnabled else { return }
            print("👆 fingers=\(fingers)")

            guard self.hideOnFourFingerTouch, let watcher = self.dockWatcher else { return }

            if fingers >= self.fourFingerThreshold {
                guard !self.fourFingersDown else { return }   // already handled
                self.fourFingersDown = true

                // Latch first: otherwise the 0.12s safety timer can see an empty
                // desktop and re-show the Dock before the keystroke lands.
                watcher.beginHoldHidden()

                if self.isDockCurrentlyVisible() {
                    print("  ⚡ \(fingers) fingers down → pre-hiding Dock")
                    watcher.simulateOptionCommandDPublic()
                } else {
                    print("  · \(fingers) fingers down → already hidden, holding")
                }

            } else if self.fourFingersDown {
                self.fourFingersDown = false
                watcher.endHoldHidden(after: self.preHideRelease)
                print("  ✋ fingers lifted → hold releases in \(self.preHideRelease)s")
            }
        }
    }

    // MARK: - Dynamic Glyph

    /// The Dock's live autohide setting. A fresh instance every call, since a
    /// long-lived UserDefaults for another app's domain can serve a stale
    /// snapshot of that domain.
    private func isDockCurrentlyVisible() -> Bool {
        !(UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false)
    }

    /// Polls the Dock state for the sole purpose of picking a glyph.
    ///
    /// This is intentionally a separate loop rather than a hook inside
    /// DockWatcher. It only ever reads, never calls into DockWatcher, and never
    /// participates in a toggle decision — so the worst a wrong or late read can
    /// do is show the wrong chevron for a fraction of a second. It cannot move
    /// the Dock.
    private func startGlyphTimer() {
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, !self.isQuitting else { return }
            self.applyStatusIcon(dockVisible: self.isDockCurrentlyVisible())
        }
        // .common so the glyph keeps updating while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        glyphTimer = timer
    }

    /// Dock up (visible)  -> up chevron at full strength.
    /// Dock down (hidden) -> down chevron at full strength.
    private func applyStatusIcon(dockVisible: Bool) {
        guard glyphShowsDockVisible != dockVisible else { return }

        let name = dockVisible ? "DockAwayStatus-Up" : "DockAwayStatus-Down"
        guard let image = NSImage(named: name) else {
            print("⚠️ Missing menu bar image asset: \(name)")
            return
        }

        glyphShowsDockVisible = dockVisible
        image.isTemplate = true
        image.accessibilityDescription = dockVisible ? "Dock visible" : "Dock hidden"
        statusItem.button?.image = image
    }

    private func buildMenu() {
        let menu = NSMenu()

        let statusMenuItem = NSMenuItem()
        let statusView = DockAwayStatusView(frame: NSRect(x: 0, y: 0, width: 232, height: 38))
        statusView.pauseResumeButton.target = self
        statusView.pauseResumeButton.action = #selector(toggleDockAway)
        statusView.update(active: dockAwayEnabled, status: activeStatusText)
        statusMenuItem.view = statusView
        dockAwayStatusView = statusView
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        let launchAtLogin = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLogin.tag = 200
        launchAtLogin.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchAtLogin)

        let blacklistItem = NSMenuItem(title: "Blacklist", action: nil, keyEquivalent: "")
        let blacklistMenu = NSMenu(title: "Blacklist")
        blacklistMenu.autoenablesItems = false
        blacklistMenu.delegate = self
        blacklistItem.submenu = blacklistMenu
        self.blacklistMenu = blacklistMenu
        rebuildBlacklistMenu()
        menu.addItem(blacklistItem)
        menu.addItem(.separator())
        
        // --- SPARKLE UPDATE MENU ITEM  ---
        let updateMenuItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateMenuItem.state = .on
        updateMenuItem.onStateImage = menuIcon(from: NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: "Check for Updates"
        ))
        
        // Safety check to ensure we have a controller
        if let controller = self.updaterController {
            updateMenuItem.target = controller
            updateMenuItem.isEnabled = true
        } else {
            // If it's nil, we initialize it right here as a fallback
            self.updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            updateMenuItem.target = self.updaterController
            updateMenuItem.isEnabled = true
        }

        menu.addItem(updateMenuItem)

        menu.addItem(NSMenuItem(title: "About DockAway", action: #selector(showAbout), keyEquivalent: ""))
        let quitMenuItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitMenuItem.state = .on
        quitMenuItem.onStateImage = menuIcon(from: NSImage(
            systemSymbolName: "power",
            accessibilityDescription: "Quit DockAway"
        ))
        menu.addItem(quitMenuItem)

        statusItem.menu = menu
    }

    // MARK: - Blacklist

    private var ignoredWindowBundleIdentifiers: Set<String> {
        Set(
            UserDefaults.standard.stringArray(
                forKey: Self.ignoredWindowBundleIdentifiersKey
            ) ?? []
        )
    }

    private func saveIgnoredWindowBundleIdentifiers(_ identifiers: Set<String>) {
        UserDefaults.standard.set(
            identifiers.sorted(),
            forKey: Self.ignoredWindowBundleIdentifiersKey
        )
        dockWatcher?.resetState()
    }

    private func rebuildBlacklistMenu() {
        guard let blacklistMenu else { return }

        blacklistMenu.removeAllItems()

        let ignoredIdentifiers = ignoredWindowBundleIdentifiers
        var applicationsByIdentifier = [String: BlacklistApplication]()

        // Keep previously blacklisted apps visible even when they are not running.
        for bundleIdentifier in ignoredIdentifiers {
            applicationsByIdentifier[bundleIdentifier] = applicationInfo(
                forBundleIdentifier: bundleIdentifier
            )
        }

        // Mos uses the same useful shortcut: show regular running apps first,
        // then offer Finder for anything that is not currently open.
        for application in NSWorkspace.shared.runningApplications {
            guard
                application.activationPolicy == .regular,
                let bundleIdentifier = application.bundleIdentifier,
                bundleIdentifier != Bundle.main.bundleIdentifier
            else { continue }

            applicationsByIdentifier[bundleIdentifier] = BlacklistApplication(
                bundleIdentifier: bundleIdentifier,
                name: application.localizedName ?? bundleIdentifier,
                icon: application.icon
            )
        }

        let applications = applicationsByIdentifier.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        if applications.isEmpty {
            let emptyItem = NSMenuItem(
                title: "No Running Applications",
                action: nil,
                keyEquivalent: ""
            )
            emptyItem.isEnabled = false
            blacklistMenu.addItem(emptyItem)
        } else {
            for application in applications {
                let item = NSMenuItem(
                    title: application.name,
                    action: #selector(toggleBlacklistedApplication(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = application.bundleIdentifier
                item.state = ignoredIdentifiers.contains(application.bundleIdentifier) ? .on : .off
                item.attributedTitle = menuTitle(
                    application.name,
                    icon: application.icon ?? NSImage(
                        systemSymbolName: "app",
                        accessibilityDescription: "Application"
                    )
                )
                blacklistMenu.addItem(item)
            }
        }

        blacklistMenu.addItem(.separator())

        let chooseItem = NSMenuItem(
            title: "Choose Application…",
            action: #selector(chooseBlacklistApplication),
            keyEquivalent: ""
        )
        chooseItem.target = self
        chooseItem.image = NSImage(systemSymbolName: "plus.app", accessibilityDescription: nil)
        blacklistMenu.addItem(chooseItem)

        let clearItem = NSMenuItem(
            title: "Remove All",
            action: #selector(clearBlacklist),
            keyEquivalent: ""
        )
        clearItem.target = self
        clearItem.isEnabled = !ignoredIdentifiers.isEmpty
        blacklistMenu.addItem(clearItem)

        blacklistMenu.addItem(.separator())

        let helpItem = NSMenuItem(title: "About Blacklist", action: nil, keyEquivalent: "")
        helpItem.attributedTitle = menuTitle(
            "About Blacklist",
            icon: NSImage(
                systemSymbolName: "questionmark.circle",
                accessibilityDescription: "Blacklist Help"
            )
        )
        helpItem.toolTip = "A blacklisted app keeps the Dock shown while it is the frontmost app on the active display. When another app moves in front, DockAway hides the Dock normally."
        helpItem.isEnabled = true
        blacklistMenu.addItem(helpItem)
    }

    private func applicationInfo(forBundleIdentifier bundleIdentifier: String) -> BlacklistApplication {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return BlacklistApplication(
                bundleIdentifier: bundleIdentifier,
                name: bundleIdentifier,
                icon: nil
            )
        }

        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent

        return BlacklistApplication(
            bundleIdentifier: bundleIdentifier,
            name: name,
            icon: NSWorkspace.shared.icon(forFile: url.path)
        )
    }

    private func menuIcon(from image: NSImage?) -> NSImage? {
        guard let icon = image?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    private func menuTitle(_ title: String, icon sourceImage: NSImage?) -> NSAttributedString {
        guard let icon = menuIcon(from: sourceImage) else {
            return NSAttributedString(string: title)
        }

        let attachment = NSTextAttachment()
        attachment.image = icon
        attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)

        let attributedTitle = NSMutableAttributedString(attachment: attachment)
        attributedTitle.append(NSAttributedString(string: "  \(title)"))
        return attributedTitle
    }

    @objc private func toggleBlacklistedApplication(_ sender: NSMenuItem) {
        guard let bundleIdentifier = sender.representedObject as? String else { return }

        var identifiers = ignoredWindowBundleIdentifiers
        if identifiers.contains(bundleIdentifier) {
            identifiers.remove(bundleIdentifier)
        } else {
            identifiers.insert(bundleIdentifier)
        }

        saveIgnoredWindowBundleIdentifiers(identifiers)
        rebuildBlacklistMenu()
    }

    @objc private func chooseBlacklistApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Application to Blacklist"
        panel.prompt = "Blacklist"
        panel.directoryURL = FileManager.default.urls(
            for: .applicationDirectory,
            in: .localDomainMask
        ).first
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self, response == .OK else { return }

            var identifiers = self.ignoredWindowBundleIdentifiers
            for url in panel.urls {
                if let bundleIdentifier = Bundle(url: url)?.bundleIdentifier,
                   bundleIdentifier != Bundle.main.bundleIdentifier {
                    identifiers.insert(bundleIdentifier)
                }
            }

            self.saveIgnoredWindowBundleIdentifiers(identifiers)
            self.rebuildBlacklistMenu()
        }
    }

    @objc private func clearBlacklist() {
        saveIgnoredWindowBundleIdentifiers([])
        rebuildBlacklistMenu()
    }

    func updateStatus(_ text: String) {
        DispatchQueue.main.async {
            guard self.dockAwayEnabled else { return }
            self.activeStatusText = text
            self.dockAwayStatusView?.update(active: true, status: text)
        }
    }

    @objc private func toggleDockAway() {
        if dockAwayEnabled {
            dockAwayEnabled = false
            fourFingersDown = false
            dockWatcher?.stop()
            multitouch.stop()
            updateDockAwayMenuState()
            restoreDockState()
            print("🔴 DockAway inactive")
        } else {
            guard AXIsProcessTrusted() else {
                let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
                AXIsProcessTrustedWithOptions(options)
                return
            }

            dockAwayEnabled = true
            if dockWatcher == nil {
                dockWatcher = DockWatcher()
            }
            dockWatcher.start()
            startMultitouchPreHide()
            updateDockAwayMenuState()
            dockWatcher.resetState()
            print("🟢 DockAway active")
        }
    }

    private func updateDockAwayMenuState() {
        dockAwayStatusView?.update(
            active: dockAwayEnabled,
            status: activeStatusText
        )
    }

    // MARK: - Launch at Login

    private func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            print("⚠️ Launch at login error: \(error)")
        }
        statusItem.menu?.item(withTag: 200)?.state = isLaunchAtLoginEnabled() ? .on : .off
    }

    // MARK: - About

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        
        let creditsText = "Copyright © Abdullah Khairaddin 2026                  All rights reserved."
        
        let attributedCredits = NSAttributedString(
            string: creditsText,
            attributes: [.paragraphStyle: paragraphStyle]
        )
        
        NSApp.orderFrontStandardAboutPanel(options: [
            NSApplication.AboutPanelOptionKey.applicationName: "DockAway",
            NSApplication.AboutPanelOptionKey.credits: attributedCredits
        ])
    }

    // MARK: - First Launch

    private func ensureDockAwayIsOn() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let defaults = UserDefaults(suiteName: "com.apple.dock")
            let isAlreadyOn = defaults?.bool(forKey: "autohide") ?? false
            if !isAlreadyOn {
                self.dockWatcher.simulateOptionCommandDPublic()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.dockWatcher.resetState()
            }
        }
    }

    private func showWelcomeIfNeeded() {
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        guard !hasLaunchedBefore else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let alert = NSAlert()
            alert.messageText = "Welcome to DockAway 👋"
            alert.informativeText = "Your Dock will now automatically appear when you are on an empty desktop and hides when an app occupies the screen.\n\n• Toggle Launch at Login from the menu bar.\n• The app runs silently and efficiently in the background.\n\nEnjoy your Extra Real Estate!"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Let's Go!")

            // An .accessory app is never frontmost, so a modal can open behind
            // whatever the user is actually looking at.
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()

            // Mark it seen only once it HAS been seen. Setting the flag up front
            // loses the welcome permanently if the app dies in the meantime —
            // which is exactly what macOS does right after an Accessibility grant.
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
        }
    }

    // MARK: - Accessibility

    private func requestAccessibilityPermission() {
        if AXIsProcessTrusted() {
            dockWatcher = DockWatcher()
            ensureDockAwayIsOn()
            dockWatcher.start()
            showWelcomeIfNeeded()
        } else {
            let alert = NSAlert()
            alert.messageText = "But First ☝️"
            alert.informativeText = "Accessibility Permission is Required:\nDockAway is requesting accessibility permission from system settings in order to detect desktop app occupancy status. Input monitoring (Automatically enabled after accessibility permission is granted) is required to detect when the Dock should be shown or hidden on a 4 finger press."
            alert.alertStyle = .informational
            
            alert.addButton(withTitle: "Allow Access")
            alert.addButton(withTitle: "Quit")
            alert.layout()
            
            NSApp.activate(ignoringOtherApps: true)
            
            if let contentView = alert.window.contentView {
                func findTextField(in view: NSView, matching text: String) -> NSTextField? {
                    if let textField = view as? NSTextField, textField.stringValue.contains(text) {
                        return textField
                    }
                    for subview in view.subviews {
                        if let found = findTextField(in: subview, matching: text) {
                            return found
                        }
                    }
                    return nil
                }
                
                if let informativeTextField = findTextField(in: contentView, matching: "Accessibility Permission is Required:") {
                    let fullString = informativeTextField.stringValue as NSString
                    let targetLine = "Accessibility Permission is Required:"
                    let firstLineRange = fullString.range(of: targetLine)
                    let remainingRange = NSRange(location: firstLineRange.length, length: fullString.length - firstLineRange.length)
                    
                    let attributedString = NSMutableAttributedString(string: informativeTextField.stringValue)
                    
                    attributedString.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 11), range: firstLineRange)
                    attributedString.addAttribute(.foregroundColor, value: NSColor.labelColor, range: firstLineRange)
                    attributedString.addAttribute(.font, value: NSFont.systemFont(ofSize: 11), range: remainingRange)
                    attributedString.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: remainingRange)
                    
                    let paragraphStyle = NSMutableParagraphStyle()
                    paragraphStyle.lineSpacing = 2
                    paragraphStyle.paragraphSpacing = 4
                    attributedString.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: fullString.length))
                    
                    informativeTextField.attributedStringValue = attributedString
                }
            }
            
            if alert.runModal() == .alertFirstButtonReturn {
                let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
                AXIsProcessTrustedWithOptions(options)
                waitForAccessibility()
            } else {
                NSApp.terminate(nil)
            }
        }
    }

    private func waitForAccessibility() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if AXIsProcessTrusted() {
                print("✅ Accessibility granted - starting detector")
                self.dockWatcher = DockWatcher()
                self.ensureDockAwayIsOn()
                self.dockWatcher.start()
                self.showWelcomeIfNeeded()
            } else {
                self.waitForAccessibility()
            }
        }
    }

    // MARK: - Unix Signal & Cleanup

    private func setupSignalHandler() {
        // 1. Ignore the default sudden-death SIGTERM so we can handle it ourselves
        signal(SIGTERM, SIG_IGN)
        
        // 2. Set up a listener for the Unix signal
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            print("  ⚠️ Caught Unix SIGTERM (Activity Monitor)")
            self?.isQuitting = true
            self?.restoreDockState()
            
            // 3. Manually exit after our cleanup is finished
            exit(0)
        }
        source.resume()
        sigtermSource = source
    }

    private func restoreDockState() {
        let defaults = UserDefaults(suiteName: "com.apple.dock")
        defaults?.synchronize()
        let isHidden = defaults?.bool(forKey: "autohide") ?? false
        
        if isHidden, let watcher = dockWatcher {
            print("  ⚡ Restoring Dock visibility before termination")
            watcher.simulateOptionCommandDPublic()
            
            // The Life Support Hold: Keep the app alive just long enough for the keystroke to register
            Thread.sleep(forTimeInterval: 0.15)
        }
    }

    @objc private func quit() {
        // Polite exit (triggers applicationWillTerminate)
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        isQuitting = true
        glyphTimer?.invalidate()
        multitouch.stop()
        restoreDockState()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if menu === blacklistMenu {
            rebuildBlacklistMenu()
        }
    }
}
