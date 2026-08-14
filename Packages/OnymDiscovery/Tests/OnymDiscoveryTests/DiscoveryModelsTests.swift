import Foundation
import XCTest
@testable import OnymDiscovery

final class DiscoveryModelsTests: XCTestCase {
    private func entryJSON(extra: String = "", uri: String = "https://x.example/m.json") -> String {
        """
        {"componentId":"onym:component:a","seatType":"notary",\
        "manifest":{"digest":"sha256:\(String(repeating: "0", count: 64))","uri":"\(uri)"},\
        "operator":"onym:key:\(String(repeating: "a", count: 64))",\
        "profiles":[],"evidence":[],"listedAt":"2026-08-13T00:00:00Z",\
        "relationship":"none","placement":"policy-ranked"\(extra)}
        """
    }

    private func snapshotJSON(entries: [String]) -> Data {
        Data("""
        {"version":1,"implementationProfileId":"onym:discovery-implementation:static-ed25519-v1",\
        "catalogId":"c","providerId":"onym:component:p","sequence":1,\
        "policyDigest":"sha256:\(String(repeating: "1", count: 64))",\
        "generatedAt":"2026-08-13T00:00:00Z","expiresAt":"2026-09-12T00:00:00Z",\
        "entries":[\(entries.joined(separator: ","))],"signature":"AA=="}
        """.utf8)
    }

    func testLossyEntryDecodingSkipsMalformedEntriesAndCountsThem() throws {
        // One valid entry, one with an unknown field, one missing a
        // required field: the valid one survives, the others are
        // skipped — never defaulted.
        let good = entryJSON()
        let unknownField = entryJSON(extra: #","surprise":true"#)
        let missingRelationship = entryJSON().replacingOccurrences(
            of: #""relationship":"none","#, with: ""
        )
        let snapshot = try DiscoveryJSON.decoder().decode(
            CatalogSnapshot.self,
            from: snapshotJSON(entries: [good, unknownField, missingRelationship])
        )
        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertEqual(snapshot.skippedEntryCount, 2)
        XCTAssertEqual(snapshot.entries.first?.componentId, "onym:component:a")
    }

    func testEntryWithHTTPManifestURIIsSkipped() throws {
        let bad = entryJSON(uri: "http://x.example/m.json")
        let snapshot = try DiscoveryJSON.decoder().decode(
            CatalogSnapshot.self,
            from: snapshotJSON(entries: [entryJSON(), bad])
        )
        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertEqual(snapshot.skippedEntryCount, 1)
    }

    func testURIRules() {
        XCTAssertTrue(DiscoveryFormat.isValidURI("https://discovery.onym.app/manifest.json"))
        // http scheme
        XCTAssertFalse(DiscoveryFormat.isValidURI("http://discovery.onym.app/manifest.json"))
        // IP literals, v4 and v6
        XCTAssertFalse(DiscoveryFormat.isValidURI("https://192.168.1.10/m.json"))
        XCTAssertFalse(DiscoveryFormat.isValidURI("https://[::1]/m.json"))
        // query / fragment / userinfo / explicit port
        XCTAssertFalse(DiscoveryFormat.isValidURI("https://x.example/m.json?a=1"))
        XCTAssertFalse(DiscoveryFormat.isValidURI("https://x.example/m.json#frag"))
        XCTAssertFalse(DiscoveryFormat.isValidURI("https://user@x.example/m.json"))
        XCTAssertFalse(DiscoveryFormat.isValidURI("https://x.example:8443/m.json"))
        XCTAssertFalse(DiscoveryFormat.isValidURI("https://x.example:443/m.json"))
    }

    func testIdentifierAndDigestFormats() {
        XCTAssertNotNil(DiscoveryFormat.operatorKeyHex("onym:key:" + Fixture.operatorKeyHex))
        XCTAssertNil(DiscoveryFormat.operatorKeyHex("onym:key:" + Fixture.operatorKeyHex.uppercased()))
        XCTAssertNil(DiscoveryFormat.operatorKeyHex("onym:key:abcd"))
        XCTAssertTrue(DiscoveryFormat.isComponentId("onym:component:onym-discovery"))
        XCTAssertFalse(DiscoveryFormat.isComponentId("onym:component:Bad_Id"))
        XCTAssertTrue(DiscoveryFormat.isDigest("sha256:" + String(repeating: "0", count: 64)))
        XCTAssertFalse(DiscoveryFormat.isDigest("sha256:" + String(repeating: "0", count: 63)))
        XCTAssertFalse(DiscoveryFormat.isDigest("sha512:" + String(repeating: "0", count: 64)))
    }
}
