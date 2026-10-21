<p align="center">
  <img src="DockAway/docs/DockAwayIcon.png" alt="DockAway app icon" width="160" height="160">
</p>

<h1 align="center">DockAway</h1>

A native macOS menu-bar utility that shows the Dock on empty desktops and hides it when an app occupies the active display. Keep it visible for selected apps with the Auto-Hide Blacklist, and manage your desktops without leaving the menu bar.

<p align="center">
  <a href="https://github.com/akhairaddin/DockAway/releases/latest">Download</a> ·
  <a href="#features">Features</a> ·
  <a href="#desktop-manager">Desktop Manager</a> ·
  <a href="#first-launch-and-permissions">Setup</a> ·
  <a href="#privacy">Privacy</a> ·
  <a href="changelog.html">Changelog</a> ·
  <a href="https://github.com/akhairaddin/DockAway/issues">Support</a>
</p>

**DockAway 2.1.4** adds a black menu bar for filled screens and middle click with force click. See the [changelog](changelog.html) for the complete release notes.

## Features

- **Automatic Dock visibility:** Reacts to app switches, window changes, and desktop swipes on the display under your pointer. Predictive hiding helps the Dock get out of the way as you open an app.
- **Desktop indicators:** Customize desktop numbers in the menu bar and optionally show a brief **Desktop Change Popup**, which can list the apps on the desktop you arrive on, the app in front first.
- **Window navigation:** Optional activate-on-hover, cursor teleportation between displays, and active-desktop placement for Finder and Chromium web apps.
- **Fill Window with Green Button:** Bring a window forward and toggle between filling the available display area and its remembered size. Without a saved size, restore to a centered smaller window. Option-click enters fullscreen.
- **Black Out Menu Bar for Filled Screens:** While a window fills the screen, the menu bar and a thin frame down the window's sides turn black so the window blends in, with the menu bar text staying white on any still-image wallpaper.
- **Middle Click with Force Click:** Press harder on the trackpad to middle click, so you can open links in new tabs or close tabs without a mouse.
- **Mission Control:** Optional automatic desktop-strip expansion and hovered-window actions for closing, minimizing, or quitting. Ability to use keyboard shortcuts to close or minimize apps.
- **Dock controls:** Adjust position, animation speed, reveal delay, and which settings persist after quitting. Optional Dock-icon actions minimize or hide an app's windows and restore them on another click, or cycle through its windows.
- **Extras and appearance:** Optional screenshot copying with or without the floating thumbnail, Delete moving selected Finder items to the Trash, upright Quick Look image copies, lock/unlock sounds, a mute-aware volume icon, and turning the keyboard light off during full-screen video. Appearance follows macOS.
- **Everyday essentials:** Pause/resume DockAway, Launch at Login, configurable automatic updates through Sparkle, Signed and Apple-Notarized official releases.

### Dock behavior and Auto-Hide Blacklist

An empty desktop or minimizing its last window shows the Dock. App windows hide it, unless a blacklisted app is frontmost. A blacklisted window behind another app does not keep the Dock visible.

Use **Auto-Hide Blacklist → Choose Application…** for apps that aren't running. DockAway respects your system Dock-hiding shortcut, **Command+Option+D** by default, and checks the live Dock state before toggling it. Quitting restores normal Dock visibility.

## A Whole Desktop Manager, In Your Menubar.

<p align="center">
  <img src="DockAway/Assets.xcassets/DesktopManagerPreview.imageset/desktop-manager-preview.png" alt="DockAway Desktop Manager showing app icons, numbered desktops, and add buttons grouped across two displays" width="380">
</p>

See your desktops and their app icons, grouped by display. Switch to, create, close, drag desktops to reorder them or even move them between monitors. Fullscreen apps get their own named tiles, and the layout adapts to the number of desktops and apps. Incredible handy when you have 2+ Displays and you're juggling between desktops.

Open the menu with **Option+Up** or **Option+Shift+W**, then navigate with **arrow keys or WASD**. Right- and left-hand profiles have customizable select and close bindings. Closing while **+** is selected first moves the highlight back to a desktop; a second press closes it. Escape dismisses the menu.

## First launch and permissions

Requires **macOS 14 Sonoma or newer**. Guided setup walks you through **Accessibility** and checks **Input Access**, requesting Input Monitoring only when needed. Choose **Later** if macOS asks to quit during setup, then return to DockAway and select **Continue**. The app verifies access and restarts only if necessary.

If permissions are later revoked, DockAway pauses and shows **Permission Required**. Restore access and choose **Resume** to finish setup again. Signing and notarization do not bypass these permissions.

**Full Disk Access** is optional. **Black Out Menu Bar for Filled Screens** asks for it only when a wallpaper app keeps its wallpapers in its own private folder, explaining first why it's needed. Everything else works without it.

**Reveal delay:** On its first ready launch, DockAway removes any existing nonzero Dock reveal delay and briefly restarts the Dock. Later choices in **Dock Settings → Reveal Delay** are respected; another Dock utility can override them.

## Privacy

No accounts, ads, analytics, or telemetry. Window and gesture processing stays on your Mac. DockAway uses application identities, window metadata, Accessibility events, and trackpad contacts and pressure to manage the Dock, windows, and clicks. Keyboard features handle configured shortcuts; DockAway does not keep a keystroke or gesture history. Preferences are stored locally. Optional screenshot copying places captured images on your clipboard while retaining their saved files. To keep menu bar text white, the black menu bar briefly uses a copy of your wallpaper with a black band at the top, kept in DockAway's own folder, and puts yours back as soon as no window fills the screen. With **Full Disk Access**, DockAway reads only the wallpaper macOS reports for your desktop.

Sparkle checks GitHub-hosted update information and downloads releases. GitHub may receive ordinary connection information such as your IP address. For manual-only checks, open **DockAway Settings → Update Frequency**, select **Manual Only**, and turn off **Check at Launch**.

<details>
<summary>How it works</summary>

Accessibility and workspace notifications drive window and desktop detection, backed by lightweight safety checks and cached application identities. Trackpad contacts allow early Dock hiding during desktop swipes. Mission Control transitions temporarily hold visibility decisions to avoid competing with macOS animations. Monitoring pauses during sleep and lock, and missing permissions stop monitoring safely. Some desktop and gesture capabilities depend on private macOS interfaces and can vary across OS versions or hardware.

</details>

## Special thanks

[Rilmazafone](https://github.com/kageroumado/rilmazafone), by [kageroumado](https://github.com/kageroumado), powers DockAway's DMG design and release workflow, including signing, notarization, and verification.
