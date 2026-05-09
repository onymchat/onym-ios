import Foundation

/// Output of `InvitationEnvelopeDecrypting.decryptInvitationWithSender`.
/// Bundles the inner plaintext with the Ed25519 pubkey that signed
/// the outer `SealedEnvelope` — receivers that need to authenticate
/// the sender (e.g. the admin-Ed25519 trust check on
/// `MemberAnnouncementPayload`) read both at the same time without
/// re-decoding the envelope.
///
/// `senderEd25519PublicKey` is `nil` when the envelope shipped
/// without a `sender_ed25519_public_key` block. That's allowed by
/// the wire format (the signature block is optional), so callers
/// that require provenance MUST treat `nil` as "no proof of sender"
/// and refuse to act on the plaintext as if it were authenticated.
struct DecryptedEnvelope: Equatable, Sendable {
    let plaintext: Data
    /// 32-byte raw Ed25519 pubkey, or `nil` when the envelope
    /// didn't include a signature block.
    let senderEd25519PublicKey: Data?
}
