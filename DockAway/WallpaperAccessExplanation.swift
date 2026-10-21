import AppKit

/// Explains why the black menu bar needs Full Disk Access when a wallpaper app
/// keeps the wallpaper in its own private folder, and what DockAway does with
/// that access, before sending people to System Settings.
enum WallpaperAccessExplanation {
    static let title = "Allow DockAway to Read Your Wallpaper"
    static let menuTitle = "Allow Wallpaper Access"

    /// What's wrong, in a sentence or two.
    static func summary(for blocked: MenuBarBlackoutBlockedWallpaper) -> String {
        guard blocked.isInAppFolder else {
            return "Your wallpaper is in a folder macOS keeps private, so DockAway can't read it."
        }
        let app = blocked.appName ?? "Your wallpaper app"
        return "\(app) saves the wallpapers it sets in its own private folder. macOS keeps other apps out of that folder, so DockAway can't read your current wallpaper."
    }

    /// Why DockAway needs it, what it does with it, and how to allow it.
    static func sections(for blocked: MenuBarBlackoutBlockedWallpaper) -> [(heading: String, body: String)] {
        let stillWorks = blocked.isInAppFolder
            ? "The black menu bar keeps working with wallpapers that aren't in an app's private folder."
            : "The black menu bar keeps working with wallpapers DockAway can read."
        return [
            ("Why DockAway Needs It",
             "macOS picks the menu bar's text color from the top of your wallpaper. To keep the text white over the black, DockAway briefly uses a copy of your wallpaper with a black band at the top. Without reading your wallpaper, it can't make that copy, so on a light wallpaper the menu bar stays as it is rather than hide black text on black."),
            ("What DockAway Does With It",
             "Full Disk Access is broad: it lets an app read files anywhere on your Mac, and macOS has no narrower setting for another app's folder.\n• DockAway asks for it only to read the wallpaper macOS says is on your desktop.\n• Its copy stays on your Mac, in DockAway's own folder, and your wallpaper comes back as soon as no window fills the screen.\n• DockAway never uploads your files. It only goes online to check for updates."),
            ("How to Allow It",
             "Click Open Full Disk Access and turn on DockAway. If it isn't in the list, click + and choose DockAway. macOS may ask to reopen DockAway afterward.\n\nYou can turn it off again whenever you like. \(stillWorks)")
        ]
    }

    /// The menu row's help, shown when hovering over it.
    static func menuHelp(for blocked: MenuBarBlackoutBlockedWallpaper?) -> String {
        let summary = blocked.map(summary(for:)) ?? "macOS keeps DockAway from reading your current wallpaper."
        return "\(summary) Until it can, the menu bar can't turn black over a light wallpaper.\n\n• Click to see why DockAway needs Full Disk Access to read it, what it does with that access, and how to turn it on.\n• This goes away once DockAway can read your wallpaper."
    }

    /// The sections, left-aligned and wider than an alert's own text, so the
    /// longer explanation stays easy to read.
    @MainActor
    static func detailsView(for blocked: MenuBarBlackoutBlockedWallpaper) -> NSView {
        let width: CGFloat = 400
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 2
        // Wrapped bullet lines line up under the text, not the bullet.
        let bullet = NSMutableParagraphStyle()
        bullet.paragraphSpacing = 2
        bullet.headIndent = ceil(NSAttributedString(string: "• ", attributes: [.font: font]).size().width)
        let text = NSMutableAttributedString()
        for (index, section) in sections(for: blocked).enumerated() {
            let heading = NSMutableParagraphStyle()
            heading.paragraphSpacingBefore = index == 0 ? 0 : 10
            heading.paragraphSpacing = 3
            text.append(NSAttributedString(string: (index == 0 ? "" : "\n") + section.heading + "\n", attributes: [
                .font: NSFont.boldSystemFont(ofSize: font.pointSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: heading
            ]))
            let lines = section.body.components(separatedBy: "\n")
            for (lineIndex, line) in lines.enumerated() {
                text.append(NSAttributedString(string: line + (lineIndex < lines.count - 1 ? "\n" : ""), attributes: [
                    .font: font,
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: line.hasPrefix("• ") ? bullet : paragraph
                ]))
            }
        }
        let field = NSTextField(labelWithAttributedString: text)
        field.isSelectable = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = width
        let height = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width,
                                                            height: .greatestFiniteMagnitude)).height ?? 0
        // In line with the alert's own text, which sits a little further in.
        let inset: CGFloat = 4
        field.frame = NSRect(x: inset, y: 0, width: width, height: ceil(height))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width + inset, height: field.frame.height))
        container.addSubview(field)
        return container
    }
}

/// Shows the explanation as an alert in its own floating window rather than a
/// modal one, since it can appear by itself while a window fills the screen,
/// and DockAway keeps working while it waits for an answer.
@MainActor
final class WallpaperAccessPrompt: NSObject {
    private var alert: NSAlert?
    private var previousApplication: NSRunningApplication?
    private var openSettings: (() -> Void)?

    var isShowing: Bool { alert?.window.isVisible == true }

    /// Shows the explanation, or brings it forward if it's showing. Not Now
    /// goes back to the app that was in front before.
    func show(for blocked: MenuBarBlackoutBlockedWallpaper, returningTo previous: NSRunningApplication?,
              openSettings: @escaping () -> Void) {
        self.openSettings = openSettings
        if let window = alert?.window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        previousApplication = previous?.processIdentifier == getpid() ? nil : previous
        let alert = NSAlert()
        alert.messageText = WallpaperAccessExplanation.title
        alert.informativeText = WallpaperAccessExplanation.summary(for: blocked)
        alert.accessoryView = WallpaperAccessExplanation.detailsView(for: blocked)
        let open = alert.addButton(withTitle: "Open Full Disk Access")
        open.target = self
        open.action = #selector(openFullDiskAccess)
        let later = alert.addButton(withTitle: "Not Now")
        later.keyEquivalent = "\u{1b}"
        later.target = self
        later.action = #selector(notNow)
        alert.layout()
        let window = alert.window
        // An accessory app has no Dock icon to bring it back with, so it
        // stays up when another app comes forward, on whichever desktop.
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()
        self.alert = alert
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func openFullDiskAccess() {
        close()
        openSettings?()
    }

    @objc private func notNow() {
        let previous = previousApplication
        close()
        if let previous, !previous.isTerminated { previous.activate(options: []) }
    }

    private func close() {
        alert?.window.orderOut(nil)
        alert = nil
        previousApplication = nil
    }
}
