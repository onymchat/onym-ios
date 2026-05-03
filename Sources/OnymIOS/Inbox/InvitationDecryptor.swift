import Foundation

/// Stateless interactor: takes a persisted `IncomingInvitation` (opaque
/// ciphertext) and turns it into a parsed `DecryptedInvitation`. Two
/// steps: the envelope-decrypter seam unwraps the X25519 layer, then
/// `JSONDecoder` parses the payload.
///
/// Depends on the narrow `InvitationEnvelopeDecrypting` seam, not the
/// whole `IdentityRepository`. Tests substitute a fake decrypter and
/// drive specific plaintext bytes; the real wiring binds it to
/// `IdentityRepository`.
struct InvitationDecryptor: Sendable {
    let envelopeDecrypter: any InvitationEnvelopeDecrypting

    /// Decrypt and parse one invitation. Throws the underlying
    /// `InvitationDecryptError` on envelope-layer failures, or a
    /// `DecodingError` if the plaintext isn't a `DecryptedInvitation`.
    ///
    /// The envelope decrypts under `invitation.ownerIdentityID`'s
    /// X25519 key — the per-record stamp set by the fan-out transport
    /// at receive time. This makes cross-identity decryption work:
    /// invitations sitting in the inbox of an identity that isn't the
    /// currently-selected one still decrypt successfully when the
    /// user later switches to (or just acts on a notification for)
    /// that identity.
    func decrypt(_ invitation: IncomingInvitation) async throws -> DecryptedInvitation {
        let plaintext = try await envelopeDecrypter.decryptInvitation(
            envelopeBytes: invitation.payload,
            asIdentity: invitation.ownerIdentityID
        )
        return try JSONDecoder().decode(DecryptedInvitation.self, from: plaintext)
    }
}
