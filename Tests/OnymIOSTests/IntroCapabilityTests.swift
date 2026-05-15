import XCTest
@testable import OnymIOS

/// Wire-format pin for `IntroCapability`. The shape is the contract
/// onym-android already ships — keep it stable. Mirrors
/// `IntroCapabilityTest.kt` test-for-test.
final class IntroCapabilityTests: XCTestCase {

    private let sampleIntroPub = Data(repeating: 0xAA, count: 32)
    private let sampleGroupId = Data(repeating: 0x42, count: 32)

    // MARK: - roundtrip

    func test_roundtrip_minimalShape_preservesAllFields() throws {
        let original = try IntroCapability(
            introPublicKey: sampleIntroPub,
            groupId: sampleGroupId,
            groupName: nil
        )
        let encoded = original.encode()
        let decoded = try IntroCapability.decode(encoded)
        XCTAssertEqual(original, decoded)
    }

    func test_roundtrip_withGroupName_preservesAllFields() throws {
        let original = try IntroCapability(
            introPublicKey: sampleIntroPub,
            groupId: sampleGroupId,
            groupName: "Family"
        )
        let encoded = original.encode()
        let decoded = try IntroCapability.decode(encoded)
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(decoded.groupName, "Family")
    }

    func test_encode_isUrlSafeBase64_noPaddingOrSpecialChars() throws {
        let cap = try IntroCapability(
            introPublicKey: sampleIntroPub,
            groupId: sampleGroupId,
            groupName: "test"
        )
        let encoded = cap.encode()
        XCTAssertFalse(encoded.contains("+"), "no `+` in URL-safe encoding")
        XCTAssertFalse(encoded.contains("/"), "no `/` in URL-safe encoding")
        XCTAssertFalse(encoded.contains("="), "no `=` padding")
        XCTAssertFalse(encoded.contains(where: { $0.isWhitespace }), "no whitespace")
    }

    // MARK: - link forms

    func test_toAppLink_isOnymAppJoinPath() throws {
        let cap = try IntroCapability(
            introPublicKey: sampleIntroPub,
            groupId: sampleGroupId
        )
        XCTAssertTrue(cap.toAppLink().hasPrefix("https://onym.app/join?c="))
    }

    func test_toCustomSchemeLink_isOnymJoinScheme() throws {
        let cap = try IntroCapability(
            introPublicKey: sampleIntroPub,
            groupId: sampleGroupId
        )
        XCTAssertTrue(cap.toCustomSchemeLink().hasPrefix("onym://join?c="))
    }

    // MARK: - fromLink

    func test_fromLink_appLinkForm_decodesBackToOriginal() throws {
        let original = try IntroCapability(
            introPublicKey: sampleIntroPub,
            groupId: sampleGroupId,
            groupName: "Crew"
        )
        let parsed = IntroCapability.fromLink(original.toAppLink())
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed, original)
    }

    func test_fromLink_customSchemeForm_decodesBackToOriginal() throws {
        let original = try IntroCapability(
            introPublicKey: sampleIntroPub,
            groupId: sampleGroupId,
            groupName: "Crew"
        )
        let parsed = IntroCapability.fromLink(original.toCustomSchemeLink())
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed, original)
    }

    func test_fromLink_extraQueryParams_returnsCapability_ignoringExtras() throws {
        // Future schemas may grow tracking params (utm_*, etc.) — the
        // parser must pluck `c=` and ignore the rest.
        let cap = try IntroCapability(
            introPublicKey: sampleIntroPub,
            groupId: sampleGroupId,
            groupName: "X"
        )
        let link = "\(cap.toAppLink())&utm_source=share-sheet&ref=foo"
        let parsed = IntroCapability.fromLink(link)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed, cap)
    }

    func test_fromLink_missingCapabilityParam_returnsNull() {
        XCTAssertNil(IntroCapability.fromLink("https://onym.app/join"))
        XCTAssertNil(IntroCapability.fromLink("https://onym.app/join?other=value"))
    }

    func test_fromLink_malformedUri_returnsNull() {
        XCTAssertNil(IntroCapability.fromLink("not a url"))
        XCTAssertNil(IntroCapability.fromLink(""))
    }

    // MARK: - decode failure modes

    func test_decode_invalidBase64_throwsInvalidIntroCapability() {
        XCTAssertThrowsError(try IntroCapability.decode("@@@not-base64@@@")) { error in
            guard let err = error as? InvalidIntroCapability else {
                return XCTFail("expected InvalidIntroCapability, got \(error)")
            }
            if case .base64 = err { /* ok */ } else {
                XCTFail("expected .base64 case, got \(err)")
            }
        }
    }

    func test_decode_validBase64_butNotJson_throwsInvalidIntroCapability() {
        let notJson = Self.urlSafeBase64("not json at all".data(using: .utf8)!)
        XCTAssertThrowsError(try IntroCapability.decode(notJson)) { error in
            XCTAssertTrue(error is InvalidIntroCapability)
        }
    }

    func test_decode_validJson_butWrongPubkeySize_throwsInvalidIntroCapability() {
        let badShape = #"{"intro_pub":"AAA=","group_id":"AAA="}"#
        let encoded = Self.urlSafeBase64(badShape.data(using: .utf8)!)
        XCTAssertThrowsError(try IntroCapability.decode(encoded)) { error in
            guard let err = error as? InvalidIntroCapability else {
                return XCTFail("expected InvalidIntroCapability, got \(error)")
            }
            if case .shape = err { /* ok */ } else {
                XCTFail("expected .shape case, got \(err)")
            }
        }
    }

    // MARK: - constructor

    func test_constructor_rejectsWrongSizedKeys() {
        XCTAssertThrowsError(try IntroCapability(
            introPublicKey: Data(repeating: 0, count: 31),
            groupId: sampleGroupId
        )) { error in
            XCTAssertTrue(error is InvalidIntroCapability)
        }
        XCTAssertThrowsError(try IntroCapability(
            introPublicKey: sampleIntroPub,
            groupId: Data(repeating: 0, count: 33)
        )) { error in
            XCTAssertTrue(error is InvalidIntroCapability)
        }
    }

    // MARK: - shareText

    func test_shareText_includesGroupName_whenSet() throws {
        let cap = try IntroCapability(
            introPublicKey: sampleIntroPub,
            groupId: sampleGroupId,
            groupName: "Friends"
        )
        let text = IntroCapability.shareText(link: cap.toAppLink(), groupName: cap.groupName)
        XCTAssertTrue(text.contains("\"Friends\""))
        XCTAssertTrue(text.contains("https://onym.app/join?c="))
    }

    func test_shareText_omitsGroupName_whenBlankOrNull() throws {
        let cap = try IntroCapability(
            introPublicKey: sampleIntroPub,
            groupId: sampleGroupId
        )
        let text = IntroCapability.shareText(link: cap.toAppLink(), groupName: cap.groupName)
        XCTAssertFalse(text.contains("\""), "no quoted name when nil")
        XCTAssertTrue(text.contains("Join my chat"))
    }

    // MARK: - byte-level

    func test_roundtrip_byteForByteIntroPub_isPreserved() throws {
        // Random-ish bytes — base64+JSON+base64 must not mutate any
        // byte position.
        let pub = Data((0..<32).map { UInt8(($0 * 7 + 13) & 0xFF) })
        let gid = Data((0..<32).map { UInt8(($0 * 11 + 3) & 0xFF) })
        let cap = try IntroCapability(introPublicKey: pub, groupId: gid, groupName: "X")
        let decoded = try IntroCapability.decode(cap.encode())
        XCTAssertEqual(decoded.introPublicKey, pub)
        XCTAssertEqual(decoded.groupId, gid)
    }

    // MARK: - Helpers

    private static func urlSafeBase64(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }
}
