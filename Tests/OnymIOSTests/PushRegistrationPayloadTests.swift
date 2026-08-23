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

    /// The digest binds grouping, not just the flattened (tag, relay)
    /// pairs: the per-entry relay count makes one entry carrying two
    /// relays digest differently from the same tag split across two
    /// entries. This exact collision existed before the count was
    /// added — pinned here so it cannot come back.
    func testDigestIsGroupingSensitive() {
        let grouped = [
            PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://r1.example", "wss://r2.example"]),
        ]
        let split = [
            PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://r1.example"]),
            PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://r2.example"]),
        ]
        XCTAssertNotEqual(
            SignedPushSessionPayload.digest(of: grouped),
            SignedPushSessionPayload.digest(of: split)
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
            + "32325431323a30303a30305a000000060a0b0c0deeff00000020058ea2fe4226d7fb35"
            + "a804975feb9961e1800113e70fd39a7dd61647cbdd92b5"
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
            + "000000060a0b0c0deeff00000020058ea2fe4226d7fb35a804975feb9961e1800113e7"
            + "0fd39a7dd61647cbdd92b5"
        let payload = SignedPushSessionPayload.register(
            deviceToken: nil,
            userKey: userKey,
            timestamp: timestamp,
            apnsToken: apnsToken,
            subscriptions: subscriptions
        )
        XCTAssertEqual(hex(payload), expected)
        // The empty-Data spelling is fixture-pinned too, not just
        // proven equal to nil elsewhere: both spellings must produce
        // these exact backend-verified bytes.
        let emptyToken = SignedPushSessionPayload.register(
            deviceToken: Data(),
            userKey: userKey,
            timestamp: timestamp,
            apnsToken: apnsToken,
            subscriptions: subscriptions
        )
        XCTAssertEqual(hex(emptyToken), expected)
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
            "058ea2fe4226d7fb35a804975feb9961e1800113e70fd39a7dd61647cbdd92b5"
        )
    }

    /// The digest binds grouping, not just flattened pairs: an entry
    /// with an empty relay list still contributes bytes (tag plus a
    /// zero relay count), so `{tag, relays: []}` differs from omitting
    /// the entry — and an empty subscription list digests to
    /// SHA-256 of nothing, both pinned against the backend.
    func testEmptyRelayListsStillShapeTheDigest() {
        let bareEntry = [PushSubscription(tag: "a1b2c3d4e5f60718", relays: [])]
        XCTAssertEqual(
            hex(SignedPushSessionPayload.digest(of: bareEntry)),
            "03a2f27940d35cb25a941ba710b844a82cf4aabf50aa0c893785cf8726aab8b8"
        )
        XCTAssertEqual(
            hex(SignedPushSessionPayload.digest(of: [])),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertNotEqual(
            SignedPushSessionPayload.digest(of: bareEntry),
            SignedPushSessionPayload.digest(of: [])
        )
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
