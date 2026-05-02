import XCTest
@testable import OnymIOS

/// Pin AES-GCM roundtrip semantics + Keychain key stability. The key
/// itself isn't exercised here (test runs share the same install root
/// secret); the goal is to catch a regression in the encrypt/decrypt
/// pair or a silent migration of the AES-GCM combined-byte layout.
final class StorageEncryptionTests: XCTestCase {

    // MARK: - Roundtrip

    func test_encryptDecryptData_roundtripsArbitraryBytes() throws {
        let plaintext = Data((0..<256).map { UInt8($0) })
        let combined = try StorageEncryption.encrypt(plaintext)
        let decrypted = try StorageEncryption.decrypt(combined)
        XCTAssertEqual(decrypted, plaintext)
    }

    func test_encryptDecryptString_roundtripsUTF8() throws {
        let original = "received invitation: 2025-Q4 launch · 🎉"
        let combined = try StorageEncryption.encrypt(original)
        let decrypted = try StorageEncryption.decryptString(combined)
        XCTAssertEqual(decrypted, original)
    }

    func test_encryptEmptyData_roundtrips() throws {
        let combined = try StorageEncryption.encrypt(Data())
        let decrypted = try StorageEncryption.decrypt(combined)
        XCTAssertEqual(decrypted, Data())
    }

    // MARK: - Layout

    func test_combinedByteLayout_isNonceCiphertextTag() throws {
        // Empty plaintext → 12B nonce + 0B ciphertext + 16B tag = 28B.
        // Pinning this catches a silent SealedBox.combined format change.
        let combined = try StorageEncryption.encrypt(Data())
        XCTAssertEqual(combined.count, 28)
    }

    func test_eachEncryptCallProducesDistinctCiphertext() throws {
        // Same plaintext + same key → different ciphertext, because
        // AES.GCM seal generates a fresh random nonce per call.
        let plaintext = Data("invitation".utf8)
        let a = try StorageEncryption.encrypt(plaintext)
        let b = try StorageEncryption.encrypt(plaintext)
        XCTAssertNotEqual(a, b, "nonce reuse is the cardinal AES-GCM sin")
    }

    // MARK: - Tampering

    func test_decryptRejectsTamperedCiphertext() throws {
        let plaintext = Data("invitation".utf8)
        var combined = try StorageEncryption.encrypt(plaintext)
        // Flip a bit in the ciphertext (skip past the 12B nonce).
        combined[15] ^= 0x01
        XCTAssertThrowsError(try StorageEncryption.decrypt(combined))
    }

    func test_decryptRejectsTruncatedInput() {
        XCTAssertThrowsError(try StorageEncryption.decrypt(Data([0x00, 0x01, 0x02])))
    }

    // MARK: - Key stability

    func test_storageKey_isStableAcrossCalls() {
        // The cached root secret should produce the same derived key
        // every time within a single install — otherwise persisted
        // ciphertext becomes unreadable across method calls.
        let keyA = StorageEncryption.storageKey
        let keyB = StorageEncryption.storageKey
        let dataA = keyA.withUnsafeBytes { Data($0) }
        let dataB = keyB.withUnsafeBytes { Data($0) }
        XCTAssertEqual(dataA, dataB)
    }
}
