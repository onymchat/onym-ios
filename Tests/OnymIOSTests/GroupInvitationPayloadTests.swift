import XCTest
@testable import OnymIOS

/// Wire-format pin for `GroupInvitationPayload`. Focused on the
/// `member_profiles` field added in PR 8a; the rest of the wire
/// format has been stable since group-create v1 and is exercised
/// indirectly via `CreateGroupInteractorTests` /
/// `JoinRequestApproverTests` (when those land).
final class GroupInvitationPayloadTests: XCTestCase {

    // MARK: - Round-trip

    func test_roundtrip_withMemberProfiles_preservesDirectory() throws {
        let aliceHex = "11".repeated(48)
        let profiles: [String: MemberProfile] = [
            aliceHex: MemberProfile(
                alias: "Alice",
                inboxPublicKey: Data(repeating: 0xAA, count: 32)
            )
        ]
        let original = makePayload(memberProfiles: profiles)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GroupInvitationPayload.self, from: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.memberProfiles?[aliceHex]?.alias, "Alice")
    }

    func test_roundtrip_withoutMemberProfiles_decodesAsNil() throws {
        let original = makePayload(memberProfiles: nil)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GroupInvitationPayload.self, from: encoded)
        XCTAssertNil(decoded.memberProfiles)
    }

    // MARK: - Forward-compat

    func test_decoder_acceptsLegacyPayloadWithoutMemberProfiles() throws {
        // Older onym-android / pre-PR-8a builds ship invitations
        // without member_profiles. The wire format must round-trip
        // those into a payload with `memberProfiles == nil` so the
        // joiner-side materializer falls back to "no aliases yet"
        // rather than failing decode.
        let gid = Data(repeating: 0, count: 32).base64EncodedString()
        let secret = Data(repeating: 0, count: 32).base64EncodedString()
        let salt = Data(repeating: 0, count: 32).base64EncodedString()
        let legacy = #"""
        {"version":1,"group_id":"\#(gid)","group_secret":"\#(secret)","name":"Family","members":[],"epoch":0,"salt":"\#(salt)","tier_raw":1,"group_type_raw":"tyranny"}
        """#
        let bytes = legacy.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(GroupInvitationPayload.self, from: bytes)
        XCTAssertNil(decoded.memberProfiles)
        XCTAssertEqual(decoded.name, "Family")
    }

    // MARK: - Wire shape

    func test_member_profiles_keySpelling_matches_android_parity() throws {
        let payload = makePayload(memberProfiles: [
            "ab".repeated(48): MemberProfile(
                alias: "x",
                inboxPublicKey: Data(repeating: 0, count: 32)
            )
        ])
        let encoded = try JSONEncoder().encode(payload)
        let obj = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertNotNil(obj?["member_profiles"],
                        "snake_case key 'member_profiles' must match Android parity")
    }

    // MARK: - Helpers

    private func makePayload(
        memberProfiles: [String: MemberProfile]?
    ) -> GroupInvitationPayload {
        GroupInvitationPayload(
            version: 1,
            groupID: Data(repeating: 0x42, count: 32),
            groupSecret: Data(repeating: 0x33, count: 32),
            name: "Family",
            members: [],
            epoch: 0,
            salt: Data(repeating: 0x44, count: 32),
            commitment: nil,
            tierRaw: 1,
            groupTypeRaw: "tyranny",
            adminPubkeyHex: nil,
            peerBlsSecret: nil,
            memberProfiles: memberProfiles
        )
    }
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
