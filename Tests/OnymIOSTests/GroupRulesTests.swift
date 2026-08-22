import XCTest
import CryptoKit
@testable import OnymIOS
import OnymGroup

/// The agreement itself: what the signature covers, and what it must
/// refuse to cover.
///
/// The negative cases carry the weight here. A signature that verifies
/// is one property; a signature that keeps verifying after the group,
/// the signer, or a comma has changed would make the whole thing
/// decorative.
final class GroupRulesTests: XCTestCase {

    private let groupID = Data(repeating: 0x11, count: 32)
    private let otherGroupID = Data(repeating: 0x22, count: 32)
    private let rules = "Be kind. No links. Ask before adding anyone."

    // MARK: - Canonicalization

    func test_canonical_trimsTheEndsAndNothingElse() {
        // Inner shape is the founder's, and a joiner is agreeing to it:
        // collapsing runs or normalising case would mean signing
        // something other than what was displayed.
        let messy = "  Rule one.\n\n  Rule  two.   \n"
        XCTAssertEqual(GroupRules.canonical(messy), "Rule one.\n\n  Rule  two.")
    }

    func test_normalized_treatsBlankAsNoRules() {
        // A group asking nothing must not acquire an empty string to
        // sign — that would make every joiner tick a box about nothing.
        XCTAssertNil(GroupRules.normalized(nil))
        XCTAssertNil(GroupRules.normalized(""))
        XCTAssertNil(GroupRules.normalized("   \n\t "))
        XCTAssertEqual(GroupRules.normalized("  hi  "), "hi")
    }

    func test_hash_ignoresTheWhitespaceCanonicalizationRemoves() {
        // Both sides hash through `canonical`, so a trailing newline
        // out of a text field can't make agreement fail on a character
        // nobody can see.
        XCTAssertEqual(GroupRules.hash(rules), GroupRules.hash("\n\(rules)  "))
    }

    func test_hash_isSensitiveToTheTextItself() {
        XCTAssertNotEqual(GroupRules.hash(rules), GroupRules.hash(rules + "."))
    }

    // MARK: - The statement

    func test_statement_isDomainSeparated() {
        let statement = GroupRules.statement(
            groupID: groupID,
            rulesHash: GroupRules.hash(rules),
            joinerSendingPublicKey: Data(repeating: 0xEE, count: 32)
        )
        XCTAssertTrue(
            statement.starts(with: Data("onym-group-rules-v1".utf8)),
            "without the domain prefix this signature is replayable as any other this key makes"
        )
        // Domain + three fixed-length fields, which is what makes the
        // concatenation unambiguous without length prefixes.
        XCTAssertEqual(statement.count, "onym-group-rules-v1".utf8.count + 32 + 32 + 32)
    }

    // MARK: - Verification

    func test_agreement_verifiesForTheJoinerWhoSignedTheseRules() {
        let joiner = Curve25519.Signing.PrivateKey()
        XCTAssertTrue(
            GroupRules.isAgreement(
                signature: sign(rules, as: joiner, group: groupID),
                rules: rules,
                groupID: groupID,
                joinerSendingPublicKey: joiner.publicKey.rawRepresentation
            )
        )
    }

    func test_agreement_survivesTheTrimmingThatCanonicalizationDoes() {
        // The founder's stored copy and the copy that travelled in a
        // link can differ by a trailing newline and still be the same
        // rules.
        let joiner = Curve25519.Signing.PrivateKey()
        XCTAssertTrue(
            GroupRules.isAgreement(
                signature: sign("\(rules)\n", as: joiner, group: groupID),
                rules: rules,
                groupID: groupID,
                joinerSendingPublicKey: joiner.publicKey.rawRepresentation
            )
        )
    }

    func test_agreement_failsWhenTheRulesChanged() {
        // The point of hashing the text: editing a rule invalidates
        // every agreement made to the old wording, rather than silently
        // extending them to words nobody accepted.
        let joiner = Curve25519.Signing.PrivateKey()
        XCTAssertFalse(
            GroupRules.isAgreement(
                signature: sign(rules, as: joiner, group: groupID),
                rules: "\(rules) And no photos.",
                groupID: groupID,
                joinerSendingPublicKey: joiner.publicKey.rawRepresentation
            )
        )
    }

    func test_agreement_doesNotTransferToAnotherGroupWithTheSameRules() {
        // Two groups can adopt identical text. Without `group_id` in the
        // statement, an acceptance collected by the permissive one would
        // be presentable as agreement to the strict one.
        let joiner = Curve25519.Signing.PrivateKey()
        XCTAssertFalse(
            GroupRules.isAgreement(
                signature: sign(rules, as: joiner, group: groupID),
                rules: rules,
                groupID: otherGroupID,
                joinerSendingPublicKey: joiner.publicKey.rawRepresentation
            )
        )
    }

    func test_agreement_cannotBeReattributedToAnotherJoiner() {
        // The signer is named inside the signed bytes, so a signature
        // lifted from one request can't be presented as someone else's.
        let signer = Curve25519.Signing.PrivateKey()
        let bystander = Curve25519.Signing.PrivateKey()
        XCTAssertFalse(
            GroupRules.isAgreement(
                signature: sign(rules, as: signer, group: groupID),
                rules: rules,
                groupID: groupID,
                joinerSendingPublicKey: bystander.publicKey.rawRepresentation
            )
        )
    }

    func test_agreement_refusesGarbageRatherThanThrowing() {
        // A malformed key or signature is a "no", not a crash: both
        // arrive over the wire from a stranger.
        let joiner = Curve25519.Signing.PrivateKey()
        XCTAssertFalse(
            GroupRules.isAgreement(
                signature: Data(repeating: 0x00, count: 64),
                rules: rules,
                groupID: groupID,
                joinerSendingPublicKey: joiner.publicKey.rawRepresentation
            )
        )
        XCTAssertFalse(
            GroupRules.isAgreement(
                signature: sign(rules, as: joiner, group: groupID),
                rules: rules,
                groupID: groupID,
                joinerSendingPublicKey: Data([0x01, 0x02])
            )
        )
    }

    // MARK: - Helpers

    private func sign(
        _ rules: String,
        as key: Curve25519.Signing.PrivateKey,
        group: Data
    ) -> Data {
        try! key.signature(for: GroupRules.statement(
            groupID: group,
            rulesHash: GroupRules.hash(rules),
            joinerSendingPublicKey: key.publicKey.rawRepresentation
        ))
    }
}
