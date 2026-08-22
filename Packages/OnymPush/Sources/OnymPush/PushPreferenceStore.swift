import Foundation

/// The user's push opt-in, and the fingerprint of the last
/// registration the backend accepted.
///
/// Push is **off by default**: enabling it hands a third party (the
/// push backend, and Apple) the inbox-tag ↔ device linkage the rest of
/// the app avoids creating, so that trade is the user's to make in
/// Settings, never a default.
public struct PushPreferenceStore: Sendable {
    private static let enabledKey = "push.enabled"
    private static let fingerprintKey = "push.lastRegistrationFingerprint"
    private static let registeredAtKey = "push.lastRegisteredAt"

    private let defaults: @Sendable () -> UserDefaults

    public init(defaults: @escaping @Sendable () -> UserDefaults = { .standard }) {
        self.defaults = defaults
    }

    public var isEnabled: Bool {
        defaults().bool(forKey: Self.enabledKey)
    }

    public func setEnabled(_ enabled: Bool) {
        defaults().set(enabled, forKey: Self.enabledKey)
        if !enabled {
            clearRegistration()
        }
    }

    /// Hash of (token, subscriptions) the backend last accepted, so
    /// reconciliation can tell "nothing changed" from "re-register".
    public var lastRegistrationFingerprint: String? {
        defaults().string(forKey: Self.fingerprintKey)
    }

    public var lastRegisteredAt: Date? {
        defaults().object(forKey: Self.registeredAtKey) as? Date
    }

    public func recordRegistration(fingerprint: String, at date: Date) {
        defaults().set(fingerprint, forKey: Self.fingerprintKey)
        defaults().set(date, forKey: Self.registeredAtKey)
    }

    public func clearRegistration() {
        defaults().removeObject(forKey: Self.fingerprintKey)
        defaults().removeObject(forKey: Self.registeredAtKey)
    }
}
