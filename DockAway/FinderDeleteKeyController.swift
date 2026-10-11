import Cocoa
@preconcurrency import ApplicationServices

struct FinderDeleteKeyDecision {
    static let deleteKeyCode: CGKeyCode = 51

    private static let editingRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox"
    ]
    private static let editingSubroles: Set<String> = [
        "AXSearchField",
        "AXSecureTextField"
    ]
    private static let modalRoles: Set<String> = [
        "AXMenu",
        "AXMenuItem",
        "AXSheet"
    ]
    private static let modalWindowSubroles: Set<String> = [
        "AXDialog",
        "AXSystemDialog"
    ]

    static func shouldRemap(
        frontmostBundleIdentifier: String?,
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        isRepeat: Bool,
        focusedRole: String?,
        focusedSubrole: String?,
        focusedWindowRole: String?,
        focusedWindowSubrole: String?
    ) -> Bool {
        guard isCandidate(
            frontmostBundleIdentifier: frontmostBundleIdentifier,
            keyCode: keyCode,
            flags: flags,
            isRepeat: isRepeat
        ) else { return false }
        // Moving files to the Trash needs a positively identified focus.
        guard let focusedRole else { return false }

        if editingRoles.contains(focusedRole) || modalRoles.contains(focusedRole) {
            return false
        }
        if let focusedSubrole, editingSubroles.contains(focusedSubrole) {
            return false
        }
        if focusedWindowRole == "AXSheet" {
            return false
        }
        if let focusedWindowSubrole,
           modalWindowSubroles.contains(focusedWindowSubrole) {
            return false
        }
        return true
    }

    /// The checks that need no Accessibility messages. Every other app's
    /// Delete key is rejected here without querying anything.
    static func isCandidate(
        frontmostBundleIdentifier: String?,
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        isRepeat: Bool
    ) -> Bool {
        guard frontmostBundleIdentifier == "com.apple.finder",
              keyCode == deleteKeyCode,
              !isRepeat else { return false }

        let shortcutModifiers: CGEventFlags = [
            .maskCommand,
            .maskControl,
            .maskAlternate,
            .maskShift,
            .maskSecondaryFn
        ]
        return flags.intersection(shortcutModifiers).isEmpty
    }
}

@MainActor
final class FinderDeleteKeyController {
    static let preferenceKey = "finderDeleteKeyMovesItemsToTrash"
    private static let syntheticEventMarker: Int64 = 0x46444C54

    private struct FocusContext {
        let role: String?
        let subrole: String?
        let windowRole: String?
        let windowSubrole: String?
    }

    private var eventTap: EventTap?
    private var interceptingPhysicalDelete = false
    var isSuppressed: (() -> Bool)?

    func setEnabled(_ enabled: Bool) {
        enabled ? start() : stop()
    }

    func stop() {
        interceptingPhysicalDelete = false
        eventTap?.invalidate()
        eventTap = nil
    }

    private func start() {
        guard eventTap == nil, AXIsProcessTrusted() else { return }
        eventTap = EventTap(events: [.keyDown, .keyUp]) { [weak self] type, event in
            self?.handle(type: type, event: event) ?? false
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            interceptingPhysicalDelete = false
            return false
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return false
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == FinderDeleteKeyDecision.deleteKeyCode else { return false }

        if type == .keyUp {
            guard interceptingPhysicalDelete else { return false }
            interceptingPhysicalDelete = false
            return true
        }
        guard type == .keyDown else { return false }

        if interceptingPhysicalDelete {
            return true
        }
        guard isSuppressed?() != true else { return false }

        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        // Ask Finder about focus only when everything else already matches, so
        // Backspace in other apps never waits on an Accessibility reply.
        // Without an answer in time, leave the key alone: it may be a rename field.
        guard let finder = frontmostApplication,
              FinderDeleteKeyDecision.isCandidate(
                frontmostBundleIdentifier: finder.bundleIdentifier,
                keyCode: keyCode,
                flags: event.flags,
                isRepeat: isRepeat
              ),
              let context = Self.focusContext(processIdentifier: finder.processIdentifier)
        else { return false }
        let shouldRemap = FinderDeleteKeyDecision.shouldRemap(
            frontmostBundleIdentifier: finder.bundleIdentifier,
            keyCode: keyCode,
            flags: event.flags,
            isRepeat: isRepeat,
            focusedRole: context.role,
            focusedSubrole: context.subrole,
            focusedWindowRole: context.windowRole,
            focusedWindowSubrole: context.windowSubrole
        )
        guard shouldRemap else { return false }

        interceptingPhysicalDelete = true
        postCommandDelete()
        return true
    }

    private func postCommandDelete() {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(
            keyboardEventSource: source,
            virtualKey: FinderDeleteKeyDecision.deleteKeyCode,
            keyDown: true
        ), let up = CGEvent(
            keyboardEventSource: source,
            virtualKey: FinderDeleteKeyDecision.deleteKeyCode,
            keyDown: false
        ) else { return }

        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(
                .eventSourceUserData,
                value: Self.syntheticEventMarker
            )
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// nil unless Finder answered every read within the budget. The budget
    /// covers all six messages, so a busy Finder can't hold up keyboard input
    /// for long, and a failed read is never mistaken for an absent value.
    private static func focusContext(processIdentifier: pid_t) -> FocusContext? {
        let budget = AccessibilityRequestBudget(seconds: 0.08, messageLimit: 0.08)
        let application = AXUIElementCreateApplication(processIdentifier)
        var unreadable = false
        func read(_ name: String, of element: AXUIElement?) -> CFTypeRef? {
            guard let element, !unreadable else { return nil }
            let result = budget.attribute(name, of: element)
            if result.failed { unreadable = true }
            return result.value
        }
        func element(_ name: String, of parent: AXUIElement?) -> AXUIElement? {
            guard let value = read(name, of: parent), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        let focusedElement = element(kAXFocusedUIElementAttribute, of: application)
        let focusedWindow = element(kAXFocusedWindowAttribute, of: application)
        let context = FocusContext(
            role: read(kAXRoleAttribute, of: focusedElement) as? String,
            subrole: read(kAXSubroleAttribute, of: focusedElement) as? String,
            windowRole: read(kAXRoleAttribute, of: focusedWindow) as? String,
            windowSubrole: read(kAXSubroleAttribute, of: focusedWindow) as? String
        )
        return unreadable || budget.expired ? nil : context
    }
}
