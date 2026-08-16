<p align="center">
  <img src="DockAway/docs/DockAwayIcon.png" alt="App Icon" width="256" height="256">
</p>

<h1 align="center">DockAway</h1>

A tiny macOS menu bar utility that keeps your Dock out of the way. It appears only when you're actually looking at an empty desktop and disappears the instant any app has a window on screen.

## When it's hidden and when it's shown
- Desktop is visible, no app window on screen | Dock Shown|
- Any app window is on screen |Dock Hidden|
- You minimize the only/last window on screen |Dock Shown|
- Two windows open, you minimize one |Dock Hidden|

It works by activating the system shortcut **⌘⌥D** (Command+Option+D), the same one you'd press manually to toggle Dock auto-hide, so it's never fighting macOS, just pressing the button for you at the right moments.

## Features

- A lightweight, Dynamic Menu bar app that's 100% Native, built with Swift.
- Works excellently with window management apps like "Rectangle" by Ryan Hanson or "Swish" by Christian Renninger (Highly Recommended, Incredible app.)
- Detects every app switch and every Space/desktop swipe in real time
- Detects the desktop state on the display under your pointer, rather than just checking Finder. This correctly handles minimizing an app's last window, tiled/split-screen layouts, trackpad gesture minimizing, and multi-display setups.
- Self-correcting: instead of trusting its own memory of "is the Dock shown?" it reads the live `com.apple.dock autohide` value before acting, so it can't quietly drift out of sync
- Features a safety check as a backstop, plus a check anchored to the exact moment of each Space change, so there's never a long window where it's silently wrong
- "Launch at Login" toggle built right into the menu, no detour through System Settings
- When quitting the app, it explicitly turns the Dock auto-hide setting off and shows the displays the dock which indicates the app has closed and that everything is back to normal. 
- Dynamic menu bar, Indicates dock status (Hidden or Shown) via up and down chevrons
- Automatic updates and changelogs via Sparkle

## Menu bar

- **Status**: Shows the active app and whether DockAway is currently running
- **Stop / Resume**: Temporarily pauses DockAway and restores normal Dock visibility, then resumes monitoring from the same media-style control
- **Launch at Login Toggle**: Activates via `SMAppService`, no System Settings round-trip needed
- **Blacklist**: Check running apps directly, or choose installed apps from Finder, so their windows do not hide the Dock
- **About DockAway**: The standard macOS about panel
- **Quit**: Also resets `autohide` to off and restarts the Dock. Quitting the app will bring the dock back up and visibly restore normal behavior

## Application Blacklist

By default, every standard app window counts as an occupied display. Open **Blacklist** from DockAway's menu-bar menu and check any running app that should keep the Dock shown while it is in front. Use **Choose Application…** to select an app that is not currently open. Blacklisted apps remain listed with a checkmark and can be removed individually, or all at once with **Remove All**. When another app is brought in front of a blacklisted app, DockAway resumes its normal hiding behavior.

## Requirements

- **macOS 14 (Sonoma) or newer**
- **Accessibility permission**: Required because the app sends a synthetic ⌘⌥D keystroke via `CGEvent`. Granted under **System Settings → Privacy & Security → Accessibility**.
- **Input Monitoring permission (activated automatically when granting Accessibility)**: Used by `MultitouchWatcher` to detect four fingers before macOS begins a workspace gesture. DockAway uses that early signal to pre-hide the Dock before a desktop swipe, preventing a late Dock slide or window artifact during landing.

## How the detection actually works

The core logic is distributed across `DockWatcher.swift`, `MultitouchWatcher.swift`, and `AppDelegate.swift`, combining event-driven accessibility notifications, window-list classification, and raw trackpad detection.

1. **Event-Driven Detection:** Per-app `AXObserver` notifications catch window creation, destruction, minimizing, restoring, moving, resizing, and focus changes. Workspace notifications cover app activation and Space changes.
2. **Source-Aware Trackpad Holds:** `MultitouchWatcher` reads raw trackpad contact positions before macOS recognizes a gesture. A sub-percent movement threshold distinguishes left, right, upward, and downward motion. On an empty source, DockAway takes a read-only snapshot of the neighboring Spaces while the fingers are still resting: a known occupied neighbor pre-hides at the first directional motion, while an empty or blacklisted neighbor keeps the Dock continuously visible. If that private Space information is unavailable, the existing short-lived on-screen destination probe takes over automatically. Upward Mission Control entry never sends HIDE.
3. **Mission Control Awareness:** DockAway watches Dock's accessibility hierarchy for Mission Control and uses a WindowServer signature as a fallback. While the overview or its landing animation is active, DockAway freezes its own visibility decisions and leaves the underlying auto-hide policy untouched. macOS can therefore present and dismiss its temporary Mission Control Dock natively, without changing an app window's landing geometry mid-animation. On a downward exit, the cached pre-overview desktop state chooses the landing hold: occupied apps remain hidden, while empty or blacklisted desktops keep the Dock continuously visible.
4. **Smart Window Detection:** `CGWindowListCopyWindowInfo` classifies the foremost normal app window on the display under the pointer. System overlays and tiny edge overlaps are ignored, and a covered blacklisted window cannot override the app in front of it.
5. **State Verification:** Before sending ⌘⌥D, DockAway checks the live `com.apple.dock autohide` value and tracks its most recent command so overlapping events cannot double-toggle the Dock.
6. **Timings & Safety Nets:** Four-finger direction is recognized directly from trackpad frames; pointer-display and Mission Control state changes retain a lightweight 0.12-second check. A 2-second full scan catches apps with incomplete accessibility support. Visible and hidden gesture holds release 0.60 seconds after finger lift, and Mission Control exit uses one 0.12-second verification tick before a fresh occupancy decision.
7. **Dynamic UI & Graceful Exits:** A dedicated 0.25-second timer updates the menu-bar chevron. Monitoring stops while the Mac is asleep or locked, and quitting DockAway restores the Dock to its normal visible state.

## Unsigned App Warning

Since I don't want to pay Apple $100 a year just for the pleasure of having my simple app "signed and notarized", You may get a pop-up saying " "DockAway" Not Opened ". In that case:
1. Click "Done" on the pop up
2. Go to System Settings> Privacy and Security and scroll all the way down
3. You'll see "DockAway was blocked to protect your mac", click "Open Anyway" 
4. Click "Open Anyway" again on the pop-up
5. Confirm with fingerprint/Password
6. Open DockAway again and grant accessibility permission. You're done! Enjoy your extra space.

## Note:
- If you have the **"Supercharge" app** by Sindre Horus, Please **set the "Delay before showing the Dock when hidden" option to "None"**. By default in the app, it is set to "0.2 seconds". Doing this prevents the annoying and slow 0.2s delay before the dock comes back up on empty desktops.
