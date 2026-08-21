import XCTest
import CryptoKit
@testable import OnymIOS
@testable import OnymGroup

/// Golden vectors for the bytes Android has to reproduce, plus the two
/// boundary rules that decide whether a link is usable at all.
///
/// These live in the same PR as the format rather than with the rest of
/// the tests, because a stack can land partially and these bytes are a
/// cross-platform contract: `statement()` is what the other
/// implementation is written against, and a fixture is a cheaper
/// specification than prose.
///
/// Every constant below is fixed on purpose. If one of them has to
/// change, the wire format changed, and the domain string carries a
/// version for exactly that.
final class GroupRulesVectorTests: XCTestCase {

    /// A 32-byte Ed25519 seed, fixed. Not a real identity's.
    private let seed = Data(repeating: 0x07, count: 32)
    private let groupID = Data((0..<32).map { UInt8($0) })
    private let rules = "Be kind. No links."

    private var key: Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    /// The expected values below were derived from an independent
    /// RFC 8032 implementation, not read back out of CryptoKit — a
    /// vector copied from the code it checks pins nothing.
    func test_vector_rulesHash() {
        // SHA-256 of the canonical text's UTF-8, and nothing else — no
        // length prefix, no domain, no normalisation beyond trimming.
        XCTAssertEqual(
            hex(GroupRules.hash(rules)),
            "440518f597c71a23fe7d99980df8c2156ac86dcc7f5b49493a4d403819b16473"
        )
    }

    func test_vector_publicKeyFromTheFixedSeed() {
        XCTAssertEqual(
            hex(key.publicKey.rawRepresentation),
            "ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c"
        )
    }

    func test_vector_statementBytes() {
        // The preimage, byte for byte: 19-byte domain, then three
        // 32-byte fields in this order.
        let statement = GroupRules.statement(
            groupID: groupID,
            rulesHash: GroupRules.hash(rules),
            joinerSendingPublicKey: key.publicKey.rawRepresentation
        )
        XCTAssertEqual(
            hex(statement.prefix(19)),
            hex(Data("onym-group-rules-v1".utf8)),
            "domain string, unversioned changes to which must break this"
        )
        XCTAssertEqual(hex(statement.dropFirst(19).prefix(32)), hex(groupID))
        XCTAssertEqual(
            hex(statement.dropFirst(51).prefix(32)),
            hex(GroupRules.hash(rules))
        )
        XCTAssertEqual(
            hex(statement.suffix(32)),
            hex(key.publicKey.rawRepresentation)
        )
        XCTAssertEqual(statement.count, 115)
    }

    /// The vector is a signature to **verify**, not one to reproduce.
    ///
    /// CryptoKit's Ed25519 signing is randomized: signing the same
    /// bytes with the same key twice gives two different signatures,
    /// both valid. So "sign and compare hex" cannot be the contract in
    /// either direction, and asserting it would have pinned a value
    /// that changes run to run.
    ///
    /// What can be pinned — and is the thing that has to hold across
    /// platforms — is that a signature produced *elsewhere* over these
    /// exact bytes verifies here. The value below came from an
    /// independent RFC 8032 implementation, which is also the shape
    /// Android's Ed25519 produces. If `statement()` ever disagrees with
    /// its counterpart by one byte, this test fails and the wire format
    /// has changed.
    func test_vector_aForeignSignatureOverTheseBytesVerifies() {
        let fromAnotherImplementation =
            "d1b32ae2d65faad6f3867c7a47dec90a1c040ccbcb14e70cfbf5c4ce29229eb9"
            + "c39055e12bacbfb46c3c83940fd5fed61a9747a5c2ef8fc6468db5fc9421810e"
        XCTAssertTrue(GroupRules.isAgreement(
            signature: Data(hexString: fromAnotherImplementation)!,
            rules: rules,
            groupID: groupID,
            joinerSendingPublicKey: key.publicKey.rawRepresentation
        ))
    }

    func test_ourOwnSignature_verifies() {
        let signature = try! key.signature(for: GroupRules.statement(
            groupID: groupID,
            rulesHash: GroupRules.hash(rules),
            joinerSendingPublicKey: key.publicKey.rawRepresentation
        ))
        XCTAssertTrue(GroupRules.isAgreement(
            signature: signature,
            rules: rules,
            groupID: groupID,
            joinerSendingPublicKey: key.publicKey.rawRepresentation
        ))
    }

    // MARK: - Canonicalization across platforms

    func test_canonical_trimsTheCodepointsKotlinDoesNot() {
        // The reason `trimmedCodepoints` is spelled out. NBSP rides in
        // on text pasted from a web page; if the two platforms disagree
        // about it, a genuine agreement reads to the founder as a
        // signature that doesn't check out.
        for scalar in ["\u{00A0}", "\u{202F}", "\u{205F}", "\u{2007}", "\u{0085}"] {
            XCTAssertEqual(
                GroupRules.canonical("\(scalar)\(rules)\(scalar)"),
                rules,
                "U+\(String(scalar.unicodeScalars.first!.value, radix: 16, uppercase: true)) must be trimmed on both platforms"
            )
        }
    }

    func test_canonical_leavesInnerTextExactlyAsWritten() {
        // Only the ends. Inner shape is the founder's, and it is what
        // the joiner reads and signs.
        let shaped = "One.\u{00A0}\u{00A0}Two.\n\n  Three."
        XCTAssertEqual(GroupRules.canonical("  \(shaped)  "), shaped)
    }

    // MARK: - The cap, in the unit the wire spends

    func test_theCap_isBytesNotCharacters() throws {
        // A character cap would admit this: 500 grapheme clusters and
        // ~12.5 KB, seven times the QR ceiling it exists to defend.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let emoji = String(repeating: family, count: 500)
        XCTAssertEqual(emoji.count, 500, "500 characters by Swift's count")
        XCTAssertGreaterThan(emoji.utf8.count, 12_000)
        XCTAssertThrowsError(
            try IntroCapability(
                introPublicKey: Data(repeating: 0x44, count: 32),
                groupId: groupID,
                rules: emoji
            ),
            "a character cap would have let this through"
        )
    }

    func test_rulesAtTheByteCap_areAccepted() throws {
        let capability = try IntroCapability(
            introPublicKey: Data(repeating: 0x44, count: 32),
            groupId: groupID,
            rules: String(repeating: "則", count: GroupRules.maxBytes / 3)
        )
        XCTAssertEqual(capability.rules?.utf8.count, GroupRules.maxBytes)
    }

    func test_overLongRulesOnTheWire_areRejectedNotTruncated() {
        // The mint-time cap is not a defence: a hostile link never
        // passes through it. Truncating would have someone sign rules
        // that end mid-sentence.
        let payload = """
        {"intro_pub":"\(Data(repeating: 0x44, count: 32).base64EncodedString())",\
        "group_id":"\(groupID.base64EncodedString())",\
        "rules":"\(String(repeating: "x", count: GroupRules.maxBytes + 1))"}
        """
        XCTAssertThrowsError(try IntroCapability.decode(urlSafe(Data(payload.utf8))))
    }

    // MARK: - Pairing

    func test_halfAnAgreement_isRejected() {
        // A signature with nothing naming what it covers can't be
        // checked; a hash with no signature is a claim, not a proof.
        XCTAssertThrowsError(try request(hash: GroupRules.hash(rules), signature: nil))
        XCTAssertThrowsError(try request(hash: nil, signature: Data(repeating: 0x55, count: 64)))
    }

    // MARK: - Helpers

    private func request(hash: Data?, signature: Data?) throws -> JoinRequestPayload {
        try JoinRequestPayload(
            joinerInboxPublicKey: Data(repeating: 0xAA, count: 32),
            joinerBlsPublicKey: nil,
            joinerLeafHash: nil,
            joinerSendingPublicKey: key.publicKey.rawRepresentation,
            joinerDisplayLabel: "Bob",
            groupId: groupID,
            rulesHash: hash,
            rulesSignature: signature
        )
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func urlSafe(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }

}

private extension Data {
    /// Test-only, so the golden signature can be written as the hex a
    /// reader can compare against another implementation's output.
    init?(hexString: String) {
        var bytes: [UInt8] = []
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2, limitedBy: hexString.endIndex)
            guard let next, let byte = UInt8(hexString[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
