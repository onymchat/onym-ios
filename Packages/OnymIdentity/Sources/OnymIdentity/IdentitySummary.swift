import Foundation

/// View-facing projection of one identity. Carries everything the UI
/// needs (name, public material, inbox handle) without holding any
/// secret bytes — the keychain is the only source of truth for those.
///
/// Constructed by `IdentityRepository` from a `(StoredSnapshot, name)`
/// pair; broadcast via the `identities` stream so SwiftUI views can
/// render the picker without ever crossing into the actor's secret-
/// material path.
public struct IdentitySummary: Hashable, Sendable, Identifiable {
    public let id: IdentityID
    public let name: String
    /// 48-byte arkworks-compressed BLS12-381 G1 public key. Hex-prefix
    /// rendering is the "fingerprint" shown in the picker row.
    public let blsPublicKey: Data
    /// 32-byte X25519 raw public key. Pasted as the inbox handle senders
    /// need; also feeds the inbox-tag derivation that PR-4's transport
    /// fan-out subscribes against.
    public let inboxPublicKey: Data
    /// 32-byte Ed25519 raw public key (`Identity.stellarPublicKey`).
    /// Same key that signs every `SealedEnvelope`. Carried on the
    /// summary so the chat dispatcher can populate the receiver's own
    /// `MemberProfile.sendingPubkey` without crossing into the
    /// repository's secret-material path.
    public let sendingPublicKey: Data

    public init(
        id: IdentityID,
        name: String,
        blsPublicKey: Data,
        inboxPublicKey: Data,
        sendingPublicKey: Data
    ) {
        self.id = id
        self.name = name
        self.blsPublicKey = blsPublicKey
        self.inboxPublicKey = inboxPublicKey
        self.sendingPublicKey = sendingPublicKey
    }
}
