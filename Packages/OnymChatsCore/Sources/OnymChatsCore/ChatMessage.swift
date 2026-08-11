import Foundation
import OnymChain
import OnymIdentity

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
public struct ChatMessage: Equatable, Sendable, Identifiable {
    /// Stable per-message UUID. Matches `ChatMessagePayload.messageID`
    /// for incoming rows; minted locally at send time for outgoing.
    /// Receive-side dedup is a uniqueness check on this ID.
    public let id: UUID

    /// 64-char hex of the parent `ChatGroup.id`. Plain (queryable) on
    /// disk so `list(groupID:)` is a single `#Predicate`.
    public let groupID: String

    /// Identity that owns this row. Inherits from
    /// `ChatGroup.ownerIdentityID` of the parent group at write time.
    public let ownerIdentityID: IdentityID

    /// Lowercase BLS pubkey hex (96 chars) of the sender. Matches the
    /// `memberProfiles` keying — the dispatcher will use this to look
    /// up the sender's `sendingPubkey` for envelope-signature
    /// verification in PR 4.
    public let senderBlsPubkeyHex: String

    public let body: String

    /// Sender's claim of when they sent. For incoming, taken from
    /// the payload's `sent_at_millis`. For outgoing, the local clock
    /// at submit time. Drives chronological display order.
    public let sentAt: Date

    public let direction: MessageDirection

    /// Mutable for outgoing (pending → sent / failed). For incoming,
    /// always `.received` at insert and never changes.
    public let status: MessageStatus

    /// The message this one replies to, if any. Mirrors
    /// `ChatMessagePayload.replyToMessageID`. Only the target ID is
    /// stored — the UI resolves the quoted sender + body by looking
    /// this up among the group's other messages at render time, so a
    /// target that isn't on this device renders as "message
    /// unavailable" instead of carrying a stale copy of its text.
    public let replyToMessageID: UUID?

    /// Mirrors `ChatMessageVariant.kind`. Stored alongside the body so
    /// migrating to multi-variant rendering later doesn't need to
    /// re-fetch the group to learn the flavour.
    public let groupType: SEPGroupType

    /// Why the last send attempt failed. Non-nil only when `status ==
    /// .failed`; cleared when a retry flips the row back to `.pending`.
    /// Categorized by `SendMessageInteractor` from the transport error
    /// so the chat UI can tell the user what went wrong instead of a
    /// bare red bang.
    public let failureReason: SendFailureReason?

    /// Encrypted image attached to this message, if any. Mirrors
    /// `ChatMessagePayload.attachment`; `body` is the caption when this
    /// is present. The blob is fetched + decrypted lazily at render
    /// time (see `ChatImageLoader`), not stored inline.
    public let imageAttachment: ChatImageAttachment?

    /// Encrypted video attached to this message, if any. Mirrors
    /// `ChatMessagePayload.videoAttachment`; `body` is the caption when
    /// this is present. The poster is fetched + decrypted lazily like an
    /// image; the video blob only downloads on play (see
    /// `ChatVideoLoader`).
    public let videoAttachment: ChatVideoAttachment?

    /// A multi-media album (2+ items) attached to this message. Mirrors
    /// `ChatMessagePayload.attachments`. `nil` for text + single-media
    /// messages (which use `imageAttachment` / `videoAttachment`).
    public let albumAttachments: [ChatMediaAttachment]?

    /// Encrypted voice message attached to this message, if any. Mirrors
    /// `ChatMessagePayload.voiceAttachment`. The bubble renders the
    /// waveform + duration from the descriptor and only downloads the
    /// audio blob on play (see `ChatVoiceLoader`). Mutually exclusive with
    /// the image/video/album fields.
    public let voiceAttachment: ChatVoiceAttachment?

    /// Sender's detached Ed25519 signature over `body`, retained solely
    /// so an incoming text message can be disclosed as independently
    /// verifiable moderation evidence. Nil for legacy and media-only
    /// messages that this first reporting surface cannot file.
    public let moderationAuthenticityProof: String?

    /// Non-nil when this row is a locally-minted system notice ("Alice
    /// joined") rather than something a person typed. `nil` is the
    /// overwhelmingly common case and means "ordinary message".
    ///
    /// Deliberately absent from `ChatMessagePayload`: system rows are
    /// **never** carried on the wire. Each device mints its own copy
    /// from an event it independently verified (the admin from its own
    /// approve, members from a signature-checked
    /// `MemberAnnouncementPayload`, the joiner from its materialized
    /// invitation). A wire field here would let any peer forge
    /// "X joined" history.
    public let systemEvent: ChatSystemEvent?

    /// True for locally-minted system notices. Reads better than
    /// `systemEvent != nil` at the several call sites that only care
    /// whether the row is a notice, not which kind.
    public var isSystem: Bool { systemEvent != nil }

    /// Canonical media list for rendering: the album when present, else
    /// the single image/video wrapped in a one-element list, else empty.
    public var media: [ChatMediaAttachment] {
        if let albumAttachments, !albumAttachments.isEmpty { return albumAttachments }
        if let imageAttachment { return [.image(imageAttachment)] }
        if let videoAttachment { return [.video(videoAttachment)] }
        return []
    }

    /// One-line preview for the chat-list row subtitle. Media messages
    /// (which carry no/empty body) render a label; text renders its body.
    /// Own messages get a "You: " prefix to disambiguate in a group.
    ///
    /// System notices render their own sentence and never take the
    /// "You: " prefix — "You: Alice joined" would read as if the user
    /// had said it.
    public var chatListPreview: String {
        if let systemEvent { return systemEvent.localizedText }
        let content: String
        if voiceAttachment != nil {
            content = "Voice message"
        } else if let album = albumAttachments, !album.isEmpty {
            content = "Album"
        } else if videoAttachment != nil {
            content = "Video"
        } else if imageAttachment != nil {
            content = "Photo"
        } else {
            content = body
        }
        return direction == .outgoing ? "You: \(content)" : content
    }

    public init(
        id: UUID,
        groupID: String,
        ownerIdentityID: IdentityID,
        senderBlsPubkeyHex: String,
        body: String,
        sentAt: Date,
        direction: MessageDirection,
        status: MessageStatus,
        replyToMessageID: UUID?,
        groupType: SEPGroupType,
        failureReason: SendFailureReason? = nil,
        moderationAuthenticityProof: String? = nil,
        imageAttachment: ChatImageAttachment? = nil,
        videoAttachment: ChatVideoAttachment? = nil,
        albumAttachments: [ChatMediaAttachment]? = nil,
        voiceAttachment: ChatVoiceAttachment? = nil,
        systemEvent: ChatSystemEvent? = nil
    ) {
        self.id = id
        self.groupID = groupID
        self.ownerIdentityID = ownerIdentityID
        self.senderBlsPubkeyHex = senderBlsPubkeyHex
        self.body = body
        self.sentAt = sentAt
        self.direction = direction
        self.status = status
        self.replyToMessageID = replyToMessageID
        self.groupType = groupType
        self.failureReason = failureReason
        self.moderationAuthenticityProof = moderationAuthenticityProof
        self.imageAttachment = imageAttachment
        self.videoAttachment = videoAttachment
        self.albumAttachments = albumAttachments
        self.voiceAttachment = voiceAttachment
        self.systemEvent = systemEvent
    }
}

/// A locally-minted, non-conversational notice rendered in the thread —
/// the membership events every member should see without anyone having
/// to type them.
///
/// Cases carry **structured data, not prose** — the stored row holds an
/// alias and a group name, never a rendered sentence, so re-wording the
/// copy doesn't require a migration.
///
/// The sentence itself lives in exactly one place: `localizedText`. Both
/// the thread's notice cell and the chat-list subtitle read it, so they
/// cannot drift apart. It resolves through the app's string catalog
/// rather than hardcoding English the way `SendFailureReason.explanation`
/// above does.
///
/// Raw values are a persistence format (`kind`): stable forever.
public enum ChatSystemEvent: Equatable, Sendable, Codable {
    /// Someone else was admitted. Rendered to the admin (who approved)
    /// and to every existing member (via `MemberAnnouncementPayload`).
    /// `alias` is self-asserted by the joiner — same trust caveat as
    /// everywhere else aliases are shown.
    case memberJoined(alias: String)
    /// This device's own identity was admitted — the first row in a
    /// freshly materialized thread, so a brand-new chat explains itself
    /// instead of rendering blank.
    case youJoined(groupName: String)

    /// The one rendering of this event, used by both the thread's notice
    /// cell and the chat-list subtitle. Localized here rather than in the
    /// UI layer because `chatListPreview` is a Core-level computed
    /// property with no view in scope, and having the cell assemble its
    /// own copy of these sentences meant a re-word in one place silently
    /// diverged from the other. The strings live in the app's catalog;
    /// package sources resolve against `Bundle.main`.
    public var localizedText: String {
        switch self {
        case .memberJoined(let alias):
            return String(localized: "\(alias) joined")
        case .youJoined(let groupName):
            return String(localized: "You joined \(groupName)")
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case kind
        case alias
        case groupName = "group_name"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "member_joined":
            self = .memberJoined(alias: try c.decode(String.self, forKey: .alias))
        case "you_joined":
            self = .youJoined(groupName: try c.decode(String.self, forKey: .groupName))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: c,
                debugDescription: "Unknown system-event kind '\(other)'"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .memberJoined(let alias):
            try c.encode("member_joined", forKey: .kind)
            try c.encode(alias, forKey: .alias)
        case .youJoined(let groupName):
            try c.encode("you_joined", forKey: .kind)
            try c.encode(groupName, forKey: .groupName)
        }
    }
}

public enum MessageDirection: String, Codable, Sendable {
    case incoming
    case outgoing
}

/// Coarse, user-explainable category of why an outgoing message
/// failed to send. Persisted on the row (as its raw string) so the
/// explanation survives app restarts alongside the `.failed` status.
///
/// Categorization lives in `SendMessageInteractor.categorize(_:)`;
/// the wording lives in `explanation` and is consumed by
/// `ChatBubbleCell` under the failed bubble. Raw values are stable —
/// they're a persistence format.
public enum SendFailureReason: String, Codable, Sendable {
    /// The transport had no relay connections at all — empty relay
    /// list or `connect` never ran.
    case noRelayConnection
    /// The device looks offline (no internet route).
    case offline
    /// TLS to every relay failed — bad/expired certificate or ATS
    /// rejection. Distinct from `relayUnreachable` because there's
    /// nothing the user can do beyond waiting for the operator.
    case secureConnectionFailed
    /// Network errors (DNS, timeout, connection refused, …) on every
    /// relay — none could be reached to accept or reject.
    case relayUnreachable
    /// At least one relay answered and none accepted the message.
    case relayRejected
    /// Sealing the envelope for a recipient failed locally, before
    /// anything hit the network.
    case encryptionFailed
    /// Fallback for errors that fit none of the above.
    case unknown

    /// One-sentence user-facing explanation. The cell appends its own
    /// "Tap the message to retry." call to action, so keep these to
    /// the cause alone.
    public var explanation: String {
        switch self {
        case .noRelayConnection:
            return "Not connected to any message relay. Check your relay settings."
        case .offline:
            return "You appear to be offline. Check your internet connection."
        case .secureConnectionFailed:
            return "Couldn't make a secure connection to any message relay. The relay may be having certificate problems — try again later."
        case .relayUnreachable:
            return "None of your message relays could be reached."
        case .relayRejected:
            return "The message relays refused to accept this message."
        case .encryptionFailed:
            return "This message couldn't be encrypted for the group."
        case .unknown:
            return "Something went wrong while sending."
        }
    }
}

public enum MessageStatus: String, Codable, Sendable {
    /// Outgoing only — in flight to transport.
    case pending
    /// Outgoing only — transport accepted (per-envelope errors
    /// resolved or tolerated). Single check.
    case sent
    /// Outgoing only — a recipient's device received + decrypted the
    /// message and sent back a delivered receipt. Double check.
    case delivered
    /// Outgoing only — a recipient opened the thread and sent back a
    /// read receipt (gated by the symmetric read-receipt setting).
    /// Accent double check.
    case read
    /// Outgoing only — transport rejected. Retry via
    /// `SendMessageInteractor` flips back to `.pending`.
    case failed
    /// Incoming only — payload decoded and persisted.
    case received

    /// Position on the outgoing delivery ladder
    /// (`pending → sent → delivered → read`). Receipts only ever
    /// *raise* the status — a late `delivered` arriving after `read`
    /// must not move it back — so callers compare ranks before
    /// applying. `nil` for statuses outside the ladder (`failed`,
    /// `received`), which receipts never transition to.
    var deliveryRank: Int? {
        switch self {
        case .pending:   return 0
        case .sent:      return 1
        case .delivered: return 2
        case .read:      return 3
        case .failed, .received: return nil
        }
    }
}
