import Cocoa
import IOKit.hid

if CommandLine.arguments.contains("--dockaway-permission-probe") {
    // Exit before starting AppKit, observers, updater, or changing preferences.
    // Codes 20...23 are reserved for a completed, no-prompt permission snapshot.
    // AX trust can lag a revocation. Corroborate it with the public posting
    // preflight, also used by Chromium to detect stale AX grants.
    let accessibility = AXIsProcessTrusted()
        && IOHIDCheckAccess(kIOHIDRequestTypePostEvent) == kIOHIDAccessTypeGranted
    let input = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    exit(20 + (accessibility ? 1 : 0) + (input ? 2 : 0))
} else if CommandLine.arguments.contains("--dockaway-input-monitoring-probe") {
    let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    exit(access == kIOHIDAccessTypeGranted ? EXIT_SUCCESS : EXIT_FAILURE)
} else {
    MainActor.assumeIsolated {
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}
