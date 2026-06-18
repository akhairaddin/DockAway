# DockAutoHide

A tiny macOS menu bar utility that keeps your Dock out of the way. It appears only when you're actually looking at the desktop, and disappears the instant any app has a window on screen.

## What it Does
| Desktop visible, no window from any app on screen | Shown |

| Any app's window is on screen | Hidden |

| You minimize the only window on screen | Shown |

| Two windows open, you minimize one | Hidden |

It works by activating the system shortcut **⌥⌘D** (Command+Option+D), the same one you'd press manually to toggle Dock auto-hide, so it's never fighting macOS, just pressing the button for you at the right moments.

## Features

- Menu bar only, no Dock icon, no clutter
- Detects every app switch and every Space/desktop swipe in real time
- Detects the true desktop state system-wide rather than just checking Finder, so it correctly handles minimizing any app's last window, tiled/split-screen layouts, trackpad gesture minimizing, and so on
- Self-correcting: instead of trusting its own memory of "is the Dock shown," it reads the live `com.apple.dock autohide` value before acting, so it can't quietly drift out of sync
- A lightweight repeating safety check as a backstop, plus a check anchored to the exact moment of each Space change, so there's never a long window where it's silently wrong
- Launch at Login toggle built right into the menu, no detour through System Settings
- Standard macOS About panel
- On quit, it explicitly turns Dock auto-hide back off and restarts the Dock, so closing the app visibly hands control back to you

## Menu bar

- **Status**: Live text showing what triggered the last action
- **Launch at Login**: Toggles via `SMAppService`, no System Settings round-trip needed
- **About DockAutoHide**: The standard macOS about panel
- **Quit**: Also resets `autohide` to off and restarts the Dock, so quitting visibly restores normal behavior

## Requirements

- macOS 13 (Ventura) or later
- **Accessibility permission**: required because the app sends a synthetic ⌥⌘D keystroke via `CGEvent`. Grant under **System Settings → Privacy & Security → Accessibility**.

## How the detection actually works

The core logic lives in `DockWatcher.swift`:

1. It listens for `NSWorkspace.didActivateApplicationNotification` (app switches) and `NSWorkspace.activeSpaceDidChangeNotification` (Space/desktop swipes).
2. On either, it checks the whole screen via `CGWindowListCopyWindowInfo` for any normal-sized, normal-level window owned by any app. None found means you're on the desktop. One found means you're not. This is what makes it correctly ignore a minimized window when another app is still visible.
3. It only sends ⌥⌘D if the Dock's actual current state, read live from `UserDefaults(suiteName: "com.apple.dock")`, doesn't already match what it should be, so it never double-fires or fights itself.
4. Space changes get a check at 150ms (to let the window list settle after the swipe) and a second check at 300ms, anchored to that exact swipe rather than to the separate safety timer. This was the fix for occasional random-feeling lag, since waiting on an independent, out-of-phase timer meant some swipes got lucky timing and some didn't.
5. A repeating safety check, decoupled from any notification, catches anything notifications alone might miss, like minimizing a window with a trackpad gesture, which doesn't fire a notification at all.

## Known Technical Limitations

- Relies on `CGWindowListCopyWindowInfo`, which Apple has signaled may eventually need to move to `SCShareableContent` on a future macOS version, will push new code whenever that happens.
