import XCTest
@testable import OnymPush

/// The signed session payload MUST match `payload.rs` in the push
/// backend byte-for-byte — these are the same properties and fixtures
/// pinned on the Rust side, so drift on either end fails a build
/// before it refuses every real signature in production.
final class PushRegistrationPayloadTests: XCTestCase {
    private let userKey = "onym:key:aabb"
    private let deviceToken = Data("device-token".utf8)
    private let timestamp = ISO8601DateFormatter.push.date(from: "2026-08-22T12:00:00Z")!
    private let apnsToken = Data([0x0a, 0x0b, 0x0c, 0x0d, 0xee, 0xff])
    private let subscriptions = [
        PushSubscription(
            tag: "a1b2c3d4e5f60718",
            relays: ["wss://nostr.onym.app", "wss://relay.example.com"]
        ),
        PushSubscription(tag: "00ff00ff00ff00ff", relays: ["wss://nostr.onym.app"]),
    ]

    func testFieldsAreLengthPrefixedBigEndian() {
        let payload = SignedPushSessionPayload.unregister(
            deviceToken: Data("ab".utf8),
            userKey: "k",
            timestamp: timestamp,
            apnsToken: Data([0x01])
        )
        let context = SignedPushSessionPayload.unregisterContext
        // context + token(2) + userKey(1) + timestamp(20) + apnsToken(1)
        // + empty digest, each with a 4-byte prefix.
        XCTAssertEqual(payload.count, 4 * 6 + context.count + 2 + 1 + 20 + 1)
        XCTAssertEqual(Array(payload.prefix(4)), [0, 0, 0, UInt8(context.count)])
    }

    func testRegisterAndUnregisterAreDomainSeparated() {
        let register = SignedPushSessionPayload.register(
            deviceToken: deviceToken,
            userKey: userKey,
            timestamp: timestamp,
            apnsToken: apnsToken,
            subscriptions: []
        )
        let unregister = SignedPushSessionPayload.unregister(
            deviceToken: deviceToken,
            userKey: userKey,
            timestamp: timestamp,
            apnsToken: apnsToken
        )
        XCTAssertNotEqual(register, unregister)
    }

    /// The digest covers the wire order — reordering the subscription
    /// list is a different signature, because the backend recomputes
    /// from exactly what was transmitted.
    func testDigestIsOrderSensitiveAndInjective() {
        let reversed = [subscriptions[1], subscriptions[0]]
        XCTAssertNotEqual(
            SignedPushSessionPayload.digest(of: subscriptions),
            SignedPushSessionPayload.digest(of: reversed)
        )
        // Length prefixes: no two different field splits collide.
        XCTAssertNotEqual(
            SignedPushSessionPayload.digest(of: [PushSubscription(tag: "ab", relays: ["c"])]),
            SignedPushSessionPayload.digest(of: [PushSubscription(tag: "a", relays: ["bc"])])
        )
    }

    /// An absent device token and an empty one encode identically —
    /// intentional, matching the moderation payload's contract.
    func testAbsentAndEmptyDeviceTokenAgree() {
        XCTAssertEqual(
            SignedPushSessionPayload.register(
                deviceToken: nil, userKey: userKey, timestamp: timestamp,
                apnsToken: apnsToken, subscriptions: []
            ),
            SignedPushSessionPayload.register(
                deviceToken: Data(), userKey: userKey, timestamp: timestamp,
                apnsToken: apnsToken, subscriptions: []
            )
        )
    }

    // ─── Cross-implementation fixtures ───────────────────────────────
    //
    // These hex strings are what THIS implementation produced over the
    // inputs above; the backend's `payload.rs` pins the same strings.
    // Regenerate from Swift — never by hand — if the format changes,
    // and update both sides in the same change.

    func testRegisterFixtureMatchesTheBackend() {
        let expected = "000000156f6e796d2d707573682d72656769737465722d76310000000c646576696365"
            + "2d746f6b656e0000000d6f6e796d3a6b65793a6161626200000014323032362d30382d"
            + "32325431323a30303a30305a000000060a0b0c0deeff000000203ae773f8c0e9d68"
            + "10aadf1564c3c63821a019269b84d50ddccb902878399fc48"
        let payload = SignedPushSessionPayload.register(
            deviceToken: deviceToken,
            userKey: userKey,
            timestamp: timestamp,
            apnsToken: apnsToken,
            subscriptions: subscriptions
        )
        XCTAssertEqual(hex(payload), expected)
    }

    func testRegisterWithoutTokenFixtureMatchesTheBackend() {
        let expected = "000000156f6e796d2d707573682d72656769737465722d7631000000000000000d6f6e"
            + "796d3a6b65793a6161626200000014323032362d30382d32325431323a30303a30305a"
            + "000000060a0b0c0deeff000000203ae773f8c0e9d6810aadf1564c3c63821a019269b8"
            + "4d50ddccb902878399fc48"
        let payload = SignedPushSessionPayload.register(
            deviceToken: nil,
            userKey: userKey,
            timestamp: timestamp,
            apnsToken: apnsToken,
            subscriptions: subscriptions
        )
        XCTAssertEqual(hex(payload), expected)
    }

    func testUnregisterFixtureMatchesTheBackend() {
        let expected = "000000176f6e796d2d707573682d756e72656769737465722d76310000000c64657669"
            + "63652d746f6b656e0000000d6f6e796d3a6b65793a6161626200000014323032362d30"
            + "382d32325431323a30303a30305a000000060a0b0c0deeff00000000"
        let payload = SignedPushSessionPayload.unregister(
            deviceToken: deviceToken,
            userKey: userKey,
            timestamp: timestamp,
            apnsToken: apnsToken
        )
        XCTAssertEqual(hex(payload), expected)
    }

    func testSubscriptionsDigestFixtureMatchesTheBackend() {
        XCTAssertEqual(
            hex(SignedPushSessionPayload.digest(of: subscriptions)),
            "3ae773f8c0e9d6810aadf1564c3c63821a019269b84d50ddccb902878399fc48"
        )
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
