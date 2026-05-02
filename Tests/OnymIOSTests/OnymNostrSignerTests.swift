import XCTest
import OnymSDK
@testable import OnymIOS

/// Hits OnymSDK's BIP340 / secp256k1 FFI through `OnymNostrSigner` —
/// no mocks. The roundtrip uses `Common.nostrVerifyEventSignature` so
/// a regression in either signing or verification surfaces here.
final class OnymNostrSignerTests: XCTestCase {

    // MARK: - constructor

    func test_init_acceptsValid32ByteSecret() throws {
        let secret = Data(repeating: 0x01, count: 32)
        XCTAssertNoThrow(try OnymNostrSigner(secretKey: secret))
    }

    func test_init_rejectsShortSecret() {
        let secret = Data(repeating: 0x01, count: 31)
        XCTAssertThrowsError(try OnymNostrSigner(secretKey: secret)) { error in
            guard case NostrSignerError.invalidSecretKeyLength(let actual) = error else {
                return XCTFail("expected invalidSecretKeyLength, got \(error)")
            }
            XCTAssertEqual(actual, 31)
        }
    }

    func test_init_rejectsLongSecret() {
        let secret = Data(repeating: 0x01, count: 33)
        XCTAssertThrowsError(try OnymNostrSigner(secretKey: secret))
    }

    func test_init_rejectsEmptySecret() {
        XCTAssertThrowsError(try OnymNostrSigner(secretKey: Data()))
    }

    // MARK: - publicKey

    func test_publicKey_is32Bytes() throws {
        let signer = try OnymNostrSigner(secretKey: Data(repeating: 0x42, count: 32))
        let pub = try signer.publicKey()
        XCTAssertEqual(pub.count, 32, "BIP340 x-only pubkey is 32 bytes")
    }

    func test_publicKey_isDeterministic() throws {
        let secret = Data(repeating: 0x42, count: 32)
        let signerA = try OnymNostrSigner(secretKey: secret)
        let signerB = try OnymNostrSigner(secretKey: secret)
        let pubA = try signerA.publicKey()
        let pubB = try signerB.publicKey()
        XCTAssertEqual(pubA, pubB)
    }

    // MARK: - signEventID

    func test_signEventID_rejectsShortEventID() throws {
        let signer = try OnymNostrSigner(secretKey: Data(repeating: 0x01, count: 32))
        XCTAssertThrowsError(try signer.signEventID(Data(repeating: 0xAA, count: 31))) { error in
            guard case NostrSignerError.invalidEventIDLength(let actual) = error else {
                return XCTFail("expected invalidEventIDLength, got \(error)")
            }
            XCTAssertEqual(actual, 31)
        }
    }

    func test_signEventID_returns64Bytes() throws {
        let signer = try OnymNostrSigner(secretKey: Data(repeating: 0x01, count: 32))
        let eventID = Data(repeating: 0xAA, count: 32)
        let sig = try signer.signEventID(eventID)
        XCTAssertEqual(sig.count, 64, "BIP340 schnorr sig is 64 bytes")
    }

    func test_signEventID_verifiesAgainstOnymSDK() throws {
        let signer = try OnymNostrSigner(secretKey: Data(repeating: 0x01, count: 32))
        let pub = try signer.publicKey()
        let eventID = Data(repeating: 0xAA, count: 32)
        let sig = try signer.signEventID(eventID)
        XCTAssertNoThrow(
            try Common.nostrVerifyEventSignature(publicKey: pub, eventId: eventID, signature: sig),
            "OnymSDK must verify a signature its own signer just produced"
        )
    }

    func test_signEventID_verificationFailsForWrongMessage() throws {
        let signer = try OnymNostrSigner(secretKey: Data(repeating: 0x01, count: 32))
        let pub = try signer.publicKey()
        let signedID = Data(repeating: 0xAA, count: 32)
        let otherID = Data(repeating: 0xBB, count: 32)
        let sig = try signer.signEventID(signedID)
        XCTAssertThrowsError(
            try Common.nostrVerifyEventSignature(publicKey: pub, eventId: otherID, signature: sig)
        )
    }

    // MARK: - ephemeral

    func test_ephemeral_producesDistinctKeysPerCall() throws {
        let a = try OnymNostrSigner.ephemeral()
        let b = try OnymNostrSigner.ephemeral()
        XCTAssertNotEqual(a.secretKey, b.secretKey)
        XCTAssertNotEqual(try a.publicKey(), try b.publicKey())
    }

    func test_ephemeral_secretIs32Bytes() throws {
        let signer = try OnymNostrSigner.ephemeral()
        XCTAssertEqual(signer.secretKey.count, 32)
    }

    func test_ephemeral_canSignAndVerify() throws {
        let signer = try OnymNostrSigner.ephemeral()
        let pub = try signer.publicKey()
        let eventID = Data(repeating: 0x55, count: 32)
        let sig = try signer.signEventID(eventID)
        XCTAssertNoThrow(
            try Common.nostrVerifyEventSignature(publicKey: pub, eventId: eventID, signature: sig)
        )
    }
}
