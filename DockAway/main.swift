import Cocoa
import IOKit.hid

if CommandLine.arguments.contains("--dockaway-input-monitoring-probe") {
    let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    exit(access == kIOHIDAccessTypeGranted ? EXIT_SUCCESS : EXIT_FAILURE)
} else {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}
