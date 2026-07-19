import Foundation

/// Admin → invitee "you've been invited" offer, sealed to the
/// invitee's X25519 inbox key and delivered over the normal inbox
/// transport (NOT an intro tag — the invitee doesn't have one yet).
///
/// ## Why this is not a `GroupInvitationPayload`
///
/// A `GroupInvitationPayload` is a *membership grant*: it pins
/// `(members, epoch, commitment, salt)` for one on-chain epoch, and
/// the receiver auto-materializes a group from it. Shipping that at
/// create time is wrong on two counts:
///   1. The invitee isn't on chain yet — they have no BLS leaf in the
///      committed roster, so the snapshot is a lie.
///   2. It's epoch-pinned, so the moment any *other* invitee is
///      anchored the snapshot goes stale and the receiver drops it.
///
/// The offer instead carries only what the invitee needs to *ask* to
/// join: a fresh per-invite intro public key (the reply channel the
/// admin minted via `InviteIntroducer`) plus enough context to render
/// "Alice invited you to Maple Garden". It contains **no** epoch,
/// commitment, members, or group secret — so it never expires and
/// grants nothing. Membership only happens later, when the invitee
/// explicitly accepts (ships a `JoinRequestPayload` to `introPublicKey`)
/// and the admin explicitly approves (anchors via `update_commitment`).
///
/// ## Wire disambiguation
///
/// The receive-side dispatcher trial-decodes inbound plaintext against
/// several payload types. `offer_version` + `inviter_alias` +
/// `intro_pub` are required and unique to this type, so a successful
/// decode is unambiguous — no other inbox payload carries
/// `inviter_alias`.
struct GroupInviteOfferPayload: Codable, Equatable, Sendable {
    let version: Int
    /// 32-byte X25519 public key of the admin's freshly-minted intro
    /// key for this invite. The invitee seals their `JoinRequestPayload`
    /// to this and the admin's `IntroInboxPump` picks it up.
    let introPublicKey: Data
    /// 32-byte on-chain `group_id` the invite is for. Lets the invitee
    /// verify the group exists on chain before responding.
    let groupID: Data
    /// Optional plaintext group name for the invitee's preview. Mirrors
    /// `IntroCapability.groupName` — public, transits cleartext-ish
    /// channels (it's sealed here, but treat as low-sensitivity).
    let groupName: String?
    /// Admin's self-asserted display name, surfaced in the invitee's
    /// "X invited you" prompt. Untrusted text — render, don't trust.
    let inviterAlias: String
    /// Optional free-text invitation the creator wrote (greeting / group
    /// policy / articles of association). Shown on the invitee's invite
    /// card *before* they accept. Sealed here, so any length is fine.
    /// Untrusted text — render, don't trust. `decodeIfPresent` for
    /// forward-compat with pre-feature senders.
    let invitationMessage: String?

    enum CodingKeys: String, CodingKey {
        case version = "offer_version"
        case introPublicKey = "intro_pub"
        case groupID = "group_id"
        case groupName = "group_name"
        case inviterAlias = "inviter_alias"
        case invitationMessage = "invitation_message"
    }

    init(
        version: Int = 1,
        introPublicKey: Data,
        groupID: Data,
        groupName: String?,
        inviterAlias: String,
        invitationMessage: String? = nil
    ) throws {
        guard introPublicKey.count == 32 else {
            throw GroupInviteOfferPayloadError.shape(
                "introPublicKey: expected 32 bytes, got \(introPublicKey.count)"
            )
        }
        guard groupID.count == 32 else {
            throw GroupInviteOfferPayloadError.shape(
                "groupID: expected 32 bytes, got \(groupID.count)"
            )
        }
        self.version = version
        self.introPublicKey = introPublicKey
        self.groupID = groupID
        self.groupName = groupName
        self.inviterAlias = inviterAlias
        self.invitationMessage = invitationMessage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: c.decode(Int.self, forKey: .version),
            introPublicKey: c.decode(Data.self, forKey: .introPublicKey),
            groupID: c.decode(Data.self, forKey: .groupID),
            groupName: c.decodeIfPresent(String.self, forKey: .groupName),
            inviterAlias: c.decode(String.self, forKey: .inviterAlias),
            invitationMessage: c.decodeIfPresent(String.self, forKey: .invitationMessage)
        )
    }

    /// Explicit encoder so the optional invitation message is *omitted*
    /// (not encoded as null) when absent — matching Android's
    /// `encodeDefaults = false` and keeping the sealed payload compact.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(introPublicKey, forKey: .introPublicKey)
        try c.encode(groupID, forKey: .groupID)
        try c.encodeIfPresent(groupName, forKey: .groupName)
        try c.encode(inviterAlias, forKey: .inviterAlias)
        try c.encodeIfPresent(invitationMessage, forKey: .invitationMessage)
    }

    /// Rebuild the `IntroCapability` the invitee feeds to
    /// `JoinRequestSender.send` on accept. Throws if the offer's bytes
    /// don't satisfy `IntroCapability`'s shape invariants (can't happen
    /// for an offer that decoded successfully, but `IntroCapability`'s
    /// init is the single source of truth for the sizes).
    func introCapability() throws -> IntroCapability {
        try IntroCapability(
            introPublicKey: introPublicKey,
            groupId: groupID,
            groupName: groupName
        )
    }
}

enum GroupInviteOfferPayloadError: Error, Equatable {
    case shape(String)
}
