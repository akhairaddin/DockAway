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

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 APP LAUNCHED")
        NSApp.setActivationPolicy(.accessory)
        
        //Initialize Sparkle
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        setupMenuBar()
        requestAccessibilityPermission()
        
        // Arm the signal trapper
        setupSignalHandler()
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(named: "Imageset")
        }
        buildMenu()
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
        
        let creditsText = "Copyright © Abdullah Khairaddin 2026 All rights reserved.\n\nHides the Dock when apps are on screen and it reappears on an empty desktop."
        
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
        UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let alert = NSAlert()
            alert.messageText = "Welcome to DockAway 👋"
            alert.informativeText = "Your Dock will now automatically appear when you are on an empty desktop and hides when an app occupies the screen.\n\n• Toggle Launch at Login from the menu bar.\n• The app runs silently and efficiently in the background.\n\nEnjoy your Extra Real Estate!"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Awesome!")
            alert.runModal()
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
            alert.informativeText = "Accessibility Permission is Required:\nDockAway is requesting accessibility permission from system settings in order to detect desktop app occupancy status."
            alert.alertStyle = .informational
            
            alert.addButton(withTitle: "Allow Access")
            alert.addButton(withTitle: "Quit")
            alert.layout()
            
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
        restoreDockState()
    }
}
