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

    func testEntryWithMalformedComponentIdOrOperatorKeyIsSkipped() throws {
        // Junk in the identifier fields is checked with the same
        // DiscoveryFormat helpers the manifests use — the entry is
        // skipped (lossy), never carried through with an id or key no
        // later stage could attribute or verify.
        let badComponentId = entryJSON().replacingOccurrences(
            of: #""componentId":"onym:component:a""#,
            with: #""componentId":"NOT AN ID!""#
        )
        let badOperatorKey = entryJSON().replacingOccurrences(
            of: "onym:key:\(String(repeating: "a", count: 64))",
            with: "onym:key:junk"
        )
        let snapshot = try DiscoveryJSON.decoder().decode(
            CatalogSnapshot.self,
            from: snapshotJSON(entries: [entryJSON(), badComponentId, badOperatorKey])
        )
        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertEqual(snapshot.skippedEntryCount, 2)
        XCTAssertEqual(snapshot.entries.first?.componentId, "onym:component:a")
    }

    private func descriptorJSON(catalogId: String = "c", extra: String = "") -> String {
        """
        {"catalogId":"\(catalogId)","snapshot":"https://x.example/c.json",\
        "audience":"public","seatTypes":["notary"],\
        "policy":"sha256:\(String(repeating: "1", count: 64))",\
        "policyUri":"https://x.example/policy.md"\(extra)}
        """
    }

    private func manifestJSON(catalogs: [String]) -> Data {
        Data("""
        {"version":1,"implementationProfileId":"onym:discovery-implementation:static-ed25519-v1",\
        "providerId":"onym:component:p","operator":"onym:key:\(String(repeating: "a", count: 64))",\
        "seat":"discovery","catalogs":[\(catalogs.joined(separator: ","))],\
        "capabilities":[],"privacyProfile":"sha256:\(String(repeating: "2", count: 64))",\
        "privacyProfileUri":"https://x.example/privacy.md","offers":[],\
        "validUntil":"2026-12-31T23:59:59Z","signature":"AA=="}
        """.utf8)
    }

    func testLossyDescriptorDecodingSkipsMalformedDescriptorsAndCountsThem() throws {
        // One valid descriptor, one with an unknown field, one missing
        // the required policyUri: the valid one survives, the others
        // are skipped and counted — never defaulted (§4.1).
        let good = descriptorJSON()
        let unknownField = descriptorJSON(catalogId: "d", extra: #","surprise":true"#)
        let missingPolicyUri = descriptorJSON(catalogId: "e").replacingOccurrences(
            of: #","policyUri":"https://x.example/policy.md""#, with: ""
        )
        let manifest = try DiscoveryJSON.decoder().decode(
            DiscoveryProviderManifest.self,
            from: manifestJSON(catalogs: [good, unknownField, missingPolicyUri])
        )
        XCTAssertEqual(manifest.catalogs.map(\.catalogId), ["c"])
        XCTAssertEqual(manifest.skippedCatalogCount, 2)
    }

    func testManifestWithoutPrivacyProfileFailsDecoding() {
        let stripped = String(data: manifestJSON(catalogs: [descriptorJSON()]), encoding: .utf8)!
            .replacingOccurrences(
                of: #""privacyProfile":"sha256:\#(String(repeating: "2", count: 64))","#,
                with: ""
            )
        XCTAssertThrowsError(try DiscoveryJSON.decoder().decode(
            DiscoveryProviderManifest.self, from: Data(stripped.utf8)
        ))
    }

    func testUnknownRelationshipSkipsEntry() throws {
        // §4.2 fails closed against the extensible relationship set: a
        // disclosure the client cannot render is one the user never
        // saw — the entry is skipped, never passed through verbatim.
        let bad = entryJSON().replacingOccurrences(
            of: #""relationship":"none""#, with: #""relationship":"equity-stake""#
        )
        let snapshot = try DiscoveryJSON.decoder().decode(
            CatalogSnapshot.self,
            from: snapshotJSON(entries: [entryJSON(), bad])
        )
        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertEqual(snapshot.skippedEntryCount, 1)
    }

    func testMinimalEntryWithoutProfilesOrEvidenceSurvives() throws {
        // §4.1 lists profiles and evidence as optional: a minimal
        // conforming entry must not be skipped.
        let minimal = entryJSON().replacingOccurrences(
            of: #""profiles":[],"evidence":[],"#, with: ""
        )
        let snapshot = try DiscoveryJSON.decoder().decode(
            CatalogSnapshot.self,
            from: snapshotJSON(entries: [minimal])
        )
        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertEqual(snapshot.skippedEntryCount, 0)
        XCTAssertEqual(snapshot.entries.first?.profiles, [])
        XCTAssertEqual(snapshot.entries.first?.evidence, [])
    }

    func testNonEmptyEvidenceSkipsEntry() throws {
        // §4.2: evidence must be absent or empty in v1 — a non-empty
        // array is an unrenderable attestation, and the entry is
        // skipped.
        let bad = entryJSON().replacingOccurrences(
            of: #""evidence":[]"#,
            with: #""evidence":[{"type":"audit"}]"#
        )
        let snapshot = try DiscoveryJSON.decoder().decode(
            CatalogSnapshot.self,
            from: snapshotJSON(entries: [entryJSON(), bad])
        )
        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertEqual(snapshot.skippedEntryCount, 1)
    }

    func testValidStatusSurvivesAndInvalidStatusSkips() throws {
        // §4.2: a VALID status must never skip the entry — skipping it
        // is the exact warning-dropping failure the field exists to
        // prevent. An undecodable status skips the entry.
        let warned = entryJSON(extra: #","status":{"state":"warning","uri":"https://x.example/note.md"}"#)
        let reviewed = entryJSON(extra: #","status":{"state":"review"}"#)
            .replacingOccurrences(of: #""componentId":"onym:component:a""#, with: #""componentId":"onym:component:b""#)
        let unknownState = entryJSON(extra: #","status":{"state":"suspended"}"#)
            .replacingOccurrences(of: #""componentId":"onym:component:a""#, with: #""componentId":"onym:component:c""#)
        let httpUri = entryJSON(extra: #","status":{"state":"warning","uri":"http://x.example/note.md"}"#)
            .replacingOccurrences(of: #""componentId":"onym:component:a""#, with: #""componentId":"onym:component:d""#)
        let snapshot = try DiscoveryJSON.decoder().decode(
            CatalogSnapshot.self,
            from: snapshotJSON(entries: [warned, reviewed, unknownState, httpUri])
        )
        XCTAssertEqual(snapshot.entries.count, 2)
        XCTAssertEqual(snapshot.skippedEntryCount, 2)
        XCTAssertEqual(snapshot.entries[0].status?.state, "warning")
        XCTAssertEqual(snapshot.entries[0].status?.uri, "https://x.example/note.md")
        XCTAssertEqual(snapshot.entries[1].status?.state, "review")
        XCTAssertNil(snapshot.entries[1].status?.uri)
    }

    func testSeatTypesMemberValidationSkipsDescriptor() throws {
        // §4.1: members are tokens in [a-z0-9.-]{1,64} or the lone
        // "*" wildcard; anything else skips the descriptor.
        let good = descriptorJSON()
        let wildcard = descriptorJSON(catalogId: "w").replacingOccurrences(
            of: #""seatTypes":["notary"]"#, with: #""seatTypes":["*"]"#
        )
        let badMember = descriptorJSON(catalogId: "x").replacingOccurrences(
            of: #""seatTypes":["notary"]"#, with: #""seatTypes":["Notary!"]"#
        )
        let wildcardNotAlone = descriptorJSON(catalogId: "y").replacingOccurrences(
            of: #""seatTypes":["notary"]"#, with: #""seatTypes":["*","notary"]"#
        )
        let manifest = try DiscoveryJSON.decoder().decode(
            DiscoveryProviderManifest.self,
            from: manifestJSON(catalogs: [good, wildcard, badMember, wildcardNotAlone])
        )
        XCTAssertEqual(manifest.catalogs.map(\.catalogId), ["c", "w"])
        XCTAssertEqual(manifest.skippedCatalogCount, 2)
    }

    func testNonPublicAudienceIsSkippedNotMalformed() throws {
        // §1: non-public catalogs are skipped-and-surfaced, distinct
        // from malformed descriptors.
        let good = descriptorJSON()
        let internalOnly = descriptorJSON(catalogId: "i").replacingOccurrences(
            of: #""audience":"public""#, with: #""audience":"internal""#
        )
        let manifest = try DiscoveryJSON.decoder().decode(
            DiscoveryProviderManifest.self,
            from: manifestJSON(catalogs: [good, internalOnly])
        )
        XCTAssertEqual(manifest.catalogs.map(\.catalogId), ["c"])
        XCTAssertEqual(manifest.nonPublicCatalogs.map(\.catalogId), ["i"])
        XCTAssertEqual(manifest.audienceSkippedCatalogCount, 1)
        XCTAssertEqual(manifest.skippedCatalogCount, 0)
    }

    func testURIRules() {
        XCTAssertTrue(DiscoveryFormat.isValidURI("https://discovery.onym.app/manifest.json"))
        // Schemes are case-insensitive (RFC 3986 §3.1): an uppercase
        // scheme validates instead of being silently dropped.
        XCTAssertTrue(DiscoveryFormat.isValidURI("HTTPS://discovery.onym.app/manifest.json"))
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
        // §7 raw-string port check: a redundant :443 is normalized
        // away by URL libraries before any parsed-port check — the raw
        // string must be rejected regardless.
        XCTAssertFalse(DiscoveryFormat.isValidURI("https://x.example:443/m.json"))
        // Integer-form and hex-form IPv4 literals.
        XCTAssertFalse(DiscoveryFormat.isValidURI("https://3232235777/m.json"))
        XCTAssertFalse(DiscoveryFormat.isValidURI("https://0xc0a80101/m.json"))
        XCTAssertFalse(DiscoveryFormat.isValidURI("https://192.168.1.0x1/m.json"))
    }

    func testURIRulesWithAllowedScheme() {
        // Seat adapters validate WebSocket endpoints under the same §7
        // rules with the scheme swapped for the one the seat expects.
        XCTAssertTrue(DiscoveryFormat.isValidURI("wss://relay.example", scheme: "wss"))
        XCTAssertTrue(DiscoveryFormat.isValidURI("wss://relay.example/inbox", scheme: "wss"))
        // Case-insensitive: `WSS://…` must validate, not silently drop.
        XCTAssertTrue(DiscoveryFormat.isValidURI("WSS://relay.example", scheme: "wss"))
        // The default stays https-only; wss passes only when asked for.
        XCTAssertFalse(DiscoveryFormat.isValidURI("wss://relay.example"))
        XCTAssertFalse(DiscoveryFormat.isValidURI("https://relay.example", scheme: "wss"))
        // The rest of the rules still apply under an allowed scheme.
        XCTAssertFalse(DiscoveryFormat.isValidURI("wss://relay.example:8443", scheme: "wss"))
        XCTAssertFalse(DiscoveryFormat.isValidURI("wss://user@relay.example", scheme: "wss"))
        XCTAssertFalse(DiscoveryFormat.isValidURI("wss://relay.example/x?a=1", scheme: "wss"))
        XCTAssertFalse(DiscoveryFormat.isValidURI("wss://192.168.1.10/x", scheme: "wss"))
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
