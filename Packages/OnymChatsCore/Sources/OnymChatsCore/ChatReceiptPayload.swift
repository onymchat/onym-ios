import Foundation
import OnymTransport

/// Delivery / read receipt sent back to a message's original sender.
/// Sealed + shipped over the same `InboxTransport` path as
/// `ChatMessagePayload`, addressed to the sender's inbox key.
///
/// The receiver of a chat message emits `.delivered` as soon as it
/// persists the message; it emits `.read` when the user opens the
/// thread (gated by the symmetric read-receipt setting). The original
/// sender decodes this and *raises* the matching outgoing message's
/// status — receipts never downgrade (see `MessageStatus.deliveryRank`).
///
/// Wire-format disjoint from every other inbox payload: the required
/// `kind` + `message_ids` keys appear in no other type, and it carries
/// neither `ChatMessagePayload`'s `variant`/`message_id` nor the invite
/// payloads' fields, so the dispatcher's `try? decode` fast-paths can't
/// cross-match it.
public struct ChatReceiptPayload: Codable, Equatable, Sendable {
    /// Wire schema version. Additive fields don't bump it.
    public let version: Int

    /// Group the acknowledged messages belong to. The sender scopes the
    /// status update to this group's thread.
    public let groupID: Data

    /// BLS pubkey hex of the party emitting the receipt (the recipient
    /// of the original message). Informational under v1 — any
    /// recipient's receipt raises the sender's status — but recorded so
    /// per-member delivered/read tracking can land later without a wire
    /// bump.
    public let senderBlsPubkeyHex: String

    public let kind: Kind

    /// The messages being acknowledged. Batched so opening a thread with
    /// many unread messages ships one receipt, not one per message.
    public let messageIDs: [UUID]

    public enum Kind: String, Codable, Sendable {
        case delivered
        case read
    }

    public init(
        version: Int,
        groupID: Data,
        senderBlsPubkeyHex: String,
        kind: Kind,
        messageIDs: [UUID]
    ) {
        self.version = version
        self.groupID = groupID
        self.senderBlsPubkeyHex = senderBlsPubkeyHex
        self.kind = kind
        self.messageIDs = messageIDs
    }

    enum CodingKeys: String, CodingKey {
        case version
        case groupID = "group_id"
        case senderBlsPubkeyHex = "sender_bls_pubkey_hex"
        case kind
        case messageIDs = "message_ids"
    }
}
