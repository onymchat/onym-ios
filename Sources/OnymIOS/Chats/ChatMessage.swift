import Foundation

/// One persisted chat message — what the UI renders and what the
/// store hands back. Mirrors `ChatMessagePayload` but flattens the
/// `variant` into a `body` + `groupType` pair because every variant
/// has a body (today) and a single type column is enough for the
/// store-level layer.
///
/// Stable across direction: incoming and outgoing messages share the
/// same shape, distinguished by `direction` + `status`. Each row
/// belongs to exactly one `ownerIdentityID` so cascade-delete on
/// identity removal is a `WHERE owner = ?` over the messages table —
/// same pattern as `ChatGroup`.
struct ChatMessage: Equatable, Sendable, Identifiable {
    /// Stable per-message UUID. Matches `ChatMessagePayload.messageID`
    /// for incoming rows; minted locally at send time for outgoing.
    /// Receive-side dedup is a uniqueness check on this ID.
    let id: UUID

    /// 64-char hex of the parent `ChatGroup.id`. Plain (queryable) on
    /// disk so `list(groupID:)` is a single `#Predicate`.
    let groupID: String

    /// Identity that owns this row. Inherits from
    /// `ChatGroup.ownerIdentityID` of the parent group at write time.
    let ownerIdentityID: IdentityID

    /// Lowercase BLS pubkey hex (96 chars) of the sender. Matches the
    /// `memberProfiles` keying — the dispatcher will use this to look
    /// up the sender's `sendingPubkey` for envelope-signature
    /// verification in PR 4.
    let senderBlsPubkeyHex: String

    let body: String

    /// Sender's claim of when they sent. For incoming, taken from
    /// the payload's `sent_at_millis`. For outgoing, the local clock
    /// at submit time. Drives chronological display order.
    let sentAt: Date

    let direction: MessageDirection

    /// Mutable for outgoing (pending → sent / failed). For incoming,
    /// always `.received` at insert and never changes.
    let status: MessageStatus

    /// Mirrors `ChatMessageVariant.kind`. Stored alongside the body so
    /// migrating to multi-variant rendering later doesn't need to
    /// re-fetch the group to learn the flavour.
    let groupType: SEPGroupType
}

enum MessageDirection: String, Codable, Sendable {
    case incoming
    case outgoing
}

enum MessageStatus: String, Codable, Sendable {
    /// Outgoing only — in flight to transport.
    case pending
    /// Outgoing only — transport accepted (per-envelope errors
    /// resolved or tolerated).
    case sent
    /// Outgoing only — transport rejected. Retry via
    /// `SendMessageInteractor` flips back to `.pending`.
    case failed
    /// Incoming only — payload decoded and persisted.
    case received
}
