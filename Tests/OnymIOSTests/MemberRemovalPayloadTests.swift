import XCTest
@testable import OnymIOS

/// Round-trip vectors for `MemberRemovalPayload` plus trial-decode
/// disjointness against every other inbox payload — the dispatcher's
/// routing depends on no payload decoding as another.
///
/// Wire format authored on Android first (`MemberRemovalPayload.kt`);
/// `test_decode_wireVector` decodes the exact wire shape Android's
/// `MemberRemovalPayloadTest.decode_wireVector` freezes (same byte
/// values, same base64 encoding).
final class MemberRemovalPayloadTests: XCTestCase {

    private let groupID = Data(repeating: 0xAA, count: 32)
    private let victimHex = String(repeating: "bb", count: 48)
    private let commitment = Data(repeating: 0xDD, count: 32)
    private let secretNew = Data(repeating: 0x11, count: 32)
    private let saltNew = Data(repeating: 0x22, count: 32)

    private func memberVariant() throws -> MemberRemovalPayload {
        try MemberRemovalPayload(
            version: 1,
            groupID: groupID,
            removedBlsHex: victimHex,
            commitment: commitment,
            epoch: 3,
            sentAtMillis: 1_700_000_000_000,
            groupSecretNew: secretNew,
            saltNew: saltNew
        )
    }

    private func victimVariant() throws -> MemberRemovalPayload {
        try MemberRemovalPayload(
            version: 1,
            groupID: groupID,
            removedBlsHex: victimHex,
            commitment: commitment,
            epoch: 3,
            sentAtMillis: 1_700_000_000_000
        )
    }

    // MARK: - Round-trips

    func test_roundTrip_memberVariant() throws {
        let encoded = try JSONEncoder().encode(memberVariant())
        let decoded = try JSONDecoder().decode(MemberRemovalPayload.self, from: encoded)
        XCTAssertEqual(decoded, try memberVariant())
        XCTAssertEqual(decoded.groupSecretNew, secretNew)
        XCTAssertEqual(decoded.saltNew, saltNew)
    }

    func test_roundTrip_victimVariant_omitsSecretKeysEntirely() throws {
        let encoded = try JSONEncoder().encode(victimVariant())
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        // Not just null-valued — the keys must be absent from the wire.
        XCTAssertFalse(text.contains("group_secret_new"))
        XCTAssertFalse(text.contains("salt_new"))
        let decoded = try JSONDecoder().decode(MemberRemovalPayload.self, from: encoded)
        XCTAssertNil(decoded.groupSecretNew)
        XCTAssertNil(decoded.saltNew)
        XCTAssertEqual(decoded, try victimVariant())
    }

    // MARK: - Frozen wire vector (Android parity)

    func test_decode_wireVector() throws {
        // Frozen wire shape — Android's MemberRemovalPayloadTest
        // encodes these exact values; both platforms must decode it.
        let text = """
        {
          "removal_version": 1,
          "removal_group_id": "\(groupID.base64EncodedString())",
          "removal_member_bls_hex": "\(victimHex)",
          "removal_commitment": "\(commitment.base64EncodedString())",
          "removal_epoch": 3,
          "removal_sent_at_millis": 1700000000000,
          "group_secret_new": "\(secretNew.base64EncodedString())",
          "salt_new": "\(saltNew.base64EncodedString())"
        }
        """
        let decoded = try JSONDecoder().decode(
            MemberRemovalPayload.self,
            from: Data(text.utf8)
        )
        XCTAssertEqual(decoded, try memberVariant())
    }

    // MARK: - Trial-decode disjointness (both directions)

    func test_removal_doesNotDecodeAsAnyOtherInboxPayload() throws {
        let wire = try JSONEncoder().encode(memberVariant())
        XCTAssertNil(try? JSONDecoder().decode(GroupInviteOfferPayload.self, from: wire))
        XCTAssertNil(try? JSONDecoder().decode(GroupStateRefreshRequest.self, from: wire))
        XCTAssertNil(try? JSONDecoder().decode(MemberAnnouncementPayload.self, from: wire))
        XCTAssertNil(try? JSONDecoder().decode(GroupInvitationPayload.self, from: wire))
        XCTAssertNil(try? JSONDecoder().decode(GroupAvatarPayload.self, from: wire))
        XCTAssertNil(try? JSONDecoder().decode(GroupNamePayload.self, from: wire))
        XCTAssertNil(try? JSONDecoder().decode(ChatReceiptPayload.self, from: wire))
        XCTAssertNil(try? JSONDecoder().decode(ChatMessagePayload.self, from: wire))
    }

    func test_otherInboxPayloads_doNotDecodeAsRemoval() throws {
        let announcement = try JSONEncoder().encode(
            try MemberAnnouncementPayload(
                version: 1,
                groupId: groupID,
                newMember: try MemberAnnouncementPayload.AnnouncedMember(
                    blsPub: Data(repeating: 0xBB, count: 48),
                    inboxPub: Data(repeating: 0xCC, count: 32),
                    alias: "Bob",
                    sendingPub: Data(repeating: 0xDE, count: 32)
                ),
                adminAlias: "Alice",
                commitment: commitment,
                epoch: 3
            )
        )
        XCTAssertNil(try? JSONDecoder().decode(MemberRemovalPayload.self, from: announcement))

        let invitation = try JSONEncoder().encode(
            GroupInvitationPayload(
                version: 1,
                groupID: groupID,
                groupSecret: secretNew,
                name: "Family",
                members: [],
                epoch: 3,
                salt: saltNew,
                commitment: commitment,
                tierRaw: SEPTier.small.rawValue,
                groupTypeRaw: SEPGroupType.tyranny.rawValue,
                adminPubkeyHex: victimHex
            )
        )
        XCTAssertNil(try? JSONDecoder().decode(MemberRemovalPayload.self, from: invitation))
    }

    // MARK: - Shape validation

    func test_init_rejectsWrongSizes() {
        XCTAssertThrowsError(try MemberRemovalPayload(
            version: 1, groupID: Data(repeating: 0xAA, count: 31),
            removedBlsHex: victimHex, commitment: commitment,
            epoch: 3, sentAtMillis: 0
        ))
        XCTAssertThrowsError(try MemberRemovalPayload(
            version: 1, groupID: groupID,
            removedBlsHex: "ab", commitment: commitment,
            epoch: 3, sentAtMillis: 0
        ))
        XCTAssertThrowsError(try MemberRemovalPayload(
            version: 1, groupID: groupID,
            removedBlsHex: victimHex, commitment: Data(repeating: 0xDD, count: 16),
            epoch: 3, sentAtMillis: 0
        ))
        XCTAssertThrowsError(try MemberRemovalPayload(
            version: 1, groupID: groupID,
            removedBlsHex: victimHex, commitment: commitment,
            epoch: 3, sentAtMillis: 0,
            groupSecretNew: Data(repeating: 0x11, count: 16)
        ))
        XCTAssertThrowsError(try MemberRemovalPayload(
            version: 1, groupID: groupID,
            removedBlsHex: victimHex, commitment: commitment,
            epoch: 3, sentAtMillis: 0,
            saltNew: Data(repeating: 0x22, count: 16)
        ))
    }

    func test_decode_rejectsWrongSizedGroupID() throws {
        let text = """
        {
          "removal_version": 1,
          "removal_group_id": "\(Data(repeating: 0xAA, count: 16).base64EncodedString())",
          "removal_member_bls_hex": "\(victimHex)",
          "removal_commitment": "\(commitment.base64EncodedString())",
          "removal_epoch": 3,
          "removal_sent_at_millis": 1700000000000
        }
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(MemberRemovalPayload.self, from: Data(text.utf8))
        )
    }
}
