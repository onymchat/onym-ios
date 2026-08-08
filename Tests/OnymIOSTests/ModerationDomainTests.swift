import XCTest
@testable import OnymModeration

/// Domain primitives: the duration grammar, ban terms, manifest hash
/// pinning, and mandate signing-bytes determinism — the properties
/// consent immutability rests on.
final class ModerationDomainTests: XCTestCase {

    // MARK: - ISO8601Duration

    func testParsesDayGranularDurations() throws {
        XCTAssertEqual(try ISO8601Duration(parsing: "P1D").days, 1)
        XCTAssertEqual(try ISO8601Duration(parsing: "P3D").days, 3)
        XCTAssertEqual(try ISO8601Duration(parsing: "P30D").days, 30)
        XCTAssertEqual(try ISO8601Duration(parsing: "P365D").days, 365)
        XCTAssertEqual(try ISO8601Duration(parsing: "P3D").timeInterval, 3 * 86_400)
        XCTAssertEqual(try ISO8601Duration(parsing: "P7D").raw, "P7D")
    }

    func testRejectsUnsupportedDurations() {
        for raw in ["", "P", "PD", "P0D", "P-1D", "PT1H", "P3W", "3D", "P3", "p3d"] {
            XCTAssertThrowsError(try ISO8601Duration(parsing: raw), raw)
        }
    }

    // MARK: - BanTerm

    func testBanTermDecodesPermanentAndDuration() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(
            try decoder.decode(BanTerm.self, from: Data("\"permanent\"".utf8)),
            .permanent
        )
        XCTAssertEqual(
            try decoder.decode(BanTerm.self, from: Data("\"P90D\"".utf8)),
            .duration(try ISO8601Duration(parsing: "P90D"))
        )
        XCTAssertThrowsError(
            try decoder.decode(BanTerm.self, from: Data("\"forever\"".utf8))
        )
    }

    // MARK: - Manifest hash pinning

    func testManifestHashIsOverExactBytes() {
        // SHA-256("abc") — the FIPS 180-2 test vector.
        XCTAssertEqual(
            SignedManifest.hash(of: Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testOneByteDifferenceChangesManifestHash() {
        let original = Data("{\"version\":1}".utf8)
        let tweaked = Data("{\"version\":2}".utf8)
        XCTAssertNotEqual(SignedManifest.hash(of: original), SignedManifest.hash(of: tweaked))
    }

    // MARK: - Mandate signing bytes

    private func fixtureMandate(signatures: [String] = []) -> ModerationMandate {
        ModerationMandate(
            user: "onym:key:user",
            interface: "onym:component:onym-ios",
            authority: "onym:component:authority",
            manifestHash: "aa",
            classes: ["csam"],
            deviceBinding: "enrollment-1",
            acceptedAt: Date(timeIntervalSince1970: 1_700_000_000),
            signatures: signatures
        )
    }

    func testSigningBytesAreDeterministic() throws {
        let mandate = fixtureMandate()
        XCTAssertEqual(try mandate.signingBytes(), try mandate.signingBytes())
    }

    func testSigningBytesExcludeSignatures() throws {
        // The signed form must not change when signatures are added —
        // otherwise the interface countersignature would invalidate
        // the user's own signature.
        let unsigned = fixtureMandate()
        let signed = fixtureMandate(signatures: ["user-sig", "interface-sig"])
        XCTAssertEqual(try unsigned.signingBytes(), try signed.signingBytes())
        let bytes = try signed.signingBytes()
        XCTAssertFalse(String(data: bytes, encoding: .utf8)!.contains("signatures"))
    }

    func testMandateHashStableAcrossCountersigning() throws {
        // `mandateRef` in notices/verdicts must resolve the same
        // mandate before and after the interface countersigns.
        XCTAssertEqual(
            try fixtureMandate(signatures: ["user-sig"]).mandateHash(),
            try fixtureMandate(signatures: ["user-sig", "interface-sig"]).mandateHash()
        )
    }
}
