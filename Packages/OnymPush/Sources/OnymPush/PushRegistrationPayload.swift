import CryptoKit
import Foundation

/// One inbox tag and the relays the push backend should watch for it.
/// The tag is the identity's public routing handle (first 8 bytes hex
/// of `SHA256("sep-inbox-v1" || inboxPublicKey)`) — already visible to
/// every relay, which is the point: registering it tells the backend
/// nothing a relay operator doesn't know, except that this device
/// wants to be woken for it.
public struct PushSubscription: Codable, Sendable, Equatable {
    public let tag: String
    public let relays: [String]

    public init(tag: String, relays: [String]) {
        self.tag = tag
        self.relays = relays
    }
}

/// Shared construction for the session payloads the user key signs.
///
/// These MUST match `payload.rs` in the push backend
/// (`onym-push/apple/src/payload.rs`) byte-for-byte, or every
/// signature check fails. Every field is length-prefixed and the
/// payload is domain-separated by context, so no two field layouts can
/// collide and a register signature can never be replayed as an
/// unregister.
///
/// The signature covers the raw APNs token even though it travels
/// encrypted (see `PushTokenEnvelope`), binding the envelope's content
/// to the session — and it covers the subscription list **exactly as
/// transmitted**: wire order, grouping, and relay counts, with no
/// normalization, so no two distinct transmitted lists share bytes.
///
/// The user key authenticates the session only. The backend verifies
/// it and discards it; nothing derived from it is stored.
public enum SignedPushSessionPayload {
    public static let registerContext = "onym-push-register-v1"
    public static let unregisterContext = "onym-push-unregister-v1"

    /// The bytes the user key signs for `POST /v1/register`.
    public static func register(
        deviceToken: Data?,
        userKey: String,
        timestamp: Date,
        apnsToken: Data,
        subscriptions: [PushSubscription]
    ) -> Data {
        bytes(
            context: registerContext,
            deviceToken: deviceToken,
            userKey: userKey,
            timestamp: timestamp,
            apnsToken: apnsToken,
            subscriptionsDigest: digest(of: subscriptions)
        )
    }

    /// The bytes the user key signs for `POST /v1/unregister`. The
    /// trailing digest slot is empty — same layout, different context.
    public static func unregister(
        deviceToken: Data?,
        userKey: String,
        timestamp: Date,
        apnsToken: Data
    ) -> Data {
        bytes(
            context: unregisterContext,
            deviceToken: deviceToken,
            userKey: userKey,
            timestamp: timestamp,
            apnsToken: apnsToken,
            subscriptionsDigest: Data()
        )
    }

    /// SHA-256 over the subscription list exactly as transmitted,
    /// grouping included: for each subscription in wire order,
    /// `len32(tag) || tag || be32(relays.count)` followed by
    /// `len32(relay) || relay` for each relay. Mirrors
    /// `subscriptions_digest` in the backend's `payload.rs`.
    ///
    /// The bare big-endian relay count binds the *shape* of the list,
    /// not just its flattened pairs: the same tag→relay pairs split
    /// into different entries digest differently, and an entry with an
    /// empty relay list still contributes bytes rather than vanishing.
    static func digest(of subscriptions: [PushSubscription]) -> Data {
        var encoded = Data()
        for subscription in subscriptions {
            append(&encoded, Data(subscription.tag.utf8))
            var count = UInt32(subscription.relays.count).bigEndian
            withUnsafeBytes(of: &count) { encoded.append(contentsOf: $0) }
            for relay in subscription.relays {
                append(&encoded, Data(relay.utf8))
            }
        }
        return Data(SHA256.hash(data: encoded))
    }

    private static func bytes(
        context: String,
        deviceToken: Data?,
        userKey: String,
        timestamp: Date,
        apnsToken: Data,
        subscriptionsDigest: Data
    ) -> Data {
        var payload = Data()
        append(&payload, Data(context.utf8))
        append(&payload, deviceToken ?? Data())
        append(&payload, Data(userKey.utf8))
        append(&payload, Data(ISO8601DateFormatter.push.string(from: timestamp).utf8))
        append(&payload, apnsToken)
        append(&payload, subscriptionsDigest)
        return payload
    }

    /// Big-endian 32-bit length prefix, so concatenation is injective.
    private static func append(_ payload: inout Data, _ field: Data) {
        var length = UInt32(field.count).bigEndian
        withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
        payload.append(field)
    }
}

extension ISO8601DateFormatter {
    /// One formatter configuration for signed payloads — the stable
    /// subset (no fractional seconds), pinned so the signed bytes
    /// can't shift with a caller's formatter settings. Matches the
    /// moderation package's formatter.
    static let push: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
