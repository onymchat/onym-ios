import Foundation

/// Whether this device listens on the Bluetooth mesh. Off by default:
/// listening is silent, but turning it on asks for Bluetooth permission
/// and keeps the radio scanning, and people should choose that.
///
/// Read at launch — the Settings toggle takes effect the next time the
/// app starts.
public enum MeshListeningPreference {
    /// Shared with the Settings `@AppStorage` toggle.
    public static let storageKey = "app.onym.ios.mesh.listen"

    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: storageKey)
    }
}
