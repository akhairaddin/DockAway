import AppKit
import CoreAudio

/// Controls Apple's existing Sound item. The visibility preference is undocumented,
/// so only take ownership of the explicitly supported Show When Active mode.
@MainActor
final class MutedVolumeMenuBarController {
    static let preferenceKey = "showSoundMenuBarWhenMuted"
    private static let ownershipKey = "mutedSoundMenuBarOwnedMode"
    private static let domain = "com.apple.controlcenter" as CFString
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var timer: Timer?
    private var device = AudioDeviceID(kAudioObjectUnknown)
    private var expectedMode: Int?
    /// When DockAway last changed Sound's visibility. macOS takes a moment to
    /// settle after a change, and a read in between can still show the
    /// previous value, which looked like the person changing it.
    private var lastWriteAt: TimeInterval = -.infinity
    /// Checks in a row that found a different setting than DockAway's.
    private var mismatches = 0
    private static let settleTime: TimeInterval = 3
    private var isRunning = false
    private let silenceProvider: (() -> Bool?)?
    /// Why the option turned itself off.
    enum DisableReason: Equatable {
        /// Sound's visibility was changed in System Settings, to this mode.
        case changedInSettings(mode: Int?)
        /// macOS didn't take DockAway's change to Sound's visibility.
        case couldNotSwitch
    }

    var onDisabled: ((DisableReason) -> Void)?

    /// Always Show, as Sound's visibility setting stores it.
    static let alwaysShowMode = 18

    init(silenceProvider: (() -> Bool?)? = nil) {
        self.silenceProvider = silenceProvider
    }

    static func desiredMode(isSilent: Bool) -> Int { isSilent ? 18 : 2 }

    static func readMode() -> Int? {
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        return (CFPreferencesCopyValue("Sound" as CFString, domain,
                                      kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? NSNumber)?.intValue
    }

    @discardableResult
    private static func writeMode(_ mode: Int) -> Bool {
        CFPreferencesSetValue("Sound" as CFString, mode as CFNumber, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        return CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            && readMode() == mode
    }

    /// Recover a temporary Always Show setting after an interrupted previous run.
    func recoverPreviousSession() {
        guard let owned = UserDefaults.standard.object(forKey: Self.ownershipKey) as? Int else { return }
        if Self.readMode() == owned {
            lastWriteAt = ProcessInfo.processInfo.systemUptime
            guard Self.writeMode(2) else { return }
        }
        UserDefaults.standard.removeObject(forKey: Self.ownershipKey)
    }

    /// Checks and saves turning the option on without starting it, for while
    /// DockAway is paused. Resume starts it with setEnabled(true).
    func saveEnabledWithoutStarting() -> Bool {
        guard Self.readMode() == 2 else {
            UserDefaults.standard.set(false, forKey: Self.preferenceKey)
            return false
        }
        UserDefaults.standard.set(true, forKey: Self.preferenceKey)
        return true
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        if !enabled {
            stop()
            UserDefaults.standard.set(false, forKey: Self.preferenceKey)
            return true
        }
        if isRunning { return true }
        guard Self.readMode() == 2 else {
            UserDefaults.standard.set(false, forKey: Self.preferenceKey)
            return false
        }
        isRunning = true
        expectedMode = 2
        UserDefaults.standard.set(true, forKey: Self.preferenceKey)
        rebindDevice()
        guard isRunning else { return false }
        // Also notice manual visibility changes and devices whose drivers omit callbacks.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        return true
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        removeListeners()
        if let expectedMode, Self.readMode() == expectedMode {
            if Self.writeMode(2) { UserDefaults.standard.removeObject(forKey: Self.ownershipKey) }
        } else {
            UserDefaults.standard.removeObject(forKey: Self.ownershipKey)
        }
        expectedMode = nil
        device = AudioDeviceID(kAudioObjectUnknown)
    }

    private func removeListeners() {
        for (object, var address, block) in listeners {
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        listeners.removeAll()
    }

    private func listen(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    private func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                         initial: T) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let result = withUnsafeMutableBytes(of: &value) { bytes in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard result == noErr else { return nil }
        return value
    }

    private func currentDevice() -> AudioDeviceID {
        read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
             scope: kAudioObjectPropertyScopeGlobal, initial: AudioDeviceID(kAudioObjectUnknown)) ?? AudioDeviceID(kAudioObjectUnknown)
    }

    private func rebindDevice() {
        removeListeners()
        listen(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice,
               scope: kAudioObjectPropertyScopeGlobal)
        device = currentDevice()
        if device != kAudioObjectUnknown {
            for element in 0...2 {
                for selector in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
                    listen(device, selector: selector, scope: kAudioDevicePropertyScopeOutput, element: UInt32(element))
                }
            }
        }
        refresh()
    }

    private func silent() -> Bool? {
        if let silenceProvider { return silenceProvider() }
        guard device != kAudioObjectUnknown else { return nil }
        let mute: UInt32? = read(device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, initial: UInt32(0))
        if mute == 1 { return true }
        if let volume: Float32 = read(device, kAudioDevicePropertyVolumeScalar,
                                      scope: kAudioDevicePropertyScopeOutput, initial: Float32(0)) {
            return volume <= 0.0001
        }
        // Some output drivers expose only per-channel volume. Require both channels
        // to be readable before concluding that the output is silent.
        let left: Float32? = read(device, kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: 1, initial: Float32(0))
        let right: Float32? = read(device, kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: 2, initial: Float32(0))
        if let left, let right { return max(left, right) <= 0.0001 }
        return mute.map { $0 != 0 }
    }

    func refresh() {
        guard isRunning else { return }
        let mode = Self.readMode()
        guard mode == expectedMode else {
            // Only a change that lasts is the person's: not one read while
            // DockAway's own change settles, and not a single odd read.
            mismatches += 1
            if ProcessInfo.processInfo.systemUptime - lastWriteAt < Self.settleTime || mismatches < 2 { return }
            mismatches = 0
            // A manual change wins. Do not restore over the user's new choice.
            expectedMode = nil
            stop()
            UserDefaults.standard.set(false, forKey: Self.preferenceKey)
            onDisabled?(.changedInSettings(mode: mode))
            return
        }
        mismatches = 0
        // While the person is in System Settings, Sound's setting stays as
        // it is, so DockAway never changes it under them as they pick one.
        // It catches up once they leave.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences" { return }
        if currentDevice() != device { rebindDevice(); return }
        // Unknown output state should not strand a temporary Always Show setting.
        let desired = Self.desiredMode(isSilent: silent() ?? false)
        guard desired != expectedMode else { return }
        UserDefaults.standard.set(desired, forKey: Self.ownershipKey)
        lastWriteAt = ProcessInfo.processInfo.systemUptime
        guard Self.writeMode(desired) else {
            NSLog("DockAway: unable to update native Sound menu bar visibility")
            if Self.readMode() == desired { expectedMode = desired }
            stop()
            UserDefaults.standard.set(false, forKey: Self.preferenceKey)
            onDisabled?(.couldNotSwitch)
            return
        }
        expectedMode = desired
    }
}
