import AppKit

// Preserve the borderless onboarding appearance while allowing AppKit to
// route keyboard focus, Return, Escape, and accessibility interactions.
final class PermissionSetupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
