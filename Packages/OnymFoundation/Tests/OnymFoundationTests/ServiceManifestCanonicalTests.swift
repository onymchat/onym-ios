import Foundation
import XCTest
@testable import OnymFoundation

/// The canonical form only works if the *other* side — an operator's
/// publishing pipeline in any language — reproduces it byte for byte.
/// These tests pin `ServiceManifestCanonical` to the §3 / serde_json
/// rules on exactly the vectors where Foundation's
/// `JSONSerialization.sortedKeys` (case-insensitive, numeric-aware)
/// silently diverges, and prove cross-language agreement against a
/// manifest signed by the Rust reference CLI.
final class ServiceManifestCanonicalTests: XCTestCase {
    private func canonical(_ json: String) throws -> String {
        let bytes = try ServiceManifestCanonical.signingBytes(of: Data(json.utf8))
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Key order is UTF-8 byte order

    /// The case-divergence vector: byte order puts `seatID` (capital
    /// `I`, 0x49) before `seatable` (lowercase `a`, 0x61); Foundation's
    /// case-insensitive `.sortedKeys` puts `seatable` first.
    func testCaseDivergentKeysSortByByteOrder() throws {
        XCTAssertEqual(
            try canonical(#"{"seatable":1,"seatID":2,"signature":"sig"}"#),
            #"{"seatID":2,"seatable":1}"#
        )
    }

    /// The numeric-awareness vector: byte order puts `relay10` before
    /// `relay2` (`'1'` < `'2'` at the deciding byte); a numeric-aware
    /// sort flips them.
    func testNumericLookingKeysSortByByteOrderNotNumerically() throws {
        XCTAssertEqual(
            try canonical(#"{"relay2":"b","relay10":"a"}"#),
            #"{"relay10":"a","relay2":"b"}"#
        )
    }

    /// Guard: this is what `JSONSerialization.sortedKeys` would emit
    /// on the same vectors — and it must not be what we emit. If
    /// Foundation ever changes to byte order this fails, which is the
    /// moment to revisit the comment on `ServiceManifestCanonical`.
    func testJSONSerializationOrderingWouldDiffer() throws {
        let caseVector = try JSONSerialization.data(
            withJSONObject: ["seatID": 2, "seatable": 1],
            options: [.sortedKeys]
        )
        XCTAssertEqual(String(decoding: caseVector, as: UTF8.self), #"{"seatable":1,"seatID":2}"#)

        let numericVector = try JSONSerialization.data(
            withJSONObject: ["relay10": "a", "relay2": "b"],
            options: [.sortedKeys]
        )
        XCTAssertEqual(String(decoding: numericVector, as: UTF8.self), #"{"relay2":"b","relay10":"a"}"#)
    }

    /// Nested objects sort at every level, and only the *top-level*
    /// `signature` is removed — a nested one is ordinary signed content.
    func testNestedKeysSortAndNestedSignatureIsKept() throws {
        XCTAssertEqual(
            try canonical(#"{"signature":"top","b":{"signature":"inner","a":1},"a":[{"z":1,"y":2}]}"#),
            #"{"a":[{"y":2,"z":1}],"b":{"a":1,"signature":"inner"}}"#
        )
    }

    // MARK: - §3 pinned escaping and number form

    /// Exactly `"` `\` and U+0000–U+001F are escaped; `/` and
    /// non-ASCII are not. serde_json's exact behavior.
    func testEscapingIsThePinnedSet() throws {
        // Input decodes to: a/b, newline, e-acute, U+0001. Canonical
        // form escapes the newline (two-character \\n) and the control
        // character (lowercase \\u0001), leaves / and e-acute untouched.
        let input = "{\"k\":\"a\\/b\\n\\u00e9\\u0001\"}"
        XCTAssertEqual(
            try canonical(input),
            "{\"k\":\"a/b\\n\u{e9}\\u0001\"}"
        )
    }

    /// §3: all numbers are non-negative integers — a float has no
    /// canonical form, so it must be rejected, never re-serialized
    /// into whatever form `JSONSerialization` happens to pick.
    func testNonIntegerNumberIsRejected() {
        XCTAssertThrowsError(try canonical(#"{"a":1.5}"#)) { error in
            guard case ServiceManifestError.manifestInvalid = error else {
                return XCTFail("expected manifestInvalid, got \(error)")
            }
        }
    }

    func testIntegersAndBoolsKeepTheirForm() throws {
        XCTAssertEqual(
            try canonical(#"{"n":42,"t":true,"f":false,"z":null}"#),
            #"{"f":false,"n":42,"t":true,"z":null}"#
        )
    }

    // MARK: - Cross-language proof

    /// A destination manifest signed by the Rust reference CLI
    /// (`onym-discovery` `tests/fixtures/destination-manifest.json`,
    /// serde_json canonical bytes). If our canonical bytes differed
    /// from serde_json's on any byte, the Ed25519 verify would fail —
    /// so a passing review is cross-language agreement, not the
    /// self-consistency of signing and verifying with the same code.
    func testRustSignedFixtureVerifiesEndToEnd() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "destination-manifest",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let raw = try Data(contentsOf: url)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-14T00:00:00Z"))

        let reviewed = try ServiceManifestReviewer().review(
            raw: raw,
            expectedDigest: ServiceManifestFormat.sha256Digest(of: raw),
            now: now
        )
        let manifest = reviewed.signedManifest
        XCTAssertEqual(manifest.componentId, "onym:component:onym-courier")
        XCTAssertEqual(manifest.seat, "transport.message")
        XCTAssertEqual(manifest.offers.map(\.offerId), ["courier-free-v1"])
        XCTAssertEqual(manifest.rawBytes, raw)
    }

    /// The same fixture with one content byte flipped must fail the
    /// signature — pinning that the fixture test above actually
    /// exercises the verify, not a vacuous pass.
    func testTamperedRustFixtureFailsSignature() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "destination-manifest",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let raw = try Data(contentsOf: url)
        var text = String(decoding: raw, as: UTF8.self)
        XCTAssertTrue(text.contains("wss://nostr.onym.app"))
        text = text.replacingOccurrences(of: "wss://nostr.onym.app", with: "wss://nostr.evil.app")
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-14T00:00:00Z"))

        XCTAssertThrowsError(
            try ServiceManifestReviewer().review(raw: Data(text.utf8), now: now)
        ) { error in
            guard case ServiceManifestError.signatureInvalid = error else {
                return XCTFail("expected signatureInvalid, got \(error)")
            }
        }
    }
}
