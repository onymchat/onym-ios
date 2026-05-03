import XCTest
@testable import OnymIOS

/// Cross-platform wire-format pin. The hand-constructed JSON byte
/// patterns below MUST decode to the same `IntroCapability` on both
/// onym-ios and onym-android — and a matching test in
/// `IntroCapabilityInteropTest.kt` MUST cover the same vectors. Keep
/// the two in lockstep; never edit one without also updating the
/// other.
///
/// Why hand-constructed JSON instead of re-encoded base64 strings?
/// JSON object key order isn't semantically meaningful, but
/// `JSONEncoder` and `kotlinx.serialization.Json` don't promise
/// matching key ordering on emit. So we pin the **decoder** contract
/// — given identical input bytes, both platforms produce identical
/// `IntroCapability` values — and let each platform freely re-encode
/// its own way. The roundtrip test inside the same suite still
/// proves encoder→decoder is a closed loop on each platform.
final class IntroCapabilityInteropTests: XCTestCase {

    // MARK: - Vector A — minimal, no group_name

    /// `intro_pub` is 32 bytes of `0x01`, `group_id` is 32 bytes of
    /// `0x02`. Inner base64 uses standard alphabet **with padding**
    /// (Swift `JSONEncoder` `.base64` default + Android
    /// `Base64.getEncoder()`). 32 bytes encodes to 44 base64 chars
    /// (32 * 4/3 rounded up + padding).
    func test_vectorA_decodesMinimalShape() throws {
        let pub = Data(repeating: 0x01, count: 32)
        let gid = Data(repeating: 0x02, count: 32)
        let pubB64 = pub.base64EncodedString()  // 44 chars w/ trailing '='
        let gidB64 = gid.base64EncodedString()
        let json = #"{"intro_pub":"\#(pubB64)","group_id":"\#(gidB64)"}"#

        let payload = Self.urlSafeBase64NoPadding(json.data(using: .utf8)!)
        let cap = try IntroCapability.decode(payload)

        XCTAssertEqual(cap.introPublicKey, pub)
        XCTAssertEqual(cap.groupId, gid)
        XCTAssertNil(cap.groupName, "Vector A omits group_name → must decode to nil")
    }

    // MARK: - Vector B — with group_name "Family"

    func test_vectorB_decodesWithGroupName() throws {
        let pub = Data((0..<32).map { UInt8($0) })          // 0x00..0x1F
        let gid = Data((0..<32).map { UInt8(0xFF - $0) })   // 0xFF..0xE0
        let pubB64 = pub.base64EncodedString()
        let gidB64 = gid.base64EncodedString()
        let json = #"{"intro_pub":"\#(pubB64)","group_id":"\#(gidB64)","group_name":"Family"}"#

        let payload = Self.urlSafeBase64NoPadding(json.data(using: .utf8)!)
        let cap = try IntroCapability.decode(payload)

        XCTAssertEqual(cap.introPublicKey, pub)
        XCTAssertEqual(cap.groupId, gid)
        XCTAssertEqual(cap.groupName, "Family")
    }

    // MARK: - Vector C — group_name with non-ASCII (UTF-8 quoted)

    /// Confirms UTF-8 round-trips through both platforms' JSON
    /// readers — group names like "Семья" or "👨‍👩‍👧" must survive
    /// the wire intact.
    func test_vectorC_decodesUtf8GroupName() throws {
        let pub = Data(repeating: 0xAB, count: 32)
        let gid = Data(repeating: 0xCD, count: 32)
        let pubB64 = pub.base64EncodedString()
        let gidB64 = gid.base64EncodedString()
        // "Семья 👨‍👩‍👧" — Cyrillic + ZWJ-emoji sequence. JSON requires
        // either raw UTF-8 or `\uXXXX` escapes; we ship raw UTF-8
        // since both `JSONEncoder` and `kotlinx.serialization` emit
        // raw by default.
        let groupName = "Семья 👨‍👩‍👧"
        let json = #"{"intro_pub":"\#(pubB64)","group_id":"\#(gidB64)","group_name":"\#(groupName)"}"#

        let payload = Self.urlSafeBase64NoPadding(json.data(using: .utf8)!)
        let cap = try IntroCapability.decode(payload)

        XCTAssertEqual(cap.introPublicKey, pub)
        XCTAssertEqual(cap.groupId, gid)
        XCTAssertEqual(cap.groupName, groupName)
    }

    // MARK: - Reverse direction: iOS-minted payload must round-trip

    /// Encoder smoke check: decode our own emit + reconstruct.
    /// Per-platform encoders may differ in key order, but a
    /// freshly-minted payload must always decode back to the same
    /// values on the same platform. Pair with a Kotlin
    /// `@Test fun encodedHere_decodesOnAndroid()` in the matching
    /// PR on Android.
    func test_iosEncoded_decodesBack() throws {
        let original = try IntroCapability(
            introPublicKey: Data((0..<32).map { UInt8(($0 * 13 + 7) & 0xFF) }),
            groupId: Data((0..<32).map { UInt8(($0 * 17 + 5) & 0xFF) }),
            groupName: "Crew"
        )
        let payload = original.encode()
        let decoded = try IntroCapability.decode(payload)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Helpers

    private static func urlSafeBase64NoPadding(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }
}
