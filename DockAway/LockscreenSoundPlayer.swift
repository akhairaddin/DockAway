import AppKit

@MainActor
final class LockscreenSoundPlayer {
    enum Event: Hashable {
        case lock
        case unlock

        var preferenceKey: String {
            switch self {
            case .lock: "PlayLockSound"
            case .unlock: "PlayUnlockSound"
            }
        }

        var resourceName: String {
            switch self {
            case .lock: "DockAwayLock"
            case .unlock: "DockAwayUnlock"
            }
        }
    }

    private var sounds: [Event: NSSound] = [:]

    func playIfEnabled(_ event: Event) {
        guard UserDefaults.standard.bool(forKey: event.preferenceKey) else { return }
        play(event)
    }

    func play(_ event: Event) {
        guard let sound = sound(for: event) else {
            dockAwayDebugLog("Lockscreen sound resource is unavailable: \(event.resourceName)")
            return
        }

        sound.stop()
        sound.currentTime = 0
        if !sound.play() {
            dockAwayDebugLog("Lockscreen sound could not be played: \(event.resourceName)")
        }
    }

    private func sound(for event: Event) -> NSSound? {
        if let sound = sounds[event] { return sound }
        guard let url = Bundle.main.url(forResource: event.resourceName, withExtension: "m4a"),
              let loadedSound = NSSound(contentsOf: url, byReference: false) else {
            return nil
        }
        sounds[event] = loadedSound
        return loadedSound
    }
}
