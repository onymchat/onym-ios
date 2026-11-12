import Foundation
import Observation

/// Whether this device listens on the Bluetooth mesh. Off by default:
/// listening is silent, but turning it on asks for Bluetooth permission
/// and keeps the radio scanning, and people should choose that.
///
/// Applied live — the app follows [values] and starts or stops the
/// listener the moment the switch moves.
public enum MeshListeningPreference {
    /// Shared with the Settings `@AppStorage` toggle.
    public static let storageKey = "app.onym.ios.mesh.listen"

    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: storageKey)
    }

    /// The current value, then every change. `@AppStorage` writes go
    /// through `UserDefaults.standard`, which posts `didChangeNotification`
    /// for any key — so this filters to real changes of this one.
    public static func values() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            var last = isEnabled
            continuation.yield(last)
            let observer = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: nil
            ) { _ in
                let now = isEnabled
                guard now != last else { return }
                last = now
                continuation.yield(now)
            }
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

/// What the listener is doing, for the line under the Settings switch —
/// so a field test can see where things stop: no permission, radio off,
/// nothing heard, or heard but nothing addressed here.
@MainActor
@Observable
public final class MeshListenerStatus {
    public static let shared = MeshListenerStatus()

    public enum Radio: Equatable, Sendable {
        /// Not listening (switch off), or the scanner hasn't reported yet.
        case idle
        case starting
        case on
        case off
        case unauthorized
        case unsupported
    }

    public internal(set) var radio: Radio = .idle
    /// Onym frames heard on the air — anyone's, matched or not.
    public internal(set) var framesHeard = 0
    /// Envelopes reassembled and handed to the app for this device.
    public internal(set) var envelopesDelivered = 0

    /// Called when listening stops, so the line doesn't show stale numbers.
    public func reset() {
        radio = .idle
        framesHeard = 0
        envelopesDelivered = 0
    }

    nonisolated static func report(_ change: @escaping @MainActor (MeshListenerStatus) -> Void) {
        Task { @MainActor in change(shared) }
    }
}
