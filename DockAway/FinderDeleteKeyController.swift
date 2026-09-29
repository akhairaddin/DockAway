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
        guard flags.intersection(shortcutModifiers).isEmpty else { return false }

        if let focusedRole,
           editingRoles.contains(focusedRole) || modalRoles.contains(focusedRole) {
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
        let context = frontmostApplication.map {
            Self.focusContext(processIdentifier: $0.processIdentifier)
        }
        let shouldRemap = FinderDeleteKeyDecision.shouldRemap(
            frontmostBundleIdentifier: frontmostApplication?.bundleIdentifier,
            keyCode: keyCode,
            flags: event.flags,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            focusedRole: context?.role,
            focusedSubrole: context?.subrole,
            focusedWindowRole: context?.windowRole,
            focusedWindowSubrole: context?.windowSubrole
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

    private static func focusContext(processIdentifier: pid_t) -> FocusContext {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.08)
        let focusedElement = application.element(kAXFocusedUIElementAttribute)
        let focusedWindow = application.element(kAXFocusedWindowAttribute)
        return FocusContext(
            role: focusedElement?.string(kAXRoleAttribute),
            subrole: focusedElement?.string(kAXSubroleAttribute),
            windowRole: focusedWindow?.string(kAXRoleAttribute),
            windowSubrole: focusedWindow?.string(kAXSubroleAttribute)
        )
    }
}
