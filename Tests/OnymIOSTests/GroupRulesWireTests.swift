import XCTest
import CryptoKit
@testable import OnymIOS
@testable import OnymGroup

/// The two wire shapes that carry rules and the agreement to them:
/// the link a joiner opens, and the request they send back.
final class GroupRulesWireTests: XCTestCase {

    private let introPub = Data(repeating: 0x44, count: 32)
    private let groupID = Data(repeating: 0x11, count: 32)

    // MARK: - IntroCapability

    func test_link_carriesTheRulesThroughEncodeAndDecode() throws {
        let capability = try IntroCapability(
            introPublicKey: introPub,
            groupId: groupID,
            groupName: "Maple Garden",
            rules: "Be kind."
        )
        let decoded = try XCTUnwrap(IntroCapability.fromLink(capability.toAppLink()))
        XCTAssertEqual(decoded.rules, "Be kind.")
        XCTAssertEqual(decoded, capability)
    }

    func test_link_usesTheAgreedJSONKey() throws {
        // The wire shape is a documented byte-for-byte contract with
        // Android; the key name is the contract.
        let capability = try IntroCapability(
            introPublicKey: introPub,
            groupId: groupID,
            rules: "Be kind."
        )
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(capability)
        ) as? [String: Any]
        XCTAssertEqual(json?["rules"] as? String, "Be kind.")
    }

    func test_link_omitsRulesEntirelyWhenThereAreNone() throws {
        // Not `"rules": null`: Android encodes with defaults off, and a
        // group that asks nothing should cost the link nothing.
        let capability = try IntroCapability(introPublicKey: introPub, groupId: groupID)
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(capability)
        ) as? [String: Any]
        XCTAssertNil(json?.index(forKey: "rules"))
    }

    func test_aLinkFromAnOlderBuild_hasNoRules() throws {
        // Forward compatibility in the direction that matters: a link
        // minted before rules existed still opens.
        let legacy = """
        {"intro_pub":"\(introPub.base64EncodedString())",\
        "group_id":"\(groupID.base64EncodedString())","group_name":"Maple Garden"}
        """
        let decoded = try IntroCapability.decode(urlSafe(Data(legacy.utf8)))
        XCTAssertNil(decoded.rules)
    }

    func test_blankRules_areTheSameAsNoRules() throws {
        let capability = try IntroCapability(
            introPublicKey: introPub,
            groupId: groupID,
            rules: "   \n "
        )
        XCTAssertNil(capability.rules, "an empty string must not become a thing to sign")
    }

    func test_rulesAtTheByteCap_areAccepted() throws {
        let capability = try IntroCapability(
            introPublicKey: introPub,
            groupId: groupID,
            rules: String(repeating: "x", count: GroupRules.maxBytes)
        )
        XCTAssertEqual(capability.rules?.utf8.count, GroupRules.maxBytes)
    }

    func test_overLongRules_areRejectedRatherThanTruncated() {
        // Truncating would have someone sign rules ending mid-sentence.
        XCTAssertThrowsError(
            try IntroCapability(
                introPublicKey: introPub,
                groupId: groupID,
                rules: String(repeating: "x", count: GroupRules.maxBytes + 1)
            )
        )
    }

    func test_overLongRulesArrivingOnTheWire_areRejectedToo() throws {
        // The mint-time cap is not a defence on its own: the decode side
        // is where a hostile link lands.
        let payload = """
        {"intro_pub":"\(introPub.base64EncodedString())",\
        "group_id":"\(groupID.base64EncodedString())",\
        "rules":"\(String(repeating: "x", count: GroupRules.maxBytes + 1))"}
        """
        XCTAssertThrowsError(try IntroCapability.decode(urlSafe(Data(payload.utf8))))
    }

    /// Byte-mode capacity at correction level M — what `SettingsQRCode`
    /// renders at, and the only reason `GroupRules.maxLength` has the
    /// value it has.
    private let qrCapacityAtLevelM = 2331

    func test_theCappedLinkFitsAQRCode() throws {
        // Assert the property the cap exists for, not the arithmetic
        // behind it. Three UTF-8 bytes per rules character is the case
        // that decides the cap.
        let capability = try IntroCapability(
            introPublicKey: introPub,
            groupId: groupID,
            groupName: "Maple Garden",
            rules: String(repeating: "則", count: GroupRules.maxBytes / 3)
        )
        XCTAssertLessThanOrEqual(capability.toAppLink().utf8.count, qrCapacityAtLevelM)
    }

    func test_theWorstCaseNameAndRulesTogether_overrunTheQRCode() throws {
        // Pinned as a known limit rather than a passing claim. The cap
        // bounds the rules; nothing bounds the group name, and three-
        // byte characters in both at once clear the ceiling — a
        // 30-character CJK name alongside full CJK rules already does.
        //
        // The failure is soft: `CIQRCodeGenerator` yields no image and
        // the link stays copyable. This test exists so that raising
        // `maxLength`, or capping the name, starts from a measured
        // boundary instead of a guess.
        let capability = try IntroCapability(
            introPublicKey: introPub,
            groupId: groupID,
            groupName: String(repeating: "名", count: 30),
            rules: String(repeating: "則", count: GroupRules.maxBytes / 3)
        )
        XCTAssertGreaterThan(capability.toAppLink().utf8.count, qrCapacityAtLevelM)
    }

    // MARK: - JoinRequestPayload

    func test_request_carriesTheAgreementThroughARoundTrip() throws {
        let payload = try makeRequest(
            rulesHash: Data(repeating: 0x33, count: 32),
            rulesSignature: Data(repeating: 0x55, count: 64)
        )
        let decoded = try JSONDecoder().decode(
            JoinRequestPayload.self,
            from: JSONEncoder().encode(payload)
        )
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.rulesSignature?.count, 64)
    }

    func test_aRequestFromAnOlderBuild_decodesWithNoAgreement() throws {
        let legacy = """
        {"joiner_inbox_pub":"\(Data(repeating: 0xAA, count: 32).base64EncodedString())",\
        "joiner_sending_pub":"\(Data(repeating: 0xEE, count: 32).base64EncodedString())",\
        "joiner_display_label":"Bob",\
        "group_id":"\(groupID.base64EncodedString())"}
        """
        let decoded = try JSONDecoder().decode(
            JoinRequestPayload.self,
            from: Data(legacy.utf8)
        )
        XCTAssertNil(decoded.rulesSignature)
        XCTAssertNil(decoded.rulesHash)
    }

    func test_halfAnAgreement_isRejected() throws {
        // A signature with nothing naming what it covers can't be
        // checked; a hash with no signature is a claim, not a proof.
        XCTAssertThrowsError(
            try makeRequest(rulesHash: Data(repeating: 0x33, count: 32), rulesSignature: nil)
        )
        XCTAssertThrowsError(
            try makeRequest(rulesHash: nil, rulesSignature: Data(repeating: 0x55, count: 64))
        )
    }

    func test_wrongSizedAgreementBytes_areRejected() throws {
        XCTAssertThrowsError(
            try makeRequest(
                rulesHash: Data(repeating: 0x33, count: 31),
                rulesSignature: Data(repeating: 0x55, count: 64)
            )
        )
        XCTAssertThrowsError(
            try makeRequest(
                rulesHash: Data(repeating: 0x33, count: 32),
                rulesSignature: Data(repeating: 0x55, count: 63)
            )
        )
    }

    // MARK: - Helpers

    private func makeRequest(
        rulesHash: Data?,
        rulesSignature: Data?
    ) throws -> JoinRequestPayload {
        try JoinRequestPayload(
            joinerInboxPublicKey: Data(repeating: 0xAA, count: 32),
            joinerBlsPublicKey: nil,
            joinerLeafHash: nil,
            joinerSendingPublicKey: Data(repeating: 0xEE, count: 32),
            joinerDisplayLabel: "Bob",
            groupId: groupID,
            rulesHash: rulesHash,
            rulesSignature: rulesSignature
        )
    }

    private func urlSafe(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }
}
