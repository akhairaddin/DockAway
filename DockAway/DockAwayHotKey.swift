import Cocoa
import Carbon

// Native menu tracking can consume arrows before local NSEvent monitors run.
// Own these keys upstream only for the lifetime of the Desktop Manager menu.
@MainActor
final class DesktopMenuKeyboardCapture {
    private var tap: EventTap?
    private var generation = 0
    private var pressedKeys = Set<Int64>()
    private var openSubmenus = Set<ObjectIdentifier>()
    var isSuspended: Bool { !openSubmenus.isEmpty }
    private var action: ((UInt16) -> Void)?
    private var closeAction: (() -> Void)?
    var onCloseKeyUp: ((UInt16) -> Void)?
    var onSelectKeyUp: ((UInt16) -> Void)?
    var onRepeatCloseKey: ((UInt16) -> Void)?
    var onRepeatSelectKey: ((UInt16) -> Void)?
    private(set) var heldCloseKey: UInt16?
    private(set) var heldSelectKey: UInt16?

    var isCloseKeyHeld: Bool {
        guard let key = heldCloseKey else { return false }
        return pressedKeys.contains(Int64(key))
    }

    var isSelectKeyHeld: Bool {
        guard let key = heldSelectKey else { return false }
        return pressedKeys.contains(Int64(key))
    }

    func setSubmenu(_ menu: NSMenu, isOpen: Bool) {
        let wasSuspended = isSuspended
        if isOpen { openSubmenus.insert(ObjectIdentifier(menu)) }
        else { openSubmenus.remove(ObjectIdentifier(menu)) }
        guard isSuspended != wasSuspended else { return }
        // Invalidate already queued key actions as well as future events. Never
        // resume a held create/delete gesture after a submenu has had focus.
        generation += 1
        if let key = heldCloseKey { onCloseKeyUp?(key) }
        if let key = heldSelectKey { onSelectKeyUp?(key) }
        heldCloseKey = nil
        heldSelectKey = nil
        pressedKeys.removeAll()
    }

    func start(
        action: @escaping (UInt16) -> Void,
        closeAction: (() -> Void)? = nil,
        onCloseKeyUp: ((UInt16) -> Void)? = nil,
        onSelectKeyUp: ((UInt16) -> Void)? = nil,
        onRepeatCloseKey: ((UInt16) -> Void)? = nil,
        onRepeatSelectKey: ((UInt16) -> Void)? = nil
    ) -> Bool {
        stop()
        self.action = action
        self.closeAction = closeAction
        self.onCloseKeyUp = onCloseKeyUp
        self.onSelectKeyUp = onSelectKeyUp
        self.onRepeatCloseKey = onRepeatCloseKey
        self.onRepeatSelectKey = onRepeatSelectKey
        guard let tap = EventTap(
            events: [.keyDown, .keyUp, .flagsChanged],
            includeEventTracking: true,
            handler: { [weak self] type, event in self?.handle(type, event) ?? false }
        ) else {
            self.action = nil
            self.closeAction = nil
            return false
        }
        self.tap = tap
        return true
    }

    func stop() {
        generation += 1
        openSubmenus.removeAll()
        action = nil
        closeAction = nil
        onCloseKeyUp = nil
        onSelectKeyUp = nil
        onRepeatCloseKey = nil
        onRepeatSelectKey = nil
        heldCloseKey = nil
        heldSelectKey = nil
        pressedKeys.removeAll()
        tap?.invalidate()
        tap = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            return false
        }
        guard !isSuspended, !DockSettingKeyRebindRowView.isRecording else { return false }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let prefs = KeyboardNavigationPreferences.current
        if type == .flagsChanged,
           DockSettingKeyRebindRowView.isStandaloneOptionKey(UInt16(key)) {
            guard action != nil, prefs.allKeyCodes.contains(key) else { return false }
            if event.flags.contains(.maskAlternate) {
                pressedKeys.insert(key)
                return true
            }
            // Ignore the release of the Option key that was already held to
            // open the menu. A fresh press and release is required to select.
            guard pressedKeys.remove(key) != nil else { return false }
            deliver(key)
            return true
        }
        if type == .keyUp {
            if prefs.closeKeyCodes.contains(key) {
                heldCloseKey = nil
                onCloseKeyUp?(UInt16(key))
            }
            if prefs.selectKeyCodes.contains(key) {
                heldSelectKey = nil
                onSelectKeyUp?(UInt16(key))
            }
            return pressedKeys.remove(key) != nil
        }
        guard type == .keyDown, action != nil else { return false }

        var modifiers: UInt32 = 0
        if event.flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
        if event.flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
        if event.flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
        if event.flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }

        if isMenuCloseShortcut(key: key, modifiers: modifiers, prefs: prefs) {
            if pressedKeys.contains(key) { return true }
            pressedKeys.insert(key)
            deliverClose()
            return true
        }

        guard (prefs.allKeyCodes.contains(key) || key == 53),
              event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else { return false }
        if prefs.closeKeyCodes.contains(key) {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0 || pressedKeys.contains(key)
            heldCloseKey = UInt16(key)
            pressedKeys.insert(key)
            if isRepeat {
                // Repeated keyDown events confirm the key remains held, but subsequent
                // deletions are paced progressively by the continuous delete scheduler.
                onRepeatCloseKey?(UInt16(key))
                return true
            }
            deliver(key)
            return true
        }
        if prefs.selectKeyCodes.contains(key) {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0 || pressedKeys.contains(key)
            heldSelectKey = UInt16(key)
            pressedKeys.insert(key)
            if isRepeat {
                // Repeated keyDown events confirm the key remains held, but subsequent
                // actions (e.g. desktop creation) are paced progressively by the scheduler.
                onRepeatSelectKey?(UInt16(key))
                return true
            }
            deliver(key)
            return true
        }
        pressedKeys.insert(key)
        deliver(key)
        return true
    }

    private func isMenuCloseShortcut(key: Int64, modifiers: UInt32, prefs: KeyboardNavigationSettings) -> Bool {
        if key == 53 { return true }

        if KeyboardNavigationPreferences.isRightHandEnabled {
            // Keep the established right-hand open/close combinations.
            if (key == 125 || key == 126), modifiers == UInt32(optionKey) { return true }
            if prefs.rightDown != KeyboardNavigationPreferences.unboundKeyCode,
               key == Int64(prefs.rightDown),
               modifiers == prefs.rightOpenModifiers { return true }
            if prefs.rightOpenKey != KeyboardNavigationPreferences.unboundKeyCode,
               key == Int64(prefs.rightOpenKey),
               modifiers == prefs.rightOpenModifiers { return true }
        }

        if KeyboardNavigationPreferences.isLeftHandEnabled {
            // Keep the established left-hand open/close combinations.
            if key == 1 && modifiers == UInt32(optionKey | shiftKey) { return true }
            if prefs.leftDown != KeyboardNavigationPreferences.unboundKeyCode,
               key == Int64(prefs.leftDown),
               modifiers == prefs.leftOpenModifiers { return true }
            if key == 13 && modifiers == UInt32(optionKey | shiftKey) { return true }
            if prefs.leftOpenKey != KeyboardNavigationPreferences.unboundKeyCode,
               key == Int64(prefs.leftOpenKey),
               modifiers == prefs.leftOpenModifiers { return true }
        }

        return false
    }

    private func deliverClose() {
        let request = generation
        RunLoop.main.perform(inModes: [.eventTracking, .default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == request,
                      !self.isSuspended, !DockSettingKeyRebindRowView.isRecording else { return }
                if let closeAction = self.closeAction {
                    closeAction()
                } else {
                    self.action?(53)
                }
            }
        }
    }

    private func deliver(_ key: Int64) {
        let request = generation
        // Deliver during menu tracking, outside the event-tap callback itself.
        RunLoop.main.perform(inModes: [.eventTracking, .default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == request,
                      !self.isSuspended, !DockSettingKeyRebindRowView.isRecording else { return }
                self.action?(UInt16(key))
            }
        }
    }
}

/// Encapsulates a global system hotkey using Carbon's RegisterEventHotKey subsystem.
/// Operates without requiring Accessibility or Input Monitoring permissions.
final class DockAwayHotKey {
    private struct Shortcut {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    private var shortcuts: [Shortcut] {
        let prefs = KeyboardNavigationPreferences.current
        let right = prefs.shortcut(for: .rightHand, action: .openMenu)
        let left = prefs.shortcut(for: .leftHand, action: .openMenu)
        var list: [Shortcut] = []
        if KeyboardNavigationPreferences.isRightHandEnabled,
           right.keyCode != KeyboardNavigationPreferences.unboundKeyCode {
            list.append(Shortcut(keyCode: UInt32(right.keyCode), modifiers: right.modifiers))
        }
        if KeyboardNavigationPreferences.isLeftHandEnabled,
           left.keyCode != KeyboardNavigationPreferences.unboundKeyCode {
            list.append(Shortcut(keyCode: UInt32(left.keyCode), modifiers: left.modifiers))
        }
        return list
    }

    static var shortcutDisplayString: String {
        let prefs = KeyboardNavigationPreferences.current
        let right = prefs.shortcut(for: .rightHand, action: .openMenu)
        let left = prefs.shortcut(for: .leftHand, action: .openMenu)
        var parts: [String] = []
        if KeyboardNavigationPreferences.isRightHandEnabled,
           right.keyCode != KeyboardNavigationPreferences.unboundKeyCode {
            parts.append(KeyboardNavigationPreferences.displayName(for: right.keyCode, modifiers: right.modifiers))
        }
        if KeyboardNavigationPreferences.isLeftHandEnabled,
           left.keyCode != KeyboardNavigationPreferences.unboundKeyCode {
            parts.append(KeyboardNavigationPreferences.displayName(for: left.keyCode, modifiers: left.modifiers))
        }
        return parts.isEmpty ? "None" : parts.joined(separator: " / ")
    }
    static let preferenceKey = "openDockAwayShortcutEnabled"

    private let onTrigger: @MainActor () -> Void

    private var hotKeyRefs = [EventHotKeyRef]()
    private var eventHandlerRef: EventHandlerRef?
    // Desired state is independent of whether any shortcuts are currently bound
    // or Carbon was able to register them. Reload must be able to retry both.
    private(set) var isEnabled: Bool = false
    var registeredShortcutCount: Int { hotKeyRefs.count }

    private final class Trampoline {
        let action: @MainActor () -> Void
        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }
    }

    private var trampoline: Trampoline?

    init(onTrigger: @escaping @MainActor () -> Void) {
        self.onTrigger = onTrigger
    }

    deinit {
        disable()
    }

    func enable() {
        guard !isEnabled else { return }
        isEnabled = true

        let trampoline = Trampoline(action: onTrigger)
        self.trampoline = trampoline
        let userData = Unmanaged.passUnretained(trampoline).toOpaque()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let trampoline = Unmanaged<Trampoline>.fromOpaque(userData).takeUnretainedValue()
                // Opening NSMenu enters a nested tracking loop until dismissal.
                // Do not occupy a main-dispatch-queue callback for that entire
                // time: icon refresh tasks need that queue while the menu is open.
                RunLoop.main.perform(inModes: [.default, .eventTracking]) {
                    MainActor.assumeIsolated {
                        trampoline.action()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )

        guard status == noErr else {
            self.trampoline = nil
            NSLog("DockAway: Failed to install hotkey event handler: %d", status)
            return
        }

        registerHotKeys()

    }

    private func registerHotKeys() {
        for (index, shortcut) in shortcuts.enumerated() {
            var hotKeyRef: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(
                signature: OSType(0x44415759),
                id: UInt32(index + 1)
            ) // 'DAWY'
            let regStatus = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers,
                hotKeyID,
                GetEventDispatcherTarget(),
                0,
                &hotKeyRef
            )

            if regStatus == noErr, let hotKeyRef {
                hotKeyRefs.append(hotKeyRef)
            } else {
                NSLog("DockAway: Failed to register hotkey %d: %d", index + 1, regStatus)
            }
        }
    }

    private func unregisterHotKeys() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    func reloadHotKeys() {
        guard isEnabled else { return }
        disable()
        enable()
    }

    func disable() {
        guard isEnabled else { return }

        unregisterHotKeys()

        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
        trampoline = nil
        isEnabled = false
    }
}
