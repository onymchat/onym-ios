import CryptoKit
import Foundation

/// NIP-01 Nostr event. Codable on the wire, integrity-checked via
/// `verifyEventID`, and constructable through `build` which computes the
/// canonical id and asks a `NostrSigner` to produce the Schnorr signature.
struct NostrEvent: Codable, Identifiable, Sendable {
    let id: String
    let pubkey: String
    let createdAt: Int64
    let kind: Int
    let tags: [[String]]
    let content: String
    let sig: String

    enum CodingKeys: String, CodingKey {
        case id, pubkey, kind, tags, content, sig
        case createdAt = "created_at"
    }

    var jsonObject: [String: Any] {
        [
            "id": id,
            "pubkey": pubkey,
            "created_at": createdAt,
            "kind": kind,
            "tags": tags,
            "content": content,
            "sig": sig,
        ]
    }

    /// Recompute the event id from canonical JSON and compare. Catches
    /// relay-level tampering of `content`, `pubkey`, or `tags`. Full
    /// Schnorr signature verification is a separate concern.
    func verifyEventID() -> Bool {
        let canonical: [Any] = [0, pubkey, createdAt, kind, tags, content]
        guard let serialized = try? JSONSerialization.data(withJSONObject: canonical, options: []) else {
            return false
        }
        let hash = SHA256.hash(data: serialized)
        let computedID = Data(hash).map { String(format: "%02x", $0) }.joined()
        return computedID == id
    }

    /// App-local millisecond timestamp from `["ms", "..."]`. NIP-01's
    /// `created_at` is second-resolution; the extra tag is a private
    /// convention added by `build` so we can order messages within a
    /// second. Other clients ignore it.
    var displayMilliseconds: Int64 {
        if let msTag = tags.first(where: { $0.first == "ms" && $0.count >= 2 }),
           let ms = Int64(msTag[1]), ms >= 0 {
            return ms
        }
        return createdAt * 1000
    }

    /// Build a NIP-01 event: append the `["ms", ...]` ordering tag,
    /// compute the canonical id, sign it with `signer`. The signer's
    /// `publicKey` becomes the event `pubkey` — pass an ephemeral signer
    /// for metadata-hiding (kinds 44114 / 34113 in this codebase) so the
    /// outer pubkey can't be used to cluster related events.
    static func build(
        kind: Int,
        tags: [[String]],
        content: String,
        signer: NostrSigner
    ) throws -> NostrEvent {
        let pubkeyBytes = try signer.publicKey()
        let pubkeyHex = pubkeyBytes.map { String(format: "%02x", $0) }.joined()

        let unixMs = Int64(Date().timeIntervalSince1970 * 1000)
        let createdAt = unixMs / 1000
        var allTags = tags
        allTags.append(["ms", String(unixMs)])

        let canonical: [Any] = [0, pubkeyHex, createdAt, kind, allTags, content]
        let serialized = try JSONSerialization.data(withJSONObject: canonical, options: [])
        let eventID = Data(SHA256.hash(data: serialized))
        let eventIDHex = eventID.map { String(format: "%02x", $0) }.joined()

        let signature = try signer.signEventID(eventID)
        let sigHex = signature.map { String(format: "%02x", $0) }.joined()

        return NostrEvent(
            id: eventIDHex,
            pubkey: pubkeyHex,
            createdAt: createdAt,
            kind: kind,
            tags: allTags,
            content: content,
            sig: sigHex
        )
    }
}
