import Foundation

/// Receive-side fan-out target for the inbox pump. Inspects every
/// inbound message after decryption and routes it to the right
/// destination:
///
///   - `MemberAnnouncementPayload` → applied directly to the
///     matching local `ChatGroup.memberProfiles`. Never lands in the
///     invitations queue; existing members just need their roster
///     directory updated.
///   - Anything else (current build: `GroupInvitationPayload` or
///     unknown / undecryptable) → persisted as an opaque
///     `IncomingInvitation` for later display via
///     `InvitationDecryptor`. This preserves today's behavior for
///     true invitations and for ciphertext we can't open at receive
///     time (wrong recipient, corrupted envelope, etc.).
///
/// ## V1 trust model
///
/// The outer `SealedEnvelope`'s Ed25519 signature is verified by
/// `decryptInvitation` (when `senderEd25519PublicKey` is present).
/// We do **not** yet cross-check the signer against the group's
/// admin Ed25519 pubkey because the receiver-side group
/// materialization isn't wired — joiners process announcements as
/// no-ops (no local `ChatGroup`) and the admin already knows about
/// the join (no spoofing risk inside their own loop). When
/// joiner-side group materialization lands, this dispatcher should
/// gain an `assert senderEd25519 == storedAdminEd25519` check.
///
/// ## Cost
///
/// Every inbound message is decrypted at receive time (one extra
/// X25519/AES-GCM op per message). For the low-volume Onym inbox
/// this is negligible; the simplification gain — never leaking an
/// announcement into the invitation list — is worth it.
struct IncomingMessageDispatcher: Sendable {
    let envelopeDecrypter: any InvitationEnvelopeDecrypting
    let groupRepository: GroupRepository
    let invitationsRepository: IncomingInvitationsRepository

    func dispatch(
        messageID: String,
        ownerIdentityID: IdentityID,
        payload: Data,
        receivedAt: Date
    ) async {
        // Fast path: try to interpret as a `MemberAnnouncementPayload`.
        // A successful decode + group-match consumes the message and
        // skips the invitation store. Anything else falls through.
        if let plaintext = try? await envelopeDecrypter.decryptInvitation(
            envelopeBytes: payload,
            asIdentity: ownerIdentityID
        ),
           let announcement = try? JSONDecoder().decode(
               MemberAnnouncementPayload.self,
               from: plaintext
           ) {
            await applyAnnouncement(announcement)
            return
        }
        // Fall-through: store opaque ciphertext for the invitations
        // pipeline to handle (matches pre-PR-6 behavior).
        await invitationsRepository.recordIncoming(
            id: messageID,
            ownerIdentityID: ownerIdentityID,
            payload: payload,
            receivedAt: receivedAt
        )
    }

    /// Idempotent merge of one announced member into the matching
    /// local group's `memberProfiles`. No-op when:
    ///
    ///   - The group isn't on this device (joiner whose local
    ///     materialization hasn't shipped, or stale announcement
    ///     for an unrelated group).
    ///   - The member is already known under the same BLS pubkey
    ///     hex key (re-delivery, or the admin's own approve loop
    ///     re-broadcasting).
    ///
    /// Dedup key is BLS pubkey hex, mirroring the producer-side
    /// dictionary key in `JoinRequestApprover.recordJoiner`.
    private func applyAnnouncement(_ payload: MemberAnnouncementPayload) async {
        let groups = await groupRepository.currentGroups()
        guard let group = groups.first(where: { $0.groupIDData == payload.groupId }) else {
            return
        }
        let key = payload.newMember.blsPub
            .map { String(format: "%02x", $0) }.joined()
        if group.memberProfiles[key] != nil { return }
        var updated = group
        updated.memberProfiles[key] = MemberProfile(
            alias: payload.newMember.alias,
            inboxPublicKey: payload.newMember.inboxPub
        )
        await groupRepository.insert(updated)
    }
}
