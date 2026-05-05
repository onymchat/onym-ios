import Foundation

/// Narrow seam the inbox-side interactor depends on instead of the
/// whole `IdentityRepository`. Lets test fakes substitute a canned
/// decrypter without standing up a real identity, and keeps the
/// secret-material rule honest: only the producer of this protocol
/// (i.e. `IdentityRepository`) ever holds the X25519 private key.
protocol InvitationEnvelopeDecrypting: Sendable {
    /// Decode `envelopeBytes` (a JSON-serialised `SealedEnvelope`) and
    /// open the AES-GCM ciphertext using `identityID`'s X25519 private
    /// key. Callers pass the per-record `ownerIdentityID` stamped at
    /// receive time, so cross-identity envelopes still decrypt without
    /// requiring the user to switch identities first.
    ///
    /// Throws on: malformed JSON, wrong scheme, identity not found in
    /// the keychain, invalid signature on the ephemeral key (when
    /// present), or AES-GCM tag mismatch.
    func decryptInvitation(envelopeBytes: Data, asIdentity identityID: IdentityID) async throws -> Data

    /// Same as `decryptInvitation` but additionally surfaces the
    /// sender's Ed25519 pubkey from the outer envelope. Used by
    /// receivers that need to authenticate the sender (e.g. verify a
    /// `MemberAnnouncementPayload` came from the group's known admin)
    /// without doing a second envelope decode. The default
    /// implementation re-decodes the envelope just to extract the
    /// sender pubkey — production conformers (`IdentityRepository`)
    /// override with a single-pass implementation that decodes once.
    func decryptInvitationWithSender(
        envelopeBytes: Data,
        asIdentity identityID: IdentityID
    ) async throws -> DecryptedEnvelope
}

extension InvitationEnvelopeDecrypting {
    /// Default fallback: decrypt via the existing API + decode the
    /// envelope a second time to fish out the sender pubkey. Test
    /// stubs that don't care about provenance get this for free.
    func decryptInvitationWithSender(
        envelopeBytes: Data,
        asIdentity identityID: IdentityID
    ) async throws -> DecryptedEnvelope {
        let plaintext = try await decryptInvitation(
            envelopeBytes: envelopeBytes,
            asIdentity: identityID
        )
        let envelope = try? JSONDecoder().decode(
            SealedEnvelope.self,
            from: envelopeBytes
        )
        return DecryptedEnvelope(
            plaintext: plaintext,
            senderEd25519PublicKey: envelope?.senderEd25519PublicKey
        )
    }
}

enum InvitationDecryptError: Error, Equatable, Sendable {
    case identityNotLoaded
    case malformedEnvelope
    case unsupportedScheme(String)
    case missingEphemeralKey
    case missingNonceOrTag
    case signatureVerificationFailed
    case decryptionFailed
}
