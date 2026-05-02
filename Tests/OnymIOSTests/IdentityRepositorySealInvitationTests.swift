import CryptoKit
import XCTest
@testable import OnymIOS

/// Sender side of the invitation envelope. Mirrors
/// `IdentityRepositoryInvitationDecryptTests` but exercises the new
/// `sealInvitation` method — sealed bytes round-trip through
/// `decryptInvitation` on a *different* `IdentityRepository` (the
/// recipient) and the M-5 ephemeral-pubkey signature must verify
/// against the sender's identity key.
final class IdentityRepositorySealInvitationTests: XCTestCase {
    private var senderKeychain: KeychainStore!
    private var sender: IdentityRepository!
    private var recipientKeychain: KeychainStore!
    private var recipient: IdentityRepository!

    override func setUp() async throws {
        try await super.setUp()
        senderKeychain = KeychainStore(
            service: "chat.onym.ios.identity.tests.sender.\(UUID().uuidString)",
            account: "current"
        )
        sender = IdentityRepository(keychain: senderKeychain)
        _ = try await sender.restore(
            mnemonic: "legal winner thank year wave sausage worth useful legal winner thank yellow"
        )

        recipientKeychain = KeychainStore(
            service: "chat.onym.ios.identity.tests.recipient.\(UUID().uuidString)",
            account: "current"
        )
        recipient = IdentityRepository(keychain: recipientKeychain)
        _ = try await recipient.restore(
            mnemonic: "letter advice cage absurd amount doctor acoustic avoid letter advice cage above"
        )
    }

    override func tearDown() async throws {
        try? senderKeychain.wipe()
        try? recipientKeychain.wipe()
        senderKeychain = nil
        sender = nil
        recipientKeychain = nil
        recipient = nil
        try await super.tearDown()
    }

    func test_sealInvitation_roundtripsThroughDecrypt() async throws {
        let recipientIdentity = try await XCTUnwrapAsync(await recipient.currentIdentity())
        let plaintext = Data("hello, invitee".utf8)

        let sealed = try await sender.sealInvitation(
            payload: plaintext,
            to: recipientIdentity.inboxPublicKey
        )
        let decrypted = try await recipient.decryptInvitation(envelopeBytes: sealed)
        XCTAssertEqual(decrypted, plaintext)
    }

    func test_sealInvitation_signatureVerifiesAgainstSenderIdentity() async throws {
        let recipientIdentity = try await XCTUnwrapAsync(await recipient.currentIdentity())
        let senderIdentity = try await XCTUnwrapAsync(await sender.currentIdentity())

        let sealed = try await sender.sealInvitation(
            payload: Data("attested".utf8),
            to: recipientIdentity.inboxPublicKey
        )
        let envelope = try JSONDecoder().decode(SealedEnvelope.self, from: sealed)

        let senderPub = try XCTUnwrap(envelope.senderEd25519PublicKey)
        XCTAssertEqual(
            senderPub,
            senderIdentity.stellarPublicKey,
            "sender Ed25519 pubkey embedded in envelope must match the sender's identity"
        )
        let sig = try XCTUnwrap(envelope.ephemeralKeySignature)
        let ephPub = try XCTUnwrap(envelope.ephemeralPublicKey)
        let verifyingKey = try Curve25519.Signing.PublicKey(rawRepresentation: senderPub)
        XCTAssertTrue(verifyingKey.isValidSignature(sig, for: ephPub))
    }

    func test_sealInvitation_freshEphemeralPerCall() async throws {
        let recipientIdentity = try await XCTUnwrapAsync(await recipient.currentIdentity())

        let firstBytes = try await sender.sealInvitation(
            payload: Data("a".utf8),
            to: recipientIdentity.inboxPublicKey
        )
        let secondBytes = try await sender.sealInvitation(
            payload: Data("a".utf8),
            to: recipientIdentity.inboxPublicKey
        )
        let first = try JSONDecoder().decode(SealedEnvelope.self, from: firstBytes)
        let second = try JSONDecoder().decode(SealedEnvelope.self, from: secondBytes)
        XCTAssertNotEqual(
            first.ephemeralPublicKey,
            second.ephemeralPublicKey,
            "each seal must mint a fresh per-envelope X25519 keypair"
        )
        XCTAssertNotEqual(first.ciphertext, second.ciphertext, "different nonce → different ciphertext")
    }

    func test_sealInvitation_rejectsInvalidRecipientPublicKey() async throws {
        let badPub = Data(repeating: 0, count: 16)  // X25519 expects 32B
        await assertThrows(
            try await sender.sealInvitation(payload: Data("x".utf8), to: badPub),
            InvitationSealError.invalidRecipientPublicKey
        )
    }

    func test_sealInvitation_throwsIdentityNotLoaded_afterWipe() async throws {
        let recipientIdentity = try await XCTUnwrapAsync(await recipient.currentIdentity())
        try await sender.wipe()
        await assertThrows(
            try await sender.sealInvitation(
                payload: Data("x".utf8),
                to: recipientIdentity.inboxPublicKey
            ),
            InvitationSealError.identityNotLoaded
        )
    }

    // MARK: - Helpers

    private func assertThrows<T: Sendable>(
        _ expression: @autoclosure () async throws -> T,
        _ expected: InvitationSealError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected to throw \(expected), got success", file: file, line: line)
        } catch let error as InvitationSealError {
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
}
