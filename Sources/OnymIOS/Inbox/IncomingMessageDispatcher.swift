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
    /// Persistence target for incoming chat messages. The dispatcher
    /// looks up the sender's `MemberProfile.sendingPubkey`, verifies
    /// the envelope's Ed25519 signer matches, and writes the message
    /// here for the chat screen to render.
    let messageRepository: MessageRepository
    /// Receive-side sink for decoded `GroupInviteOfferPayload`s — the
    /// push counterpart to the deeplink join flow. An offer lands here
    /// as a `PendingInvite` awaiting the user's explicit Accept (which
    /// ships a `JoinRequestPayload`) or dismiss. It grants nothing and
    /// never materializes a group: membership only follows the
    /// invitee's accept + the admin's explicit on-chain approve.
    ///
    /// Defaulted to a fresh store so the many existing test
    /// constructions don't have to thread a spy they don't exercise;
    /// production (`OnymIOSApp`) passes the shared store explicitly.
    /// `var` (not `let`) so the synthesized memberwise initializer
    /// keeps it as a defaulted parameter — a `let` with a default is
    /// omitted from the memberwise init entirely.
    var pendingInvites: any PendingInvitesRecording = PendingInvitesStore()
    /// Seam for the verify-at-current state machine (Option 2). A stale
    /// Tyranny snapshot (chain advanced past its epoch) is deferred here
    /// on the invitee side; inbound `GroupStateRefreshRequest`s are
    /// answered here on the admin side. Defaulted to a no-op for the
    /// same reason as `pendingInvites`.
    var groupStateRefresher: any GroupStateRefreshing = NoopGroupStateRefresher()
    /// Ships a delivered receipt back to a chat message's sender the
    /// moment we persist it. Defaulted to a no-op so the many existing
    /// test constructions don't have to thread it.
    var receiptSender: any ChatReceiptSending = NoopChatReceiptSender()
    /// Symmetric read-receipt gate: an inbound `.read` receipt only
    /// raises a message to `.read` when this device also sends read
    /// receipts. Defaulted to `true` (the shipping default).
    var readReceiptsEnabled: @Sendable () -> Bool = { true }
    /// Base delay before re-checking the chain for a removal whose
    /// claimed epoch is ahead of our read (see `applyRemoval`). Must
    /// exceed `CachingChainStateReader`'s 10s TTL or the retry
    /// re-reads the same cached entry. Attempt N waits N × this.
    var removalRetryDelayNanos: UInt64 = 12_000_000_000
    /// How many delayed re-attempts a chain-behind removal gets before
    /// this delivery gives up (the next inbox replay retries from
    /// scratch). `0` disables retries entirely.
    var removalMaxRetries: Int = 2
    /// Test seam for the retry delay — production sleeps for real;
    /// tests inject a no-op so the bounded-retry loop runs instantly.
    var removalRetrySleep: @Sendable (UInt64) async -> Void = { nanos in
        try? await Task.sleep(nanoseconds: nanos)
    }
    /// Test seam for how a retry attempt is scheduled. Production
    /// fire-and-forgets a `Task` so a 12–24s wait never blocks the
    /// inbox pump; tests inject `{ await $0() }` so `dispatch` only
    /// returns once the retries have run to completion.
    var removalRetryScheduler: @Sendable (@escaping @Sendable () async -> Void) async -> Void = { work in
        Task { await work() }
    }
    /// Dedup registry for scheduled removal retries — a relay
    /// re-delivery during the delay window must not stack a second
    /// timer for the same removal. Reference type so every copy of
    /// this value-type dispatcher shares one registry.
    var removalRetries = RemovalRetryRegistry()

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

        // Fast path 0: GroupInviteOfferPayload — a push invitation.
        // Decoded + queued for the user's explicit Accept; it carries
        // no epoch / commitment / roster, so it never materializes a
        // group or touches the on-chain commitment. Tried first
        // because its required `inviter_alias` + `intro_pub` keys are
        // unique to this type — no other inbox payload decodes as one.
        if let offer = try? JSONDecoder().decode(
            GroupInviteOfferPayload.self,
            from: envelope.plaintext
        ) {
            await recordOffer(
                offer,
                messageID: messageID,
                ownerIdentityID: ownerIdentityID,
                receivedAt: receivedAt
            )
            return
        }

        // Fast path 0.5: GroupStateRefreshRequest — a member asking the
        // admin for the current group state (Option 2 verify-at-current).
        // Admin-side; delegated to the verifier, which gates on the
        // requester being a current member before disclosing the salt.
        if let refresh = try? JSONDecoder().decode(
            GroupStateRefreshRequest.self,
            from: envelope.plaintext
        ) {
            await groupStateRefresher.handleRefreshRequest(
                refresh,
                ownerIdentityID: ownerIdentityID,
                requesterEd25519: envelope.senderEd25519PublicKey
            )
            return
        }

        // Fast path 0.7: MemberRemovalPayload — the admin removed a
        // member (possibly us). Its required `removal_*` keys are
        // unique to this type, so the trial-decode is unambiguous.
        // Tried before the announcement branch: a removal is the only
        // subtractive roster mutation and must never be mistaken for
        // an additive one.
        if let removal = try? JSONDecoder().decode(
            MemberRemovalPayload.self,
            from: envelope.plaintext
        ) {
            await applyRemovalWithRetry(
                removal,
                ownerIdentityID: ownerIdentityID,
                senderEd25519PublicKey: envelope.senderEd25519PublicKey
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

        // Fast path 1.5: GroupAvatarPayload — admin updated the group
        // photo. Group-state delta like the announcement above; its
        // unique `avatar_*` keys keep it from decoding as a chat
        // message (which shares version / group_id / sender).
        if let avatarMsg = try? JSONDecoder().decode(
            GroupAvatarPayload.self,
            from: envelope.plaintext
        ) {
            await applyAvatar(
                avatarMsg,
                senderEd25519PublicKey: envelope.senderEd25519PublicKey
            )
            return
        }

        // Fast path 1.6: GroupNamePayload — admin renamed the group.
        // Group-state delta like the avatar above; its unique `name_*`
        // keys keep it from decoding as any other payload.
        if let nameMsg = try? JSONDecoder().decode(
            GroupNamePayload.self,
            from: envelope.plaintext
        ) {
            await applyName(
                nameMsg,
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

        // Fast path: chat receipt — a peer acking one of OUR messages
        // as delivered / read. Wire-shape-disjoint from every other
        // payload (unique `kind` + `message_ids` keys), so this `try?`
        // decode can't steal a different payload.
        if let receipt = try? JSONDecoder().decode(
            ChatReceiptPayload.self,
            from: envelope.plaintext
        ) {
            await applyReceipt(receipt, ownerIdentityID: ownerIdentityID)
            return
        }

        // Fast path 3: ChatMessagePayload — body of the chat thread.
        // Verifies the envelope's Ed25519 signer matches the claimed
        // sender's `MemberProfile.sendingPubkey` (insider-spoof
        // defense, PR 3), then persists via `messageRepository`.
        if let chatMessage = try? JSONDecoder().decode(
            ChatMessagePayload.self,
            from: envelope.plaintext
        ) {
            await persistChatMessage(
                chatMessage,
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

    /// Queue a decoded push offer for the user's explicit Accept.
    /// Keyed by the inbound Nostr event id so a re-delivered offer
    /// (replaceable events are re-fetched on every relaunch) is
    /// idempotent in the store.
    private func recordOffer(
        _ offer: GroupInviteOfferPayload,
        messageID: String,
        ownerIdentityID: IdentityID,
        receivedAt: Date
    ) async {
        await pendingInvites.record(PendingInvite(
            id: messageID,
            ownerIdentityID: ownerIdentityID,
            introPublicKey: offer.introPublicKey,
            groupID: offer.groupID,
            groupName: offer.groupName,
            inviterAlias: offer.inviterAlias,
            invitationMessage: offer.invitationMessage,
            receivedAt: receivedAt
        ))
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

        // Receiver-side verification (Option 2). For Tyranny groups the
        // snapshot's commitment must match the recomputed Poseidon root
        // AND the on-chain commitment at an exact epoch. Non-Tyranny
        // groups skip verification (no admin-anchored update path; trust
        // falls back to the sender's envelope signature).
        if groupType == .tyranny {
            switch await verifyTyrannyInvitation(invitation, tier: tier) {
            case .verified:
                break  // materialize below
            case .reject:
                return
            case .staleNeedsRefresh:
                // The chain has advanced past this snapshot's epoch, so
                // we can't byte-verify it. Don't materialize an
                // unverifiable group — hand it to the verifier, which
                // asks the admin for the current state and surfaces a
                // "couldn't verify" state to the user if the admin is
                // unreachable.
                await groupStateRefresher.deferVerification(
                    invitation: invitation,
                    ownerIdentityID: ownerIdentityID
                )
                return
            }
        }

        // Build the directory: wire-shipped profiles first, then add
        // self if we can resolve our own identity. The "wire first"
        // ordering means a sender that mistakenly includes us under
        // our own BLS key gets overwritten by our locally-trusted
        // alias + inbox pub — the receiver's view of itself wins. The
        // wire entry's statusEpoch is PRESERVED through the overwrite:
        // a re-admitted member's own status marker is what refuses a
        // replayed stale self-removal — erasing it would re-lock the
        // composer on the next inbox replay.
        var profiles = invitation.memberProfiles ?? [:]
        if let selfEntry = await selfMemberProfileEntry(for: ownerIdentityID) {
            profiles[selfEntry.key] = selfEntry.value.withStatus(
                revoked: selfEntry.value.revoked,
                statusEpoch: profiles[selfEntry.key]?.statusEpoch
            )
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
            isPublishedOnChain: true,
            // Group photo as the sender knew it. `nil` for avatar-less
            // groups or pre-avatar senders; a later GroupAvatarPayload
            // can still fill it in.
            avatarJPEG: invitation.avatar,
            // The group's invitation/intro, as the sender wrote it.
            invitationMessage: invitation.invitationMessage
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
    /// Outcome of receiver-side Tyranny invitation verification.
    enum TyrannyInvitationVerification: Equatable {
        /// Internally consistent AND matches the on-chain commitment at
        /// an exact epoch — safe to materialize.
        case verified
        /// Internally consistent and the group exists on chain, but the
        /// chain has advanced past the snapshot's epoch, so it can't be
        /// byte-verified. Needs a current-state refresh from the admin.
        case staleNeedsRefresh
        /// Forged / unverifiable — drop.
        case reject
    }

    private func verifyTyrannyInvitation(
        _ invitation: GroupInvitationPayload,
        tier: SEPTier
    ) async -> TyrannyInvitationVerification {
        guard let claimedCommitment = invitation.commitment else {
            return .reject
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
            return .reject
        }
        guard recomputed == claimedCommitment else { return .reject }

        // Skip the chain read when we've already verified+materialized
        // this exact (commitment, epoch). Re-confirming what we confirmed
        // on a prior pass adds nothing — the recompute above already
        // rejects a replay that swaps the roster while reusing the
        // commitment (Poseidon would have to collide). This is the
        // load-bearing fix for the launch-time `get_commitment` storm:
        // every relay reconnect replays the full inbox, and without this
        // each replayed invitation re-hit the relayer, tripping its rate
        // limit and making fresh joins fail until the burst subsided.
        if let existing = await groupRepository.currentGroups()
            .first(where: { $0.groupIDData == invitation.groupID }),
           existing.commitment == claimedCommitment,
           existing.epoch == invitation.epoch {
            return .verified
        }

        // External anchor: matches what's on chain.
        let onchain: SEPCommitmentEntry
        do {
            onchain = try await chainState.tyrannyCommitment(
                groupID: invitation.groupID
            )
        } catch {
            // Couldn't reach / read the relayer (throttled, offline, or
            // unconfigured). NOT evidence of forgery — never reject. Defer
            // so the verifier retries via the admin-refresh path and the
            // group materializes once the read succeeds, instead of being
            // silently dropped until the next relay replay (a restart).
            return .staleNeedsRefresh
        }
        // Verify at current chain state (Option 2). The chain stores
        // only the LATEST (commitment, epoch), so a snapshot is only
        // byte-verifiable when the chain is exactly at its epoch.
        //   - chain BEHIND the snapshot → our read is lagging the admin's
        //     just-landed `update_commitment` (indexer/relayer catch-up),
        //     OR a self-consistent forgery claiming a future epoch. We
        //     can't tell here, so defer + ask the admin rather than
        //     reject: deferral never materializes without a later exact-
        //     epoch match, so a forgery still can't get in, while a real
        //     lagging read recovers. (Previously a hard reject — the root
        //     cause of "joiner only sees the chat after a restart".)
        //   - chain EXACTLY at the snapshot's epoch → byte-verify the
        //     committed roster. Strong anti-forgery: reproducing
        //     `Poseidon(Poseidon(root, epoch), salt)` needs the random
        //     `salt`, which is never on chain — only a legitimate
        //     invitation carries it.
        //   - chain AHEAD → can't byte-verify here; defer and ask the
        //     admin for the current state rather than trusting (and
        //     thereby letting a self-consistent fake materialize).
        guard onchain.epoch >= invitation.epoch else { return .staleNeedsRefresh }
        if onchain.epoch == invitation.epoch {
            return onchain.commitment == claimedCommitment ? .verified : .reject
        }
        return .staleNeedsRefresh
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
        // Same converge-forward gate as the invitation verifier. The
        // announcement is already admin-Ed25519-signed (checked by the
        // caller), so a stale-but-signed roster delta is a legitimate
        // update we may have missed — accept when the chain is at or
        // ahead of the claimed epoch, byte-verifying only on an exact
        // epoch match.
        guard onchain.epoch >= claimedEpoch else { return false }
        if onchain.epoch == claimedEpoch {
            guard onchain.commitment == claimedCommitment else { return false }
        }
        return true
    }

    /// Look up the receiver's own `MemberProfile` entry keyed by
    /// their BLS pubkey hex. Returns `nil` when the identity can't
    /// be resolved (race during identity removal, test stub returns
    /// empty, etc.) — caller leaves the directory wire-only.
    private func selfMemberProfileEntry(
        for identityID: IdentityID
    ) async -> (key: String, value: MemberProfile)? {
        let summaries = (try? await identities.currentIdentities()) ?? []
        guard let me = summaries.first(where: { $0.id == identityID }) else {
            return nil
        }
        let key = me.blsPublicKey
            .map { String(format: "%02x", $0) }.joined()
        let profile = MemberProfile(
            alias: me.name,
            inboxPublicKey: me.inboxPublicKey,
            sendingPubkey: me.sendingPublicKey
        )
        return (key, profile)
    }

    /// H-2: authorize a group-mutating control message (announcement /
    /// avatar / rename) by its *verified* envelope signer.
    ///
    ///   - A missing signer is ALWAYS rejected — these mutations are
    ///     never anonymous. (`senderEd25519PublicKey` is nil either
    ///     because the envelope carried no signature block or, post
    ///     C-1, because a claimed sender key failed verification.)
    ///   - When the group stores an admin Ed25519 (Tyranny), the signer
    ///     must equal it — the existing PR 9 trust check.
    ///   - When the group has NO stored admin (anarchy / oneOnOne, or a
    ///     pre-PR-9 row), the signer must be a CURRENT member, i.e.
    ///     match some `memberProfiles[*].sendingPubkey`. This replaces
    ///     the old "skip the check entirely when there's no admin"
    ///     branch that let any party who knew the recipient's inbox
    ///     pubkey mutate the group unconditionally.
    private func isAuthorizedGroupMutation(
        group: ChatGroup,
        senderEd25519PublicKey: Data?
    ) -> Bool {
        guard let senderEd25519PublicKey else { return false }
        if let storedAdmin = group.adminEd25519PubkeyHex {
            let senderHex = senderEd25519PublicKey
                .map { String(format: "%02x", $0) }.joined()
                .lowercased()
            return senderHex == storedAdmin.lowercased()
        }
        // Admin-less governance: the verified signer must belong to a
        // current member (`memberProfiles` is keyed by BLS hex, but
        // `sendingPubkey` is the Ed25519 that signs every envelope).
        // Tombstoned (revoked) members are no longer CURRENT members —
        // their signature stops authorizing mutations.
        return group.memberProfiles.values.contains {
            !$0.revoked && $0.sendingPubkey == senderEd25519PublicKey
        }
    }

    /// Idempotent merge of one announced member into the matching
    /// local group's `memberProfiles`. No-op when:
    ///
    ///   - The group isn't on this device (joiner whose local
    ///     materialization hasn't shipped, or stale announcement
    ///     for an unrelated group).
    ///   - The verified sender fails `isAuthorizedGroupMutation`: for
    ///     a group with a stored `adminEd25519PubkeyHex` the signer
    ///     must be that admin; for an admin-less group it must be a
    ///     current member. Missing/unverified signer is rejected
    ///     (PR 9 + H-2).
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

        // Dedup BEFORE any chain read. The dedup key is BLS pubkey hex,
        // mirroring the producer-side dictionary key in
        // `JoinRequestApprover.recordJoiner`. Every relay reconnect
        // replays the full inbox, so an already-applied announcement is
        // re-delivered on each launch — bailing here keeps those replays
        // from each firing a `get_commitment` against the relayer (the
        // launch-time storm). Cheap, local, and idempotent.
        // A tombstoned (revoked) profile does NOT dedup: the admin may
        // have re-admitted a previously-removed member, and that
        // announcement must overwrite the tombstone (revoked = false
        // via the fresh MemberProfile below).
        let key = payload.newMember.blsPub
            .map { String(format: "%02x", $0) }.joined()
        if let existing = group.memberProfiles[key], !existing.revoked { return }

        // PR 9 + H-2 trust check: the verified envelope signer must be
        // the group's known admin, or — for admin-less groups — a
        // current member. A missing/unverified signer is rejected.
        guard isAuthorizedGroupMutation(
            group: group,
            senderEd25519PublicKey: senderEd25519PublicKey
        ) else { return }

        // PR 13b on-chain check: announcement's claimed commitment +
        // epoch must match what's actually anchored. Closes the
        // residual spoof path where Bob (with admin's Ed25519
        // somehow obtained) ships an announcement with a fake
        // `commitment`. The chain has the truth; we cross-check.
        guard await verifyTyrannyAnnouncement(payload, on: group) else {
            return
        }

        var updated = group
        updated.memberProfiles[key] = MemberProfile(
            alias: payload.newMember.alias,
            inboxPublicKey: payload.newMember.inboxPub,
            sendingPubkey: payload.newMember.sendingPub,
            // Stamp the (re-)admission epoch so an out-of-order
            // REMOVAL replayed later (with a lower epoch) can't
            // re-tombstone this member — see
            // `MemberProfile.statusEpoch`. Nil only from legacy
            // senders that omit `epoch`, which never race removals.
            statusEpoch: payload.epoch
        )
        await groupRepository.insert(updated)
    }

    /// Result of one `applyRemoval` pass.
    private enum RemovalApplyResult {
        /// Applied, or dropped for a terminal reason — do not retry.
        case done
        /// The chain read was behind the claimed epoch (or the
        /// relayer was unreachable) — worth re-checking after the
        /// cache TTL.
        case chainBehind
    }

    /// Apply an inbound `MemberRemovalPayload`.
    ///
    /// Two apply shapes, split on whether the removal names *us*:
    ///
    ///  - **Self (victim device):** flip `ChatGroup.membershipRevoked`.
    ///    History, profiles, and secrets stay untouched (the victim's
    ///    payload variant carries no new secrets anyway); the UI swaps
    ///    the composer for a "you were removed" banner.
    ///  - **Remaining member:** tombstone the victim's `MemberProfile`
    ///    (`revoked = true` — never deleted), drop them from the
    ///    on-chain `ChatGroup.members` roster, and advance
    ///    epoch / commitment / salt / groupSecret to the payload's
    ///    post-removal values. From this point every fanout excludes
    ///    the victim's inbox and every trust gate rejects their key.
    ///
    /// Order of gates (cheapest first, mirroring `applyAnnouncement`):
    /// group lookup → fail-closed admin requirement → self
    /// classification → local applicability check (BEFORE any chain
    /// read — relays replay the full inbox on every reconnect) →
    /// admin-Ed25519 authorization → on-chain converge-forward check.
    ///
    /// ## Two independently-guarded effects
    ///
    /// Relay dispatch order is ARRIVAL order, not epoch order — an
    /// offline device can receive "remove B (epoch 6)" before
    /// "remove A (epoch 5)". A single group-level epoch guard would
    /// drop the epoch-5 removal forever, leaving A trusted. So the
    /// apply decomposes:
    ///
    ///  - **Group-state advance** (epoch / commitment / salt /
    ///    groupSecret): strictly converge-forward — only when
    ///    `payload.epoch > group.epoch`. Never rolls backward, which
    ///    keeps the re-admission replay from restoring old secrets.
    ///  - **Tombstone** (per-member, order-independent): applies when
    ///    this removal is NEWER than the member's last known status
    ///    change (`MemberProfile.statusEpoch`) — so a stale-but-unseen
    ///    removal still lands, while a removal replayed after that
    ///    member's later re-admission is refused. The victim's
    ///    `ChatGroup.members` leaf is subtracted together with the
    ///    tombstone (a member removed at epoch 5 is not in ANY later
    ///    tree unless re-admitted, which resets statusEpoch).
    ///
    /// A payload where NEITHER effect applies is dropped before any
    /// chain read — that's the idempotency for relay re-delivery.
    ///
    /// ## Fail closed on a missing admin key
    ///
    /// Groups materialized from an unsigned invitation envelope store
    /// `adminEd25519PubkeyHex == nil`. `isAuthorizedGroupMutation`'s
    /// any-current-member fallback is tolerable for additive
    /// announcements, but a subtractive op would let any member evict
    /// any other member from every peer's local view — so removal
    /// requires the stored admin key, full stop.
    ///
    /// Mirrors `applyRemoval` from onym-android's
    /// `IncomingMessageDispatcher.kt`.
    private func applyRemoval(
        _ payload: MemberRemovalPayload,
        ownerIdentityID: IdentityID,
        senderEd25519PublicKey: Data?
    ) async -> RemovalApplyResult {
        let groups = await groupRepository.currentGroups()
        guard let group = groups.first(where: {
            $0.groupIDData == payload.groupID && $0.ownerIdentityID == ownerIdentityID
        }) else { return .done }
        guard group.groupType == .tyranny else { return .done }

        // Subtractive ops fail CLOSED without a stored admin key —
        // see the doc comment. (isAuthorizedGroupMutation would
        // otherwise fall back to any-current-member.)
        guard group.adminEd25519PubkeyHex != nil else { return .done }

        // Self classification. If we can't resolve our own BLS key we
        // can't tell which branch is safe — drop rather than let the
        // victim's own device take the remaining-member branch and
        // delete itself from its own roster. (Production always wires
        // the identities provider; this is the fallback posture.)
        let victimHex = payload.removedBlsHex.lowercased()
        let summaries = (try? await identities.currentIdentities()) ?? []
        guard let selfHex = summaries.first(where: { $0.id == ownerIdentityID })?
            .blsPublicKey
            .map({ String(format: "%02x", $0) }).joined()
        else { return .done }
        let isSelf = selfHex == victimHex

        // Local applicability — BEFORE any chain read (launch-storm
        // pattern). Which effects would this payload have?
        let victimProfile = group.memberProfiles[victimHex]
        let advancesState = payload.epoch > group.epoch
        let tombstoneApplies: Bool = {
            guard !isSelf, let victimProfile, !victimProfile.revoked else { return false }
            return victimProfile.statusEpoch.map { payload.epoch > $0 } ?? true
        }()
        let selfApplies: Bool = {
            guard isSelf, !group.membershipRevoked else { return false }
            return (victimProfile?.statusEpoch).map { payload.epoch > $0 } ?? true
        }()
        if isSelf && !selfApplies { return .done }
        if !isSelf && !tombstoneApplies && !advancesState { return .done }

        // Trust gate: only the stored admin may shrink the roster.
        guard isAuthorizedGroupMutation(
            group: group,
            senderEd25519PublicKey: senderEd25519PublicKey
        ) else { return .done }

        // On-chain converge-forward gate (same posture as
        // verifyTyrannyAnnouncement: no roster recompute, the anchor
        // is the strong check). chain ahead → accept (we missed
        // updates; the admin-signed removal is still legitimate),
        // exact epoch → byte-verify, chain behind → caller retries.
        let onchain: SEPCommitmentEntry
        do {
            onchain = try await chainState.tyrannyCommitment(groupID: payload.groupID)
        } catch {
            // Unreachable relayer is not evidence of forgery, but
            // accepting unverified would let a stolen admin key
            // shrink rosters offline. Retry like chain-behind.
            return .chainBehind
        }
        if onchain.epoch < payload.epoch { return .chainBehind }
        if onchain.epoch == payload.epoch, onchain.commitment != payload.commitment {
            return .done
        }

        if isSelf {
            // Victim device: mark and keep everything else untouched.
            // (No state advance from the secret-free victim variant.)
            var updated = group
            updated.membershipRevoked = true
            await groupRepository.insert(updated)
            return .done
        }

        var updated = group
        // Tombstone effect — order-independent (see the doc comment).
        if tombstoneApplies {
            let victimBytes = ChatGroup.bytes(fromHex: victimHex)
            updated.members.removeAll { $0.publicKeyCompressed == victimBytes }
            if let victimProfile {
                updated.memberProfiles[victimHex] = victimProfile.withStatus(
                    revoked: true,
                    statusEpoch: payload.epoch
                )
            }
        }
        // Group-state effect — strictly converge-forward. The victim's
        // own copy carries no secrets; a remaining member that somehow
        // received it keeps the old material and converges via the
        // admin's refresh path.
        if advancesState {
            updated.epoch = payload.epoch
            updated.commitment = payload.commitment
            updated.salt = payload.saltNew ?? group.salt
            updated.groupSecret = payload.groupSecretNew ?? group.groupSecret
        }
        await groupRepository.insert(updated)
        return .done
    }

    /// One initial `applyRemoval` pass plus a bounded retry loop for
    /// the chain-behind case.
    ///
    /// A removal usually lands seconds after the admin anchors, while
    /// `CachingChainStateReader` may serve a ≤10s-old entry — the
    /// chain read looks *behind* the claimed epoch. For announcements
    /// that case is a plain drop (later activity backfills); a dropped
    /// removal would leave the victim trusted, so we re-check after
    /// `removalRetryDelayNanos` (then 2×) — each attempt past the
    /// cache TTL. After `removalMaxRetries` the payload is dropped for
    /// THIS delivery; the next inbox replay retries from scratch, so
    /// the removal is never permanently lost.
    ///
    /// The dedup key is held for the WHOLE retry loop — including the
    /// network-bound `applyRemoval` re-attempts — so a relay
    /// re-delivery at any point while a retry chain is live can't
    /// stack a parallel chain. It's released when the loop ends, so a
    /// later replay gets a fresh retry budget.
    private func applyRemovalWithRetry(
        _ payload: MemberRemovalPayload,
        ownerIdentityID: IdentityID,
        senderEd25519PublicKey: Data?
    ) async {
        let first = await applyRemoval(
            payload,
            ownerIdentityID: ownerIdentityID,
            senderEd25519PublicKey: senderEd25519PublicKey
        )
        guard first == .chainBehind else { return }
        guard removalMaxRetries > 0 else { return }

        let groupIDHex = payload.groupID.map { String(format: "%02x", $0) }.joined()
        let key = "\(groupIDHex):\(payload.removedBlsHex.lowercased()):\(payload.epoch)"
        guard await removalRetries.begin(key) else { return }

        let dispatcher = self
        let maxRetries = removalMaxRetries
        let baseDelay = removalRetryDelayNanos
        let sleep = removalRetrySleep
        let registry = removalRetries
        await removalRetryScheduler {
            for attempt in 1...maxRetries {
                await sleep(baseDelay * UInt64(attempt))
                let result = await dispatcher.applyRemoval(
                    payload,
                    ownerIdentityID: ownerIdentityID,
                    senderEd25519PublicKey: senderEd25519PublicKey
                )
                if result != .chainBehind { break }
            }
            await registry.end(key)
        }
    }

    /// Apply an inbound group-photo update to the matching local group.
    /// Same trust gate as `applyAnnouncement` (`isAuthorizedGroupMutation`):
    /// the verified Ed25519 signer must match the group's stored
    /// `adminEd25519PubkeyHex`, or — for admin-less groups — be a
    /// current member. An unsigned/unverified update is rejected
    /// (H-2). No on-chain cross-check —
    /// the avatar isn't part of the group commitment. No-op when the
    /// group is unknown or the photo already matches (re-delivery).
    private func applyAvatar(
        _ payload: GroupAvatarPayload,
        senderEd25519PublicKey: Data?
    ) async {
        let groups = await groupRepository.currentGroups()
        guard let group = groups.first(where: { $0.groupIDData == payload.groupID }) else {
            return
        }
        // PR 9 + H-2: admin (or, for admin-less groups, a current
        // member) must be the verified signer; unsigned is rejected.
        guard isAuthorizedGroupMutation(
            group: group,
            senderEd25519PublicKey: senderEd25519PublicKey
        ) else { return }
        guard group.avatarJPEG != payload.avatar else { return }
        var updated = group
        updated.avatarJPEG = payload.avatar
        await groupRepository.insert(updated)
    }

    /// Apply an admin group-rename (`GroupNamePayload`). Same gate as
    /// `applyAvatar` (`isAuthorizedGroupMutation`): the verified signer
    /// must be the stored admin, or — for admin-less groups — a current
    /// member; an unsigned/unverified rename is dropped (H-2).
    /// Idempotent + ignores a blank name.
    private func applyName(
        _ payload: GroupNamePayload,
        senderEd25519PublicKey: Data?
    ) async {
        let trimmed = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let groups = await groupRepository.currentGroups()
        guard let group = groups.first(where: { $0.groupIDData == payload.groupID }) else {
            return
        }
        // PR 9 + H-2: admin (or, for admin-less groups, a current
        // member) must be the verified signer; unsigned is rejected.
        guard isAuthorizedGroupMutation(
            group: group,
            senderEd25519PublicKey: senderEd25519PublicKey
        ) else { return }
        guard group.name != trimmed else { return }
        var updated = group
        updated.name = trimmed
        await groupRepository.insert(updated)
    }

    /// Persist an incoming chat message after authenticating the
    /// sender. The trust chain:
    ///
    ///   1. The envelope was decrypted to us, so the sender knew our
    ///      inbox pubkey (a group-membership-gated secret).
    ///   2. The envelope's Ed25519 signer was verified by
    ///      `decryptInvitationWithSender` — `senderEd25519PublicKey`
    ///      is *who* signed, not just *what was claimed*.
    ///   3. The payload's `senderBlsPubkeyHex` claim is cross-checked
    ///      against `memberProfiles[claim].sendingPubkey`: if the
    ///      envelope's signer matches the stored Ed25519 for the
    ///      claimed BLS member, the claim is authentic.
    ///
    /// Receive-side dedup happens in `MessageRepository.insert`
    /// (idempotent on `message.id`).
    private func persistChatMessage(
        _ payload: ChatMessagePayload,
        ownerIdentityID: IdentityID,
        senderEd25519PublicKey: Data?
    ) async {
        // Envelope must have been signed — anonymous chat messages
        // are not part of the v1 trust model.
        guard let senderEd25519PublicKey else { return }

        // Look up the local group. Drop if we don't know it (stale
        // delivery for a group we left, or routing mistake) or if it
        // belongs to a different identity than the receiving inbox.
        let groupIDHex = payload.groupID
            .map { String(format: "%02x", $0) }.joined()
        let groups = await groupRepository.currentGroups()
        guard let group = groups.first(where: {
            $0.id == groupIDHex && $0.ownerIdentityID == ownerIdentityID
        }) else {
            return
        }

        // Sender must be a known member. `memberProfiles` is keyed by
        // lowercase BLS pubkey hex; normalize the payload's claim
        // before lookup.
        let senderKey = payload.senderBlsPubkeyHex.lowercased()
        guard let senderProfile = group.memberProfiles[senderKey] else {
            return
        }

        // Removed members are tombstoned, not deleted — their key
        // still resolves, so the trust chain must check the flag:
        // a removed member's post-removal sends are dropped here.
        guard !senderProfile.revoked else { return }

        // Insider-spoof check: the verified envelope signer must match
        // the stored Ed25519 for the claimed BLS member. Without this,
        // Bob (a member) could write Alice's BLS hex into the payload
        // and the receiver would attribute it wrong.
        guard senderEd25519PublicKey == senderProfile.sendingPubkey else {
            return
        }

        // Variant must match the group's governance type — Tyranny
        // payloads belong in Tyranny groups, etc. Today only Tyranny
        // chat ships; the variant kind doubles as a forward-compat
        // gate for when other group types come online.
        let variantKind: SEPGroupType = {
            switch payload.variant {
            case .tyranny: return .tyranny
            }
        }()
        guard variantKind == group.groupType else { return }

        let sentAt = Date(timeIntervalSince1970:
            TimeInterval(payload.sentAtMillis) / 1000.0)
        let message = ChatMessage(
            id: payload.messageID,
            groupID: groupIDHex,
            ownerIdentityID: ownerIdentityID,
            senderBlsPubkeyHex: senderKey,
            body: payload.variant.body,
            sentAt: sentAt,
            direction: .incoming,
            status: .received,
            // Pointer to the quoted message, resolved against the
            // local store at render time. No trust gate needed: a ref
            // to a message we never received (or a forged one) just
            // renders as "message unavailable" — it can't pull in
            // content from outside this group because rendering only
            // looks up local rows.
            replyToMessageID: payload.replyToMessageID,
            groupType: group.groupType,
            // Encrypted image (if any). The blob is fetched + decrypted
            // lazily at render time (`ChatImageLoader`); nothing is
            // downloaded on receipt.
            imageAttachment: payload.attachment,
            // Encrypted video (if any). Only the small poster loads on
            // render; the video blob downloads on play (`ChatVideoLoader`).
            videoAttachment: payload.videoAttachment,
            // Multi-media album (if any). Each item's poster loads lazily
            // like a single image/video.
            albumAttachments: payload.attachments,
            // Encrypted voice message (if any). The waveform + duration
            // render from the descriptor; the audio blob downloads on play
            // (`ChatVoiceLoader`).
            voiceAttachment: payload.voiceAttachment
        )
        let outcome = await messageRepository.insert(message)

        // Ack the sender: delivered now (it only reveals a device
        // received the ciphertext). Read receipts are sent later, when
        // the user opens the thread. The receipt send is fire-and-
        // forget with no outbox, so inbox replays are its only retry —
        // gate on the persisted `deliveredAckSent` latch, not on
        // "newly inserted":
        // - `.inserted` → first sight, ack.
        // - `.updated` → replay; ack ONLY if no earlier attempt
        //   succeeded (re-acking every replay published a receipt per
        //   historical message on every launch, each becoming a new
        //   stored event in the sender's inbox — snowballing replays
        //   for both sides).
        // - `.failed` → nothing stored; acking would tell the sender
        //   "delivered" about a message this device lost. Stay silent
        //   so the relay copy retries on the next replay.
        let needsAck: Bool
        switch outcome {
        case .inserted:
            needsAck = true
        case .updated:
            needsAck = await messageRepository.needsDeliveredAck(
                id: message.id,
                owner: message.ownerIdentityID
            )
        case .failed:
            needsAck = false
        }
        guard needsAck else { return }
        let accepted = await receiptSender.send(
            kind: .delivered,
            messageIDs: [payload.messageID],
            groupID: payload.groupID,
            to: senderProfile.inboxPublicKey
        )
        if accepted {
            await messageRepository.markDeliveredAckSent(
                id: message.id,
                owner: message.ownerIdentityID
            )
        }
    }

    /// Apply an inbound receipt: raise the acked outgoing messages to
    /// `.delivered` / `.read` (monotonic — `MessageRepository`
    /// enforces). Read receipts are honored only when this device also
    /// sends them (symmetric).
    private func applyReceipt(_ receipt: ChatReceiptPayload, ownerIdentityID: IdentityID) async {
        let newStatus: MessageStatus
        switch receipt.kind {
        case .delivered:
            newStatus = .delivered
        case .read:
            guard readReceiptsEnabled() else { return }
            newStatus = .read
        }
        let groupIDHex = receipt.groupID
            .map { String(format: "%02x", $0) }.joined()
        for id in receipt.messageIDs {
            await messageRepository.upgradeStatus(
                id: id,
                to: newStatus,
                groupID: groupIDHex,
                owner: ownerIdentityID
            )
        }
    }
}

/// Dedup keys of member-removal retries currently scheduled, so a
/// relay re-delivery during the delay window can't stack a second
/// timer for the same removal (see
/// `IncomingMessageDispatcher.scheduleRemovalRetry`). An actor —
/// the value-type dispatcher shares one reference across its copies.
/// Mirrors `pendingRemovalRetries` from onym-android's dispatcher.
actor RemovalRetryRegistry {
    private var pending: Set<String> = []

    /// Register `key`. Returns `false` when a retry for it is already
    /// scheduled — the caller must not stack another timer.
    func begin(_ key: String) -> Bool {
        pending.insert(key).inserted
    }

    func end(_ key: String) {
        pending.remove(key)
    }
}
