import Cocoa
@preconcurrency import ApplicationServices

struct FinderDeleteKeyDecision {
    static let deleteKeyCode: CGKeyCode = 51
    static let returnKeyCode: CGKeyCode = 36
    static let keypadEnterKeyCode: CGKeyCode = 76

    enum Action: Equatable {
        case moveToTrash
        case deleteImmediately
        case confirmTrashDialog
    }

    static let trashWindowTitles: Set<String> = {
        var titles: Set<String> = ["Trash"]
        if let trashURL = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first {
            let localized = FileManager.default.displayName(atPath: trashURL.path)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !localized.isEmpty {
                titles.insert(localized)
            }
        }
        return titles
    }()

    private static let handledKeyCodes: Set<CGKeyCode> = [
        deleteKeyCode,
        returnKeyCode,
        keypadEnterKeyCode
    ]
    private static let trashConfirmationButtonTitles: Set<String> = [
        "Delete",
        "Empty Trash"
    ]
    private static let shortcutModifiers: CGEventFlags = [
        .maskCommand,
        .maskControl,
        .maskAlternate,
        .maskShift,
        .maskSecondaryFn
    ]
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

    static func isHandledKeyCode(_ keyCode: CGKeyCode) -> Bool {
        handledKeyCodes.contains(keyCode)
    }

    static func isTrashWindow(title: String?) -> Bool {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return false }
        return trashWindowTitles.contains(title)
    }

    static func isTrashConfirmationButton(identifier: String?, title: String?) -> Bool {
        identifier == "action-button--998"
            && title.map { trashConfirmationButtonTitles.contains($0) } == true
    }

    static func action(
        frontmostBundleIdentifier: String?,
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        isRepeat: Bool,
        focusedRole: String?,
        focusedSubrole: String?,
        focusedWindowRole: String?,
        focusedWindowSubrole: String?,
        focusedWindowTitle: String? = nil,
        hasTrashConfirmationButton: Bool = false
    ) -> Action? {
        guard isCandidate(
            frontmostBundleIdentifier: frontmostBundleIdentifier,
            keyCode: keyCode,
            flags: flags,
            isRepeat: isRepeat
        ) else { return nil }
        // Moving or permanently deleting files needs a positively identified focus.
        guard let focusedRole else { return nil }

        if keyCode == returnKeyCode || keyCode == keypadEnterKeyCode {
            guard hasTrashConfirmationButton else { return nil }
            guard focusedWindowSubrole == "AXDialog" || focusedWindowRole == "AXSheet" else {
                return nil
            }
            if editingRoles.contains(focusedRole) {
                return nil
            }
            if let focusedSubrole, editingSubroles.contains(focusedSubrole) {
                return nil
            }
            return .confirmTrashDialog
        }

        guard keyCode == deleteKeyCode else { return nil }

        if editingRoles.contains(focusedRole) || modalRoles.contains(focusedRole) {
            return nil
        }
        if let focusedSubrole, editingSubroles.contains(focusedSubrole) {
            return nil
        }
        if focusedWindowRole == "AXSheet" {
            return nil
        }
        if let focusedWindowSubrole,
           modalWindowSubroles.contains(focusedWindowSubrole) {
            return nil
        }
        let inTrashWindow = focusedWindowRole == "AXWindow"
            && focusedSubrole != "AXDesktop"
            && isTrashWindow(title: focusedWindowTitle)
        return inTrashWindow ? .deleteImmediately : .moveToTrash
    }

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
        action(
            frontmostBundleIdentifier: frontmostBundleIdentifier,
            keyCode: keyCode,
            flags: flags,
            isRepeat: isRepeat,
            focusedRole: focusedRole,
            focusedSubrole: focusedSubrole,
            focusedWindowRole: focusedWindowRole,
            focusedWindowSubrole: focusedWindowSubrole
        ) != nil
    }

    /// The checks that need no Accessibility messages. Every other app's
    /// key events are rejected here without querying anything.
    static func isCandidate(
        frontmostBundleIdentifier: String?,
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        isRepeat: Bool
    ) -> Bool {
        guard frontmostBundleIdentifier == "com.apple.finder",
              handledKeyCodes.contains(keyCode),
              !isRepeat else { return false }

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
        let windowTitle: String?
        let confirmButton: AXUIElement?
    }

    private var eventTap: EventTap?
    private var interceptedPhysicalKeyCodes: Set<CGKeyCode> = []
    var isSuppressed: (() -> Bool)?

    func setEnabled(_ enabled: Bool) {
        enabled ? start() : stop()
    }

    func stop() {
        interceptedPhysicalKeyCodes.removeAll()
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
            interceptedPhysicalKeyCodes.removeAll()
            return false
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return false
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard FinderDeleteKeyDecision.isHandledKeyCode(keyCode) else { return false }

        if type == .keyUp {
            return interceptedPhysicalKeyCodes.remove(keyCode) != nil
        }
        guard type == .keyDown else { return false }

        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if interceptedPhysicalKeyCodes.contains(keyCode) {
            if isRepeat {
                return true
            }
            interceptedPhysicalKeyCodes.remove(keyCode)
        }
        guard isSuppressed?() != true else { return false }

        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        // Ask Finder about focus only when everything else already matches, so
        // Backspace and Return in other apps never wait on an Accessibility reply.
        // Without an answer in time, leave the key alone: it may be a rename field.
        guard let finder = frontmostApplication,
              FinderDeleteKeyDecision.isCandidate(
                frontmostBundleIdentifier: finder.bundleIdentifier,
                keyCode: keyCode,
                flags: event.flags,
                isRepeat: isRepeat
              ),
              let context = Self.focusContext(
                processIdentifier: finder.processIdentifier,
                keyCode: keyCode
              )
        else { return false }

        guard let action = FinderDeleteKeyDecision.action(
            frontmostBundleIdentifier: finder.bundleIdentifier,
            keyCode: keyCode,
            flags: event.flags,
            isRepeat: isRepeat,
            focusedRole: context.role,
            focusedSubrole: context.subrole,
            focusedWindowRole: context.windowRole,
            focusedWindowSubrole: context.windowSubrole,
            focusedWindowTitle: context.windowTitle,
            hasTrashConfirmationButton: context.confirmButton != nil
        ) else { return false }

        switch action {
        case .moveToTrash:
            interceptedPhysicalKeyCodes.insert(keyCode)
            postDeleteShortcut(includeOption: false)
            return true
        case .deleteImmediately:
            interceptedPhysicalKeyCodes.insert(keyCode)
            postDeleteShortcut(includeOption: true)
            return true
        case .confirmTrashDialog:
            guard let confirmButton = context.confirmButton,
                  AXUIElementPerformAction(confirmButton, kAXPressAction as CFString) == .success
            else { return false }
            interceptedPhysicalKeyCodes.insert(keyCode)
            return true
        }
    }

    private func postDeleteShortcut(includeOption: Bool) {
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

        down.flags = includeOption ? [.maskCommand, .maskAlternate] : .maskCommand
        // End the chord with the modifiers actually held, so Command/Option don't
        // stay down for the rest of the session after the synthetic key-up.
        up.flags = CGEventSource.flagsState(.hidSystemState).intersection([
            .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskAlphaShift, .maskSecondaryFn
        ])
        for event in [down, up] {
            event.setIntegerValueField(
                .eventSourceUserData,
                value: Self.syntheticEventMarker
            )
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// nil unless Finder answered every read within the budget. The budget
    /// covers all messages, so a busy Finder can't hold up keyboard input
    /// for long, and a failed read is never mistaken for an absent value.
    private static func focusContext(
        processIdentifier: pid_t,
        keyCode: CGKeyCode
    ) -> FocusContext? {
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
        let role = read(kAXRoleAttribute, of: focusedElement) as? String
        let subrole = read(kAXSubroleAttribute, of: focusedElement) as? String
        let windowRole = read(kAXRoleAttribute, of: focusedWindow) as? String
        let windowSubrole = read(kAXSubroleAttribute, of: focusedWindow) as? String

        var windowTitle: String?
        if keyCode == FinderDeleteKeyDecision.deleteKeyCode, focusedWindow != nil {
            windowTitle = read(kAXTitleAttribute, of: focusedWindow) as? String
        }

        var confirmButton: AXUIElement?
        if (keyCode == FinderDeleteKeyDecision.returnKeyCode
            || keyCode == FinderDeleteKeyDecision.keypadEnterKeyCode),
           let focusedWindow,
           (windowSubrole == "AXDialog" || windowRole == "AXSheet") {
            confirmButton = trashConfirmationButton(in: focusedWindow, read: read)
        }

        let context = FocusContext(
            role: role,
            subrole: subrole,
            windowRole: windowRole,
            windowSubrole: windowSubrole,
            windowTitle: windowTitle,
            confirmButton: confirmButton
        )
        return unreadable || budget.expired ? nil : context
    }

    private static func trashConfirmationButton(
        in window: AXUIElement,
        read: (String, AXUIElement?) -> CFTypeRef?
    ) -> AXUIElement? {
        var hasCancelButton = read(kAXCancelButtonAttribute, window) != nil
        var confirmButton: AXUIElement?

        let children = (read(kAXChildrenAttribute, window) as? [AnyObject]) ?? []
        for rawChild in children {
            guard CFGetTypeID(rawChild) == AXUIElementGetTypeID() else { continue }
            let child = unsafeBitCast(rawChild, to: AXUIElement.self)
            guard (read(kAXRoleAttribute, child) as? String) == kAXButtonRole else { continue }

            let identifier = read("AXIdentifier", child) as? String
            if identifier == "action-button--999" {
                hasCancelButton = true
            } else if identifier == "action-button--998" {
                let title = read(kAXTitleAttribute, child) as? String
                let isEnabled = (read(kAXEnabledAttribute, child) as? Bool) ?? true
                if isEnabled,
                   FinderDeleteKeyDecision.isTrashConfirmationButton(
                    identifier: identifier,
                    title: title
                   ) {
                    confirmButton = child
                }
            }

            if confirmButton != nil && hasCancelButton {
                break
            }
        }
        return hasCancelButton ? confirmButton : nil
    }
}
