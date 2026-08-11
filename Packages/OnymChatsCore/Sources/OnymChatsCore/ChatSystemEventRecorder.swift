import CryptoKit
import Foundation
import OnymChain
import OnymGroup
import OnymIdentity

/// The single place that mints system rows ("Alice joined", "You joined
/// X") into a chat thread.
///
/// Three call sites produce these, on three different devices, from
/// three different triggers:
///
///   - the admin, from its own successful `JoinRequestApprover.approve`
///     (reaches this through the `GroupSystemEventRecording` seam,
///     because OnymGroup can't depend on this module);
///   - every existing member, from a signature- and chain-verified
///     `MemberAnnouncementPayload`;
///   - the joiner, from its freshly materialized group.
///
/// Nothing about a system row travels on the wire — `ChatMessagePayload`
/// has no `system_event` key and must never grow one. Each device mints
/// its own copy from an event it independently verified, so there is no
/// "forge a join notice" path for a peer.
///
/// ## Idempotence
///
/// Row ids are **derived**, not random: a stable UUID from
/// `(groupID, owner, event discriminator)`. Relays replay the full inbox
/// on every reconnect, and the callers' own dedup guards are the first
/// line of defence — this is the second. `MessageRepository.insert` is
/// idempotent on `(id, ownerIdentityID)`, so a replay that slips past a
/// guard collapses onto the existing row instead of stacking a duplicate
/// "Alice joined" on every launch.
public struct ChatSystemEventRecorder: GroupSystemEventRecording {
    private let messageRepository: MessageRepository

    public init(messageRepository: MessageRepository) {
        self.messageRepository = messageRepository
    }

    // MARK: - GroupSystemEventRecording

    public func recordMemberJoined(
        groupID: String,
        ownerIdentityID: IdentityID,
        groupType: SEPGroupType,
        joinerBlsPubkeyHex: String,
        alias: String,
        at: Date
    ) async {
        await record(
            event: .memberJoined(alias: Self.displayAlias(alias)),
            discriminator: "member-joined:\(joinerBlsPubkeyHex.lowercased())",
            groupID: groupID,
            ownerIdentityID: ownerIdentityID,
            groupType: groupType,
            senderBlsPubkeyHex: joinerBlsPubkeyHex,
            at: at
        )
    }

    // MARK: - Joiner side

    /// Append "You joined <group>" as the opening row of a thread this
    /// device was just admitted to. Keyed on the group alone, so a
    /// re-delivered invitation can't add a second one.
    public func recordYouJoined(
        groupID: String,
        ownerIdentityID: IdentityID,
        groupType: SEPGroupType,
        groupName: String,
        ownBlsPubkeyHex: String,
        at: Date
    ) async {
        await record(
            // Same reasoning as the alias: a group created without a
            // name would otherwise write "You joined " into history.
            // "(Unnamed)" matches how the chat list renders one.
            event: .youJoined(
                groupName: groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? String(localized: "(Unnamed)")
                    : groupName
            ),
            discriminator: "you-joined",
            groupID: groupID,
            ownerIdentityID: ownerIdentityID,
            groupType: groupType,
            senderBlsPubkeyHex: ownBlsPubkeyHex,
            at: at
        )
    }

    // MARK: - Private

    /// Aliases are self-asserted by the joiner and reach here unchecked
    /// from `JoinRequestPayload.joinerDisplayLabel` (admin side) and
    /// `MemberAnnouncementPayload.newMember.alias` (member side).
    ///
    /// The request row already trims and falls back before rendering, but
    /// a notice is written into *permanent history* — an empty or
    /// whitespace-only alias would leave " joined" sitting in the thread
    /// forever, with no way to correct it. Same trim + `(unnamed)`
    /// fallback the request row uses, applied before the row is stored.
    static func displayAlias(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "(unnamed)") : trimmed
    }

    private func record(
        event: ChatSystemEvent,
        discriminator: String,
        groupID: String,
        ownerIdentityID: IdentityID,
        groupType: SEPGroupType,
        senderBlsPubkeyHex: String,
        at: Date
    ) async {
        let message = ChatMessage(
            id: Self.derivedID(
                groupID: groupID,
                owner: ownerIdentityID,
                discriminator: discriminator
            ),
            groupID: groupID,
            ownerIdentityID: ownerIdentityID,
            // Carried so the row still has a well-formed sender for any
            // code that reads the column; the thread never renders a
            // name header or accent for a system row.
            senderBlsPubkeyHex: senderBlsPubkeyHex,
            // The sentence is assembled in the UI from `systemEvent`, so
            // the body stays empty rather than holding unlocalized
            // English that would leak into search and previews.
            body: "",
            sentAt: at,
            // `.incoming` + `.received` keeps the row off every outgoing
            // path (retry, receipts, the delivery-status ladder).
            // `unreadCount` excludes system rows explicitly, so this
            // does not light up a badge.
            direction: .incoming,
            status: .received,
            replyToMessageID: nil,
            groupType: groupType,
            systemEvent: event
        )
        await messageRepository.insert(message)
    }

    /// Stable UUID for a system row. SHA-256 over a domain-separated
    /// tuple, folded into a v4-shaped UUID — same value on every replay,
    /// different across groups, owners, and event kinds.
    static func derivedID(
        groupID: String,
        owner: IdentityID,
        discriminator: String
    ) -> UUID {
        let seed = "onym-system-event-v1:\(groupID):\(owner.rawValue.uuidString):\(discriminator)"
        var digest = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        // Stamp version 4 + RFC 4122 variant so the value is a
        // well-formed UUID rather than raw hash bytes.
        digest[6] = (digest[6] & 0x0F) | 0x40
        digest[8] = (digest[8] & 0x3F) | 0x80
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }
}
