import Foundation

/// Plaintext chat-message payload that gets sealed (X25519 + AES-GCM
/// via `IdentityRepository.sealInvitation`) and dropped on
/// `InboxTransport.send` for each group member — same envelope path
/// as `GroupInvitationPayload`. One envelope per recipient inbox
/// key; the encrypted bytes carry this struct verbatim.
///
/// `variant` is governance-keyed because each group flavour signs and
/// routes messages differently down the road: Tyranny only needs the
/// body, but a 1-on-1 dialog will carry per-message ratchet state and
/// Anarchy will carry a per-member signature. Today only `.tyranny`
/// ships — adding a new case is the entire surface-area cost of
/// turning a new governance type on for chat.
///
/// Versioned for forward compat. `version = 1` is the only shape the
/// receiver has to handle today; later versions can add fields with
/// non-failing `decodeIfPresent` decoders.
struct ChatMessagePayload: Codable, Equatable, Sendable {
    /// Wire schema version. Bump on a breaking field change (rename,
    /// removal, semantic shift). Adding optional fields does NOT
    /// require a bump.
    let version: Int

    /// Stable per-message identifier used for receive-side dedup —
    /// the same Nostr inbox event can be re-delivered, and a single
    /// message fans out as N sealed envelopes (one per recipient),
    /// so the inbox-event ID is not enough.
    let messageID: UUID

    /// The group this message belongs to. Receiver looks up the
    /// `ChatGroup` by this ID and rejects the message if no such
    /// group exists locally.
    let groupID: Data

    /// Lowercase BLS pubkey hex (96 chars) of the sender. Keying
    /// matches `ChatGroup.memberProfiles` so the receiver can verify
    /// the sender is a known member with one dictionary lookup.
    /// Sender identity has to live *inside* the encrypted payload —
    /// the sealed envelope's ephemeral key tells the receiver nothing
    /// about who sent it.
    let senderBlsPubkeyHex: String

    /// Milliseconds since Unix epoch at send time. Int64 (not
    /// `Date`) so the wire format is unambiguous and cross-platform.
    let sentAtMillis: Int64

    /// The message this one replies to, if any. Optional + additive,
    /// so it ships under `version = 1`: a sender that omits it decodes
    /// to `nil` on any receiver, and an old receiver decoding a payload
    /// that carries it just ignores the unknown key. Only the target's
    /// ID travels — the receiver resolves the quoted sender + body from
    /// its own local store at render time, so a dangling ref (target
    /// never delivered) degrades to "message unavailable" rather than
    /// carrying stale text.
    let replyToMessageID: UUID?

    /// Governance-keyed payload body. See `ChatMessageVariant`.
    let variant: ChatMessageVariant

    /// Optional encrypted image attached to this message. Additive +
    /// optional, so it ships under `version = 1`: a sender that omits
    /// it decodes to `nil` on any receiver, and an older receiver
    /// ignores the unknown key. When present, `variant.body` is the
    /// (possibly empty) caption. See `ChatImageAttachment`.
    let attachment: ChatImageAttachment?

    /// Optional encrypted video attached to this message. Additive +
    /// optional exactly like `attachment`, so it ships under
    /// `version = 1`: a sender that omits it decodes to `nil` on any
    /// receiver, and an older receiver ignores the unknown key. When
    /// present, `variant.body` is the (possibly empty) caption. See
    /// `ChatVideoAttachment`.
    let videoAttachment: ChatVideoAttachment?

    /// A multi-media **album** (2+ items, mixed image/video) attached to
    /// this message. Additive + optional: single-media messages leave
    /// this `nil` and use `attachment` / `videoAttachment` above; an
    /// older receiver ignores the unknown key. When present, `variant.body`
    /// is the (possibly empty) caption and the flat single fields are nil.
    let attachments: [ChatMediaAttachment]?

    /// Optional encrypted voice message attached to this message. Additive
    /// + optional exactly like `attachment`, so it ships under
    /// `version = 1`: a sender that omits it decodes to `nil` on any
    /// receiver, and an older receiver ignores the unknown key. A voice
    /// message never carries a caption or rides in an album. See
    /// `ChatVoiceAttachment`.
    let voiceAttachment: ChatVoiceAttachment?

    init(
        version: Int,
        messageID: UUID,
        groupID: Data,
        senderBlsPubkeyHex: String,
        sentAtMillis: Int64,
        replyToMessageID: UUID?,
        variant: ChatMessageVariant,
        attachment: ChatImageAttachment? = nil,
        videoAttachment: ChatVideoAttachment? = nil,
        attachments: [ChatMediaAttachment]? = nil,
        voiceAttachment: ChatVoiceAttachment? = nil
    ) {
        self.version = version
        self.messageID = messageID
        self.groupID = groupID
        self.senderBlsPubkeyHex = senderBlsPubkeyHex
        self.sentAtMillis = sentAtMillis
        self.replyToMessageID = replyToMessageID
        self.variant = variant
        self.attachment = attachment
        self.videoAttachment = videoAttachment
        self.attachments = attachments
        self.voiceAttachment = voiceAttachment
    }

    enum CodingKeys: String, CodingKey {
        case version
        case messageID = "message_id"
        case groupID = "group_id"
        case senderBlsPubkeyHex = "sender_bls_pubkey_hex"
        case sentAtMillis = "sent_at_millis"
        case replyToMessageID = "reply_to_message_id"
        case variant
        case attachment
        case videoAttachment = "video_attachment"
        case attachments
        case voiceAttachment = "voice_attachment"
    }
}

/// Governance-keyed body. The discriminator string on the wire is
/// `SEPGroupType.rawValue` so a single spelling identifies the
/// flavour across iOS, Android, the relayer, and the Stellar
/// contracts.
///
/// Today only `.tyranny` carries a real case. Unknown / unsupported
/// kinds throw on decode — the dispatcher catches and drops, which
/// is what we want: a 1-on-1 message arriving at a v1 receiver
/// should be ignored, not silently shoehorned into a Tyranny shape.
enum ChatMessageVariant: Equatable, Sendable {
    case tyranny(body: String)

    /// Plaintext message body. Every variant ships a body string;
    /// future variants may carry additional fields alongside it.
    var body: String {
        switch self {
        case .tyranny(let body): body
        }
    }
}

extension ChatMessageVariant: Codable {
    enum CodingKeys: String, CodingKey {
        case kind
        case body
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kindRaw = try c.decode(String.self, forKey: .kind)
        guard let kind = SEPGroupType(rawValue: kindRaw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: c,
                debugDescription: "Unknown chat-message kind '\(kindRaw)'"
            )
        }
        switch kind {
        case .tyranny:
            let body = try c.decode(String.self, forKey: .body)
            self = .tyranny(body: body)
        case .oneOnOne, .anarchy, .democracy, .oligarchy:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: c,
                debugDescription: "Chat-message variant '\(kindRaw)' is not yet supported"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tyranny(let body):
            try c.encode(SEPGroupType.tyranny.rawValue, forKey: .kind)
            try c.encode(body, forKey: .body)
        }
    }
}
