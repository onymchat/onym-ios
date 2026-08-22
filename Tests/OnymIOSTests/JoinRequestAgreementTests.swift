import XCTest
import CryptoKit
@testable import OnymIOS
@testable import OnymGroup

/// What the founder is told about a request, decided in
/// `JoinRequestApprover` against the group's own copy of the rules.
///
/// Five verdicts rather than a Bool, and each of them has a different
/// answer to "what should I do about this", so each gets a case here.
final class JoinRequestAgreementTests: XCTestCase {

    private let groupID = Data(repeating: 0x11, count: 32)
    private let rules = "Be kind. No links."

    func test_noRules_asksForNothing() throws {
        let joiner = Curve25519.Signing.PrivateKey()
        XCTAssertEqual(
            JoinRequestApprover.agreement(
                for: try request(signedBy: joiner, over: nil),
                rules: nil
            ),
            .notRequired
        )
    }

    func test_blankRules_alsoAskForNothing() throws {
        // A group whose rules are whitespace has none, and must not
        // report every joiner as having failed to sign.
        let joiner = Curve25519.Signing.PrivateKey()
        XCTAssertEqual(
            JoinRequestApprover.agreement(
                for: try request(signedBy: joiner, over: nil),
                rules: "   \n "
            ),
            .notRequired
        )
    }

    func test_signedTheseRules_readsAsAgreed() throws {
        let joiner = Curve25519.Signing.PrivateKey()
        XCTAssertEqual(
            JoinRequestApprover.agreement(
                for: try request(signedBy: joiner, over: rules),
                rules: rules
            ),
            .agreed
        )
    }

    func test_anOlderClient_readsAsNotSigned() throws {
        // Nothing came. The founder's move is to ask them to update,
        // which is different from every other failing case.
        let joiner = Curve25519.Signing.PrivateKey()
        XCTAssertEqual(
            JoinRequestApprover.agreement(
                for: try request(signedBy: joiner, over: nil),
                rules: rules
            ),
            .notSigned
        )
    }

    func test_signedRulesWeDoNotHold_readsAsUnknownRatherThanAsAgreement() throws {
        // Nothing here verifies what they signed — we have no copy of
        // it — so the verdict says that rather than crediting them with
        // an agreement.
        let joiner = Curve25519.Signing.PrivateKey()
        XCTAssertEqual(
            JoinRequestApprover.agreement(
                for: try request(signedBy: joiner, over: "Be kind."),
                rules: rules
            ),
            .unknownRules
        )
    }

    func test_randomBytes_cannotBuyTheSofterVerdict() throws {
        // The reason the case was renamed. Sixty-four random bytes with
        // a random hash land here, and "unknown" is the only honest
        // reading: the sole thing distinguishing this from `.invalid`
        // is a hash the sender chose. It must not read as agreement,
        // and the cell renders it neutrally rather than reassuringly.
        let joiner = Curve25519.Signing.PrivateKey()
        let noise = try JoinRequestPayload(
            joinerInboxPublicKey: Data(repeating: 0xAA, count: 32),
            joinerBlsPublicKey: nil,
            joinerLeafHash: nil,
            joinerSendingPublicKey: joiner.publicKey.rawRepresentation,
            joinerDisplayLabel: "Bob",
            groupId: groupID,
            rulesHash: Data(repeating: 0x9E, count: 32),
            rulesSignature: Data(repeating: 0x9E, count: 64)
        )
        XCTAssertEqual(JoinRequestApprover.agreement(for: noise, rules: rules), .unknownRules)
    }

    // MARK: - The retained proof

    func test_theRetainedTextIsWhatMakesTheStoredSignatureCheckable() {
        // A hash beside a live `invitationMessage` proves that
        // something was agreed and never what. The member carries the
        // text, so the question stays answerable after the group's
        // rules move on.
        let joiner = Curve25519.Signing.PrivateKey()
        let profile = MemberProfile(
            alias: "Bob",
            inboxPublicKey: Data(repeating: 0xAA, count: 32),
            sendingPubkey: joiner.publicKey.rawRepresentation,
            rulesHash: GroupRules.hash(rules),
            rulesSignature: try! signature(of: joiner, over: rules),
            rulesText: rules
        )
        XCTAssertTrue(profile.agreedToRules(groupID: groupID))
    }

    func test_aProfileWithNoRetainedText_provesNothing() {
        let joiner = Curve25519.Signing.PrivateKey()
        let profile = MemberProfile(
            alias: "Bob",
            inboxPublicKey: Data(repeating: 0xAA, count: 32),
            sendingPubkey: joiner.publicKey.rawRepresentation,
            rulesHash: GroupRules.hash(rules),
            rulesSignature: try! signature(of: joiner, over: rules),
            rulesText: nil
        )
        XCTAssertFalse(profile.agreedToRules(groupID: groupID))
    }

    func test_malformedAgreementBytes_becomeNoAgreementNotABrokenProfile() {
        // Dropping the evidence must not cost the member their inbox
        // and verification keys: the rest of the profile survives.
        let profile = MemberProfile(
            alias: "Bob",
            inboxPublicKey: Data(repeating: 0xAA, count: 32),
            sendingPubkey: Data(repeating: 0xEE, count: 32),
            rulesHash: Data(repeating: 0x33, count: 31),
            rulesSignature: Data(repeating: 0x55, count: 64),
            rulesText: rules
        )
        XCTAssertNil(profile.rulesHash)
        XCTAssertNil(profile.rulesSignature)
        XCTAssertNil(profile.rulesText, "text without the bytes it covers proves nothing")
        XCTAssertEqual(profile.alias, "Bob")
        XCTAssertEqual(profile.sendingPubkey.count, 32)
    }

    func test_theAgreementRidesTheAnnouncement() throws {
        // Without this the claim "any member can verify" is only true
        // of the founder who admitted them: everyone else rebuilds the
        // profile from the announcement.
        let joiner = Curve25519.Signing.PrivateKey()
        let announced = try MemberAnnouncementPayload.AnnouncedMember(
            blsPub: Data(repeating: 0xCC, count: 48),
            inboxPub: Data(repeating: 0xAA, count: 32),
            alias: "Bob",
            sendingPub: joiner.publicKey.rawRepresentation,
            rulesHash: GroupRules.hash(rules),
            rulesSignature: try signature(of: joiner, over: rules),
            rulesText: rules
        )
        let decoded = try JSONDecoder().decode(
            MemberAnnouncementPayload.AnnouncedMember.self,
            from: JSONEncoder().encode(announced)
        )
        XCTAssertEqual(decoded.rulesText, rules)
        let rebuilt = MemberProfile(
            alias: decoded.alias,
            inboxPublicKey: decoded.inboxPub,
            sendingPubkey: decoded.sendingPub,
            rulesHash: decoded.rulesHash,
            rulesSignature: decoded.rulesSignature,
            rulesText: decoded.rulesText
        )
        XCTAssertTrue(rebuilt.agreedToRules(groupID: groupID))
    }

    func test_anAnnouncementFromAnOlderBuild_carriesNoAgreement() throws {
        let legacy = """
        {"bls_pub":"\(Data(repeating: 0xCC, count: 48).base64EncodedString())",\
        "inbox_pub":"\(Data(repeating: 0xAA, count: 32).base64EncodedString())",\
        "alias":"Bob",\
        "sending_pub":"\(Data(repeating: 0xEE, count: 32).base64EncodedString())"}
        """
        let decoded = try JSONDecoder().decode(
            MemberAnnouncementPayload.AnnouncedMember.self,
            from: Data(legacy.utf8)
        )
        XCTAssertNil(decoded.rulesSignature)
        XCTAssertNil(decoded.rulesText)
    }

    func test_aSignatureThatDoesNotVerify_readsAsInvalid() throws {
        // Claims our exact rules and fails against them: neither an old
        // client nor a stale version, and the only verdict that should
        // give a founder pause about the request itself.
        let joiner = Curve25519.Signing.PrivateKey()
        let forged = try JoinRequestPayload(
            joinerInboxPublicKey: Data(repeating: 0xAA, count: 32),
            joinerBlsPublicKey: nil,
            joinerLeafHash: nil,
            joinerSendingPublicKey: joiner.publicKey.rawRepresentation,
            joinerDisplayLabel: "Bob",
            groupId: groupID,
            rulesHash: GroupRules.hash(rules),
            rulesSignature: Data(repeating: 0x00, count: 64)
        )
        XCTAssertEqual(
            JoinRequestApprover.agreement(for: forged, rules: rules),
            .invalid
        )
    }

    func test_aStolenSignature_doesNotPassAsTheSenderOwn() throws {
        // Someone else's valid signature over the right rules, shipped
        // under this joiner's key. Verification names the signer inside
        // the signed bytes, so it fails — and because the hash matches,
        // it fails loudly as `.invalid` rather than as a stale version.
        let signer = Curve25519.Signing.PrivateKey()
        let sender = Curve25519.Signing.PrivateKey()
        let stolen = try signature(of: signer, over: rules)
        let payload = try JoinRequestPayload(
            joinerInboxPublicKey: Data(repeating: 0xAA, count: 32),
            joinerBlsPublicKey: nil,
            joinerLeafHash: nil,
            joinerSendingPublicKey: sender.publicKey.rawRepresentation,
            joinerDisplayLabel: "Bob",
            groupId: groupID,
            rulesHash: GroupRules.hash(rules),
            rulesSignature: stolen
        )
        XCTAssertEqual(JoinRequestApprover.agreement(for: payload, rules: rules), .invalid)
    }

    func test_anHonestHashOverDishonestBytes_isNotEnough() throws {
        // Verification runs against *our* rules, never against the hash
        // the joiner sent — otherwise a joiner could choose the text
        // their own signature is checked against.
        let joiner = Curve25519.Signing.PrivateKey()
        let ownTerms = "Anything goes."
        let payload = try JoinRequestPayload(
            joinerInboxPublicKey: Data(repeating: 0xAA, count: 32),
            joinerBlsPublicKey: nil,
            joinerLeafHash: nil,
            joinerSendingPublicKey: joiner.publicKey.rawRepresentation,
            joinerDisplayLabel: "Bob",
            groupId: groupID,
            // A hash of their own terms, and a signature that genuinely
            // covers those terms. Self-consistent, and still not
            // agreement to this group's rules.
            rulesHash: GroupRules.hash(ownTerms),
            rulesSignature: try signature(of: joiner, over: ownTerms)
        )
        XCTAssertEqual(
            JoinRequestApprover.agreement(for: payload, rules: rules),
            .unknownRules
        )
    }

    // MARK: - Helpers

    private func request(
        signedBy joiner: Curve25519.Signing.PrivateKey,
        over rules: String?
    ) throws -> JoinRequestPayload {
        try JoinRequestPayload(
            joinerInboxPublicKey: Data(repeating: 0xAA, count: 32),
            joinerBlsPublicKey: nil,
            joinerLeafHash: nil,
            joinerSendingPublicKey: joiner.publicKey.rawRepresentation,
            joinerDisplayLabel: "Bob",
            groupId: groupID,
            rulesHash: rules.map { GroupRules.hash($0) },
            rulesSignature: try rules.map { try signature(of: joiner, over: $0) }
        )
    }

    private func signature(
        of key: Curve25519.Signing.PrivateKey,
        over rules: String
    ) throws -> Data {
        try key.signature(for: GroupRules.statement(
            groupID: groupID,
            rulesHash: GroupRules.hash(rules),
            joinerSendingPublicKey: key.publicKey.rawRepresentation
        ))
    }
}
