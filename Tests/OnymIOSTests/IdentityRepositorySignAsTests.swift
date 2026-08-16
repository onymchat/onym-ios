import CryptoKit
import XCTest
@testable import OnymIOS
import OnymIdentity

/// `signWithStellarKey(matchingPublicKeyHex:)` — identity-addressed
/// signing for mandate-scoped moderation sessions. The mandate names
/// the identity that consented; with several identities on the device
/// the *selected* identity can be a different one, and the signature
/// must still come from the named key or the enforcement backend
/// refuses the session as `signature_invalid`.
final class IdentityRepositorySignAsTests: XCTestCase {
    private var keychain: IdentityKeychainStore!
    private var repository: IdentityRepository!

    override func setUp() async throws {
        try await super.setUp()
        keychain = IdentityKeychainStore(
            testNamespace: "sign-as-\(UUID().uuidString)"
        )
        repository = IdentityRepository(
            keychain: keychain,
            selectionStore: .inMemory()
        )
    }

    override func tearDown() async throws {
        try? keychain.wipeAll()
        keychain = nil
        repository = nil
        try await super.tearDown()
    }

    func test_signsWithTheNamedIdentity_notTheSelectedOne() async throws {
        // First add becomes current — capture its key as "the identity
        // that consented", then switch to a second one.
        _ = try await repository.add(
            mnemonic: "legal winner thank year wave sausage worth useful legal winner thank yellow"
        )
        let current = await repository.currentIdentity()
        let enrolledKey = try XCTUnwrap(current).stellarPublicKey
        let otherID = try await repository.add(
            mnemonic: "letter advice cage absurd amount doctor acoustic avoid letter advice cage above"
        )
        try await repository.select(otherID)

        let message = Data("gate-session".utf8)
        let signature = try await repository.signWithStellarKey(
            message,
            matchingPublicKeyHex: enrolledKey.map { String(format: "%02x", $0) }.joined()
        )

        let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: enrolledKey)
        XCTAssertTrue(verifier.isValidSignature(signature, for: message))

        // The selected identity's plain signature is a different key's.
        let selectedSignature = try await repository.signWithStellarKey(message)
        XCTAssertFalse(verifier.isValidSignature(selectedSignature, for: message))
    }

    func test_unknownKeyThrowsNoIdentityForKey() async throws {
        try await repository.add()
        do {
            _ = try await repository.signWithStellarKey(
                Data("msg".utf8),
                matchingPublicKeyHex: String(repeating: "ab", count: 32)
            )
            XCTFail("expected noIdentityForKey")
        } catch let IdentityError.noIdentityForKey(hex) {
            XCTAssertEqual(hex, String(repeating: "ab", count: 32))
        }
    }
}
