import XCTest
import CryptoKit
@testable import OnymIOS
@testable import OnymGroup
import OnymIdentity

/// Where a member stands, and what an export of that standing may say.
///
/// The cases that matter are the ones where a mark would overstate:
/// bytes that don't verify, and bytes that verify over words the group
/// has since replaced. A screen that called either of those "signed"
/// would be making a claim this device cannot support.
final class GroupRulesStandingTests: XCTestCase {

    private let groupID = Data(repeating: 0x1a, count: 32)
    private let rules = "Be kind. No links."
    private let adminHex = String(repeating: "ff", count: 48)

    // MARK: - Standing

    func test_aGroupWithNoRules_hasNoStandingToReport() {
        XCTAssertEqual(standing(of: unsigned(), rules: nil), .noRules)
    }

    func test_blankRules_areNoRules() {
        // Whitespace is not a thing anyone can be held to.
        XCTAssertEqual(standing(of: unsigned(), rules: "   \n "), .noRules)
    }

    func test_theFounder_wroteThemRatherThanFailingToSign() {
        // Rendering the author as "didn't sign" would read as a failure
        // rather than as the shape of the thing.
        XCTAssertEqual(
            standing(of: unsigned(alias: "Alice"), key: adminHex, rules: rules),
            .author
        )
    }

    func test_theFounderIsMatchedCaseInsensitively() {
        // `adminPubkeyHex` and the `memberProfiles` key are both hex
        // strings from different sources; a case difference must not
        // demote the founder to "didn't sign".
        XCTAssertEqual(
            standing(
                of: unsigned(alias: "Alice"),
                key: adminHex,
                rules: rules,
                adminHex: adminHex.uppercased()
            ),
            .author
        )
    }

    func test_aVerifiedSignatureOverTheCurrentRules_isSigned() {
        XCTAssertEqual(standing(of: signer().profile, rules: rules), .signed)
    }

    func test_aMemberWithNothingStored_didNotSign() {
        XCTAssertEqual(standing(of: unsigned(), key: "dd", rules: rules), .didNotSign)
    }

    func test_rulesChangedSinceTheySigned_saysSoRatherThanFailing() {
        // The signature is still good; it covers different words. That
        // is a fact about the group's history, not about the member.
        let verdict = standing(of: signer().profile, rules: "Be kind. No links. And no photos.")
        XCTAssertEqual(verdict, .signedEarlierVersion)
        XCTAssertEqual(verdict?.isProven, true, "an earlier version still checks out")
    }

    func test_bytesThatDoNotVerify_areNotAMissingSignature() {
        // Distinct from `didNotSign`: only one of the two is odd.
        let key = Curve25519.Signing.PrivateKey()
        let profile = MemberProfile(
            alias: "Mallory",
            inboxPublicKey: Data(repeating: 0xAA, count: 32),
            sendingPubkey: key.publicKey.rawRepresentation,
            rulesHash: GroupRules.hash(rules),
            rulesSignature: Data(repeating: 0x00, count: 64),
            rulesText: rules
        )
        let verdict = standing(of: profile, key: "mm", rules: rules)
        XCTAssertEqual(verdict, .doesNotVerify)
        XCTAssertEqual(verdict?.isProven, false)
    }

    func test_aSignatureLiftedFromAnotherMember_doesNotVerifyHere() {
        // The signer is named inside the signed bytes, so re-attributing
        // one member's agreement to another fails.
        let real = signer()
        let impostor = MemberProfile(
            alias: "Mallory",
            inboxPublicKey: Data(repeating: 0xAA, count: 32),
            sendingPubkey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
            rulesHash: GroupRules.hash(rules),
            rulesSignature: real.profile.rulesSignature,
            rulesText: rules
        )
        XCTAssertEqual(standing(of: impostor, key: "mm", rules: rules), .doesNotVerify)
    }

    // MARK: - Export

    func test_theExportCarriesWhatAnOutsiderNeedsToCheckIt() throws {
        let signed = signer()
        let group = makeGroup(rules: rules, members: ["cc": signed.profile])
        let proof = try XCTUnwrap(GroupRulesProof(group: group, blsHex: "cc"))
        let json = try object(from: proof)

        XCTAssertEqual((json["group"] as? [String: Any])?["id"] as? String, group.id)
        let member = try XCTUnwrap(json["member"] as? [String: Any])
        XCTAssertEqual(member["signed"] as? Bool, true)
        XCTAssertEqual(
            member["sending_public_key"] as? String,
            hex(signed.key.publicKey.rawRepresentation)
        )
        XCTAssertEqual(member["signature"] as? String, hex(signed.profile.rulesSignature!))
        let carried = try XCTUnwrap(json["rules"] as? [String: Any])
        XCTAssertEqual(carried["text"] as? String, rules)
        XCTAssertEqual(carried["sha256"] as? String, hex(GroupRules.hash(rules)))
        XCTAssertEqual(carried["matches_current_rules"] as? Bool, true)
    }

    func test_theExportedBytesActuallyVerify() throws {
        try assertExportVerifiesItself(groupRules: rules)
    }

    func test_theExportVerifiesEvenAfterTheGroupChangedItsRules() throws {
        // The case the export exists to get right, and the one the
        // string comparison below can't prove: shipping today's wording
        // beside an old signature would produce a document that fails
        // its own instructions. Checking it cryptographically is the
        // only way to know it doesn't.
        try assertExportVerifiesItself(groupRules: "Be kind. No links. And no photos.")
    }

    /// Verifies a proof the way its `_readme` tells a stranger to:
    /// rebuild the statement out of the document's own fields, and
    /// check the signature it carries.
    private func assertExportVerifiesItself(
        groupRules: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let signed = signer()
        let proof = try XCTUnwrap(GroupRulesProof(
            group: makeGroup(rules: groupRules, members: ["cc": signed.profile]),
            blsHex: "cc"
        ))
        let json = try object(from: proof)
        let member = try XCTUnwrap(json["member"] as? [String: Any])
        let carried = try XCTUnwrap(json["rules"] as? [String: Any])
        let groupID = try XCTUnwrap(Data(
            hexString: try XCTUnwrap((json["group"] as? [String: Any])?["id"] as? String)
        ))
        let keyBytes = try XCTUnwrap(Data(
            hexString: try XCTUnwrap(member["sending_public_key"] as? String)
        ))
        let signature = try XCTUnwrap(Data(
            hexString: try XCTUnwrap(member["signature"] as? String)
        ))
        // The byte counts the readme instructs the reader to assume.
        XCTAssertEqual(groupID.count, 32, "readme says group.id is 32 bytes", file: file, line: line)
        XCTAssertEqual(keyBytes.count, 32, file: file, line: line)
        XCTAssertEqual(signature.count, 64, file: file, line: line)

        var statement = Data("onym-group-rules-v1".utf8)
        statement.append(groupID)
        statement.append(Data(SHA256.hash(data: Data(
            (try XCTUnwrap(carried["text"] as? String)).utf8
        ))))
        statement.append(keyBytes)

        let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
        XCTAssertTrue(
            key.isValidSignature(signature, for: statement),
            "the document must verify by its own instructions", file: file, line: line
        )
    }

    func test_theExportCarriesTheSignedWordingNotTodays() throws {
        // The bytes verify against what was agreed to. Exporting the
        // group's current text beside the old signature would produce a
        // document that fails its own instructions.
        let signed = signer()
        let group = makeGroup(
            rules: "Be kind. No links. And no photos.",
            members: ["cc": signed.profile]
        )
        let json = try object(from: try XCTUnwrap(
            GroupRulesProof(group: group, blsHex: "cc")
        ))
        let carried = try XCTUnwrap(json["rules"] as? [String: Any])
        XCTAssertEqual(carried["text"] as? String, rules, "the wording they signed")
        XCTAssertEqual(carried["matches_current_rules"] as? Bool, false, "and the divergence is named")
    }

    func test_anUnprovenStanding_shipsNoBytesToMistakeForProof() throws {
        // A signature in a document called a proof, which does not
        // verify, is worse than no signature: it invites a reader to
        // assume someone already checked.
        let key = Curve25519.Signing.PrivateKey()
        let profile = MemberProfile(
            alias: "Mallory",
            inboxPublicKey: Data(repeating: 0xAA, count: 32),
            sendingPubkey: key.publicKey.rawRepresentation,
            rulesHash: GroupRules.hash(rules),
            rulesSignature: Data(repeating: 0x00, count: 64),
            rulesText: rules
        )
        let json = try object(from: try XCTUnwrap(GroupRulesProof(
            group: makeGroup(rules: rules, members: ["mm": profile]), blsHex: "mm"
        )))
        let member = try XCTUnwrap(json["member"] as? [String: Any])
        XCTAssertEqual(member["signed"] as? Bool, false)
        XCTAssertNil(member["signature"])
        XCTAssertNil(member["sending_public_key"])
        XCTAssertNil(json["rules"])
        XCTAssertNotNil(member["note"], "and it says why, in words")
    }

    func test_theReadmeNamesKeysTheDocumentActuallyHas() throws {
        // Instructions citing a key that isn't in the file are worse
        // than no instructions.
        let json = try object(from: try XCTUnwrap(GroupRulesProof(
            group: makeGroup(rules: rules, members: ["cc": signer().profile]), blsHex: "cc"
        )))
        let readme = try XCTUnwrap(json["_readme"] as? [String]).joined(separator: "\n")
        let member = try XCTUnwrap(json["member"] as? [String: Any])
        for cited in ["sending_public_key", "signature"] {
            XCTAssertTrue(readme.contains(cited), "_readme cites \(cited)")
            XCTAssertNotNil(member[cited], "and the document has it")
        }
        XCTAssertTrue(readme.contains("onym-group-rules-v1"))
    }

    func test_theExportIsStableBetweenRuns() throws {
        // Sorted keys and no timestamp, so a diff between two exports
        // of the same agreement means something changed.
        let proof = try XCTUnwrap(GroupRulesProof(
            group: makeGroup(rules: rules, members: ["cc": signer().profile]), blsHex: "cc"
        ))
        XCTAssertEqual(try proof.jsonData(), try proof.jsonData())
    }

    func test_theFileNameSaysWhoAndWhichGroup() throws {
        // A realistic roster key: 96 hex characters, as a BLS pubkey
        // renders. The suffix is its first twelve.
        let key = String(repeating: "ab12", count: 24)
        let proof = try XCTUnwrap(GroupRulesProof(
            group: makeGroup(
                rules: rules, name: "Maple  Garden!", members: [key: signer().profile]
            ),
            blsHex: key
        ))
        XCTAssertEqual(
            proof.suggestedFileName,
            "onym-rules-proof-maple-garden-bob-ab12ab12ab12.json"
        )
    }

    func test_namesThatReduceToNothing_stillGiveEachMemberTheirOwnFile() throws {
        // Cyrillic and CJK survive neither diacritic folding nor the
        // ASCII filter, so the readable stem collapses entirely and
        // every member of such a group fell back to one filename. The
        // export is deliberately left in place for the share sheet, so
        // a collision means a lazily-reading extension can hand out the
        // second member's agreement under the first one's name.
        let group = makeGroup(
            rules: rules,
            name: "Дом на Тверской",
            members: [
                "aa11bb22cc33": unsigned(alias: "Борис"),
                "dd44ee55ff66": unsigned(alias: "Анна"),
            ]
        )
        let boris = try XCTUnwrap(GroupRulesProof(group: group, blsHex: "aa11bb22cc33"))
        let anna = try XCTUnwrap(GroupRulesProof(group: group, blsHex: "dd44ee55ff66"))

        XCTAssertNotEqual(boris.suggestedFileName, anna.suggestedFileName)
        XCTAssertEqual(boris.suggestedFileName, "onym-rules-proof-group-rules-aa11bb22cc33.json")
        XCTAssertTrue(boris.suggestedFileName.allSatisfy(\.isASCII))
    }

    func test_aStoredSignatureWithNoTextIsNotAMissingOne() {
        // Reachable: the admitting device records the agreement with
        // the rules as they stood, so a founder clearing them between a
        // request and its approval leaves bytes with nothing to check
        // them against. Reported as `didNotSign` it exported "joined
        // before this group had rules" — a claim, and a false one.
        let profile = MemberProfile(
            alias: "Bob",
            inboxPublicKey: Data(repeating: 0xAA, count: 32),
            sendingPubkey: Data(repeating: 0xEE, count: 32),
            rulesHash: GroupRules.hash(rules),
            rulesSignature: Data(repeating: 0x55, count: 64),
            rulesText: nil
        )
        XCTAssertEqual(standing(of: profile, rules: rules), .unknownRules)
    }

    func test_clearingTheRulesDoesNotDeleteWhatPeopleSigned() {
        // `invitationMessage` is a `var`. Reading group state before
        // the stored bytes turned every agreement ever made into "this
        // group asks nothing of anyone" — evidence deleted by editing a
        // text field.
        let verdict = standing(of: signer().profile, rules: nil)
        XCTAssertEqual(verdict, .signedEarlierVersion)
        XCTAssertEqual(verdict?.isProven, true)
    }

    func test_aProfileUnderAKeyThatIsNotInTheRoster_hasNoStandingAndNoProof() {
        // The mismatch the key-only API exists to make unsayable: the
        // admin's hex paired with somebody else's profile used to
        // return `.author`.
        let group = makeGroup(rules: rules, members: ["cc": signer().profile])
        XCTAssertNil(group.rulesStanding(ofMemberWith: adminHex))
        XCTAssertNil(GroupRulesProof(group: group, blsHex: adminHex))
    }

    // MARK: - Exports for the standings that aren't proofs

    func test_theAuthorsExportCarriesTheirWordsAndClaimsNoSignature() throws {
        // The one export every group with rules has. It must not
        // pretend to be a signature, and it must not be empty either:
        // the rules are this member's own words.
        let group = makeGroup(rules: rules, members: [adminHex: unsigned(alias: "Alice")])
        let json = try object(from: try XCTUnwrap(
            GroupRulesProof(group: group, blsHex: adminHex)
        ))
        let member = try XCTUnwrap(json["member"] as? [String: Any])
        XCTAssertEqual(member["signed"] as? Bool, false)
        XCTAssertNil(member["signature"])
        XCTAssertEqual(
            (json["rules"] as? [String: Any])?["text"] as? String, rules,
            "a document about the person who wrote the rules must contain them"
        )
        XCTAssertEqual(
            member["note"] as? String,
            "This member wrote the rules; founders do not sign their own."
        )
    }

    func test_aGroupWithNoRules_exportsThatRatherThanAnAccusation() throws {
        let group = makeGroup(rules: nil, members: ["dd": unsigned()])
        let json = try object(from: try XCTUnwrap(
            GroupRulesProof(group: group, blsHex: "dd")
        ))
        let member = try XCTUnwrap(json["member"] as? [String: Any])
        XCTAssertEqual(member["signed"] as? Bool, false)
        XCTAssertNil(json["rules"])
        XCTAssertEqual(
            member["note"] as? String,
            "This group has no rules, so nothing was asked of anyone."
        )
    }

    func test_theDivergedWordingShipsBothVersions() throws {
        // A reader told the wording changed needs the other wording to
        // compare against; `matches_current_rules` alone is a claim
        // they can't check.
        let today = "Be kind. No links. And no photos."
        let group = makeGroup(rules: today, members: ["cc": signer().profile])
        let json = try object(from: try XCTUnwrap(
            GroupRulesProof(group: group, blsHex: "cc")
        ))
        let carried = try XCTUnwrap(json["rules"] as? [String: Any])
        XCTAssertEqual(carried["text"] as? String, rules, "what they signed")
        XCTAssertEqual(carried["current_text"] as? String, today, "and what the group says now")
    }

    func test_matchingRules_shipNoRedundantCopy() throws {
        let group = makeGroup(rules: rules, members: ["cc": signer().profile])
        let json = try object(from: try XCTUnwrap(
            GroupRulesProof(group: group, blsHex: "cc")
        ))
        XCTAssertNil(
            (json["rules"] as? [String: Any])?["current_text"],
            "identical copies would be the same paragraph twice"
        )
    }

    func test_theReadmeSaysWhatTheSignatureDoesNotCover() throws {
        // Without this a reader concludes "the member with this BLS key
        // agreed" — a pairing this app asserts, not one the signature
        // carries.
        let group = makeGroup(rules: rules, members: ["cc": signer().profile])
        let json = try object(from: try XCTUnwrap(
            GroupRulesProof(group: group, blsHex: "cc")
        ))
        let readme = try XCTUnwrap(json["_readme"] as? [String]).joined(separator: "\n")
        XCTAssertTrue(readme.contains("does NOT cover"))
        for outside in ["alias", "bls_public_key"] {
            XCTAssertTrue(readme.contains(outside), "readme must name \(outside) as outside")
        }
    }

    func test_theFileNameIsTheSameOnEveryDevice() throws {
        // `lowercased()` under a Turkish locale maps I to a dotless ı,
        // and diacritic folding leaves CJK alone — either would make
        // one group's proof arrive under two names.
        let key = String(repeating: "ab12", count: 24)
        let group = makeGroup(
            rules: rules, name: "İstanbul 名簿", members: [key: signer().profile]
        )
        let name = try XCTUnwrap(GroupRulesProof(group: group, blsHex: key)).suggestedFileName
        XCTAssertEqual(name, "onym-rules-proof-istanbul-bob-ab12ab12ab12.json")
        XCTAssertTrue(name.allSatisfy(\.isASCII))
    }

    func test_aHostileRosterKeyCannotReachOutsideTheExportDirectory() throws {
        // Roster keys are arbitrary JSON object keys — nothing checks
        // their shape on decode — and this one reaches a filesystem
        // path. Measured before the fix: three levels of `..` put the
        // write in the app container, outside `tmp` entirely. The row
        // is reachable, too: a group with rules gives `.didNotSign` a
        // chevron, so opening it is all it takes.
        let key = "../../../Documents/pwned"
        let group = makeGroup(rules: rules, members: [key: unsigned()])
        let name = try XCTUnwrap(
            GroupRulesProof(group: group, blsHex: key)
        ).suggestedFileName

        XCTAssertFalse(name.contains(".."), "no parent traversal survives into the name")
        XCTAssertFalse(name.contains("/"), "and no separator does either")
        XCTAssertTrue(name.allSatisfy(\.isASCII))
        // The property that matters, stated the way the bug was found:
        // the composed URL stays inside the directory it was given.
        let directory = FileManager.default.temporaryDirectory
        let written = directory.appendingPathComponent(name).standardizedFileURL
        XCTAssertTrue(
            written.path.hasPrefix(directory.standardizedFileURL.path),
            "the export must not be writable outside the directory chosen for it"
        )
    }

    func test_aKeyTooShortToDistinguishMembers_isHashedRatherThanTruncated() throws {
        // Scrubbing a hostile or malformed key can leave a couple of
        // characters, or none — and a suffix that short puts back the
        // collision it exists to prevent. Two such members must still
        // get their own file.
        let group = makeGroup(
            rules: rules,
            name: "Maple Garden",
            members: ["../a": unsigned(alias: "Bo"), "../b": unsigned(alias: "Bo")]
        )
        let first = try XCTUnwrap(GroupRulesProof(group: group, blsHex: "../a"))
        let second = try XCTUnwrap(GroupRulesProof(group: group, blsHex: "../b"))

        XCTAssertNotEqual(first.suggestedFileName, second.suggestedFileName)
        for name in [first.suggestedFileName, second.suggestedFileName] {
            XCTAssertFalse(name.contains(".."))
            XCTAssertTrue(name.allSatisfy(\.isASCII))
        }
    }

    // MARK: - Helpers

    private func signer() -> (key: Curve25519.Signing.PrivateKey, profile: MemberProfile) {
        let key = Curve25519.Signing.PrivateKey()
        let signature = try! key.signature(for: GroupRules.statement(
            groupID: groupID,
            rulesHash: GroupRules.hash(rules),
            joinerSendingPublicKey: key.publicKey.rawRepresentation
        ))
        return (key, MemberProfile(
            alias: "Bob",
            inboxPublicKey: Data(repeating: 0xAA, count: 32),
            sendingPubkey: key.publicKey.rawRepresentation,
            rulesHash: GroupRules.hash(rules),
            rulesSignature: signature,
            rulesText: rules
        ))
    }

    private func makeGroup(
        rules: String?,
        name: String = "Maple Garden",
        adminHex: String? = nil,
        members: [String: MemberProfile] = [:]
    ) -> ChatGroup {
        ChatGroup(
            id: groupID.hexString,
            ownerIdentityID: IdentityID(),
            name: name,
            groupSecret: Data(repeating: 0x01, count: 32),
            createdAt: Date(),
            members: [],
            memberProfiles: members,
            epoch: 0,
            salt: Data(repeating: 0x02, count: 32),
            commitment: nil,
            tier: .small,
            groupType: .tyranny,
            adminPubkeyHex: adminHex ?? self.adminHex,
            adminEd25519PubkeyHex: nil,
            isPublishedOnChain: false,
            invitationMessage: rules
        )
    }

    /// The standing of the one member in a group built around them.
    private func standing(
        of member: MemberProfile,
        key: String = "cc",
        rules: String?,
        adminHex: String? = nil
    ) -> GroupRulesStanding? {
        makeGroup(rules: rules, adminHex: adminHex, members: [key: member])
            .rulesStanding(ofMemberWith: key)
    }

    private func unsigned(alias: String = "Dana") -> MemberProfile {
        MemberProfile(
            alias: alias,
            inboxPublicKey: Data(repeating: 0xAA, count: 32),
            sendingPubkey: Data(repeating: 0xEE, count: 32)
        )
    }

    private func object(from proof: GroupRulesProof) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: try proof.jsonData()) as? [String: Any]
        )
    }

    private func hex(_ data: Data) -> String { data.hexString }
}
