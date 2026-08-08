import CryptoKit
import Foundation

/// Narrow seam the inbox-side interactor depends on instead of the
/// whole `IdentityRepository`. Lets test fakes substitute a canned
/// decrypter without standing up a real identity, and keeps the
/// secret-material rule honest: only the producer of this protocol
/// (i.e. `IdentityRepository`) ever holds the X25519 private key.
public protocol InvitationEnvelopeDecrypting: Sendable {
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
    public func decryptInvitationWithSender(
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
        // C-1: fail-closed provenance. Only surface the sender pubkey
        // when a signature is present AND verifies against it over the
        // ephemeral pubkey — a raw `senderEd25519PublicKey` with no
        // valid signature is attacker-choosable and must read as nil.
        return DecryptedEnvelope(
            plaintext: plaintext,
            senderEd25519PublicKey: envelope.flatMap(Self.verifiedSender)
        )
    }

    /// Returns the envelope's Ed25519 sender pubkey iff it shipped a
    /// signature that verifies over the ephemeral pubkey; nil otherwise.
    private static func verifiedSender(in envelope: SealedEnvelope) -> Data? {
        guard let sigData = envelope.ephemeralKeySignature,
              let senderPubData = envelope.senderEd25519PublicKey,
              let ephPubData = envelope.ephemeralPublicKey,
              let verifyingKey = try? Curve25519.Signing.PublicKey(
                  rawRepresentation: senderPubData
              ),
              verifyingKey.isValidSignature(sigData, for: ephPubData)
        else {
            return nil
        }
        return senderPubData
    }
}

public enum InvitationDecryptError: Error, Equatable, Sendable {
    case identityNotLoaded
    case malformedEnvelope
    case unsupportedScheme(String)
    case missingEphemeralKey
    case missingNonceOrTag
    case signatureVerificationFailed
    case decryptionFailed
}
