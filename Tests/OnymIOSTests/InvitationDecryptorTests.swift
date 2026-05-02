import XCTest
@testable import OnymIOS

/// Interactor tests against `FakeInvitationEnvelopeDecrypter` — fast,
/// no real crypto. Asserts the pump shape: takes an `IncomingInvitation`,
/// hands its payload to the decrypter, JSON-decodes the result. Real
/// X25519 round-trip is in `IdentityRepositoryInvitationDecryptTests`.
final class InvitationDecryptorTests: XCTestCase {

    // MARK: - Happy path

    func test_decrypt_passesPayloadToDecrypterAndReturnsParsed() async throws {
        let plaintext = try Self.encodeInvitation(name: "Onym Launch", senderHex: "deadbeef")
        let decrypter = FakeInvitationEnvelopeDecrypter(mode: .fixed(plaintext))
        let interactor = InvitationDecryptor(envelopeDecrypter: decrypter)

        let invitation = Self.makeInvitation(id: "evt-1", payload: Data("envelope-bytes".utf8))
        let decrypted = try await interactor.decrypt(invitation)

        XCTAssertEqual(decrypted.name, "Onym Launch")
        XCTAssertEqual(decrypted.senderNostrPubkey, "deadbeef")
        let calls = await decrypter.decryptCalls
        XCTAssertEqual(calls, [Data("envelope-bytes".utf8)],
                       "interactor must hand the persisted ciphertext bytes to the decrypter unchanged")
    }

    func test_decrypt_drivesMultipleInvitationsIndependently() async throws {
        let p1 = try Self.encodeInvitation(name: "Group A", senderHex: "aaaa")
        let p2 = try Self.encodeInvitation(name: "Group B", senderHex: "bbbb")
        let decrypter = FakeInvitationEnvelopeDecrypter(mode: .scripted([
            Data("env-1".utf8): p1,
            Data("env-2".utf8): p2,
        ]))
        let interactor = InvitationDecryptor(envelopeDecrypter: decrypter)

        let d1 = try await interactor.decrypt(Self.makeInvitation(id: "1", payload: Data("env-1".utf8)))
        let d2 = try await interactor.decrypt(Self.makeInvitation(id: "2", payload: Data("env-2".utf8)))

        XCTAssertEqual(d1.name, "Group A")
        XCTAssertEqual(d2.name, "Group B")
    }

    // MARK: - Error paths

    func test_decrypt_propagatesDecrypterError() async {
        let decrypter = FakeInvitationEnvelopeDecrypter(mode: .failing(.signatureVerificationFailed))
        let interactor = InvitationDecryptor(envelopeDecrypter: decrypter)
        let invitation = Self.makeInvitation(id: "evt-1", payload: Data())

        do {
            _ = try await interactor.decrypt(invitation)
            XCTFail("expected throw")
        } catch let error as InvitationDecryptError {
            XCTAssertEqual(error, .signatureVerificationFailed,
                           "envelope-layer errors must surface to the caller verbatim")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_decrypt_throwsDecodingError_onMalformedPlaintext() async {
        // Decrypter returns "decryption succeeded" but the plaintext
        // isn't a `DecryptedInvitation` — JSON decode should throw.
        let decrypter = FakeInvitationEnvelopeDecrypter(mode: .fixed(Data("not the right shape".utf8)))
        let interactor = InvitationDecryptor(envelopeDecrypter: decrypter)
        let invitation = Self.makeInvitation(id: "evt-1", payload: Data())

        do {
            _ = try await interactor.decrypt(invitation)
            XCTFail("expected throw")
        } catch is DecodingError {
            // expected
        } catch {
            XCTFail("expected DecodingError, got \(error)")
        }
    }

    // MARK: - Fixtures

    private static func makeInvitation(
        id: String,
        payload: Data,
        receivedAt: Date = Date(),
        status: IncomingInvitationStatus = .pending
    ) -> IncomingInvitation {
        IncomingInvitation(id: id, payload: payload, receivedAt: receivedAt, status: status)
    }

    private static func encodeInvitation(
        name: String,
        senderHex: String,
        groupID: Data = Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
        epoch: UInt64 = 1
    ) throws -> Data {
        let invitation = DecryptedInvitation(
            groupID: groupID,
            name: name,
            epoch: epoch,
            senderNostrPubkey: senderHex
        )
        return try JSONEncoder().encode(invitation)
    }
}
