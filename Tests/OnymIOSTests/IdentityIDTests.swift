import XCTest
@testable import OnymIOS
import OnymFoundation
import OnymIdentity

final class IdentityIDTests: XCTestCase {
    func test_init_default_generatesDistinctIDs() {
        let a = IdentityID()
        let b = IdentityID()
        XCTAssertNotEqual(a, b, "default init must mint a fresh UUID each time")
    }

    func test_init_fromString_acceptsValidUUID() {
        let uuid = UUID()
        let id = IdentityID(uuid.uuidString)
        XCTAssertEqual(id?.rawValue, uuid)
    }

    func test_init_fromString_rejectsNonUUID() {
        XCTAssertNil(IdentityID("not-a-uuid"))
        XCTAssertNil(IdentityID(""))
        XCTAssertNil(IdentityID("12345"))
    }

    func test_codable_roundTripsAsUUIDString() throws {
        let id = IdentityID()
        let encoded = try JSONEncoder().encode(id)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertEqual(json, "\"\(id.rawValue.uuidString)\"",
                       "Codable must round-trip as a JSON string for keychain-suffix readability")
        let decoded = try JSONDecoder().decode(IdentityID.self, from: encoded)
        XCTAssertEqual(decoded, id)
    }

    func test_codable_rejectsNonUUIDPayload() {
        let bogus = #""not-a-uuid""#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(IdentityID.self, from: bogus))
    }

    func test_description_isUUIDString() {
        let uuid = UUID()
        let id = IdentityID(uuid)
        XCTAssertEqual(id.description, uuid.uuidString)
    }

    func test_hashable_isStableAcrossInits() {
        let uuid = UUID()
        let a = IdentityID(uuid)
        let b = IdentityID(uuid)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    // MARK: - Derivation from entropy

    /// The whole point: a recovery phrase that produced identity A must
    /// keep producing identity A. Chats and messages are owner-scoped, so
    /// an ID that changes on import is an archive nobody can see.
    func test_derivedFromEntropy_sameEntropyGivesSameID() {
        let entropy = Bip39.entropyFromMnemonic(Self.canonicalMnemonic)!

        XCTAssertEqual(
            IdentityID(derivedFromEntropy: entropy),
            IdentityID(derivedFromEntropy: entropy),
            "the same recovery phrase must always name the same identity"
        )
    }

    func test_derivedFromEntropy_differentEntropyGivesDifferentID() {
        let a = Bip39.entropyFromMnemonic(Self.canonicalMnemonic)!
        let b = Bip39.entropyFromMnemonic(Self.otherMnemonic)!

        XCTAssertNotEqual(
            IdentityID(derivedFromEntropy: a),
            IdentityID(derivedFromEntropy: b),
            "two identities must not collide onto one keychain slot"
        )
    }

    /// A one-bit change in the entropy must not leave the ID recognisably
    /// close to the original — the ID lands in plaintext SwiftData rows,
    /// and "adjacent seeds look adjacent" would make it a hint about the
    /// key material it shares a root with.
    func test_derivedFromEntropy_oneBitFlipChangesID() {
        var entropy = Bip39.entropyFromMnemonic(Self.canonicalMnemonic)!
        let original = IdentityID(derivedFromEntropy: entropy)
        entropy[0] ^= 0x01

        XCTAssertNotEqual(original, IdentityID(derivedFromEntropy: entropy))
    }

    /// `IdentityID` is reconstructed from a keychain service suffix
    /// (`app.onym.ios.identity.<uuidString>`) and from persisted
    /// `ChatGroup` rows via `UUID(uuidString:)`. A derived value that is
    /// not a well-formed UUID would fail to parse a long way from here, so
    /// assert the round trip rather than trusting the bit-twiddling.
    func test_derivedFromEntropy_isWellFormedUUIDAndSurvivesStringRoundTrip() throws {
        let entropy = Bip39.entropyFromMnemonic(Self.canonicalMnemonic)!
        let id = IdentityID(derivedFromEntropy: entropy)

        let string = id.rawValue.uuidString
        let reparsed = try XCTUnwrap(
            IdentityID(string),
            "derived ID must survive the keychain-suffix / ChatGroup-row round trip"
        )
        XCTAssertEqual(reparsed, id)

        // Version 4 + RFC 4122 variant, so a derived ID is indistinguishable
        // from a random one everywhere it is stored or printed.
        let bytes = withUnsafeBytes(of: id.rawValue.uuid) { [UInt8]($0) }
        XCTAssertEqual(bytes[6] & 0xF0, 0x40, "version nibble must say 4")
        XCTAssertEqual(bytes[8] & 0xC0, 0x80, "variant bits must say RFC 4122")
    }

    /// **Derivation fixture.** Pins the `identity-id-v1` HKDF label and the
    /// `app.onym.bip39` salt against the canonical BIP39 test vector.
    /// Changing either silently would orphan every identity already minted
    /// under the old label — the same invisible-chats failure this
    /// derivation exists to fix. Break loudly instead.
    ///
    /// onym-android must reproduce this exact value from this exact phrase
    /// for a cross-platform restore to show anything.
    func test_derivedFromEntropy_matchesFixture() {
        let entropy = Bip39.entropyFromMnemonic(Self.canonicalMnemonic)!

        XCTAssertEqual(
            IdentityID(derivedFromEntropy: entropy).description,
            Self.canonicalDerivedID
        )
    }

    private static let canonicalMnemonic =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    private static let otherMnemonic =
        "legal winner thank year wave sausage worth useful legal winner thank yellow"
    private static let canonicalDerivedID = "59B0B267-F746-46B7-AD6C-31863606156F"
}
