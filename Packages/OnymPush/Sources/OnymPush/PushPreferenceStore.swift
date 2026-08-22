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
    private static let expiresAtKey = "push.registrationExpiresAt"
    private static let lastRegisteredTokenKey = "push.lastRegisteredToken"
    private static let pendingUnregisterTokenKey = "push.pendingUnregisterToken"

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

    /// When the backend said the accepted registration lapses — drives
    /// the refresh alongside the fixed interval.
    public var registrationExpiresAt: Date? {
        defaults().object(forKey: Self.expiresAtKey) as? Date
    }

    /// The APNs token the backend last accepted, kept so an unregister
    /// after relaunch (or before APNs re-delivers) still has a token
    /// to name. Deliberately NOT dropped by `clearRegistration()` —
    /// disabling clears the registration record first and unregisters
    /// after, and the unregister is what needs this. Cleared once an
    /// unregister actually succeeds.
    public var lastRegisteredToken: Data? {
        defaults().data(forKey: Self.lastRegisteredTokenKey)
    }

    public func clearLastRegisteredToken() {
        defaults().removeObject(forKey: Self.lastRegisteredTokenKey)
    }

    /// An unregister the backend has not yet acknowledged: set before
    /// the attempt, cleared only on success, retried at every
    /// reconcile opportunity — so one offline opt-out cannot leave the
    /// device registered forever.
    public var pendingUnregisterToken: Data? {
        defaults().data(forKey: Self.pendingUnregisterTokenKey)
    }

    public func setPendingUnregister(token: Data) {
        defaults().set(token, forKey: Self.pendingUnregisterTokenKey)
    }

    public func clearPendingUnregister() {
        defaults().removeObject(forKey: Self.pendingUnregisterTokenKey)
    }

    public func recordRegistration(
        fingerprint: String,
        token: Data,
        at date: Date,
        expiresAt: Date
    ) {
        defaults().set(fingerprint, forKey: Self.fingerprintKey)
        defaults().set(token, forKey: Self.lastRegisteredTokenKey)
        defaults().set(date, forKey: Self.registeredAtKey)
        defaults().set(expiresAt, forKey: Self.expiresAtKey)
    }

    public func clearRegistration() {
        defaults().removeObject(forKey: Self.fingerprintKey)
        defaults().removeObject(forKey: Self.registeredAtKey)
        defaults().removeObject(forKey: Self.expiresAtKey)
    }
}
