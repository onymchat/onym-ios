import XCTest
@testable import OnymIOS

/// Pure-XCTest tests for `DeeplinkCapture.introCapability(from:)`.
/// The `URL` overload is one line of glue; the host/scheme allowlist
/// + `IntroCapability.fromLink` call live here and are exercised
/// via the `String?` form.
///
/// Mirrors `DeeplinkCaptureTest.kt` test-for-test. Pin the allowlist
/// semantics:
///  - `https://onym.app/join?c=…` → decoded
///  - `onym://join?c=…` → decoded
///  - any other scheme/host → nil (Info.plist + entitlements are
///    the primary gate; this is defense in depth)
///  - malformed payload → nil (`fromLink`'s `InvalidIntroCapability`
///    is swallowed; the activity should no-op rather than crash on
///    a dud URL)
final class DeeplinkCaptureTests: XCTestCase {

    private let introPub = Data((0..<32).map { UInt8($0) })
    private let groupId = Data((0..<32).map { UInt8(0x40 + $0) })

    private func fixture(name: String? = nil) throws -> IntroCapability {
        try IntroCapability(
            introPublicKey: introPub,
            groupId: groupId,
            groupName: name
        )
    }

    func test_universalLink_decodes() throws {
        let link = try fixture(name: "Test").toAppLink()
        let decoded = DeeplinkCapture.introCapability(fromString: link)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.introPublicKey, introPub)
        XCTAssertEqual(decoded?.groupId, groupId)
        XCTAssertEqual(decoded?.groupName, "Test")
    }

    func test_customScheme_decodes() throws {
        let link = try fixture().toCustomSchemeLink()
        let decoded = DeeplinkCapture.introCapability(fromString: link)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.introPublicKey, introPub)
        XCTAssertNil(decoded?.groupName)
    }

    func test_foreignHost_returnsNil() throws {
        // Same path + valid `c=` payload but the host isn't ours.
        // A malicious app could open this URL at us; the in-code
        // allowlist makes the boundary explicit.
        let good = try fixture().encode()
        let link = "https://example.com/join?c=\(good)"
        XCTAssertNil(DeeplinkCapture.introCapability(fromString: link))
    }

    func test_foreignScheme_returnsNil() throws {
        let good = try fixture().encode()
        let link = "ftp://onym.app/join?c=\(good)"
        XCTAssertNil(DeeplinkCapture.introCapability(fromString: link))
    }

    func test_nilOrEmpty_returnsNil() {
        XCTAssertNil(DeeplinkCapture.introCapability(fromString: nil))
        XCTAssertNil(DeeplinkCapture.introCapability(fromString: ""))
        XCTAssertNil(DeeplinkCapture.introCapability(from: nil))
    }

    func test_malformedURL_returnsNil() {
        // `URLComponents` accepts more strings than you'd think.
        // What we really care about is that nothing crashes; the
        // allowlist filters out anything without a known
        // (scheme, host) pair.
        XCTAssertNil(DeeplinkCapture.introCapability(fromString: "not a url"))
    }

    func test_knownHostMissingC_returnsNil() {
        XCTAssertNil(DeeplinkCapture.introCapability(fromString: "https://onym.app/join"))
        XCTAssertNil(DeeplinkCapture.introCapability(fromString: "onym://join"))
    }

    func test_knownHostBadCPayload_returnsNil() {
        // Allowed scheme/host, but the `c` value is not valid
        // base64 + the JSON payload doesn't decode. `fromLink`
        // returns nil; we propagate that → callers no-op.
        XCTAssertNil(DeeplinkCapture.introCapability(fromString: "https://onym.app/join?c=not-base64!!!"))
    }

    func test_caseInsensitiveSchemeAndHost_decodes() throws {
        // RFC 3986: scheme + host are case-insensitive. Build a
        // deliberately mixed-case form to pin the normalization.
        let good = try fixture().encode()
        let link = "HTTPS://Onym.App/join?c=\(good)"
        XCTAssertNotNil(DeeplinkCapture.introCapability(fromString: link))
    }

    func test_introCapability_fromURL_overload() throws {
        // Smoke check: the `URL?` adapter routes through the same
        // logic. We trust this delegation pattern but want one
        // direct test so a future refactor that breaks the bridge
        // surfaces here.
        let link = try fixture(name: "U").toAppLink()
        let url = URL(string: link)
        let decoded = DeeplinkCapture.introCapability(from: url)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.groupName, "U")
    }
}
