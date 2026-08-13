import Foundation
import XCTest
@testable import OnymDiscovery

/// THE cross-language agreement test (profile §3 / §10): the
/// key-order-scrambled `canonical-input.json` must canonicalize to
/// exactly the bytes of `canonical-bytes.bin`, byte for byte —
/// structural signature removal, UTF-8-byte-order key sort at every
/// level, compact output, unescaped slashes.
final class DiscoveryCanonicalTests: XCTestCase {
    func testCanonicalInputCanonicalizesToExactReferenceBytes() throws {
        let input = try Fixture.bytes("canonical-input.json")
        let expected = try Fixture.bytes("canonical-bytes.bin")
        let canonical = try DiscoveryCanonical.signingBytes(of: input)
        XCTAssertEqual(canonical, expected)
    }

    func testSignatureIsRemovedStructurallyNotTextually() throws {
        // A planted copy of the signature *value* inside a nested
        // string must survive; only the top-level "signature" field is
        // dropped.
        let raw = Data(#"{"b":"sig SIG here","signature":"SIG","a":{"signature":"nested"}}"#.utf8)
        let canonical = try DiscoveryCanonical.signingBytes(of: raw)
        XCTAssertEqual(
            String(data: canonical, encoding: .utf8),
            #"{"a":{"signature":"nested"},"b":"sig SIG here"}"#
        )
    }

    func testNonObjectTopLevelIsRejected() {
        XCTAssertThrowsError(try DiscoveryCanonical.signingBytes(of: Data("[1,2]".utf8)))
        XCTAssertThrowsError(try DiscoveryCanonical.signingBytes(of: Data("not json".utf8)))
    }

    func testFixtureDocumentsRoundTripToTheirSignedBytes() throws {
        // Sanity for the serializer agreement on the real documents:
        // canonical(manifest bytes) must reproduce the manifest minus
        // its signature field — i.e. the fixture files themselves are
        // already in canonical member order.
        for name in ["provider-manifest.json", "snapshot-1.json", "destination-manifest.json"] {
            let raw = try Fixture.bytes(name)
            let canonical = try DiscoveryCanonical.signingBytes(of: raw)
            let text = String(data: raw, encoding: .utf8)!
            // Strip the signature member textually — safe here because
            // we control the fixtures and each has exactly one.
            let stripped = text.replacingOccurrences(
                of: #","signature":"[^"]*""#,
                with: "",
                options: .regularExpression
            )
            XCTAssertEqual(String(data: canonical, encoding: .utf8), stripped, name)
        }
    }
}
