<p align="center">
  <img src="DockAway/docs/DockAwayIcon.png" alt="App Icon" width="256" height="256">
</p>

<h1 align="center">DockAway</h1>

A tiny macOS menu-bar utility that keeps your Dock out of the way when you don't need it. It shows the Dock on an empty desktop and hides it when an app window occupies the active display. Any apps you add to the blacklist can keep the Dock shown while they are focused and in-front. Dock settings are easily customizable via the menubar menu.

<p align="center">
  <a href="https://github.com/akhairaddin/DockAway/releases/latest">Download (Latest Version)</a> ·
  <a href="#first-launch-and-permissions">Setup</a> ·
  <a href="#features">Features</a> ·
  <a href="#privacy">Privacy</a> ·
  <a href="changelog.html">Changelog</a> ·
  <a href="https://github.com/akhairaddin/DockAway/issues">Contact</a>
</p>

<p align="center">
  <img src="DockAway/docs/DockAwayMenu.png" alt="DockAway menu and application blacklist" width="620">
</p>

## When it's hidden and when it's shown

<table align="center">
  <thead>
    <tr><th>What is on the active display?</th><th>DockAway's response</th></tr>
  </thead>
  <tbody>
    <tr><td>An empty desktop with no app windows</td><td>Dock shown</td></tr>
    <tr><td>One or more app windows</td><td>Dock hidden</td></tr>
    <tr><td>A blacklisted app is frontmost</td><td>Dock shown</td></tr>
    <tr><td>A blacklisted app is visible, but a non-blacklisted app is in front</td><td>Dock hidden</td></tr>
    <tr><td>The only or last window is minimized</td><td>Dock shown</td></tr>
    <tr><td>One of multiple windows is minimized</td><td>Dock remains hidden</td></tr>
  </tbody>
</table>

DockAway uses your configured system shortcut for toggling Dock auto-hide: **⌘⌥D** (Command+Option+D) by default, or whatever you've set it to. Before acting, it checks the live Dock state to avoid unnecessary or duplicate toggles. If the shortcut is disabled, DockAway shows guidance for enabling it in System Settings.

## First launch and permissions

DockAway opens a guided setup the first time it runs. Enable **Accessibility**, then DockAway checks **Input Access**. If access is already available, no additional permission is needed. Otherwise, follow the instructions to enable **Input Monitoring** in System Settings and choose **Later** if macOS asks to quit and reopen. **Continue** verifies authorization and checks that the running app can use its access. Setup finishes without restarting when those checks and monitoring initialization succeed. An automatic restart is retained only as a fallback when authorization is confirmed but access cannot be activated in the running process.

Permission status is rechecked throughout setup, including after access has been granted and when System Settings was opened separately. When macOS reports a revocation, the corresponding step returns to its incomplete state. **Continue** checks authorization again after the current-process check, so a revocation during that check cannot be overridden by an older grant. If authorization is missing or cannot be confirmed, onboarding stays open rather than restarting or starting monitoring. After restoring access, press Resume and finish onboarding to reacquire access, with a restart only if needed.

## Features

- A lightweight, native Swift menu-bar app.
- Official releases are signed with an Apple Developer ID and notarized by Apple.
- Includes guided first-launch setup with live Accessibility and Input Access status, a clear primary action, and an automatic restart only as a fallback.
- Works well alongside window-management apps such as Rectangle by Ryan Hanson and Swish by Christian Renninger.
- Responds to app switches, window changes, and Space or desktop swipes.
- Detects the desktop state on the display under your pointer, rather than just checking Finder. This correctly handles minimizing an app's last window, tiled/split-screen layouts, trackpad gesture minimizing, and multi-display setups.
- Verifies the live `com.apple.dock autohide` value before acting, reducing the chance of DockAway drifting out of sync with macOS.
- Uses accessibility events for immediate reactions and a lightweight safety check for apps that expose incomplete notifications.
- Caches running-process, bundle-identifier, and positive or negative blacklist results in memory. Cache entries are invalidated when apps launch or quit and when the blacklist changes.
- Adds native Dock Settings for position, animation speed, and reveal delay, complete with checkpoint snapping and haptic feedback.
- Lets you choose which Dock settings remain after quitting, or restore everything to the macOS defaults at any time.
- Includes a Launch at Login toggle directly in the menu, without a trip to System Settings.
- Restores the Dock to its normal visible state when DockAway quits.
- Updates the menu-bar Dock indicator from existing state events instead of running a separate cosmetic polling timer.
- Provides automatic updates and release notes through Sparkle.

## Menu bar

- **Status**: Shows the active app and whether DockAway is currently running. If a required permission is unavailable, the header displays **Permission Required** and identifies the missing access.
- **Stop / Resume**: Temporarily pauses DockAway and restores normal Dock visibility, then resumes monitoring from the same media-style control. When permission is missing, the resume control draws attention gently and reopens guided setup so access can be restored.
- **Blacklist**: Check running apps directly or choose installed apps from Finder so their windows do not hide the Dock.
- **Dock Settings**: Move the Dock to the left, bottom, or right; tune animation speed and reveal delay; choose which settings remain after quitting; or restore the macOS defaults. **More Dock Settings...**, beneath Reveal Delay, opens the native **Desktop & Dock** page in System Settings for additional options.
- **Launch at Login Toggle**: Activates via `SMAppService`, with no System Settings round-trip needed.
- **Update Frequency**: Daily checks and Check at Launch are enabled by default. You can choose Daily, Every 3 Days, Weekly, or Manual Only, and disable launch checks independently. Sparkle remembers both selections, and manual update checks remain available with every option.
- **About DockAway**: Opens the standard macOS About panel.
- **Quit**: Resets Dock auto-hide to off and restores the Dock to its normal visible state.

## Application Blacklist

By default, every standard app window counts as an occupied display. Open **Blacklist** from DockAway's menu-bar menu and click anywhere across an application row to keep the Dock shown while that app is in front. Use **Choose Application…** to select an app that is not currently open. Blacklisted apps remain grouped at the top and can be removed individually, or all at once with **Remove All**. The rows and **Remove All** update immediately as the blacklist changes. When another app is brought in front of a blacklisted app, DockAway resumes its normal hiding behavior.

## Requirements

- **macOS 14 (Sonoma) or newer**
- **Accessibility permission**: Required because the app sends your configured Dock hiding shortcut (⌘⌥D by default) via `CGEvent`. Granted under **System Settings → Privacy & Security → Accessibility**.
- **Input access**: DockAway checks whether macOS authorizes input listening. This access may already be available after enabling Accessibility, without a separate Input Monitoring entry. Onboarding provides Input Monitoring instructions only when needed. Four-finger pre-hide itself uses raw trackpad contacts from `MultitouchWatcher`; private-framework availability can vary by macOS version and hardware.

## Privacy

DockAway has no accounts, advertisements, analytics, or telemetry. Its window and gesture detection happens locally on your Mac, and that information is not uploaded by DockAway.

To do its job, DockAway detects running application names, process and bundle identifiers, window position and visibility metadata, Accessibility window events, the Dock's auto-hide preference, and raw trackpad contact positions used to recognize four-finger count and direction. It does not read window contents, document contents, or typed keyboard input, and it does not record or save trackpad gestures.

Your blacklist and basic app preferences are stored locally through macOS `UserDefaults`. Debug builds run from Xcode print diagnostic transition information to Xcode's console; those diagnostic messages are compiled out of release builds.

Sparkle is the only network-facing component. It checks DockAway's appcast on GitHub Pages, with **Daily** as the default scheduled interval and **Check at Launch** enabled independently. You can change the schedule to every three days, weekly, or manual-only from DockAway's menu. To restrict checks to manual requests, select **Manual Only** and turn off **Check at Launch**. Updates are downloaded from GitHub Releases only when needed, and a manual **Check for Updates…** command remains available at any time. GitHub and its delivery infrastructure may receive normal connection information, such as your IP address, under their own privacy policies. DockAway does not send separate usage or tracking data with those requests.

## How the detection actually works

The core logic is distributed across `DockWatcher.swift`, `MultitouchWatcher.swift`, and `AppDelegate.swift`, combining event-driven accessibility notifications, window-list classification, and raw trackpad detection.

1. **Event-Driven Detection:** Per-app `AXObserver` notifications catch window creation, destruction, minimizing, restoring, moving, resizing, and focus changes. Workspace notifications cover app activation and Space changes.
2. **Source-Aware Trackpad Holds:** `MultitouchWatcher` reads raw trackpad contact positions before macOS recognizes a gesture. A sub-percent movement threshold distinguishes left, right, upward, and downward motion. On an empty source, DockAway takes a read-only snapshot of the neighboring Spaces while the fingers are still resting: a known occupied neighbor pre-hides at the first directional motion, while an empty or blacklisted neighbor keeps the Dock continuously visible. If that private Space information is unavailable, the existing short-lived on-screen destination probe takes over automatically. Upward Mission Control entry never sends HIDE.
3. **Mission Control Awareness:** DockAway watches Dock's accessibility hierarchy for Mission Control and uses a WindowServer signature as a fallback. While the overview or its landing animation is active, DockAway freezes its own visibility decisions and leaves the underlying auto-hide policy untouched. macOS can therefore present and dismiss its temporary Mission Control Dock natively, without changing an app window's landing geometry mid-animation. On a downward exit, the cached pre-overview desktop state chooses the landing hold: occupied apps remain hidden, while empty or blacklisted desktops keep the Dock continuously visible.
4. **Smart Window Detection:** `CGWindowListCopyWindowInfo` classifies the foremost normal app window on the display under the pointer. System overlays and tiny edge overlaps are ignored, and a covered blacklisted window cannot override the app in front of it. If the window list is temporarily unavailable, DockAway preserves its last confirmed state rather than treating the failure as an empty desktop.
5. **State Verification and Caching:** Before sending ⌘⌥D or your configured Dock hiding shortcut, DockAway checks the live `com.apple.dock autohide` value and tracks its most recent command to prevent overlapping events from issuing duplicate toggles. Process identities and both positive and negative blacklist results are cached in memory, then invalidated when the owning app or blacklist changes.
6. **Timings & Safety Nets:** Four-finger direction is recognized directly from trackpad frames; pointer-display and Mission Control state changes retain a lightweight 0.12-second check. The pointer timer has a small scheduling tolerance so macOS can combine nearby wakeups without changing its response interval. A 2-second full scan catches apps with incomplete accessibility support. Visible and hidden gesture holds release 0.60 seconds after finger lift, and Mission Control exit uses one 0.12-second verification tick before a fresh occupancy decision.
7. **Dynamic UI & Graceful Exits:** The menu-bar chevron is updated through DockAway's existing state events instead of a dedicated cosmetic timer. Monitoring stops while the Mac is asleep or locked, permission problems are surfaced in the menu, and quitting DockAway restores the Dock to its normal visible state.
8. **Permission Verification:** `Permissions.swift` brings authorization snapshots, fresh-process checks, current-process access checks, and the setup completion decision into one file. Fresh authorization checks use public macOS APIs without reading the privacy database. Potentially blocking access checks run off the UI thread, and serialized work, deadlines, and cancellation guards prevent overlapping checks or obsolete results from completing setup. Authorization and usable access remain separate checks, allowing setup to finish without restarting when both are ready.

For contributors, [Tests/PermissionVerification.md](Tests/PermissionVerification.md) contains automated permission checks and a manual verification checklist for signed builds, including granting and revoking access, cancellation, and restart fallback behavior.

## Signed and Notarized

Official DockAway releases are signed with an Apple Developer ID and notarized by Apple. This allows macOS to verify the developer, confirm the app has not been altered since it was signed, and validate the release through Gatekeeper. Releases downloaded from the official GitHub page should no longer require the previous **Open Anyway** workaround.

DockAway still guides you through Accessibility and checks input access on first launch, requesting additional setup only when needed. Code signing and notarization do not bypass macOS privacy controls.

## Special Thanks

A special shout-out to [Rilmazafone](https://github.com/kageroumado/rilmazafone) and its developer [kageroumado](https://github.com/kageroumado). Rilmazafone creates DockAway's polished DMG and powers its release plan, including archiving, Developer ID signing, app and DMG notarization, stapling, verification, and release orchestration. It is a beautiful native Mac app backed by a great developer, and it made shipping DockAway dramatically better.

## Note

- On its first ready launch, DockAway removes an existing nonzero Dock reveal delay, including the **0.2-second delay** observed on a fresh installation of **Supercharge** by Sindre Sorhus. This one-time adjustment sets the system's reveal delay to **None** and briefly restarts the Dock. Later changes in **Dock Settings → Reveal Delay** are respected. If another app reapplies a delay afterward, set its delay to **None** as well.
