import CryptoKit
import XCTest
@testable import OnymIOS

/// Real X25519 + AES-GCM round-trip against `IdentityRepository`. Uses
/// an isolated Keychain service per test (same pattern as
/// `IdentityRepositoryTests`) so runs don't collide with each other or
/// with the production identity item.
///
/// `TestInvitationEncryptor` is the sender side — replicates
/// stellar-mls's `GroupCrypto.encryptInvitation` formula in test code
/// so we can produce real ciphertext without porting the encrypt path
/// to production (no app code sends invitations yet).
final class IdentityRepositoryInvitationDecryptTests: XCTestCase {
    private var keychain: IdentityKeychainStore!
    private var repository: IdentityRepository!

    /// BIP39 vector that gives a richer mnemonic than `abandon × 11 +
    /// about` — same one `RecoveryPhraseBackupFlowTests` uses.
    private let testMnemonic = "legal winner thank year wave sausage worth useful legal winner thank yellow"

    override func setUp() async throws {
        try await super.setUp()
        keychain = IdentityKeychainStore(
            testNamespace: "decrypt-tests-\(UUID().uuidString)"
        )
        repository = IdentityRepository(
            keychain: keychain,
            selectionStore: .inMemory()
        )
        _ = try await repository.restore(mnemonic: testMnemonic)
    }

    override func tearDown() async throws {
        try? keychain.wipeAll()
        keychain = nil
        repository = nil
        try await super.tearDown()
    }

    // MARK: - Happy path

    func test_decryptInvitation_roundtripsSealedPayload() async throws {
        let identity = try await XCTUnwrapAsync(await repository.currentIdentity())
        let plaintext = Data("hello, invitee".utf8)

        let envelope = try TestInvitationEncryptor.envelopeBytes(
            plaintext: plaintext,
            recipientX25519PublicKey: identity.inboxPublicKey
        )

        let decrypted = try await decryptUsingCurrent(envelope)
        XCTAssertEqual(decrypted, plaintext)
    }

    func test_decryptInvitation_acceptsValidSenderSignature() async throws {
        let identity = try await XCTUnwrapAsync(await repository.currentIdentity())
        let senderSigningKey = Curve25519.Signing.PrivateKey()

        let envelope = try TestInvitationEncryptor.envelopeBytes(
            plaintext: Data("signed".utf8),
            recipientX25519PublicKey: identity.inboxPublicKey,
            senderSigningKey: senderSigningKey
        )

        let decrypted = try await decryptUsingCurrent(envelope)
        XCTAssertEqual(decrypted, Data("signed".utf8))
    }

    // MARK: - C-1: verified-sender provenance

    func test_decryptWithSender_surfacesSenderOnlyWhenSignatureVerifies() async throws {
        let identity = try await XCTUnwrapAsync(await repository.currentIdentity())
        let senderSigningKey = Curve25519.Signing.PrivateKey()

        let envelope = try TestInvitationEncryptor.envelopeBytes(
            plaintext: Data("signed".utf8),
            recipientX25519PublicKey: identity.inboxPublicKey,
            senderSigningKey: senderSigningKey
        )

        let result = try await decryptWithSenderUsingCurrent(envelope)
        XCTAssertEqual(result.plaintext, Data("signed".utf8))
        XCTAssertEqual(
            result.senderEd25519PublicKey,
            Data(senderSigningKey.publicKey.rawRepresentation),
            "a signed envelope must surface the verified sender pubkey"
        )
    }

    func test_decryptWithSender_dropsSenderWhenSignatureOmitted() async throws {
        // C-1 attack: envelope carries a `senderEd25519PublicKey` but
        // NO `ephemeralKeySignature`. It must still decrypt, but the
        // unverified (attacker-choosable) key must NOT be surfaced —
        // `senderEd25519PublicKey` reads nil.
        let identity = try await XCTUnwrapAsync(await repository.currentIdentity())

        // Real ciphertext, no signing.
        let base = try TestInvitationEncryptor.sealedEnvelope(
            plaintext: Data("unsigned".utf8),
            recipientX25519PublicKey: identity.inboxPublicKey
        )
        // Attacker stamps an arbitrary sender pubkey, leaves signature nil.
        let attackerKey = Data(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        let forged = SealedEnvelope(
            version: base.version,
            scheme: base.scheme,
            ephemeralPublicKey: base.ephemeralPublicKey,
            ephemeralKeySignature: nil,
            senderEd25519PublicKey: attackerKey,
            nonce: base.nonce,
            ciphertext: base.ciphertext,
            authenticationTag: base.authenticationTag
        )
        let bytes = try JSONEncoder().encode(forged)

        let result = try await decryptWithSenderUsingCurrent(bytes)
        XCTAssertEqual(result.plaintext, Data("unsigned".utf8),
                       "envelope still decrypts")
        XCTAssertNil(result.senderEd25519PublicKey,
                     "C-1: an unsigned sender pubkey must NOT be surfaced as verified")
    }

    // MARK: - Error paths

    func test_decryptInvitation_rejectsMalformedJSON() async {
        await assertThrows(
            try await decryptUsingCurrent(Data("not json".utf8)),
            InvitationDecryptError.malformedEnvelope
        )
    }

    func test_decryptInvitation_rejectsUnsupportedScheme() async throws {
        let envelope = SealedEnvelope(
            version: 1,
            scheme: "aes-256-gcm-v1",  // legacy group-broadcast scheme, not invitation
            ephemeralPublicKey: Data(repeating: 0, count: 32),
            ephemeralKeySignature: nil,
            senderEd25519PublicKey: nil,
            nonce: Data(repeating: 0, count: 12),
            ciphertext: Data(),
            authenticationTag: Data(repeating: 0, count: 16)
        )
        let bytes = try JSONEncoder().encode(envelope)
        await assertThrows(
            try await decryptUsingCurrent(bytes),
            InvitationDecryptError.unsupportedScheme("aes-256-gcm-v1")
        )
    }

    func test_decryptInvitation_rejectsMissingEphemeralKey() async throws {
        let envelope = SealedEnvelope(
            version: 1,
            scheme: "x25519-aes-256-gcm-v1",
            ephemeralPublicKey: nil,
            ephemeralKeySignature: nil,
            senderEd25519PublicKey: nil,
            nonce: Data(repeating: 0, count: 12),
            ciphertext: Data(),
            authenticationTag: Data(repeating: 0, count: 16)
        )
        let bytes = try JSONEncoder().encode(envelope)
        await assertThrows(
            try await decryptUsingCurrent(bytes),
            InvitationDecryptError.missingEphemeralKey
        )
    }

    func test_decryptInvitation_rejectsTamperedSignature() async throws {
        let identity = try await XCTUnwrapAsync(await repository.currentIdentity())
        let senderSigningKey = Curve25519.Signing.PrivateKey()

        var envelope = try TestInvitationEncryptor.sealedEnvelope(
            plaintext: Data("payload".utf8),
            recipientX25519PublicKey: identity.inboxPublicKey,
            senderSigningKey: senderSigningKey
        )
        // Flip a bit in the signature. `Data(...)` copies into a fresh
        // contiguous buffer so subscript [0] is safe (CryptoKit Data
        // outputs are slices with non-zero startIndex otherwise).
        var tamperedSig = Data(envelope.ephemeralKeySignature!)
        tamperedSig[0] ^= 0x01
        envelope = SealedEnvelope(
            version: envelope.version,
            scheme: envelope.scheme,
            ephemeralPublicKey: envelope.ephemeralPublicKey,
            ephemeralKeySignature: tamperedSig,
            senderEd25519PublicKey: envelope.senderEd25519PublicKey,
            nonce: envelope.nonce,
            ciphertext: envelope.ciphertext,
            authenticationTag: envelope.authenticationTag
        )
        let bytes = try JSONEncoder().encode(envelope)

        await assertThrows(
            try await decryptUsingCurrent(bytes),
            InvitationDecryptError.signatureVerificationFailed
        )
    }

    func test_decryptInvitation_rejectsTamperedCiphertext() async throws {
        let identity = try await XCTUnwrapAsync(await repository.currentIdentity())
        var envelope = try TestInvitationEncryptor.sealedEnvelope(
            plaintext: Data("payload".utf8),
            recipientX25519PublicKey: identity.inboxPublicKey
        )
        // CryptoKit returns ciphertext as a slice into the SealedBox's
        // backing buffer; subscripting at [0] reads outside the slice
        // and crashes. `Data(...)` copies into a fresh contiguous buffer.
        var tamperedCiphertext = Data(envelope.ciphertext)
        tamperedCiphertext[0] ^= 0x01
        envelope = SealedEnvelope(
            version: envelope.version,
            scheme: envelope.scheme,
            ephemeralPublicKey: envelope.ephemeralPublicKey,
            ephemeralKeySignature: envelope.ephemeralKeySignature,
            senderEd25519PublicKey: envelope.senderEd25519PublicKey,
            nonce: envelope.nonce,
            ciphertext: tamperedCiphertext,
            authenticationTag: envelope.authenticationTag
        )
        let bytes = try JSONEncoder().encode(envelope)

        await assertThrows(
            try await decryptUsingCurrent(bytes),
            InvitationDecryptError.decryptionFailed
        )
    }

    func test_decryptInvitation_rejectsWrongRecipient() async throws {
        // Encrypt to a *different* recipient — the on-device X25519
        // private key won't match the ephemeral ECDH partner, so AES
        // tag verification fails.
        let strangerKey = Curve25519.KeyAgreement.PrivateKey()
        let strangerPubData = Data(strangerKey.publicKey.rawRepresentation)

        let envelope = try TestInvitationEncryptor.envelopeBytes(
            plaintext: Data("not for us".utf8),
            recipientX25519PublicKey: strangerPubData
        )

        await assertThrows(
            try await decryptUsingCurrent(envelope),
            InvitationDecryptError.decryptionFailed
        )
    }

    func test_decryptInvitation_throwsIdentityNotLoaded_afterWipe() async throws {
        // Capture the identity's ID BEFORE wipe — the new explicit-ID
        // API needs a target. Post-wipe, calling decrypt with that ID
        // hits an empty keychain and surfaces `.identityNotLoaded`.
        let id = try await XCTUnwrapAsync(await repository.currentSelectedID())
        try await repository.wipe()

        let strangerKey = Curve25519.KeyAgreement.PrivateKey()
        let envelope = try TestInvitationEncryptor.envelopeBytes(
            plaintext: Data("payload".utf8),
            recipientX25519PublicKey: Data(strangerKey.publicKey.rawRepresentation)
        )

        await assertThrows(
            try await repository.decryptInvitation(envelopeBytes: envelope, asIdentity: id),
            InvitationDecryptError.identityNotLoaded
        )
    }

    // MARK: - Helpers

    private func assertThrows<T: Sendable>(
        _ expression: @autoclosure () async throws -> T,
        _ expected: InvitationDecryptError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected to throw \(expected), got success", file: file, line: line)
        } catch let error as InvitationDecryptError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }

    private func XCTUnwrapAsync<T>(
        _ value: T?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> T {
        guard let value else {
            XCTFail("unexpected nil", file: file, line: line)
            throw XCTSkip("nil")
        }
        return value
    }

    /// Convenience: decrypt under the currently-selected identity.
    /// Every test in this file works with the single restored identity
    /// from `setUp`, so this saves the per-test boilerplate of fetching
    /// `currentSelectedID()` before every `decryptInvitation` call.
    /// The cross-identity routing is exercised by
    /// `IdentityRepositorySealInvitationTests` and
    /// `IncomingInvitationsRepositoryTests` instead.
    private func decryptUsingCurrent(_ envelope: Data) async throws -> Data {
        let id = try await XCTUnwrapAsync(await repository.currentSelectedID())
        return try await repository.decryptInvitation(envelopeBytes: envelope, asIdentity: id)
    }

    /// Same as `decryptUsingCurrent` but returns the verified-sender
    /// bundle, for the C-1 provenance tests.
    private func decryptWithSenderUsingCurrent(_ envelope: Data) async throws -> DecryptedEnvelope {
        let id = try await XCTUnwrapAsync(await repository.currentSelectedID())
        return try await repository.decryptInvitationWithSender(envelopeBytes: envelope, asIdentity: id)
    }
}
