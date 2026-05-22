import Foundation
import CryptoKit

/// Outgoing-message pipeline: persist a `.pending` row locally,
/// seal + ship one envelope per other group member, then flip the
/// status to `.sent` (at least one relay accepted) or `.failed`
/// (every send threw or no relay accepted).
///
/// Mirrors `CreateGroupInteractor.sendInvitations` shape — same
/// `sealInvitation` + `InboxTransport.send` per recipient, same
/// inbox-tag derivation. The local insert happens *before* the fan-
/// out so the chat thread sees the bubble immediately; the status
/// flip is the UI's signal that the network is done.
actor SendMessageInteractor {
    private let identity: IdentityRepository
    private let inboxTransport: any InboxTransport
    private let messageRepository: MessageRepository
    private let groupRepository: GroupRepository

    enum SendError: Error, Equatable {
        case noIdentityLoaded
        case unknownGroup
        /// Current identity isn't in the group's `memberProfiles`. The
        /// roster lookup is by BLS pubkey hex, so this fires when the
        /// creator's own profile was never recorded (shouldn't happen
        /// post-PR-3) or when the active identity switched mid-flight.
        case senderNotAMember
        /// Caller-side guard. Empty bodies are technically valid on
        /// the wire (the payload encodes them) but the interactor
        /// refuses to ship them — a no-op send would burn a relay
        /// publish for nothing.
        case emptyBody
    }

    init(
        identity: IdentityRepository,
        inboxTransport: any InboxTransport,
        messageRepository: MessageRepository,
        groupRepository: GroupRepository
    ) {
        self.identity = identity
        self.inboxTransport = inboxTransport
        self.messageRepository = messageRepository
        self.groupRepository = groupRepository
    }

    /// Returns the locally-persisted `ChatMessage` after the fan-out
    /// completes. The returned row always reflects the final status
    /// (`.sent` or `.failed`) — callers that want the optimistic
    /// `.pending` view subscribe to `MessageRepository.snapshots`.
    @discardableResult
    func send(
        groupID: String,
        body: String,
        now: Date = Date()
    ) async throws -> ChatMessage {
        guard !body.isEmpty else { throw SendError.emptyBody }

        guard let active = await identity.currentIdentity() else {
            throw SendError.noIdentityLoaded
        }
        let groups = await groupRepository.currentGroups()
        guard let group = groups.first(where: { $0.id == groupID }) else {
            throw SendError.unknownGroup
        }

        let myBlsHex = active.blsPublicKey
            .map { String(format: "%02x", $0) }.joined()
        guard group.memberProfiles[myBlsHex] != nil else {
            throw SendError.senderNotAMember
        }

        // Variant is governance-keyed; today only Tyranny ships.
        // Other group types throw at the payload layer because their
        // variants aren't implemented yet — PR 4 only supports the
        // tyranny case end-to-end.
        let variant: ChatMessageVariant
        switch group.groupType {
        case .tyranny:
            variant = .tyranny(body: body)
        case .oneOnOne, .anarchy, .democracy, .oligarchy:
            throw SendError.unknownGroup  // surfaces as "not supported"
        }

        let messageID = UUID()
        let sentAtMillis = Int64(now.timeIntervalSince1970 * 1000)
        let payload = ChatMessagePayload(
            version: 1,
            messageID: messageID,
            groupID: group.groupIDData,
            senderBlsPubkeyHex: myBlsHex,
            sentAtMillis: sentAtMillis,
            variant: variant
        )

        // Optimistic insert — chat UI sees the bubble immediately.
        // Status flips later after the fan-out completes; the bubble
        // never disappears (re-tries flip pending → sent again, not
        // back to a different id).
        let pending = ChatMessage(
            id: messageID,
            groupID: groupID,
            ownerIdentityID: group.ownerIdentityID,
            senderBlsPubkeyHex: myBlsHex,
            body: body,
            sentAt: now,
            direction: .outgoing,
            status: .pending,
            groupType: group.groupType
        )
        await messageRepository.insert(pending)

        // Fan out to every member except self. Best-effort per
        // recipient — one failed send doesn't doom the whole message;
        // we mark `.sent` if at least one relay accepted any envelope.
        let recipients = group.memberProfiles
            .filter { $0.key != myBlsHex }
            .map { $0.value.inboxPublicKey }

        let payloadBytes: Data
        do {
            payloadBytes = try JSONEncoder().encode(payload)
        } catch {
            // Encoding failure is a programmer error (Data field
            // can't fail at JSON encode); mark failed and surface.
            await messageRepository.updateStatus(
                id: messageID,
                status: .failed,
                groupID: groupID
            )
            return ChatMessage(
                id: pending.id,
                groupID: pending.groupID,
                ownerIdentityID: pending.ownerIdentityID,
                senderBlsPubkeyHex: pending.senderBlsPubkeyHex,
                body: pending.body,
                sentAt: pending.sentAt,
                direction: pending.direction,
                status: .failed,
                groupType: pending.groupType
            )
        }

        var successCount = 0
        for inboxKey in recipients {
            do {
                let sealed = try await identity.sealInvitation(
                    payload: payloadBytes,
                    to: inboxKey
                )
                let receipt = try await inboxTransport.send(
                    sealed,
                    to: TransportInboxID(rawValue: Self.inboxTag(from: inboxKey))
                )
                if receipt.acceptedBy >= 1 { successCount += 1 }
            } catch {
                // Swallow — best-effort per recipient.
                continue
            }
        }

        // Empty roster (only the sender is a member) is fine — the
        // message is local-only. Anything with recipients must reach
        // at least one to count as sent.
        let finalStatus: MessageStatus =
            recipients.isEmpty || successCount > 0 ? .sent : .failed
        await messageRepository.updateStatus(
            id: messageID,
            status: finalStatus,
            groupID: groupID
        )

        return ChatMessage(
            id: pending.id,
            groupID: pending.groupID,
            ownerIdentityID: pending.ownerIdentityID,
            senderBlsPubkeyHex: pending.senderBlsPubkeyHex,
            body: pending.body,
            sentAt: pending.sentAt,
            direction: pending.direction,
            status: finalStatus,
            groupType: pending.groupType
        )
    }

    /// Same derivation as `IdentityRepository.inboxTag(from:)` —
    /// duplicated here because the repo's helper is private and we
    /// only need the formula, not the keychain lookup. Matches
    /// `CreateGroupInteractor.inboxTag(from:)`.
    private static func inboxTag(from inboxPublicKey: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("sep-inbox-v1".utf8))
        hasher.update(data: inboxPublicKey)
        let hash = hasher.finalize()
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
