import Foundation
import XCTest
@testable import OnymIOS

final class GroupInviteOfferPayloadTests: XCTestCase {

    private func makeValid() throws -> GroupInviteOfferPayload {
        try GroupInviteOfferPayload(
            introPublicKey: Data(repeating: 0x11, count: 32),
            groupID: Data(repeating: 0x22, count: 32),
            groupName: "Maple Garden",
            inviterAlias: "Alice"
        )
    }

    func test_roundTrip_preservesAllFields() throws {
        let offer = try makeValid()
        let encoded = try JSONEncoder().encode(offer)
        let decoded = try JSONDecoder().decode(GroupInviteOfferPayload.self, from: encoded)
        XCTAssertEqual(decoded, offer)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.introPublicKey, Data(repeating: 0x11, count: 32))
        XCTAssertEqual(decoded.groupID, Data(repeating: 0x22, count: 32))
        XCTAssertEqual(decoded.groupName, "Maple Garden")
        XCTAssertEqual(decoded.inviterAlias, "Alice")
    }

    func test_nilGroupName_roundTrips() throws {
        let offer = try GroupInviteOfferPayload(
            introPublicKey: Data(repeating: 0x01, count: 32),
            groupID: Data(repeating: 0x02, count: 32),
            groupName: nil,
            inviterAlias: ""
        )
        let decoded = try JSONDecoder().decode(
            GroupInviteOfferPayload.self,
            from: JSONEncoder().encode(offer)
        )
        XCTAssertNil(decoded.groupName)
        XCTAssertEqual(decoded, offer)
    }

    func test_wrongIntroKeyLength_throws() {
        XCTAssertThrowsError(try GroupInviteOfferPayload(
            introPublicKey: Data(repeating: 0x11, count: 31),
            groupID: Data(repeating: 0x22, count: 32),
            groupName: nil,
            inviterAlias: "A"
        ))
    }

    func test_wrongGroupIDLength_throws() {
        XCTAssertThrowsError(try GroupInviteOfferPayload(
            introPublicKey: Data(repeating: 0x11, count: 32),
            groupID: Data(repeating: 0x22, count: 16),
            groupName: nil,
            inviterAlias: "A"
        ))
    }

    /// The dispatcher relies on `inviter_alias` + `intro_pub` being
    /// unique to this type. A `JoinRequestPayload` (the other
    /// intro-keyed payload) must NOT decode as an offer.
    func test_joinRequestPayload_doesNotDecodeAsOffer() throws {
        let join = try JoinRequestPayload(
            joinerInboxPublicKey: Data(repeating: 0x01, count: 32),
            joinerBlsPublicKey: Data(repeating: 0x02, count: 48),
            joinerLeafHash: Data(repeating: 0x03, count: 32),
            joinerSendingPublicKey: Data(repeating: 0x04, count: 32),
            joinerDisplayLabel: "Bob",
            groupId: Data(repeating: 0x05, count: 32)
        )
        let bytes = try JSONEncoder().encode(join)
        XCTAssertThrowsError(
            try JSONDecoder().decode(GroupInviteOfferPayload.self, from: bytes),
            "JoinRequestPayload must not be mistaken for an offer"
        )
    }

    func test_invitationMessage_roundTrips() throws {
        let long = String(repeating: "Articles of association. ", count: 200)
        let offer = try GroupInviteOfferPayload(
            introPublicKey: Data(repeating: 0x11, count: 32),
            groupID: Data(repeating: 0x22, count: 32),
            groupName: "Maple Garden",
            inviterAlias: "Alice",
            invitationMessage: long
        )
        let decoded = try JSONDecoder().decode(
            GroupInviteOfferPayload.self,
            from: JSONEncoder().encode(offer)
        )
        XCTAssertEqual(decoded.invitationMessage, long)
        XCTAssertEqual(decoded, offer)
    }

    /// A pre-feature sender's offer (no `invitation_message` key) still
    /// decodes — forward/backward compatibility via `decodeIfPresent`.
    func test_missingInvitationMessage_decodesToNil() throws {
        let json = """
        {"offer_version":1,"intro_pub":"\(Data(repeating: 0x11, count: 32).base64EncodedString())",\
        "group_id":"\(Data(repeating: 0x22, count: 32).base64EncodedString())",\
        "group_name":"G","inviter_alias":"A"}
        """
        let decoded = try JSONDecoder().decode(
            GroupInviteOfferPayload.self,
            from: Data(json.utf8)
        )
        XCTAssertNil(decoded.invitationMessage)
    }

    /// The optional message must be *omitted* (not null) when absent, so
    /// the wire shape matches Android's `encodeDefaults = false`.
    func test_nilInvitationMessage_isOmittedFromJSON() throws {
        let offer = try makeValid()
        let json = String(data: try JSONEncoder().encode(offer), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("invitation_message"))
    }

    func test_introCapability_rebuildsFromOffer() throws {
        let offer = try makeValid()
        let cap = try offer.introCapability()
        XCTAssertEqual(cap.introPublicKey, offer.introPublicKey)
        XCTAssertEqual(cap.groupId, offer.groupID)
        XCTAssertEqual(cap.groupName, offer.groupName)
    }
}
