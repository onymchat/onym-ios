import Foundation

/// View-facing projection of one identity. Carries everything the UI
/// needs (name, public material, inbox handle) without holding any
/// secret bytes — the keychain is the only source of truth for those.
///
/// Constructed by `IdentityRepository` from a `(StoredSnapshot, name)`
/// pair; broadcast via the `identities` stream so SwiftUI views can
/// render the picker without ever crossing into the actor's secret-
/// material path.
struct IdentitySummary: Hashable, Sendable {
    let id: IdentityID
    let name: String
    /// 48-byte arkworks-compressed BLS12-381 G1 public key. Hex-prefix
    /// rendering is the "fingerprint" shown in the picker row.
    let blsPublicKey: Data
    /// 32-byte X25519 raw public key. Pasted as the inbox handle senders
    /// need; also feeds the inbox-tag derivation that PR-4's transport
    /// fan-out subscribes against.
    let inboxPublicKey: Data
}
