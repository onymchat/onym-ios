import XCTest
@testable import OnymIOS

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
}
