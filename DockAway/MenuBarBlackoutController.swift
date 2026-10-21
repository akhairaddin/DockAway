import AppKit
import CryptoKit
import SwiftUI

/// One window as the window server reports it, in global display coordinates
/// (origin at the top left of the main display).
struct MenuBarBlackoutWindow: Equatable {
    let bounds: CGRect
    let layer: Int
    let ownerPID: pid_t
    let alpha: Double
    var id: CGWindowID = 0
}

enum MenuBarBlackoutDockEdge {
    case bottom, left, right
}

/// A display's frame and the area apps can fill below its menu bar and beside
/// the Dock, in global display coordinates.
struct MenuBarBlackoutDisplay: Equatable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let usableFrame: CGRect

    /// Zero when the display has no menu bar, or it hides automatically.
    var menuBarHeight: CGFloat { max(0, usableFrame.minY - frame.minY) }
}

enum MenuBarBlackoutDecision {
    /// Windows within this of the usable area's edges still fill it.
    static let tolerance: CGFloat = 2

    /// The wallpaper copy's black corners sit behind the window, so corners a
    /// little rounder than the window's fill the whole gap by its rounded
    /// corners even where the window's own curve is slightly different.
    static let cornerRoundingAllowance: CGFloat = 4

    /// How thick the black is down each side of a filling window, like a thin
    /// picture frame joined to the black menu bar.
    static let sideFrame: CGFloat = 0.5

    /// How far the black reaches over the window's top edge. macOS lights the
    /// outer line of a window's border there with a warm highlight, uneven
    /// around the corners, which looks jagged on black; the frame draws its
    /// own thin gray border around the opening instead.
    static let topCover: CGFloat = 0.5

    /// The part of a filling window that shows inside the black frame, in
    /// screen coordinates: its full height up to just under the menu bar,
    /// less the frame's sides. Its corners are rounded like the window's.
    static func frameOpening(window: CGRect, menuBarBottom: CGFloat) -> CGRect {
        let top = min(window.maxY, menuBarBottom) - topCover
        return CGRect(x: window.minX + sideFrame, y: window.minY,
                      width: max(0, window.width - 2 * sideFrame), height: max(0, top - window.minY))
    }

    /// Displays whose usable area an ordinary window fills. A window reaching
    /// into the menu bar is in native full screen, where macOS hides the menu
    /// bar itself, so it doesn't count.
    static func filledDisplays(_ displays: [MenuBarBlackoutDisplay], windows: [MenuBarBlackoutWindow],
                               excluding ownPID: pid_t) -> Set<CGDirectDisplayID> {
        Set(fillingWindows(displays, windows: windows, excluding: ownPID).keys)
    }

    /// The frontmost window filling each display, from a front-to-back list.
    static func fillingWindows(_ displays: [MenuBarBlackoutDisplay], windows: [MenuBarBlackoutWindow],
                               excluding ownPID: pid_t) -> [CGDirectDisplayID: MenuBarBlackoutWindow] {
        var filling: [CGDirectDisplayID: MenuBarBlackoutWindow] = [:]
        for display in displays where display.menuBarHeight > 0 {
            let usable = display.usableFrame
            filling[display.id] = windows.first { window in
                window.layer == 0 && window.alpha > 0 && window.ownerPID != ownPID
                    && abs(window.bounds.minY - usable.minY) <= tolerance
                    && window.bounds.minX <= usable.minX + tolerance
                    && window.bounds.maxX >= usable.maxX - tolerance
                    && window.bounds.maxY >= usable.maxY - tolerance
            }
        }
        return filling
    }

    /// The display as it may be on another desktop, where the Dock might be
    /// showing or hidden: a window sized to sit beside a showing Dock still
    /// fills it.
    static func allowingForDock(_ display: MenuBarBlackoutDisplay, on edge: MenuBarBlackoutDockEdge,
                                size: CGFloat) -> MenuBarBlackoutDisplay {
        let top = display.usableFrame.minY
        var area = CGRect(x: display.frame.minX, y: top, width: display.frame.width,
                          height: display.frame.maxY - top)
        switch edge {
        case .bottom: area.size.height -= size
        case .left: area.origin.x += size; area.size.width -= size
        case .right: area.size.width -= size
        }
        return MenuBarBlackoutDisplay(id: display.id, frame: display.frame, usableFrame: area)
    }

    /// Where the desktop draws a wallpaper image for its scaling options, in a
    /// canvas of the screen's pixel size.
    nonisolated static func wallpaperRect(imageSize: CGSize, canvas: CGSize, scaling: NSImageScaling,
                                          allowClipping: Bool) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: canvas) }
        let size: CGSize
        switch scaling {
        case .scaleAxesIndependently:
            size = canvas
        case .scaleNone:
            size = imageSize
        case .scaleProportionallyDown:
            let fit = min(1, canvas.width / imageSize.width, canvas.height / imageSize.height)
            size = CGSize(width: imageSize.width * fit, height: imageSize.height * fit)
        default:
            // Fill Screen clips the image to cover the screen; Fit to Screen shows it whole.
            let widthScale = canvas.width / imageSize.width, heightScale = canvas.height / imageSize.height
            let scale = allowClipping ? max(widthScale, heightScale) : min(widthScale, heightScale)
            size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        }
        return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// Where a window filling the screen covers a wallpaper copy, in its pixels
    /// (origin at the bottom left): everything below the menu bar band. The
    /// bottom reaches well below the image, so only the top corners round.
    nonisolated static func wallpaperWindowRect(canvas: CGSize, bandHeight: Int) -> CGRect {
        let top = canvas.height - CGFloat(bandHeight)
        return CGRect(x: 0, y: -canvas.height, width: canvas.width, height: top + canvas.height)
    }

    /// The squares beside that window's top corners in a wallpaper copy, each
    /// big enough for a smooth corner of this radius in pixels.
    nonisolated static func wallpaperCornerRects(canvas: CGSize, bandHeight: Int, radius: CGFloat) -> [CGRect] {
        guard radius > 0 else { return [] }
        let side = ceil(radius * 1.6) + 1
        let top = canvas.height - CGFloat(bandHeight)
        return [CGRect(x: 0, y: top - side, width: side, height: side),
                CGRect(x: canvas.width - side, y: top - side, width: side, height: side)]
    }

    /// macOS picks the menu bar's text color from the wallpaper behind it. A
    /// top band this dark already gets white text, so the wallpaper can stay.
    nonisolated static let darkBandLuminance = 0.3

    /// Whether macOS is reporting its stand-in still rather than the wallpaper
    /// itself, as it does while the desktop shows an aerial or anything else
    /// that isn't a picture file. A banded copy of it would replace the real
    /// wallpaper, and putting it back would set the stand-in for good.
    nonisolated static func isStandInWallpaper(_ path: String) -> Bool {
        path == "/System/Library/CoreServices/DefaultDesktop.heic"
            || path.hasPrefix("/System/Library/Wallpapers/.default/")
    }

    /// The app whose private folder holds a file: the folder's name under
    /// ~/Library/Containers, which is the app's bundle identifier, or under
    /// ~/Library/Group Containers. Nil anywhere else.
    nonisolated static func appFolderIdentifier(of path: String, home: String) -> String? {
        let library = (home as NSString).appendingPathComponent("Library")
        for folder in ["Containers", "Group Containers"] {
            let prefix = (library as NSString).appendingPathComponent(folder) + "/"
            guard path.hasPrefix(prefix),
                  let identifier = path.dropFirst(prefix.count).split(separator: "/").first,
                  path.count > prefix.count + identifier.count else { continue }
            return String(identifier)
        }
        return nil
    }
}

/// A wallpaper macOS won't let DockAway read without Full Disk Access.
struct MenuBarBlackoutBlockedWallpaper: Equatable {
    /// The app that keeps it in its private folder, when that's known.
    let appName: String?
    /// That folder's name, or nil if it's in another place macOS protects.
    let appFolder: String?

    var isInAppFolder: Bool { appFolder != nil }
}

/// Extras: blacks out the menu bar while a window fills the screen.
///
/// Black over the menu bar, and in a thin frame down the sides of the window,
/// gives the look right away. macOS picks
/// the menu bar's text color from the wallpaper image itself, so on a lighter
/// wallpaper the desktop briefly uses a copy with a black band at the top,
/// which turns the text white. The original wallpaper comes back as soon as
/// no window fills the screen, the option is turned off, or DockAway quits,
/// and on the next launch if DockAway was interrupted.
@MainActor
final class MenuBarBlackoutController {
    static let preferenceKey = "blackMenuBarWhenScreenFilled"
    private static let swapsKey = "menuBarBlackoutWallpaperSwaps"
    private static let pollInterval: TimeInterval = 0.25
    /// The black stays solid until a wallpaper DockAway puts back is showing,
    /// so it fades into the real wallpaper rather than over the copy's black
    /// band, which disappears all at once. macOS flips the menu bar's text
    /// color when it shows (about a third of a second); this is the longest
    /// it waits for that.
    private static let wallpaperShowTimeout: TimeInterval = 1.0
    /// How often a filled display checks whether something else changed its wallpaper.
    private static let wallpaperCheckInterval: TimeInterval = 2
    private static let maximumSwapRecords = 16

    /// A wallpaper DockAway replaced with a banded copy, so it can be put back.
    private struct Swap: Codable {
        let originalPath: String
        /// The same picture without the band, in case the original file is gone.
        let plainCopyPath: String
        let scaling: Int
        let allowClipping: Bool
        let fillColor: [Double]?
        let created: Date

        var options: [NSWorkspace.DesktopImageOptionKey: Any] {
            var options: [NSWorkspace.DesktopImageOptionKey: Any] = [
                .imageScaling: scaling, .allowClipping: allowClipping
            ]
            if let fillColor, fillColor.count == 4 {
                options[.fillColor] = NSColor(srgbRed: fillColor[0], green: fillColor[1],
                                              blue: fillColor[2], alpha: fillColor[3])
            }
            return options
        }
    }

    /// True while DockAway's menu bar should stay as it is, such as in Mission Control.
    var isSuspended: () -> Bool = { false }
    /// Whether the menu bar on a display shows white text right now, when known.
    var menuBarTextIsWhite: (CGDirectDisplayID) -> Bool? = { _ in nil }
    /// The desktop a display shows, to remember which desktops have a filling window.
    var currentSpaceID: (CGDirectDisplayID) -> UInt64? = { _ in nil }
    /// True while DockAway itself is moving between desktops.
    var isSwitchingDesktops: () -> Bool = { false }
    /// The desktops either side of a display's current one, to look ahead
    /// during a swipe.
    var adjacentDesktops: (CGDirectDisplayID) -> (previous: (id: UInt64, isFullscreen: Bool)?,
                                                  next: (id: UInt64, isFullscreen: Bool)?) = { _ in (nil, nil) }
    /// The ordinary windows on a desktop, including one that isn't showing.
    var windowIDsOnDesktop: (UInt64) -> [CGWindowID]? = { _ in nil }
    /// A window fills the screen, but the menu bar can't turn black because
    /// macOS won't let DockAway read the wallpaper. Called at each check
    /// while that lasts.
    var wallpaperAccessNeeded: (MenuBarBlackoutBlockedWallpaper) -> Void = { _ in }

    private(set) var isEnabled = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var overlays: [CGDirectDisplayID: MenuBarBlackoutOverlay] = [:]
    /// Displays whose black is waiting for their put-back wallpaper to show.
    private var fadesAwaitingWallpaper = Set<CGDirectDisplayID>()
    /// Whether each desktop had a filling window when it was last showing, so
    /// swiping between filled desktops keeps the black instead of dropping it
    /// while the window list is mid-transition.
    private var spaceFilled: [UInt64: Bool] = [:]
    /// What was last remembered for each display's current desktop.
    private var rememberedFilled: [CGDirectDisplayID: Bool] = [:]
    private var desktopGestureActive = false
    /// After a swipe lands, the window list is unreliable until macOS reports
    /// the new desktop, or until then if the swipe was cancelled instead.
    private var desktopSwitchSettlesAt: TimeInterval = 0
    /// macOS just reported a new desktop: its window list is settled, so the
    /// next check acts on it straight away.
    private var desktopJustChanged = false
    /// Whether the desktops either side of the swipe's display have a filling
    /// window, worked out as the swipe starts.
    private var swipeLookahead: (display: CGDirectDisplayID, previous: Bool?, next: Bool?)?
    /// The desktop each display showed as the swipe started. macOS keeps
    /// reporting it as current until the swipe's animation ends, so it's no
    /// sign of where the swipe is landing.
    private var swipeStartDesktops: [CGDirectDisplayID: UInt64] = [:]
    /// The swipe took the black away as it headed for a desktop that isn't
    /// filled, so it comes back if the swipe turns around.
    private var swipeHidBlack = false
    /// The menu bar text color last logged, to log only changes.
    private var loggedTextIsWhite: Bool?
    /// The lock screen shows the desktop's wallpaper, so while the screen is
    /// locked, asleep, or switched to another user, the original wallpaper is
    /// back and there's no black.
    private var isAway = false
    private var screenLockedNotified = false
    private var displaysAsleep = false
    /// Since when windows from another desktop have been showing, which means
    /// a desktop is sliding in or out.
    private var slidingSince: TimeInterval?
    /// A slide is over in about a second. A window on every desktop can look
    /// like one for good, so after this the desktop counts as settled.
    private static let longestSlide: TimeInterval = 2
    /// Since when the menu bar text has stayed black behind the black.
    private var blackTextSince: [CGDirectDisplayID: TimeInterval] = [:]
    /// How often the wallpaper was put back and banded again on this desktop
    /// to bring the text back to white.
    private var wallpaperRedos: [CGDirectDisplayID: Int] = [:]
    /// Longer than macOS takes to turn the text white after a wallpaper swap.
    private static let blackTextGrace: TimeInterval = 1.5
    /// When each display's black last stopped having a filling window. It stays
    /// until that's lasted a moment, so a brief gap mid-transition can't drop it.
    private var unfilledSince: [CGDirectDisplayID: TimeInterval] = [:]
    private static let hideDelay: TimeInterval = 0.4
    /// macOS reports the new desktop about a second after the fingers lift,
    /// once the swipe's animation finishes; a cancelled swipe reports nothing.
    private static let swipeLandingTimeout: TimeInterval = 1.4
    /// Corner radii the window server reported, by window.
    private var cornerRadii: [CGWindowID: CGFloat] = [:]
    private var filledSince: [CGDirectDisplayID: TimeInterval] = [:]
    private var lastWallpaperCheck: [CGDirectDisplayID: TimeInterval] = [:]
    /// Displays whose wallpaper was swapped while the current window filled it.
    private var swappedWhileFilled = Set<CGDirectDisplayID>()
    /// How often something else put the wallpaper back while still filled.
    private var wallpaperReverts: [CGDirectDisplayID: Int] = [:]
    private var swapsPausedUntil: [CGDirectDisplayID: TimeInterval] = [:]
    /// What each wallpaper needs, by cache key: its copies, or nothing because
    /// it's dark behind the menu bar already, or it can't be copied.
    private var preparedWallpapers: [String: WallpaperCopies] = [:]
    /// Wallpapers whose copies are being made in the background.
    private var preparingWallpapers = Set<String>()
    /// Whether each filled display's menu bar text will be white behind the
    /// black. Without that it stays as it is, rather than black on black.
    private var textWillBeWhite: [CGDirectDisplayID: Bool] = [:]
    private var swaps: [String: Swap] = [:]
    private let workspace = NSWorkspace.shared

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.swapsKey),
           let saved = try? JSONDecoder().decode([String: Swap].self, from: data) {
            swaps = saved
        }
    }

    /// Puts back any wallpaper left banded by an interrupted session, on the
    /// desktops showing now. Later desktops are handled as they appear.
    func recoverPreviousSession() {
        guard !swaps.isEmpty else { return }
        for screen in NSScreen.screens { restoreWallpaper(on: screen) }
        observeSpacesForLeftovers()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled { start() } else { stop(animated: true) }
    }

    /// Takes the black away and puts back any wallpaper DockAway replaced.
    /// Quitting stops at once; turning the option off fades out.
    func stop(animated: Bool = false) {
        isEnabled = false
        timer?.invalidate()
        timer = nil
        filledSince.removeAll()
        lastWallpaperCheck.removeAll()
        swappedWhileFilled.removeAll()
        textWillBeWhite.removeAll()
        rememberedFilled.removeAll()
        desktopSwitchSettlesAt = 0
        for screen in NSScreen.screens {
            let restored = restoreWallpaper(on: screen)
            if let display = screen.displayID {
                hideOverlay(on: display, animated: animated, awaitingWallpaper: restored, reason: "turned off or quitting")
            }
        }
        for display in Array(overlays.keys) where !animated {
            hideOverlay(on: display, animated: false, reason: "turned off or quitting")
        }
        removeObservers()
        // Banded copies may remain on desktops that aren't showing.
        if !swaps.isEmpty { observeSpacesForLeftovers() }
    }

    private func start() {
        removeObservers()
        let workspaceCenter = workspace.notificationCenter
        observers.append(workspaceCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Each desktop has its own wallpaper; finding a different one
                // after switching isn't another app changing it back.
                self.swappedWhileFilled.removeAll()
                self.wallpaperReverts.removeAll()
                self.rememberedFilled.removeAll()
                self.swipeStartDesktops.removeAll()
                self.swipeHidBlack = false
                self.wallpaperRedos.removeAll()
                self.blackTextSince.removeAll()
                self.desktopSwitchSettlesAt = 0
                self.desktopJustChanged = true
                dockAwayDebugLog("Menu bar blackout: desktop changed")
                self.evaluate(checkWallpapers: true)
            }
        })
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            observers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate(checkWallpapers: true) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate(checkWallpapers: true) }
        })
        observeLockAndSleep()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate(checkWallpapers: false) }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        evaluate(checkWallpapers: true)
    }

    private func observeSpacesForLeftovers() {
        guard observers.isEmpty else { return }
        observers.append(workspace.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isEnabled else { return }
                for screen in NSScreen.screens { self.restoreWallpaper(on: screen) }
            }
        })
    }

    private func removeObservers() {
        observers.forEach {
            workspace.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
            DistributedNotificationCenter.default().removeObserver($0)
        }
        observers.removeAll()
    }

    // MARK: - Lock screen

    private func observeLockAndSleep() {
        let distributed = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(distributed.addObserver(forName: Notification.Name(name), object: nil,
                                                     queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screenLockedNotified = locked
                    self?.evaluate(checkWallpapers: true)
                }
            })
        }
        let workspaceCenter = workspace.notificationCenter
        let sleepChanges: [(Notification.Name, Bool?)] = [
            (NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
            (NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false),
            (NSWorkspace.sessionDidResignActiveNotification, nil), (NSWorkspace.sessionDidBecomeActiveNotification, nil)
        ]
        for (name, asleep) in sleepChanges {
            observers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let asleep { self.displaysAsleep = asleep }
                    self.evaluate(checkWallpapers: true)
                }
            })
        }
    }

    /// Whether the screen is locked, asleep, or switched to another user.
    private var shouldBeAway: Bool {
        if screenLockedNotified || displaysAsleep { return true }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool == true
            || session[kCGSessionOnConsoleKey as String] as? Bool == false
    }

    /// Puts the original wallpapers back and takes the black away at once,
    /// before the lock screen shows them.
    private func stepAway() {
        isAway = true
        dockAwayDebugLog("Menu bar blackout: the screen locked or slept")
        for screen in NSScreen.screens { restoreWallpaper(on: screen) }
        for display in Array(overlays.keys) {
            hideOverlay(on: display, animated: false, reason: "the screen locked or slept")
        }
        fadesAwaitingWallpaper.removeAll()
        filledSince.removeAll()
        unfilledSince.removeAll()
        lastWallpaperCheck.removeAll()
        swappedWhileFilled.removeAll()
        textWillBeWhite.removeAll()
        rememberedFilled.removeAll()
        blackTextSince.removeAll()
    }

    // MARK: - Filled displays

    /// Trackpad fingers resting or moving: three or more is a desktop swipe.
    func desktopGestureContactsChanged(_ fingers: Int) {
        let active = fingers >= 3
        guard active != desktopGestureActive else { return }
        desktopGestureActive = active
        dockAwayDebugLog("Menu bar blackout: \(active ? "swipe started" : "fingers lifted")")
        if active {
            lookAheadForSwipe()
        } else {
            // Wait for macOS to report where the swipe landed.
            desktopSwitchSettlesAt = ProcessInfo.processInfo.systemUptime + Self.swipeLandingTimeout
        }
    }

    /// Works out whether the desktops either side have a filling window, so
    /// the black can follow the swipe instead of waiting for it to land.
    private func lookAheadForSwipe() {
        swipeLookahead = nil
        swipeStartDesktops.removeAll()
        swipeHidBlack = false
        guard isEnabled else { return }
        for display in NSScreen.screens.compactMap(\.displayID) {
            swipeStartDesktops[display] = currentSpaceID(display)
        }
        guard let display = displayUnderPointer(),
              let displayInfo = currentDisplays().first(where: { $0.id == display }) else { return }
        let neighbors = adjacentDesktops(display)
        guard neighbors.previous != nil || neighbors.next != nil else { return }
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var windowsByID: [CGWindowID: MenuBarBlackoutWindow] = [:]
        for window in Self.windows(from: list) { windowsByID[window.id] = window }
        // The Dock may be hidden here and showing there, or the other way
        // round, and macOS fits tiled windows beside a showing Dock.
        let otherDesktop = MenuBarBlackoutDecision.allowingForDock(displayInfo, on: Self.dockEdge(),
                                                                   size: Self.dockAllowance())
        func filled(_ desktop: (id: UInt64, isFullscreen: Bool)?) -> Bool? {
            guard let desktop else { return nil }
            // macOS hides the menu bar in full screen, so there's no black there.
            if desktop.isFullscreen { return false }
            guard let ids = windowIDsOnDesktop(desktop.id) else { return spaceFilled[desktop.id] }
            let windows = ids.compactMap { windowsByID[$0] }
            let isFilled = MenuBarBlackoutDecision.fillingWindows([otherDesktop], windows: windows,
                                                                  excluding: getpid())[display] != nil
            spaceFilled[desktop.id] = isFilled
            return isFilled
        }
        let lookahead = (display: display, previous: filled(neighbors.previous), next: filled(neighbors.next))
        swipeLookahead = lookahead
        func describe(_ filled: Bool?) -> String { filled.map { $0 ? "filled" : "not filled" } ?? "none" }
        dockAwayDebugLog("Menu bar blackout: previous desktop \(describe(lookahead.previous)), "
                         + "next desktop \(describe(lookahead.next))")
    }

    private static func dockEdge() -> MenuBarBlackoutDockEdge {
        switch CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String {
        case "left": .left
        case "right": .right
        default: .bottom
        }
    }

    /// Room for a showing Dock: its icons plus the space around them.
    private static func dockAllowance() -> CGFloat {
        let tileSize = (CFPreferencesCopyAppValue("tilesize" as CFString, "com.apple.dock" as CFString)
                        as? NSNumber)?.doubleValue ?? 64
        return CGFloat(min(max(tileSize, 16), 128)) + 40
    }

    /// The swipe's direction is known as soon as the fingers start moving, and
    /// again each time it turns around, up to when the fingers lift. Heading
    /// for a desktop with nothing filling it, the black fades out now. The
    /// desktop being left still has its black-band wallpaper, so the menu bar
    /// stays black and slides away with it, and its text never ends up black
    /// on black. Turning back, the black returns.
    func desktopSwipeMoved(towardNext: Bool) {
        let landing = ProcessInfo.processInfo.systemUptime < desktopSwitchSettlesAt
        guard isEnabled, !isAway, desktopGestureActive || landing, let lookahead = swipeLookahead,
              let overlay = overlays[lookahead.display] else { return }
        let destination = towardNext ? lookahead.next : lookahead.previous
        if destination == false {
            if overlay.isShown { swipeHidBlack = true }
            hideOverlay(on: lookahead.display, animated: true, reason: "swiping to a desktop that isn't filled")
        } else if swipeHidBlack {
            swipeHidBlack = false
            overlay.setShown(true, animated: true, reason: "the swipe turned back")
        }
    }

    private func displayUnderPointer() -> CGDirectDisplayID? {
        let pointer = NSEvent.mouseLocation
        return (NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main)?.displayID
    }

    /// While moving between desktops, keeps the black as it is, or follows
    /// what the arriving desktop had last time, instead of reading the window
    /// list mid-transition.
    private func followDesktopSwitch(on displays: [MenuBarBlackoutDisplay]) {
        guard !desktopGestureActive, !isSwitchingDesktops() else { return }
        for display in displays {
            guard let space = currentSpaceID(display.id), space != swipeStartDesktops[display.id],
                  let filled = spaceFilled[space] else { continue }
            if filled {
                overlays[display.id]?.setShown(true, animated: true, reason: "arrived on a desktop that was filled")
            } else if overlays[display.id]?.isShown == true,
                      MenuBarBlackoutDecision.fillingWindows([display], windows: currentWindows(),
                                                             excluding: getpid())[display.id] == nil {
                // Only once the window list agrees, in case this desktop
                // has been filled since it was last showing.
                hideOverlay(on: display.id, animated: true, quickly: true, reason: "arrived on a desktop that wasn't filled")
            }
        }
    }

    private func evaluate(checkWallpapers requestedWallpaperCheck: Bool) {
        guard isEnabled else { return }
        if shouldBeAway {
            if !isAway { stepAway() }
            return
        }
        // Back from the lock screen, the wallpapers need their bands again.
        let checkWallpapers = requestedWallpaperCheck || isAway
        isAway = false
        let now = ProcessInfo.processInfo.systemUptime
        let displays = currentDisplays()
        // Mission Control shows the desktops without the menu bar; the black
        // steps aside and the wallpapers stay as they are until it closes.
        if isSuspended() {
            for display in displays { hideOverlay(on: display.id, animated: true, reason: "Mission Control") }
            return
        }
        if desktopGestureActive || isSwitchingDesktops() || now < desktopSwitchSettlesAt {
            followDesktopSwitch(on: displays)
            return
        }
        let settledDesktop = desktopJustChanged
        desktopJustChanged = false
        let windows = currentWindows()
        let filling = MenuBarBlackoutDecision.fillingWindows(displays, windows: windows, excluding: getpid())
        // Mid-slide, the window list mixes two desktops, and macOS still
        // counts the one being left as current, so a wallpaper set then lands
        // on the wrong desktop and the menu bar text ends up out of step with
        // it. Keyboard shortcuts and other switches give no notice of the
        // slide, so nothing changes until it's over.
        let changing = displays.contains { (filling[$0.id] != nil) != (overlays[$0.id]?.isShown == true) }
        if !changing || settledDesktop {
            slidingSince = nil
        } else if desktopIsSliding(displays, windows: windows, now: now) {
            return
        }
        let fillingIDs = Set(filling.values.map(\.id))
        cornerRadii = cornerRadii.filter { fillingIDs.contains($0.key) }

        for display in displays {
            guard let screen = NSScreen.screen(withDisplayID: display.id) else { continue }
            if checkWallpapers, let inputs = wallpaperInputs(for: screen), !isBandedCopy(inputs.url) {
                // Ready before a window fills this desktop, so the swap is instant.
                prepareWallpaper(inputs)
            }
            var filled = filling[display.id] != nil
            if filled {
                unfilledSince[display.id] = nil
            } else if overlays[display.id]?.isShown == true, !settledDesktop {
                let since = unfilledSince[display.id] ?? now
                unfilledSince[display.id] = since
                // Keep the black through a brief gap, such as mid-transition.
                if now - since < Self.hideDelay { filled = true }
            }
            if rememberedFilled[display.id] != filled {
                rememberedFilled[display.id] = filled
                if let space = currentSpaceID(display.id) { spaceFilled[space] = filled }
            }
            if !filled { unfilledSince[display.id] = nil }
            if filling[display.id] == nil, filled { continue }
            if let window = filling[display.id] {
                filledSince[display.id] = filledSince[display.id] ?? now
                // The wallpaper swaps as the black fades in, so the menu bar
                // text turns white about when the fade finishes.
                let checkedRecently = now - (lastWallpaperCheck[display.id] ?? 0) < Self.wallpaperCheckInterval
                if checkWallpapers || !checkedRecently {
                    lastWallpaperCheck[display.id] = now
                    // Without a wallpaper DockAway can band, the black needs
                    // the text white already. While its color can't be told,
                    // such as with DockAway's menu open, the black stays as it is.
                    if let white = applyBand(on: screen, display: display.id, now: now) {
                        textWillBeWhite[display.id] = white
                    }
                }
                if textWillBeWhite[display.id] == true {
                    showOverlay(on: screen, display: display, around: window)
                    checkTextTurnedWhite(on: screen, display: display.id, now: now)
                } else {
                    hideOverlay(on: display.id, animated: true, reason: "the menu bar text wouldn't be white")
                }
            } else {
                let wasFilled = filledSince.removeValue(forKey: display.id) != nil
                lastWallpaperCheck[display.id] = nil
                textWillBeWhite[display.id] = nil
                blackTextSince[display.id] = nil
                swappedWhileFilled.remove(display.id)
                let restored = (wasFilled || checkWallpapers) && restoreWallpaper(on: screen)
                if settledDesktop {
                    // Arriving on this desktop, macOS gives its menu bar the
                    // wallpaper's text color right away, so the black goes quickly.
                    hideOverlay(on: display.id, animated: true, quickly: true, reason: "arrived on a desktop with nothing filling it")
                } else {
                    hideOverlay(on: display.id, animated: true, awaitingWallpaper: restored, reason: "no window fills the screen")
                }
            }
        }
        let current = Set(displays.map(\.id))
        for display in overlays.keys where !current.contains(display) {
            hideOverlay(on: display, animated: false, reason: "display disconnected")
        }
    }

    /// Whether a desktop is sliding in or out. macOS lines up the menu bars
    /// of the desktops either side just off screen while it slides, even when
    /// the desktop coming in has no windows; and the windows of the desktop
    /// coming in show before macOS counts it as current.
    private func desktopIsSliding(_ displays: [MenuBarBlackoutDisplay], windows: [MenuBarBlackoutWindow],
                                  now: TimeInterval) -> Bool {
        let ownPID = getpid()
        let menuBarLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let allWindows = Self.windows(from: CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                                      as? [[String: Any]] ?? [])
        let menuBarsOffScreen = allWindows.contains { window in
            window.layer == menuBarLevel && !displays.contains { $0.frame.intersects(window.bounds) }
        }
        let sliding = menuBarsOffScreen || displays.contains { display in
            guard let space = currentSpaceID(display.id), let ids = windowIDsOnDesktop(space) else { return false }
            let onDesktop = Set(ids)
            return windows.contains {
                $0.layer == 0 && $0.ownerPID != ownPID && $0.bounds.intersects(display.frame) && !onDesktop.contains($0.id)
            }
        }
        guard sliding else {
            slidingSince = nil
            return false
        }
        let since = slidingSince ?? now
        slidingSince = since
        return now - since < Self.longestSlide
    }

    /// The black is showing and the wallpaper is banded, so the menu bar text
    /// should be white. If it stays black anyway, macOS and the wallpaper are
    /// out of step. Rather than leave black text on black, the black goes and
    /// the wallpaper is put back, to be banded afresh at the next check.
    private func checkTextTurnedWhite(on screen: NSScreen, display: CGDirectDisplayID, now: TimeInterval) {
        guard menuBarTextIsWhite(display) == false else {
            blackTextSince[display] = nil
            return
        }
        let since = blackTextSince[display] ?? now
        blackTextSince[display] = since
        guard now - since >= Self.blackTextGrace else { return }
        blackTextSince[display] = nil
        hideOverlay(on: display, animated: true, quickly: true, reason: "the menu bar text stayed black")
        textWillBeWhite[display] = nil
        lastWallpaperCheck[display] = now
        // Putting it back here isn't another app competing for the wallpaper.
        swappedWhileFilled.remove(display)
        let redos = (wallpaperRedos[display] ?? 0) + 1
        wallpaperRedos[display] = redos
        guard redos <= 2 else {
            swapsPausedUntil[display] = now + 300
            dockAwayDebugLog("Menu bar blackout: the menu bar text keeps staying black; pausing for 5 minutes")
            return
        }
        restoreWallpaper(on: screen)
    }

    private func currentDisplays() -> [MenuBarBlackoutDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            let bounds = CGDisplayBounds(id)
            let visible = screen.visibleFrame
            let usable = CGRect(x: bounds.minX + visible.minX - screen.frame.minX,
                                y: bounds.minY + screen.frame.maxY - visible.maxY,
                                width: visible.width, height: visible.height)
            return MenuBarBlackoutDisplay(id: id, frame: bounds, usableFrame: usable)
        }
    }

    private func currentWindows() -> [MenuBarBlackoutWindow] {
        Self.windows(from: CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                      kCGNullWindowID) as? [[String: Any]] ?? [])
    }

    private static func windows(from list: [[String: Any]]) -> [MenuBarBlackoutWindow] {
        list.compactMap { info in
            guard let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
            return MenuBarBlackoutWindow(bounds: bounds,
                                         layer: info[kCGWindowLayer as String] as? Int ?? 0,
                                         ownerPID: info[kCGWindowOwnerPID as String] as? pid_t ?? 0,
                                         alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
                                         id: info[kCGWindowNumber as String] as? CGWindowID ?? 0)
        }
    }

    // MARK: - Overlay

    /// Blacks out the menu bar and a thin frame down the window's sides, with
    /// the window showing through an opening rounded like its corners.
    private func showOverlay(on screen: NSScreen, display: MenuBarBlackoutDisplay, around window: MenuBarBlackoutWindow) {
        // The window in screen coordinates (origin at the bottom left).
        let windowFrame = CGRect(x: screen.frame.minX + window.bounds.minX - display.frame.minX,
                                 y: screen.frame.maxY - (window.bounds.maxY - display.frame.minY),
                                 width: window.bounds.width, height: window.bounds.height)
        let menuBarBottom = screen.visibleFrame.maxY + MenuBarBlackoutDecision.tolerance
        let top = min(windowFrame.maxY, menuBarBottom)
        let menuBar = NSRect(x: screen.frame.minX, y: top, width: screen.frame.width, height: screen.frame.maxY - top)
        let overlay = overlays[display.id] ?? MenuBarBlackoutOverlay()
        overlays[display.id] = overlay
        overlay.update(screen: screen.frame, menuBar: menuBar,
                       window: windowFrame.intersection(screen.frame),
                       opening: MenuBarBlackoutDecision.frameOpening(window: windowFrame, menuBarBottom: menuBarBottom),
                       radius: cornerRadius(of: window.id))
        fadesAwaitingWallpaper.remove(display.id)
        overlay.setShown(true, animated: true, reason: "a window fills the screen")
    }

    private func hideOverlay(on display: CGDirectDisplayID, animated: Bool, awaitingWallpaper: Bool = false,
                             quickly: Bool = false, reason: String) {
        guard let overlay = overlays[display] else { return }
        if animated && awaitingWallpaper {
            fadesAwaitingWallpaper.insert(display)
            overlay.setShown(false, animated: true, after: Self.wallpaperShowTimeout, reason: reason)
        } else {
            overlay.setShown(false, animated: animated, quickly: quickly, reason: reason)
        }
        if !animated { overlays[display] = nil }
    }

    /// macOS changed the menu bar's text color. That happens once a wallpaper
    /// DockAway put back is showing, so black waiting for that fades out now.
    /// And if the text turned black with the black still showing and no window
    /// filling the screen, nothing is about to turn it white again, so the
    /// black goes at once rather than leave black text on black.
    func menuBarAppearanceDidChange() {
        if let display = NSScreen.main?.displayID, let white = menuBarTextIsWhite(display),
           white != loggedTextIsWhite {
            loggedTextIsWhite = white
            dockAwayDebugLog("Menu bar blackout: menu bar text turned \(white ? "white" : "black")")
        }
        for display in fadesAwaitingWallpaper { overlays[display]?.fadeOutIfWaiting() }
        fadesAwaitingWallpaper.removeAll()
        guard isEnabled else { return }
        let displays = currentDisplays()
        for display in displays where overlays[display.id]?.isShown == true
            && menuBarTextIsWhite(display.id) == false {
            let filled = MenuBarBlackoutDecision.fillingWindows([display], windows: currentWindows(),
                                                                excluding: getpid())[display.id] != nil
            if !filled {
                hideOverlay(on: display.id, animated: true, quickly: true, reason: "the menu bar text turned black")
            }
        }
    }

    private func cornerRadius(of window: CGWindowID) -> CGFloat {
        if let known = cornerRadii[window] { return known }
        let radius = WindowCornerRadius.radius(of: window) ?? Self.typicalWindowRadius
        cornerRadii[window] = radius
        return radius
    }

    /// Typical window corners, where the window server can't say.
    private static var typicalWindowRadius: CGFloat {
        if #available(macOS 26.0, *) { 16 } else { 10 }
    }

    /// A window's outline, with the same corners the black's are drawn with.
    private static func windowShape(in rect: CGRect, radius: CGFloat) -> CGPath {
        if #available(macOS 26.0, *) {
            return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
        }
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    // MARK: - Wallpaper

    /// Uses a copy of the wallpaper with a black band at the top, so the
    /// menu bar text turns white, unless the wallpaper is dark there already.
    /// The current wallpaper on a screen and what identifies its copies.
    private struct WallpaperInputs {
        let url: URL
        let options: [NSWorkspace.DesktopImageOptionKey: Any]
        let pixelSize: CGSize
        let bandHeight: Int
        /// The corners beside a filling window's top corners, in pixels.
        let cornerRadius: CGFloat
        let key: String
    }

    private func wallpaperInputs(for screen: NSScreen) -> WallpaperInputs? {
        guard let url = workspace.desktopImageURL(for: screen), url.isFileURL,
              !MenuBarBlackoutDecision.isStandInWallpaper(url.path),
              !MenuBarBlackoutDecision.isStandInWallpaper(url.resolvingSymlinksInPath().path) else { return nil }
        let options = workspace.desktopImageOptions(for: screen) ?? [:]
        let pixelSize = CGSize(width: (screen.frame.width * screen.backingScaleFactor).rounded(),
                               height: (screen.frame.height * screen.backingScaleFactor).rounded())
        let bandHeight = Int(ceil((screen.frame.maxY - screen.visibleFrame.maxY) * screen.backingScaleFactor))
        // Shaped like the black's own corners over a typical window.
        let cornerRadius = ((Self.typicalWindowRadius + MenuBarBlackoutDecision.cornerRoundingAllowance)
                            * screen.backingScaleFactor).rounded()
        return inputs(url: url, options: options, pixelSize: pixelSize, bandHeight: bandHeight,
                      cornerRadius: cornerRadius)
    }

    private func inputs(url: URL, options: [NSWorkspace.DesktopImageOptionKey: Any], pixelSize: CGSize,
                        bandHeight: Int, cornerRadius: CGFloat) -> WallpaperInputs {
        WallpaperInputs(url: url, options: options, pixelSize: pixelSize, bandHeight: bandHeight,
                        cornerRadius: cornerRadius,
                        key: cacheKey(for: url, options: options, pixelSize: pixelSize, bandHeight: bandHeight,
                                      cornerRadius: cornerRadius))
    }

    /// Returns whether the menu bar text will be white behind the black, or
    /// nil if that can't be told right now, as while DockAway's menu is open.
    private func applyBand(on screen: NSScreen, display: CGDirectDisplayID, now: TimeInterval) -> Bool? {
        guard var inputs = wallpaperInputs(for: screen) else { return menuBarTextIsWhite(display) }
        if isBandedCopy(inputs.url) {
            guard let swap = swaps[inputs.url.lastPathComponent] else { return true }
            let original = self.inputs(url: URL(fileURLWithPath: swap.originalPath), options: swap.options,
                                       pixelSize: inputs.pixelSize, bandHeight: inputs.bandHeight,
                                       cornerRadius: inputs.cornerRadius)
            // A copy made before the corners were part of it is made again.
            guard inputs.url.lastPathComponent != "\(original.key)-band.jpg",
                  FileManager.default.fileExists(atPath: swap.originalPath) else { return true }
            inputs = original
        }
        let current = inputs.url, options = inputs.options
        // Full Disk Access may have been turned on since macOS last said no.
        if case .blocked(let checkedAt)? = preparedWallpapers[inputs.key],
           now - checkedAt >= Self.blockedRetryInterval {
            preparedWallpapers[inputs.key] = nil
        }
        let copies: (banded: URL, plain: URL)
        switch preparedWallpapers[inputs.key] {
        case nil:
            // The copy is still being made. The black shows now and the
            // wallpaper follows as soon as the copy is ready, unless macOS
            // won't let DockAway read the wallpaper at all.
            prepareWallpaper(inputs)
            if case .blocked? = preparedWallpapers[inputs.key] { return textIsWhiteWithoutWallpaper(inputs, on: display) }
            return true
        case .alreadyDark?:
            return true
        case .uncopyable?:
            return menuBarTextIsWhite(display)
        case .blocked?:
            return textIsWhiteWithoutWallpaper(inputs, on: display)
        case .copies(let banded, let plain)?:
            guard FileManager.default.fileExists(atPath: banded.path) else {
                preparedWallpapers[inputs.key] = nil
                prepareWallpaper(inputs)
                return true
            }
            copies = (banded, plain)
        }
        guard (swapsPausedUntil[display] ?? 0) <= now else { return false }

        // Another app putting its wallpaper back while the window still fills
        // the screen means it's managing the wallpaper; stop competing for a while.
        if swappedWhileFilled.contains(display) {
            let reverts = (wallpaperReverts[display] ?? 0) + 1
            wallpaperReverts[display] = reverts
            if reverts >= 2 {
                wallpaperReverts[display] = 0
                swapsPausedUntil[display] = now + 300
                dockAwayDebugLog("Menu bar blackout: the wallpaper keeps changing back; pausing for 5 minutes")
                return false
            }
        }
        swappedWhileFilled.insert(display)

        let scaling = (options[.imageScaling] as? NSNumber)?.intValue ?? Int(NSImageScaling.scaleProportionallyUpOrDown.rawValue)
        let fill = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB)
        swaps[copies.banded.lastPathComponent] = Swap(
            originalPath: current.path, plainCopyPath: copies.plain.path, scaling: scaling,
            allowClipping: (options[.allowClipping] as? NSNumber)?.boolValue ?? true,
            fillColor: fill.map { [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent] },
            created: Date())
        saveSwaps()
        do {
            try workspace.setDesktopImageURL(copies.banded, for: screen, options: [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: true,
                .fillColor: NSColor.black
            ])
            return true
        } catch {
            dockAwayDebugLog("Menu bar blackout: couldn't set the banded wallpaper: \(error.localizedDescription)")
            return false
        }
    }

    private enum WallpaperCopies: Sendable {
        case copies(banded: URL, plain: URL)
        /// Dark enough behind the menu bar that the text is white already.
        case alreadyDark
        /// Dynamic, aerial, or unreadable wallpapers.
        case uncopyable
        /// macOS won't let DockAway read it, as when it's in another app's
        /// private folder, as of this time.
        case blocked(at: TimeInterval)
    }

    /// How often a wallpaper macOS wouldn't let DockAway read is tried again,
    /// in case Full Disk Access was turned on. macOS answers at once.
    private static let blockedRetryInterval: TimeInterval = 10

    /// Whether macOS's privacy protection stops DockAway reading a file, as it
    /// does in another app's private folder without Full Disk Access.
    nonisolated private static func readingIsBlocked(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor < 0 else {
            close(descriptor)
            return false
        }
        return errno == EPERM
    }

    /// The wallpaper showing on a display, when macOS won't let DockAway read
    /// it, so the menu can explain why the menu bar isn't turning black.
    var blockedWallpaper: MenuBarBlackoutBlockedWallpaper? {
        guard isEnabled else { return nil }
        for screen in NSScreen.screens {
            guard let inputs = wallpaperInputs(for: screen), case .blocked? = preparedWallpapers[inputs.key]
            else { continue }
            return blockedWallpaper(at: inputs.url)
        }
        return nil
    }

    private func blockedWallpaper(at url: URL) -> MenuBarBlackoutBlockedWallpaper {
        let folder = MenuBarBlackoutDecision.appFolderIdentifier(of: url.path, home: NSHomeDirectory())
        let app = folder.flatMap { workspace.urlForApplication(withBundleIdentifier: $0) }
        return MenuBarBlackoutBlockedWallpaper(appName: app?.deletingPathExtension().lastPathComponent,
                                               appFolder: folder)
    }

    /// Without reading the wallpaper, the black only shows if the menu bar
    /// text is white already. If it isn't, DockAway says why.
    private func textIsWhiteWithoutWallpaper(_ inputs: WallpaperInputs, on display: CGDirectDisplayID) -> Bool? {
        guard let white = menuBarTextIsWhite(display) else { return nil }
        if !white { wallpaperAccessNeeded(blockedWallpaper(at: inputs.url)) }
        return white
    }

    /// Puts back the wallpaper a banded copy replaced on this screen's desktop.
    /// Returns whether it did.
    @discardableResult
    private func restoreWallpaper(on screen: NSScreen) -> Bool {
        guard !swaps.isEmpty, let current = workspace.desktopImageURL(for: screen),
              isBandedCopy(current) else { return false }
        guard let swap = swaps[current.lastPathComponent] else { return false }
        let fileManager = FileManager.default
        let original = fileManager.fileExists(atPath: swap.originalPath)
            ? URL(fileURLWithPath: swap.originalPath)
            : URL(fileURLWithPath: swap.plainCopyPath)
        let options = fileManager.fileExists(atPath: swap.originalPath)
            ? swap.options
            : [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true]
        do {
            try workspace.setDesktopImageURL(original, for: screen, options: options)
            return true
        } catch {
            dockAwayDebugLog("Menu bar blackout: couldn't restore the wallpaper: \(error.localizedDescription)")
            return false
        }
    }

    private func isBandedCopy(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().path == Self.copiesDirectory.standardizedFileURL.path
            && url.lastPathComponent.hasSuffix("-band.jpg")
    }

    nonisolated private static var copiesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DockAway/Menu Bar Wallpapers", isDirectory: true)
    }

    private func cacheKey(for url: URL, options: [NSWorkspace.DesktopImageOptionKey: Any],
                          pixelSize: CGSize, bandHeight: Int, cornerRadius: CGFloat) -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let scaling = (options[.imageScaling] as? NSNumber)?.intValue ?? -1
        let clipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? true
        let fill = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB).map {
            "\($0.redComponent),\($0.greenComponent),\($0.blueComponent)"
        } ?? "-"
        let text = "\(url.path)|\(modified)|\(scaling)|\(clipping)|\(fill)|\(Int(pixelSize.width))x\(Int(pixelSize.height))|\(bandHeight)|corners \(Int(cornerRadius))"
        return SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Makes a wallpaper's copies in the background, ahead of a window filling
    /// the screen where possible, so neither the swap nor the fade waits on it.
    private func prepareWallpaper(_ inputs: WallpaperInputs) {
        let key = inputs.key
        guard preparedWallpapers[key] == nil, !preparingWallpapers.contains(key) else { return }
        let directory = Self.copiesDirectory
        let banded = directory.appendingPathComponent("\(key)-band.jpg")
        let plain = directory.appendingPathComponent("\(key)-plain.jpg")
        if FileManager.default.fileExists(atPath: banded.path), FileManager.default.fileExists(atPath: plain.path) {
            preparedWallpapers[key] = .copies(banded: banded, plain: plain)
            return
        }
        if Self.readingIsBlocked(inputs.url) {
            preparedWallpapers[key] = .blocked(at: ProcessInfo.processInfo.systemUptime)
            dockAwayDebugLog("Menu bar blackout: macOS won't let DockAway read the wallpaper; it needs Full Disk Access")
            return
        }
        preparingWallpapers.insert(key)
        let url = inputs.url, pixelSize = inputs.pixelSize, bandHeight = inputs.bandHeight
        let cornerRadius = inputs.cornerRadius
        let windowShape = Self.windowShape(in: MenuBarBlackoutDecision.wallpaperWindowRect(canvas: pixelSize,
                                                                                           bandHeight: bandHeight),
                                           radius: cornerRadius)
        let scaling = (inputs.options[.imageScaling] as? NSNumber)?.uintValue
            ?? NSImageScaling.scaleProportionallyUpOrDown.rawValue
        let allowClipping = (inputs.options[.allowClipping] as? NSNumber)?.boolValue ?? true
        let fill = (inputs.options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB).map {
            [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent]
        }
        let controller = self
        DispatchQueue.global(qos: .utility).async {
            let result = Self.renderCopies(of: url, scaling: scaling, allowClipping: allowClipping, fill: fill,
                                           pixelSize: pixelSize, bandHeight: bandHeight,
                                           cornerRadius: cornerRadius, windowShape: windowShape,
                                           banded: banded, plain: plain, directory: directory)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { controller.finishPreparing(key, result) }
            }
        }
    }

    private func finishPreparing(_ key: String, _ result: WallpaperCopies) {
        preparingWallpapers.remove(key)
        preparedWallpapers[key] = result
        pruneCopies()
        // A filled display waiting on this copy swaps at the next check.
        lastWallpaperCheck.removeAll()
    }

    /// Renders the wallpaper as the desktop shows it, once plain and once with
    /// the black band, unless it's dark there already or can't be copied.
    nonisolated private static func renderCopies(of url: URL, scaling scalingValue: UInt, allowClipping: Bool,
                                                 fill: [CGFloat]?, pixelSize: CGSize, bandHeight: Int,
                                                 cornerRadius: CGFloat, windowShape: CGPath,
                                                 banded: URL, plain: URL, directory: URL) -> WallpaperCopies {
        guard bandHeight > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(pixelSize.width), height: Int(pixelSize.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return .uncopyable }

        let scaling = NSImageScaling(rawValue: scalingValue) ?? .scaleProportionallyUpOrDown
        let fillColor = fill.flatMap { $0.count == 4 ? CGColor(srgbRed: $0[0], green: $0[1], blue: $0[2], alpha: $0[3]) : nil }
            ?? CGColor(gray: 0, alpha: 1)
        context.setFillColor(fillColor)
        context.fill(CGRect(origin: .zero, size: pixelSize))
        context.interpolationQuality = .high
        context.draw(image, in: MenuBarBlackoutDecision.wallpaperRect(
            imageSize: CGSize(width: image.width, height: image.height), canvas: pixelSize,
            scaling: scaling, allowClipping: allowClipping))
        guard let plainImage = context.makeImage() else { return .uncopyable }

        // Bitmap contexts put row zero at the bottom, so the band is at the top.
        let bandRect = CGRect(x: 0, y: Int(pixelSize.height) - bandHeight, width: Int(pixelSize.width), height: bandHeight)
        if let luminance = averageLuminance(of: plainImage, in: bandRect),
           luminance < MenuBarBlackoutDecision.darkBandLuminance {
            return .alreadyDark
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(bandRect)
        // And the gaps beside a filling window's rounded top corners. The
        // window hides the rest, so they come in black with the band as the
        // desktop slides in, rather than when the black over it fades in.
        for square in MenuBarBlackoutDecision.wallpaperCornerRects(canvas: pixelSize, bandHeight: bandHeight,
                                                                   radius: cornerRadius) {
            context.saveGState()
            context.clip(to: square)
            context.addRect(square)
            context.addPath(windowShape)
            context.fillPath(using: .evenOdd)
            context.restoreGState()
        }
        guard let bandedImage = context.makeImage() else { return .uncopyable }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch { return .uncopyable }
        guard writeJPEG(plainImage, to: plain), writeJPEG(bandedImage, to: banded) else { return .uncopyable }
        return .copies(banded: banded, plain: plain)
    }

    nonisolated private static func writeJPEG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    /// Average luminance of a region, sampled down to a small grid.
    nonisolated private static func averageLuminance(of image: CGImage, in rect: CGRect) -> Double? {
        let gridWidth = 64, gridHeight = 4
        guard let region = image.cropping(to: CGRect(x: rect.minX, y: CGFloat(image.height) - rect.maxY,
                                                     width: rect.width, height: rect.height)),
              let context = CGContext(data: nil, width: gridWidth, height: gridHeight, bitsPerComponent: 8,
                                      bytesPerRow: gridWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data else { return nil }
        context.draw(region, in: CGRect(x: 0, y: 0, width: gridWidth, height: gridHeight))
        let pixels = data.bindMemory(to: UInt8.self, capacity: gridWidth * gridHeight * 4)
        var total = 0.0
        for index in 0..<(gridWidth * gridHeight) {
            let red = Double(pixels[index * 4]), green = Double(pixels[index * 4 + 1]), blue = Double(pixels[index * 4 + 2])
            total += (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255
        }
        return total / Double(gridWidth * gridHeight)
    }

    private func saveSwaps() {
        if swaps.count > Self.maximumSwapRecords {
            for (name, _) in swaps.sorted(by: { $0.value.created < $1.value.created })
                .prefix(swaps.count - Self.maximumSwapRecords) {
                swaps[name] = nil
            }
        }
        if let data = try? JSONEncoder().encode(swaps) {
            UserDefaults.standard.set(data, forKey: Self.swapsKey)
        }
    }

    /// Deletes copies no saved swap refers to any more.
    private func pruneCopies() {
        let directory = Self.copiesDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        var keep = Set(swaps.keys)
        swaps.values.forEach { keep.insert(URL(fileURLWithPath: $0.plainCopyPath).lastPathComponent) }
        for case .copies(let banded, let plain) in preparedWallpapers.values {
            keep.insert(banded.lastPathComponent)
            keep.insert(plain.lastPathComponent)
        }
        // Leave the newest copies alone: they may be in use before their swap is saved.
        let recent = files.filter { name in
            guard let modified = (try? FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent(name).path))?[.modificationDate] as? Date else { return false }
            return Date().timeIntervalSince(modified) < 60
        }
        for name in files where !keep.contains(name) && !recent.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

/// The black menu bar and thin frame around the window filling one display.
@MainActor
private final class MenuBarBlackoutOverlay {
    private let frame = MenuBarBlackoutPanel(content: MenuBarBlackoutFrameView())
    /// Whether it's showing or fading in, rather than hidden or fading out.
    private(set) var isShown = false
    /// Cancels a delayed fade out when the black is wanted again first.
    private var fadeGeneration = 0
    private var fadeOutWaiting = false
    private static let fadeDuration: TimeInterval = 0.35
    /// For when the menu bar text is already, or about to be, black.
    private static let quickFadeDuration: TimeInterval = 0.15

    private var windows: [MenuBarBlackoutPanel] { [frame] }

    /// Everything in screen coordinates (origin at the bottom left).
    func update(screen: NSRect, menuBar: NSRect, window: CGRect, opening: CGRect, radius: CGFloat) {
        if frame.frame != screen { frame.setFrame(screen, display: false) }
        func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -screen.minX, dy: -screen.minY) }
        (frame.contentView as? MenuBarBlackoutFrameView)?.update(menuBar: local(menuBar), window: local(window),
                                                                  opening: local(opening), radius: radius)
    }

    /// Fades in or out. A fade out can wait, keeping the black solid meanwhile.
    func setShown(_ shown: Bool, animated: Bool, after delay: TimeInterval = 0, quickly: Bool = false,
                  reason: String) {
        guard animated else {
            fadeGeneration += 1
            isShown = shown
            windows.forEach { $0.contentView?.alphaValue = shown ? 1 : 0 }
            windows.forEach { shown ? $0.orderFrontRegardless() : $0.orderOut(nil) }
            return
        }
        // Repeating the same request, as every check does, keeps a pending fade.
        guard shown != isShown else { return }
        dockAwayDebugLog("Menu bar blackout: \(shown ? "show" : "hide") — \(reason)")
        fadeGeneration += 1
        isShown = shown
        fadeOutWaiting = !shown && delay > 0
        if fadeOutWaiting {
            let generation = fadeGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.fadeGeneration == generation else { return }
                self.fadeOutWaiting = false
                self.fade(shown: false)
            }
        } else {
            fade(shown: shown, duration: quickly ? Self.quickFadeDuration : Self.fadeDuration)
        }
    }

    /// Starts a fade out that's waiting, without waiting any longer.
    func fadeOutIfWaiting() {
        guard fadeOutWaiting, !isShown else { return }
        fadeGeneration += 1
        fadeOutWaiting = false
        fade(shown: false)
    }

    /// Fades the black through its layers, so Core Animation runs the fade and
    /// work on DockAway's main thread can't make it stall.
    private func fade(shown: Bool, duration: TimeInterval? = nil) {
        let windows = self.windows
        if shown { windows.forEach { $0.orderFrontRegardless() } }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            windows.forEach { $0.contentView?.alphaValue = shown ? 1 : 0 }
            if !shown { windows.forEach { $0.orderOut(nil) } }
            return
        }
        let generation = fadeGeneration
        let overlay = self
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration ?? Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            windows.forEach { $0.contentView?.animator().alphaValue = shown ? 1 : 0 }
        } completionHandler: {
            MainActor.assumeIsolated {
                // A later fade in wins over this one finishing.
                guard !shown, overlay.fadeGeneration == generation else { return }
                windows.forEach { $0.orderOut(nil) }
            }
        }
    }
}

/// A click-through window just below the menu bar's level, in front of the
/// filling window, so the menu bar and its items always draw over it. At the
/// menu bar's own level, whichever was brought forward last would be on top,
/// sometimes hiding the menus. The window itself stays clear; its
/// layer-backed content fades.
private final class MenuBarBlackoutPanel: NSWindow {
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)
        // Not in full screen spaces, where macOS hides the menu bar.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        content.wantsLayer = true
        content.alphaValue = 0
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // AppKit otherwise moves windows below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The black menu bar and the thin frame down the window's sides, around an
/// opening rounded like the window's corners, traced with a thin gray line
/// like a window's border. Shape layers keep it sharp without a screen-sized
/// image behind them.
private final class MenuBarBlackoutFrameView: NSView {
    private let black = CAShapeLayer()
    private let border = CAShapeLayer()
    private var geometry: [CGRect] = []
    private var radius: CGFloat = 0
    /// Over the window's own colors, like the border macOS draws on a dark window.
    private static let borderColor = NSColor(white: 1, alpha: 0.12).cgColor
    private static let borderWidth: CGFloat = 0.5

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        black.fillColor = NSColor.black.cgColor
        black.fillRule = .evenOdd
        border.fillColor = nil
        border.strokeColor = Self.borderColor
        border.lineWidth = Self.borderWidth
        for shape in [black, border] {
            shape.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
            layer?.addSublayer(shape)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// In this view's coordinates (origin at the bottom left).
    func update(menuBar: CGRect, window: CGRect, opening: CGRect, radius: CGFloat) {
        guard [menuBar, window, opening] != geometry || radius != self.radius else { return }
        geometry = [menuBar, window, opening]
        self.radius = radius
        let shape = Self.roundedRect(opening, radius: radius)
        let blackPath = CGMutablePath()
        // The menu bar and the window below it, without overlapping, so the
        // opening is the only hole.
        blackPath.addRect(menuBar)
        blackPath.addRect(CGRect(x: window.minX, y: window.minY, width: window.width,
                                 height: max(0, menuBar.minY - window.minY)))
        blackPath.addPath(shape)
        black.path = blackPath
        // Just inside the opening's edge.
        let inset = Self.borderWidth / 2
        border.path = Self.roundedRect(opening.insetBy(dx: inset, dy: inset), radius: max(0, radius - inset))
    }

    override func layout() {
        super.layout()
        black.frame = bounds
        border.frame = bounds
    }

    private static func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        if #available(macOS 26.0, *) {
            // Matches the smooth corners windows have.
            return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
        }
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}

/// A window's corner radius from the window server, which knows each window's
/// actual rounding. This is private API, so it returns nil where unavailable.
enum WindowCornerRadius {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias QueryWindows = @convention(c) (Int32, CFArray, Int32) -> Unmanaged<CFTypeRef>?
    private typealias CopyWindows = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    private typealias Advance = @convention(c) (CFTypeRef) -> Bool
    private typealias Radii = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func function<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(skyLight, name).map { unsafeBitCast($0, to: type) }
    }

    /// The largest of the window's four corner radii.
    static func radius(of window: CGWindowID) -> CGFloat? {
        guard window != 0,
              let mainConnection = function("SLSMainConnectionID", as: MainConnection.self),
              let queryWindows = function("SLSWindowQueryWindows", as: QueryWindows.self),
              let copyWindows = function("SLSWindowQueryResultCopyWindows", as: CopyWindows.self),
              let advance = function("SLSWindowIteratorAdvance", as: Advance.self),
              let radii = function("SLSWindowIteratorGetResolvedCornerRadii", as: Radii.self),
              let query = queryWindows(mainConnection(), [NSNumber(value: window)] as CFArray, 0)?.takeRetainedValue(),
              let iterator = copyWindows(query)?.takeRetainedValue(),
              advance(iterator),
              let values = radii(iterator)?.takeRetainedValue() as? [NSNumber],
              let largest = values.map({ CGFloat($0.doubleValue) }).max() else { return nil }
        return max(0, largest)
    }
}
