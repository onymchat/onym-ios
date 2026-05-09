import Foundation

/// Receive-side fan-out target for the inbox pump. Inspects every
/// inbound message after decryption and routes it to the right
/// destination:
///
///   - `MemberAnnouncementPayload` → applied directly to the
///     matching local `ChatGroup.memberProfiles`. Never lands in the
///     invitations queue.
///   - `GroupInvitationPayload` → materializes a local `ChatGroup`
///     under the recipient identity, populating `memberProfiles`
///     from the wire payload (PR 8a) and adding the receiver's own
///     entry. The invitation is consumed at this point — no need to
///     also queue it for manual acceptance.
///   - Anything else (unknown / undecryptable plaintext) → persisted
///     as an opaque `IncomingInvitation` for the legacy display
///     pipeline. This is the safety-net: ciphertext we can't open
///     at receive time (wrong recipient, corrupted envelope) still
///     gets a chance via `InvitationDecryptor` later.
///
/// ## V1 trust model
///
/// The outer `SealedEnvelope`'s Ed25519 signature is verified by
/// `decryptInvitation` (when `senderEd25519PublicKey` is present).
/// We do **not** yet cross-check the signer against the group's
/// admin Ed25519 pubkey because the joiner-side path doesn't have
/// a stored admin Ed25519 to compare against (the wire only carries
/// `admin_pubkey_hex`, which is the BLS pub). A future PR can wire
/// the SealedEnvelope's `senderEd25519PublicKey` through to the
/// materialized `ChatGroup` and use it on subsequent announcements.
///
/// ## Cost
///
/// Every inbound message is decrypted at receive time (one extra
/// X25519/AES-GCM op per message). For the low-volume Onym inbox
/// this is negligible; the simplification gain — never leaking an
/// announcement or a stale invitation into the queue — is worth it.
struct IncomingMessageDispatcher: Sendable {
    let envelopeDecrypter: any InvitationEnvelopeDecrypting
    let identities: any IdentitiesProviding
    let groupRepository: GroupRepository
    let invitationsRepository: IncomingInvitationsRepository
    /// PR 13b: chain-state reader for verifying inbound payloads
    /// against the on-chain commitment. Tyranny payloads with a
    /// `commitment` field fetch the live state via this seam and
    /// reject on mismatch.
    let chainState: any ChainStateReading

    func dispatch(
        messageID: String,
        ownerIdentityID: IdentityID,
        payload: Data,
        receivedAt: Date
    ) async {
        // Decrypt once at receive time and grab the sender's Ed25519
        // pubkey at the same hop — both fast paths use it for
        // provenance (announcement: verify against stored admin;
        // invitation: stamp into the materialized group). The
        // safety-net path only needs to know decryption failed.
        guard let envelope = try? await envelopeDecrypter.decryptInvitationWithSender(
            envelopeBytes: payload,
            asIdentity: ownerIdentityID
        ) else {
            await fallThrough(
                messageID: messageID,
                ownerIdentityID: ownerIdentityID,
                payload: payload,
                receivedAt: receivedAt
            )
            return
        }

        // Fast path 1: MemberAnnouncementPayload — incremental roster
        // delta for an existing local group.
        if let announcement = try? JSONDecoder().decode(
            MemberAnnouncementPayload.self,
            from: envelope.plaintext
        ) {
            await applyAnnouncement(
                announcement,
                senderEd25519PublicKey: envelope.senderEd25519PublicKey
            )
            return
        }

        // Fast path 2: GroupInvitationPayload — materialize a local
        // group under `ownerIdentityID`. Skips the invitations queue
        // because the group is now visible in the chat list.
        if let invitation = try? JSONDecoder().decode(
            GroupInvitationPayload.self,
            from: envelope.plaintext
        ) {
            await materializeGroup(
                invitation,
                ownerIdentityID: ownerIdentityID,
                senderEd25519PublicKey: envelope.senderEd25519PublicKey
            )
            return
        }

        // Plaintext didn't match any known payload — fall through.
        await fallThrough(
            messageID: messageID,
            ownerIdentityID: ownerIdentityID,
            payload: payload,
            receivedAt: receivedAt
        )
    }

    private func fallThrough(
        messageID: String,
        ownerIdentityID: IdentityID,
        payload: Data,
        receivedAt: Date
    ) async {
        await invitationsRepository.recordIncoming(
            id: messageID,
            ownerIdentityID: ownerIdentityID,
            payload: payload,
            receivedAt: receivedAt
        )
    }

    /// Materialize a local `ChatGroup` from an inbound
    /// `GroupInvitationPayload`. Idempotent on `groupID` —
    /// `GroupRepository.insert` delegates to `insertOrUpdate`, so a
    /// re-delivery of the same invitation overwrites in place rather
    /// than minting a duplicate row.
    ///
    /// The `memberProfiles` directory is the union of:
    ///   - whatever the sender shipped on the wire (PR 8a)
    ///   - the receiver's own profile, looked up from
    ///     `IdentitiesProviding`. We add this locally because the
    ///     sender doesn't know us by alias yet — the producer-side
    ///     `recordJoiner` runs after the invite ships.
    ///
    /// Skipped when `tier_raw` / `group_type_raw` don't decode (older
    /// or future wire versions) — better to drop the message than
    /// materialize a partial group.
    private func materializeGroup(
        _ invitation: GroupInvitationPayload,
        ownerIdentityID: IdentityID,
        senderEd25519PublicKey: Data?
    ) async {
        guard let tier = SEPTier(rawValue: invitation.tierRaw),
              let groupType = SEPGroupType(rawValue: invitation.groupTypeRaw)
        else { return }

        // PR 13b: receiver-side commitment verification. For Tyranny
        // groups, the payload's `commitment` MUST match the on-chain
        // state and the recomputed Poseidon root over the wire-shipped
        // members. Either mismatch is treated as a forged invitation —
        // drop silently. Non-Tyranny groups skip verification (no
        // admin-anchored update path; trust falls back to the
        // sender's Ed25519 signature on the envelope).
        if groupType == .tyranny {
            guard await verifyTyrannyInvitation(
                invitation,
                tier: tier
            ) else {
                return
            }
        }

        // Build the directory: wire-shipped profiles first, then add
        // self if we can resolve our own identity. The "wire first"
        // ordering means a sender that mistakenly includes us under
        // our own BLS key gets overwritten by our locally-trusted
        // alias + inbox pub — the receiver's view of itself wins.
        var profiles = invitation.memberProfiles ?? [:]
        if let selfEntry = await selfMemberProfileEntry(for: ownerIdentityID) {
            profiles[selfEntry.key] = selfEntry.value
        }

        // Stamp the inviting envelope's Ed25519 pubkey as the
        // group's admin signing key. PR 9 uses this on every
        // subsequent MemberAnnouncementPayload to verify the sender
        // is the same admin we received the invitation from. Empty
        // for `.anarchy` / `.oneOnOne` (no admin), and `nil` when
        // the envelope shipped without a signature block.
        let adminEd25519PubkeyHex: String?
        switch groupType {
        case .anarchy, .oneOnOne:
            adminEd25519PubkeyHex = nil
        default:
            adminEd25519PubkeyHex = senderEd25519PublicKey
                .map { $0.map { String(format: "%02x", $0) }.joined() }
        }

        let groupIDHex = invitation.groupID
            .map { String(format: "%02x", $0) }.joined()
        let group = ChatGroup(
            id: groupIDHex,
            ownerIdentityID: ownerIdentityID,
            name: invitation.name,
            groupSecret: invitation.groupSecret,
            createdAt: Date(),
            members: invitation.members,
            memberProfiles: profiles,
            epoch: invitation.epoch,
            salt: invitation.salt,
            commitment: invitation.commitment,
            tier: tier,
            groupType: groupType,
            adminPubkeyHex: invitation.adminPubkeyHex,
            adminEd25519PubkeyHex: adminEd25519PubkeyHex,
            // Sender already anchored before sending the invite, so
            // by the time it lands the group is on chain.
            isPublishedOnChain: true
        )
        await groupRepository.insert(group)
    }

    /// PR 13b: validate a Tyranny invitation's commitment against
    /// both the wire-shipped state (recomputed Poseidon commitment)
    /// and the on-chain state (`SEPContractClient.getCommitment`).
    ///
    /// The commitment is `Poseidon(Poseidon(merkle_root, epoch), salt)`
    /// — NOT just the merkle root. The original PR 13b verifier got
    /// this wrong and rejected every legitimate invitation because
    /// `merkle_root != commitment`. Bug fix landed here.
    ///
    /// Three failure modes — all return `false`:
    ///   - Payload omits `commitment` (pre-PR-13a sender, can't
    ///     verify, refuse).
    ///   - Recomputed `Poseidon(Poseidon(merkle_root(members),
    ///     epoch), salt)` ≠ `payload.commitment` (internally
    ///     inconsistent — sender can't have run a valid
    ///     `update_commitment` for the claimed `(members, epoch,
    ///     salt)` triple, OR they fabricated `members` while
    ///     copying a real on-chain commitment).
    ///   - On-chain `commitment` ≠ `payload.commitment` OR on-chain
    ///     `epoch` ≠ `payload.epoch` (forged commitment that
    ///     doesn't match what's anchored — chain rejected the
    ///     sender's proof, they may still try to ship a fake
    ///     invitation; receiver catches it here).
    ///
    /// Throws on chain-read transport failures are also treated as
    /// "couldn't verify, reject" — the safe default. Operators
    /// observe these via the `decryptFailures` counter (out of
    /// scope for V1).
    private func verifyTyrannyInvitation(
        _ invitation: GroupInvitationPayload,
        tier: SEPTier
    ) async -> Bool {
        guard let claimedCommitment = invitation.commitment else {
            return false
        }
        // Internal consistency: recompute the FULL Poseidon
        // commitment from (members, epoch, salt) and compare. The
        // commitment is the Poseidon hash of (root, epoch, salt) —
        // not just the root. Both sides of this check land on the
        // same byte string only when the sender ran a valid
        // `update_commitment` (or `create_group`) for these exact
        // inputs.
        let recomputed: Data
        do {
            let root = try GroupCommitmentBuilder.computeMerkleRoot(
                members: invitation.members,
                tier: tier
            )
            recomputed = try GroupCommitmentBuilder.computePoseidonCommitment(
                poseidonRoot: root,
                epoch: invitation.epoch,
                salt: invitation.salt
            )
        } catch {
            return false
        }
        guard recomputed == claimedCommitment else { return false }
        // External anchor: matches what's on chain.
        let onchain: SEPCommitmentEntry
        do {
            onchain = try await chainState.tyrannyCommitment(
                groupID: invitation.groupID
            )
        } catch {
            return false
        }
        guard onchain.commitment == claimedCommitment else { return false }
        guard onchain.epoch == invitation.epoch else { return false }
        return true
    }

    /// PR 13b: validate a Tyranny `MemberAnnouncementPayload`'s
    /// claimed commitment + epoch against the on-chain state. Same
    /// failure-modes posture as the invitation verifier — any
    /// mismatch / missing-field / read-error returns `false` and
    /// the announcement is dropped.
    ///
    /// We DON'T recompute the Poseidon root here because the
    /// announcement only carries one new member, not the full
    /// roster. The local `ChatGroup.members` plus the announced
    /// new member give the full roster, but the receiver might be
    /// behind by an epoch (e.g. a previous announcement to them
    /// got dropped). The on-chain commitment + epoch check alone
    /// is the strong gate — if those match the payload, the
    /// announcement is from the legitimate admin.
    private func verifyTyrannyAnnouncement(
        _ announcement: MemberAnnouncementPayload,
        on group: ChatGroup
    ) async -> Bool {
        // Skip verification for non-Tyranny groups (best-effort).
        guard group.groupType == .tyranny else { return true }
        guard let claimedCommitment = announcement.commitment,
              let claimedEpoch = announcement.epoch
        else { return false }
        let onchain: SEPCommitmentEntry
        do {
            onchain = try await chainState.tyrannyCommitment(
                groupID: announcement.groupId
            )
        } catch {
            return false
        }
        guard onchain.commitment == claimedCommitment else { return false }
        guard onchain.epoch == claimedEpoch else { return false }
        return true
    }

    /// Look up the receiver's own `MemberProfile` entry keyed by
    /// their BLS pubkey hex. Returns `nil` when the identity can't
    /// be resolved (race during identity removal, test stub returns
    /// empty, etc.) — caller leaves the directory wire-only.
    private func selfMemberProfileEntry(
        for identityID: IdentityID
    ) async -> (key: String, value: MemberProfile)? {
        let summaries = await identities.currentIdentities()
        guard let me = summaries.first(where: { $0.id == identityID }) else {
            return nil
        }
        let key = me.blsPublicKey
            .map { String(format: "%02x", $0) }.joined()
        let profile = MemberProfile(
            alias: me.name,
            inboxPublicKey: me.inboxPublicKey
        )
        return (key, profile)
    }

    /// Idempotent merge of one announced member into the matching
    /// local group's `memberProfiles`. No-op when:
    ///
    ///   - The group isn't on this device (joiner whose local
    ///     materialization hasn't shipped, or stale announcement
    ///     for an unrelated group).
    ///   - The sender's Ed25519 pubkey doesn't match the group's
    ///     stored `adminEd25519PubkeyHex` (forged announcement, or
    ///     announcement for a Tyranny group from a non-admin
    ///     member). PR 9 trust check.
    ///   - The member is already known under the same BLS pubkey
    ///     hex key (re-delivery, or the admin's own approve loop
    ///     re-broadcasting).
    ///
    /// Dedup key is BLS pubkey hex, mirroring the producer-side
    /// dictionary key in `JoinRequestApprover.recordJoiner`.
    private func applyAnnouncement(
        _ payload: MemberAnnouncementPayload,
        senderEd25519PublicKey: Data?
    ) async {
        let groups = await groupRepository.currentGroups()
        guard let group = groups.first(where: { $0.groupIDData == payload.groupId }) else {
            return
        }

        // PR 9 trust check: announcement must be signed by the
        // group's known admin. Skipped (best-effort) when the group
        // has no stored admin Ed25519 — happens for governance
        // models without an admin (anarchy / oneOnOne) or pre-PR-9
        // rows that materialized before the field existed.
        if let storedAdmin = group.adminEd25519PubkeyHex {
            guard let senderEd25519PublicKey else { return }
            let senderHex = senderEd25519PublicKey
                .map { String(format: "%02x", $0) }.joined()
                .lowercased()
            guard senderHex == storedAdmin.lowercased() else { return }
        }

        // PR 13b on-chain check: announcement's claimed commitment +
        // epoch must match what's actually anchored. Closes the
        // residual spoof path where Bob (with admin's Ed25519
        // somehow obtained) ships an announcement with a fake
        // `commitment`. The chain has the truth; we cross-check.
        guard await verifyTyrannyAnnouncement(payload, on: group) else {
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
