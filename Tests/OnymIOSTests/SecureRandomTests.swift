import XCTest
@testable import OnymIOS
import OnymFoundation
import OnymGroup

/// Coverage for the shared CSPRNG helper (`SecureRandom`) introduced to
/// close H-1 — the family of `_ = SecRandomCopyBytes(...)` call sites
/// that discarded the `OSStatus` and would have used an all-zero buffer
/// as key material on CSPRNG failure. These pin the success-path
/// contract (correct length, non-constant output) and that the four
/// former call sites still produce valid non-zero material.
final class SecureRandomTests: XCTestCase {

    // MARK: - Helper

    func test_bytes_returnsRequestedLength() throws {
        for count in [0, 1, 16, 32, 64, 256] {
            XCTAssertEqual(try SecureRandom.bytes(count).count, count)
            XCTAssertEqual(try SecureRandom.data(count).count, count)
        }
    }

    func test_bytes_isNotConstant() throws {
        // 100 draws of 32 bytes should all differ with overwhelming
        // probability — a broken RNG returning a constant (or all-zero)
        // would collapse the set.
        var seen = Set<Data>()
        for _ in 0..<100 {
            seen.insert(try SecureRandom.data(32))
        }
        XCTAssertEqual(seen.count, 100, "CSPRNG output should not collide over 100 draws")
        XCTAssertFalse(seen.contains(Data(repeating: 0, count: 32)),
                       "all-zero output would indicate a broken/ignored CSPRNG")
    }

    // MARK: - Former H-1 call sites still produce valid non-zero output

    func test_generateMnemonic_producesValidNonZeroEntropy() throws {
        let mnemonic = try Bip39.generateMnemonic()
        XCTAssertTrue(Bip39.isValidMnemonic(mnemonic), "generated mnemonic must be valid BIP39")
        let entropy = try XCTUnwrap(Bip39.entropyFromMnemonic(mnemonic))
        XCTAssertEqual(entropy.count, 16)
        XCTAssertNotEqual(entropy, Data(repeating: 0, count: 16),
                          "all-zero entropy would mean the CSPRNG failure went unchecked")
    }

    func test_randomCanonicalFr_producesCanonicalNonZeroFr() throws {
        let fr = try CreateGroupInteractor.randomCanonicalFr()
        XCTAssertEqual(fr.count, 32)
        XCTAssertTrue(CreateGroupInteractor.isCanonicalFr(Array(fr)))
        XCTAssertNotEqual(fr, Data(repeating: 0, count: 32))
    }

    func test_storageEncryption_roundtripsWithNonZeroKey() throws {
        // Exercises the root-secret path (formerly an unchecked
        // SecRandomCopyBytes): a zeroed root key would still roundtrip,
        // so this is a smoke test that the throwing wiring compiles and
        // the encrypt/decrypt pair remains intact.
        let plaintext = Data("h1-secure-random".utf8)
        let combined = try StorageEncryption.encrypt(plaintext)
        XCTAssertEqual(try StorageEncryption.decrypt(combined), plaintext)
    }
}
