import AppKit

@main
struct DockSettingsTests {
    @MainActor static func main() {
        func shortcut(_ enabled: Bool, _ key: Int = 2, _ flags: Int = 1572864) -> [String: Any] {
            ["52": ["enabled": enabled, "value": ["type": "standard", "parameters": [100, key, flags]]]]
        }
        precondition(DockShortcut.decode(nil) == .systemDefault)
        precondition(DockShortcut.decode([String: Any]()) == .systemDefault)
        precondition(DockShortcut.decode(shortcut(true)) == .systemDefault)
        precondition(DockShortcut.decode(shortcut(false)) == nil)
        precondition(DockShortcut.decode(shortcut(true, 65535)) == nil)
        precondition(DockShortcut.decode(shortcut(true, -1)) == nil)
        precondition(DockShortcut.decode(shortcut(true, 2, -1)) == nil)
        precondition(DockShortcut.decode(shortcut(true, 2, 1)) == nil)
        precondition(DockShortcut.decode(["52": ["enabled": true, "value": "bad"]]) == nil)
        precondition(DockShortcut.decode("bad") == nil)
        let remapped = DockShortcut.decode(shortcut(true, 40, 1179648))
        precondition(remapped?.keyCode == 40)
        precondition(remapped?.modifiers == [.maskCommand, .maskShift])
        let panel = PermissionSetupPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 515),
                                         styleMask: [.borderless], backing: .buffered, defer: false)
        precondition(panel.canBecomeKey)
        precondition(!panel.isVisible)
        print("PASS: shortcut decoding and keyboard-capable onboarding panel (no windows shown)")
    }
}
