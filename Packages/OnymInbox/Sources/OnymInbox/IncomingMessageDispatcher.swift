import Foundation
import OnymChain
import OnymChatsCore
import OnymIdentity
import OnymGroup

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
public struct IncomingMessageDispatcher: Sendable {
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
    /// as a `PendingChat` awaiting the user's explicit Accept (which
    /// ships a `JoinRequestPayload`) or dismiss. It grants nothing and
    /// never materializes a group: membership only follows the
    /// invitee's accept + the admin's explicit on-chain approve.
    ///
    /// Defaulted (in `init`) to a fresh store so the many existing test
    /// constructions don't have to thread a spy they don't exercise;
    /// production (`OnymIOSApp`) passes the shared store explicitly.
    let pendingChats: any PendingChatRecording
    /// Seam for the verify-at-current state machine (Option 2). A stale
    /// Tyranny snapshot (chain advanced past its epoch) is deferred here
    /// on the invitee side; inbound `GroupStateRefreshRequest`s are
    /// answered here on the admin side. Defaulted to a no-op for the
    /// same reason as `pendingChats`.
    let groupStateRefresher: any GroupStateRefreshing
    /// Ships a delivered receipt back to a chat message's sender the
    /// moment we persist it. Defaulted to a no-op so the many existing
    /// test constructions don't have to thread it.
    let receiptSender: any ChatReceiptSending
    /// Symmetric read-receipt gate: an inbound `.read` receipt only
    /// raises a message to `.read` when this device also sends read
    /// receipts. Defaulted to `true` (the shipping default).
    let readReceiptsEnabled: @Sendable () -> Bool
    /// Chat messages that arrived before their group (or their
    /// sender's roster entry) wait here instead of being dropped, and
    /// are re-driven when `materializeGroup` / `applyAnnouncement`
    /// catches the local state up — see `ChatMessageParkingLot`.
    /// Defaulted so existing constructions get the behaviour without
    /// a new parameter.
    let parkedMessages: ChatMessageParkingLot

    /// Mints the membership notices this device is entitled to render:
    /// "X joined" off a verified announcement, "You joined X" off a
    /// verified invitation. Derived from `messageRepository` rather than
    /// injected — it is a thin, stateless wrapper over the same
    /// repository, and every existing test construction of the
    /// dispatcher gets the behaviour without a new parameter.
    private var systemEvents: ChatSystemEventRecorder {
        ChatSystemEventRecorder(messageRepository: messageRepository)
    }

    public init(
        envelopeDecrypter: any InvitationEnvelopeDecrypting,
        identities: any IdentitiesProviding,
        groupRepository: GroupRepository,
        invitationsRepository: IncomingInvitationsRepository,
        chainState: any ChainStateReading,
        messageRepository: MessageRepository,
        pendingChats: any PendingChatRecording = NoopPendingChatRecorder(),
        groupStateRefresher: any GroupStateRefreshing = NoopGroupStateRefresher(),
        receiptSender: any ChatReceiptSending = NoopChatReceiptSender(),
        readReceiptsEnabled: @escaping @Sendable () -> Bool = { true },
        parkedMessages: ChatMessageParkingLot = ChatMessageParkingLot()
    ) {
        self.envelopeDecrypter = envelopeDecrypter
        self.identities = identities
        self.groupRepository = groupRepository
        self.invitationsRepository = invitationsRepository
        self.chainState = chainState
        self.messageRepository = messageRepository
        self.pendingChats = pendingChats
        self.groupStateRefresher = groupStateRefresher
        self.receiptSender = receiptSender
        self.readReceiptsEnabled = readReceiptsEnabled
        self.parkedMessages = parkedMessages
    }

    public func dispatch(
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

    /// Record a decoded push offer as a chat the user has been offered
    /// a seat in — a row in their chats list, awaiting the explicit
    /// Accept that ships the join request.
    ///
    /// Keyed by `(group, owner)` rather than by the inbound event id: a
    /// replaceable offer is re-fetched on every relaunch, and a row that
    /// the user has already accepted must not come back asking to be
    /// accepted again. The store's dedup handles that; nothing here has
    /// to remember which deliveries it has seen.
    ///
    /// The store's dedup cannot cover the replay that arrives *after*
    /// the group materialized, though — by then there is no row left to
    /// collapse onto, and the sweep that would clear a fresh one only
    /// runs on a `GroupRepository` emission. That row is durable now and
    /// renders in the chats list beside the real chat, offering to send
    /// a join request for a group the user is already in. So the check
    /// is here, at the only point that knows the offer is new.
    private func recordOffer(
        _ offer: GroupInviteOfferPayload,
        ownerIdentityID: IdentityID,
        receivedAt: Date
    ) async {
        let groupIDHex = offer.groupID.map { String(format: "%02x", $0) }.joined()
        let alreadyJoined = await groupRepository.currentGroups().contains {
            $0.id == groupIDHex && $0.ownerIdentityID == ownerIdentityID
        }
        // Scoped to the invited identity: another identity on this
        // device being in the group says nothing about whether this one
        // was invited to it.
        guard !alreadyJoined else { return }
        await pendingChats.record(PendingChat(
            groupID: offer.groupID,
            ownerIdentityID: ownerIdentityID,
            introPublicKey: offer.introPublicKey,
            groupName: offer.groupName,
            inviterAlias: offer.inviterAlias,
            invitationMessage: offer.invitationMessage,
            receivedAt: receivedAt,
            status: .offered
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
    /// Re-run verification for a snapshot parked because *this* device
    /// couldn't confirm it — no chain read, or the anchoring hadn't
    /// settled. Drives the Retry on those cards, since the remedy is
    /// another chain read rather than another message to the admin.
    ///
    /// Idempotent: a snapshot that still fails is re-parked with a fresh
    /// reason, and one that now verifies materializes and clears itself.
    public func reverify(
        invitation: GroupInvitationPayload,
        ownerIdentityID: IdentityID,
        senderEd25519PublicKey: Data?
    ) async {
        await materializeGroup(
            invitation,
            ownerIdentityID: ownerIdentityID,
            // Carried through from the original delivery. Dropping it
            // would leave the materialized group without
            // `adminEd25519PubkeyHex`, and every later
            // `MemberAnnouncementPayload` is checked against exactly
            // that — so a group admitted via Retry would silently stop
            // accepting new members.
            senderEd25519PublicKey: senderEd25519PublicKey
        )
    }

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
            let verification = await verifyTyrannyInvitation(invitation, tier: tier)
            switch verification {
            case .verified:
                break  // materialize below
            case .reject:
                return
            case .staleNeedsRefresh:
                // Genuinely past the archive window: the admin is the
                // only remaining source of current state, so ask them.
                await groupStateRefresher.deferVerification(
                    invitation: invitation,
                    ownerIdentityID: ownerIdentityID
                )
                return
            case .chainUnreachable, .chainNotConfigured:
                // This device's problem, not the admin's. Park it with a
                // reason the user can act on and send nothing — a
                // refresh request would be answered and still leave the
                // snapshot unverifiable.
                await groupStateRefresher.deferLocally(
                    invitation: invitation,
                    ownerIdentityID: ownerIdentityID,
                    senderEd25519PublicKey: senderEd25519PublicKey,
                    status: verification == .chainNotConfigured
                        ? .chainNotConfigured
                        : .chainUnreachable
                )
                return
            case .groupNotOnChainYet, .chainBehindSnapshot:
                // Both resolve by re-reading in a moment: the group's
                // anchoring is still settling, or our read lags it.
                await groupStateRefresher.deferLocally(
                    invitation: invitation,
                    ownerIdentityID: ownerIdentityID,
                    senderEd25519PublicKey: senderEd25519PublicKey,
                    status: .chainSettling
                )
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
            isPublishedOnChain: true,
            // Group photo as the sender knew it. `nil` for avatar-less
            // groups or pre-avatar senders; a later GroupAvatarPayload
            // can still fill it in.
            avatarJPEG: invitation.avatar,
            // The group's invitation/intro, as the sender wrote it.
            invitationMessage: invitation.invitationMessage
        )

        // Was this thread already on the device? Relays replay the
        // inbox on every reconnect, so a re-delivered invitation is
        // routine — only the first one is a "you joined" moment.
        let existing = await groupRepository.currentGroups().contains {
            $0.id == groupIDHex && $0.ownerIdentityID == ownerIdentityID
        }

        await groupRepository.insert(group)

        // The group exists now — re-drive any chat messages that
        // arrived ahead of this invitation in the replay stream.
        await drainParkedMessages(groupIDHex: groupIDHex)

        // Open the joiner's brand-new thread with a line explaining
        // what it is, instead of a blank screen, once the invitation has
        // cleared verification above.
        guard !existing,
              let selfEntry = await selfMemberProfileEntry(for: ownerIdentityID)
        else { return }
        await systemEvents.recordYouJoined(
            groupID: groupIDHex,
            ownerIdentityID: ownerIdentityID,
            groupType: groupType,
            groupName: invitation.name,
            ownBlsPubkeyHex: selfEntry.key,
            at: Date()
        )
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
        /// chain has advanced past the snapshot's epoch *and* the
        /// archived entry for that epoch is out of the contract's
        /// 64-entry window. Only here is a refresh from the admin the
        /// actual remedy.
        case staleNeedsRefresh
        /// The chain couldn't be read at all — throttled, offline, or a
        /// relayer that answered with an error.
        ///
        /// Split out from `staleNeedsRefresh` because the two need
        /// opposite responses. This one is entirely local to the
        /// receiver: asking the admin cannot fix it, and the previous
        /// behaviour — defer, tell the user "the admin is offline",
        /// offer a Retry that re-sends to the admin — left a joiner
        /// looping forever against a wall they alone could take down.
        case chainUnreachable
        /// No relayer endpoint or no contract binding for the active
        /// network — nothing was attempted over the network at all.
        case chainNotConfigured
        /// The contract has no record of this group yet
        /// (`GroupNotFound`). The admin's `create_group` is still
        /// settling; seconds later this becomes verifiable on its own.
        case groupNotOnChainYet
        /// The chain is *behind* the snapshot: our read hasn't caught up
        /// with an `update_commitment` that has already landed. Also
        /// what a self-consistent forgery claiming a future epoch looks
        /// like — indistinguishable here, which is why this waits rather
        /// than trusting. Resolves by re-reading, not by asking anyone.
        case chainBehindSnapshot
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
            // NOT evidence of forgery — never reject. But which failure
            // it is decides what the user should do about it, and these
            // used to be indistinguishable: everything became "ask the
            // admin", including the failures no admin could resolve.
            if let sepError = error as? SEPError,
               sepError.contractErrorCode == SEPContractErrorCode.groupNotFound.rawValue {
                return .groupNotOnChainYet
            }
            if let readError = error as? ChainReadError {
                // No relayer / no contract binding: nothing was even
                // attempted over the network, so this is a setup state
                // rather than a failed call — and on a fresh install
                // it's usually just the launch fetch not having landed.
                _ = readError
                return .chainNotConfigured
            }
            return .chainUnreachable
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
        guard onchain.epoch >= invitation.epoch else { return .chainBehindSnapshot }
        if onchain.epoch == invitation.epoch {
            return onchain.commitment == claimedCommitment ? .verified : .reject
        }

        // Chain AHEAD. The contract archives every entry it supersedes
        // and keeps the last `historyWindow`, so a snapshot the chain
        // has moved past is still checkable against what was actually
        // committed at its own epoch — reproducing
        // `Poseidon(Poseidon(root, epoch), salt)` for an archived epoch
        // needs the same never-on-chain `salt`, so this is exactly as
        // strong as the exact-epoch check above.
        //
        // This is why the admin no longer has to be awake for the common
        // case: an admin who admits a second joiner before the first has
        // opened the app used to strand that first invitation on a
        // round-trip to a sleeping phone.
        do {
            let history = try await chainState.tyrannyHistory(
                groupID: invitation.groupID,
                maxEntries: Self.historyWindow
            )
            if let archived = history.first(where: { $0.epoch == invitation.epoch }) {
                return archived.commitment == claimedCommitment ? .verified : .reject
            }
        } catch {
            // History unreadable (older relayer, throttle). Fall through
            // to the admin refresh rather than failing: this path is an
            // optimization over asking, not a replacement for it.
        }

        // Older than the window, or no history available — the admin is
        // now genuinely the only source for current state.
        return .staleNeedsRefresh
    }

    /// Matches `HISTORY_WINDOW` in `sep-tyranny`. Asking for more than
    /// the contract keeps is harmless (it clamps), but asking for the
    /// exact figure documents the bound this relies on.
    private static let historyWindow: UInt32 = 64

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
        return group.memberProfiles.values.contains {
            $0.sendingPubkey == senderEd25519PublicKey
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
        let key = payload.newMember.blsPub
            .map { String(format: "%02x", $0) }.joined()
        if group.memberProfiles[key] != nil { return }

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
            // Carried through rather than defaulted away: this is the
            // step that makes a member's agreement checkable by
            // everyone already in the group, not only by the founder
            // who admitted them.
            rulesHash: payload.newMember.rulesHash,
            rulesSignature: payload.newMember.rulesSignature,
            rulesText: payload.newMember.rulesText
        )
        await groupRepository.insert(updated)

        // The roster caught up — re-drive any of this member's chat
        // messages that arrived ahead of their announcement.
        await drainParkedMessages(groupIDHex: updated.id)

        // "X joined", for every existing member. Reached only past the
        // dedup guard above (`memberProfiles[key] != nil`), the admin
        // signature check, and the on-chain commitment check — so a
        // relay replaying this announcement on each reconnect can't
        // append a second notice, and an unverified announcement can't
        // append one at all.
        await systemEvents.recordMemberJoined(
            groupID: updated.id,
            ownerIdentityID: updated.ownerIdentityID,
            groupType: updated.groupType,
            joinerBlsPubkeyHex: key,
            alias: payload.newMember.alias,
            at: Date()
        )
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

    /// Re-drive every parked message for `groupIDHex` through the
    /// normal persist path now that the group or its roster caught
    /// up. Entries that are still blocked (e.g. their sender's
    /// announcement hasn't landed yet) re-park themselves; each
    /// drain removes the batch first, so a still-blocked entry is
    /// processed once per drain, never in a loop.
    private func drainParkedMessages(groupIDHex: String) async {
        for entry in await parkedMessages.takeMatching(groupIDHex: groupIDHex) {
            await persistChatMessage(
                entry.payload,
                ownerIdentityID: entry.ownerIdentityID,
                senderEd25519PublicKey: entry.senderEd25519PublicKey
            )
        }
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

        // Look up the local group. An unknown group is NOT dropped:
        // relays replay the inbox newest-first, so on a fresh (or
        // store-lost) device the thread's messages routinely arrive
        // before the invitation that materializes the group. Park them;
        // `materializeGroup` drains the lot once the group exists. A
        // genuinely stale delivery (group we left for good) just ages
        // out of the session-scoped lot.
        let groupIDHex = payload.groupID
            .map { String(format: "%02x", $0) }.joined()
        let groups = await groupRepository.currentGroups()
        guard let group = groups.first(where: {
            $0.id == groupIDHex && $0.ownerIdentityID == ownerIdentityID
        }) else {
            await parkedMessages.park(.init(
                groupIDHex: groupIDHex,
                payload: payload,
                ownerIdentityID: ownerIdentityID,
                senderEd25519PublicKey: senderEd25519PublicKey
            ))
            return
        }

        // Sender must be a known member. `memberProfiles` is keyed by
        // lowercase BLS pubkey hex; normalize the payload's claim
        // before lookup. Unknown senders park too — during a replay
        // the member's announcement may simply not have been applied
        // yet; `applyAnnouncement` drains the lot when it lands.
        let senderKey = payload.senderBlsPubkeyHex.lowercased()
        guard let senderProfile = group.memberProfiles[senderKey] else {
            await parkedMessages.park(.init(
                groupIDHex: groupIDHex,
                payload: payload,
                ownerIdentityID: ownerIdentityID,
                senderEd25519PublicKey: senderEd25519PublicKey
            ))
            return
        }

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
            moderationAuthenticityProof: payload.moderationAuthenticityProof,
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
