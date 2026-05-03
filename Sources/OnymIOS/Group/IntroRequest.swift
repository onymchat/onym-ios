import Foundation

/// One inbound "request to join" envelope received over an intro
/// inbox tag. Opaque bytes here — decryption + parsing of the inner
/// payload (which carries the joiner's identity pubkey + group
/// acknowledgement) happens in PR-4's `JoinRequestApprover`.
///
/// Mirrors the shape of `IncomingInvitationRecord`; the two stores
/// are deliberately parallel (identity inbox vs intro inbox)
/// because the consumer flows differ — invitations are autonomic
/// (the joiner's chat appears), intro requests are interactive (the
/// inviter taps Approve/Decline).
struct IntroRequest: Equatable, Sendable {
    /// Nostr event id; dedupe key.
    let id: String
    /// The inviter's intro pubkey this request was addressed to.
    /// Doubles as the lookup key into `IntroKeyStore` —
    /// `store.find(introPublicKey:)` returns the privkey that
    /// decrypts `payload`.
    let targetIntroPublicKey: Data
    /// Sealed envelope bytes — the inner JSON is encrypted to
    /// `targetIntroPublicKey` via X25519 + AES-GCM.
    let payload: Data
    let receivedAt: Date
}
