import Cocoa
import ServiceManagement
import Sparkle


@objc class AppDelegate: NSObject, NSApplicationDelegate {
    var isQuitting = false
    private var statusItem: NSStatusItem!
    private var dockWatcher: DockWatcher!
    private var updaterController: SPUStandardUpdaterController!
    
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
            guard let self, !self.isQuitting else { return }
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

        let statusMenuItem = NSMenuItem(title: "Status: Detecting…", action: nil, keyEquivalent: "")
        statusMenuItem.tag = 100
        statusMenuItem.isEnabled = false
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
        menu.addItem(.separator())
        
        // --- SPARKLE UPDATE MENU ITEM  ---
        let updateMenuItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        
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
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    func updateStatus(_ text: String) {
        DispatchQueue.main.async {
            self.statusItem.menu?.item(withTag: 100)?.title = "Status: \(text)"
        }
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
        
        let creditsText = "Copyright © Abdullah Khairaddin 2026                  All rights reserved.\n\nHides the Dock when apps are on screen and reappears on an empty desktop ."
        
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
