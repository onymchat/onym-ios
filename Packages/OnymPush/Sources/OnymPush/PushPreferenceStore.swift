import Foundation

/// The user's push opt-in, and the fingerprint of the last
/// registration the backend accepted.
///
/// Push is **off by default**: enabling it hands a third party (the
/// push backend, and Apple) the inbox-tag ↔ device linkage the rest of
/// the app avoids creating, so that trade is the user's to make in
/// Settings, never a default.
///
/// Raw APNs tokens sit here in plaintext `UserDefaults`, deliberately.
/// An APNs token is not a secret in the keychain sense: it is a
/// routing handle that only the operator's APNs auth key can turn
/// into a delivered push, and Apple rotates it on restore or
/// reinstall — a copy lifted from an unencrypted backup lets an
/// attacker do nothing on their own. That is a different posture from
/// `UserDefaultsCaseSubmissionStore` (encrypted at rest because a
/// statement is the user's own words), and a different adversary from
/// the one `PushTokenEnvelope` defends against (passive capture in
/// the operator's infrastructure, where the token would otherwise sit
/// beside the APNs key that makes it potent).
public struct PushPreferenceStore: Sendable {
    private static let enabledKey = "push.enabled"
    private static let fingerprintKey = "push.lastRegistrationFingerprint"
    private static let registeredAtKey = "push.lastRegisteredAt"
    private static let expiresAtKey = "push.registrationExpiresAt"
    private static let lastRegisteredTokenKey = "push.lastRegisteredToken"
    private static let pendingUnregisterTokensKey = "push.pendingUnregisterTokens"

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

    /// Every unregister the backend has not yet acknowledged: each
    /// token is added before the attempt, removed only on success, and
    /// retried at every reconcile opportunity — so one offline opt-out
    /// cannot leave the device registered forever. A *set*, not a
    /// slot: a rotation whose drain failed (old token still pending)
    /// followed by a disable (new token now pending too) owes the
    /// backend two unregisters, and a single slot would silently drop
    /// one, leaving that token wake-able until the 60-day sweep.
    /// Persisted as an array; membership is deduplicated on add.
    public var pendingUnregisterTokens: [Data] {
        defaults().array(forKey: Self.pendingUnregisterTokensKey) as? [Data] ?? []
    }

    public func addPendingUnregister(token: Data) {
        var tokens = pendingUnregisterTokens
        guard !tokens.contains(token) else { return }
        tokens.append(token)
        defaults().set(tokens, forKey: Self.pendingUnregisterTokensKey)
    }

    public func removePendingUnregister(token: Data) {
        var tokens = pendingUnregisterTokens
        tokens.removeAll { $0 == token }
        if tokens.isEmpty {
            defaults().removeObject(forKey: Self.pendingUnregisterTokensKey)
        } else {
            defaults().set(tokens, forKey: Self.pendingUnregisterTokensKey)
        }
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
