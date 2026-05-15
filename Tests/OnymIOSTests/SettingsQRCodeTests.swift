import XCTest
@testable import OnymIOS

/// Producer-side checks for the inbox-key invite URL emitted by
/// Settings → Invite Key. The consumer side
/// (`CreateGroupFlow.canonicalizeInviteKey`) lives in
/// `CreateGroupFlowTests`; the round-trip case here is the
/// load-bearing assertion that the QR is actually scannable —
/// without it the producer can drift to an encoding the consumer
/// silently rejects.
final class SettingsQRCodeTests: XCTestCase {

    func test_settingsInviteURL_encodesFullKey() {
        // Truncating the key would mean the scanning device couldn't
        // reconstruct the 32-byte inbox handle the InviteByKey paste
        // field expects (validator requires 64 hex chars). 32 bytes
        // → 64 hex chars; anything shorter is decorative.
        let key = Data((0..<32).map { UInt8($0) })
        let url = settingsInviteURL(blsPublicKey: key)
        XCTAssertTrue(url.hasPrefix("https://onym.app?payload="))
        let payload = url.replacingOccurrences(of: "https://onym.app?payload=", with: "")
        XCTAssertEqual(payload.count, 64, "32 bytes should serialise to 64 hex chars")
        XCTAssertEqual(payload, "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    }

    @MainActor
    func test_settingsInviteURL_roundTripsThroughCanonicalize() {
        // Producer ↔ consumer contract: a URL emitted by
        // `settingsInviteURL` must canonicalize back to the original
        // 64-char hex on the scanning device. If this fails, the QR
        // scans but the InviteByKey validator rejects it as
        // "doesn't look like a valid inbox key" — the symptom that
        // the truncated `prefix(22)` regression produced before this
        // change.
        let key = Data((0..<32).map { UInt8($0 ^ 0x5A) })
        let expectedHex = key.map { String(format: "%02x", $0) }.joined()
        let url = settingsInviteURL(blsPublicKey: key)
        XCTAssertEqual(CreateGroupFlow.canonicalizeInviteKey(url), expectedHex)
    }
}
