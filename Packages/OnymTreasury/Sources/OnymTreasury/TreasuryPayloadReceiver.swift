import Foundation
import OnymGroup
import OnymIdentity
import OnymStellar
import OnymFoundation

/// Applies inbound treasury payloads, after checking them.
///
/// Every method here is reached from `IncomingMessageDispatcher` with
/// the envelope's **verified** Ed25519 sender — the key that actually
/// sealed the message, not a name the payload chose. Matching that key
/// against the group roster is what stops an insider from posting a
/// proposal under someone else's name, and is the same defence the
/// chat dispatcher applies to `ChatMessagePayload`.
///
/// Nothing here logs. A treasury payload names who is moving money with
/// whom, which is precisely the activity the app does not keep records
/// of.
public struct TreasuryPayloadReceiver: Sendable {
    private let treasury: TreasuryRepository
    private let groups: GroupRepository

    public init(treasury: TreasuryRepository, groups: GroupRepository) {
        self.treasury = treasury
        self.groups = groups
    }

    // MARK: - Declaration

    public func apply(
        _ payload: TreasurySignerDeclarationPayload,
        ownerIdentityID: IdentityID,
        senderEd25519PublicKey: Data?,
        now: Date = Date()
    ) async {
        guard let group = await group(payload.groupID, ownerIdentityID),
              let account = try? StellarAccountID(accountID: payload.signerAccountID)
        else { return }

        // The claimed declarer must be a member, and the envelope must
        // have been sealed by that member's own key. Without the second
        // check any member could declare an account on another's
        // behalf, which is a way to hand a stranger a seat or to
        // deadlock the treasury with an account nobody holds.
        // A nil sender is an envelope that shipped without a signature.
        // It cannot be attributed to anyone, so it cannot be a
        // declaration by anyone — refused here explicitly rather than
        // by an accidental comparison against empty bytes.
        guard let senderEd25519PublicKey,
              let profile = group.memberProfiles[payload.declarerBlsPubkeyHex],
              profile.sendingPubkey == senderEd25519PublicKey
        else { return }

        // The detached signature is what makes this showable to a third
        // party later; the envelope only says who sent it.
        guard TreasurySignerDeclaration.isDeclaration(
            signature: payload.signature,
            signerAccount: account,
            groupID: group.groupIDData,
            declarerSendingPublicKey: profile.sendingPubkey
        ) else { return }

        // Two re-declarations delivered out of order would otherwise
        // leave the group on the older account — inbox delivery has no
        // ordering guarantee, and `sentAtMillis` is outside the signed
        // statement so it is the sender's word. That is enough for
        // *monotonicity*, though: a sender can only make their own
        // declaration harder to replace, never someone else's, because
        // the statement binds the declarer. `declaredAt` is already
        // stored, so the guard is nearly free.
        let declaredAt = Date(
            timeIntervalSince1970: TimeInterval(payload.sentAtMillis) / 1000
        )
        let existing = await treasury
            .snapshot(groupID: group.id, ownerIdentityID: ownerIdentityID)
            .declarations
            .first { $0.memberBlsPubkeyHex == payload.declarerBlsPubkeyHex }
        if let existing, existing.declaredAt > declaredAt { return }

        await treasury.record(TreasurySignerDeclarationRecord(
            groupID: group.id,
            ownerIdentityID: ownerIdentityID,
            memberBlsPubkeyHex: payload.declarerBlsPubkeyHex,
            account: account,
            source: payload.source,
            signature: payload.signature,
            declarerSendingPublicKey: profile.sendingPubkey,
            declaredAt: declaredAt
        ))
    }

    // MARK: - Anchor

    /// Adopt a treasury the founder announced.
    ///
    /// Admin-gated against `ChatGroup.adminEd25519PubkeyHex`, the same
    /// gate `GroupAvatarPayload` uses. And **refused if this group
    /// already has a treasury**: re-anchoring would let a compromised
    /// or careless founder redirect the group to a different account,
    /// and every subsequent proposal would verify cleanly against the
    /// new one. Moving a treasury is not a thing this app does; a group
    /// that wants a different account makes a new one and the old
    /// address stays on the ledger where everyone can see it.
    public func apply(
        _ payload: TreasuryAnchorPayload,
        ownerIdentityID: IdentityID,
        senderEd25519PublicKey: Data?
    ) async {
        guard let senderEd25519PublicKey,
              let group = await group(payload.groupID, ownerIdentityID),
              let adminHex = group.adminEd25519PubkeyHex?.lowercased(),
              senderEd25519PublicKey.hexString == adminHex,
              let account = try? StellarAccountID(accountID: payload.treasuryAccountID),
              let network = StellarNetwork(passphrase: payload.networkPassphrase)
        else { return }

        let existing = await treasury
            .snapshot(groupID: group.id, ownerIdentityID: ownerIdentityID)
            .treasury
        guard existing == nil else { return }

        await treasury.anchor(Treasury(
            account: account,
            groupID: group.id,
            ownerIdentityID: ownerIdentityID,
            network: network,
            creationTxHash: payload.creationTxHash,
            createdAt: Date(timeIntervalSince1970: TimeInterval(payload.sentAtMillis) / 1000)
        ))
        await treasury.refresh(groupID: group.id, ownerIdentityID: ownerIdentityID)

        // The anchor and the first proposal are independent envelopes
        // with no ordering guarantee between them, so a founder who
        // announces and immediately proposes leaves some members
        // holding a proposal that arrived first and was refused for
        // `noTreasury` — permanently, with no path back. The chat layer
        // has `ChatMessageParkingLot` for exactly this shape; here the
        // refused rows *are* the parking lot, so adopting the anchor
        // re-runs them.
        await reverifyRefusedProposals(group: group, ownerIdentityID: ownerIdentityID)
    }

    /// Re-run proposals this device turned down for a reason that was
    /// never about the bytes.
    ///
    /// `TreasuryRejection.isAboutTheLedger` draws the line, and only
    /// those rows are re-run: every other refusal is a fact about the
    /// transaction that no later message can change, and re-running
    /// them would be a way to launder a refusal by sending an anchor
    /// afterwards. `implausibleSequence` joins `noTreasury` here
    /// because it is decided against a cached account read — a device
    /// whose snapshot had fallen more than the lookahead behind refused
    /// proposals the network would accept, and without this the refusal
    /// was permanent.
    private func reverifyRefusedProposals(
        group: ChatGroup,
        ownerIdentityID: IdentityID
    ) async {
        let snapshot = await treasury.snapshot(
            groupID: group.id,
            ownerIdentityID: ownerIdentityID
        )
        guard let anchored = snapshot.treasury else { return }
        // The live read, not the cached one. Re-running a sequence
        // refusal against the same stale snapshot that produced it
        // would reach the same answer every time.
        let currentSequence = await treasury.refresh(
            groupID: group.id,
            ownerIdentityID: ownerIdentityID
        )?.sequenceNumber ?? snapshot.account?.sequenceNumber
        for stored in snapshot.proposals
        where stored.rejection?.isAboutTheLedger == true {
            let proposal = stored.proposal
            let outcome = TreasuryProposalVerifier.verify(
                envelope: proposal.envelope,
                network: proposal.network,
                treasury: anchored,
                proposerBlsPubkeyHex: proposal.proposerBlsPubkeyHex,
                group: group,
                currentSequence: currentSequence
            )
            switch outcome {
            case .accepted(let kind):
                var revived = proposal
                revived.kind = kind
                await treasury.record(StoredProposal(proposal: revived, rejection: nil))
            case .rejected(let reason):
                await treasury.record(
                    StoredProposal(proposal: proposal, rejection: reason)
                )
            }
        }
    }

    // MARK: - Proposal

    public func apply(
        _ payload: TreasuryProposalPayload,
        ownerIdentityID: IdentityID,
        senderEd25519PublicKey: Data?
    ) async {
        guard let group = await group(payload.groupID, ownerIdentityID) else { return }

        // Same insider-spoof defence as the declaration: the sealed
        // envelope's signer must be the member the payload names.
        guard let senderEd25519PublicKey,
              let profile = group.memberProfiles[payload.proposerBlsPubkeyHex],
              profile.sendingPubkey == senderEd25519PublicKey
        else { return }

        // A proposal id is chosen by its sender, and the store keys on
        // `(id, owner)`. Without this, a member could resend a proposal
        // reusing an id already on the device: the envelope, the
        // submitted hash and the rejection would be overwritten while
        // the proposer, the kind and the creation date kept the
        // original's — so an attacker's operations would render under
        // an honest member's name, at a `kind` no longer matching the
        // envelope (a signer change checked against the *medium*
        // threshold), with the collected signatures dropped and an
        // already-submitted proposal made actionable again.
        //
        // The first arrival wins. A genuine resend is a replay of bytes
        // this device already holds, so ignoring it loses nothing;
        // signatures arrive on their own payload.
        if await treasury.proposal(
            id: payload.proposalID,
            ownerIdentityID: ownerIdentityID
        ) != nil {
            return
        }

        let snapshot = await treasury.snapshot(
            groupID: group.id,
            ownerIdentityID: ownerIdentityID
        )
        let createdAt = Date(
            timeIntervalSince1970: TimeInterval(payload.sentAtMillis) / 1000
        )

        guard let network = StellarNetwork(passphrase: payload.networkPassphrase),
              let envelope = try? TransactionEnvelope(base64XDR: payload.xdr)
        else {
            // Dropped, not stored. Every other refusal keeps the row so
            // the refusal is visible — but those all have a real
            // decoded envelope to keep. Storing this one would mean
            // inventing a transaction to hang the rejection on, and an
            // invented transaction that ever lost its rejection flag
            // would render as a genuine proposal. A row that could
            // become a lie is worse than a missing row.
            return
        }

        // Read the account before judging the sequence, when there is
        // one to read. `snapshot.account` is a cache that only `refresh`
        // fills — anchor, submit, an explicit pull on the treasury
        // screen — and nothing on the receive path filled it. A device
        // that had not looked at the ledger in a while compared a
        // genuine proposal against a sequence long since passed and
        // refused it for being implausible. The refusal survives a
        // failed read, in which case `currentSequence` is whatever was
        // cached and the guard stays as forgiving as it was.
        let currentSequence: Int64?
        if snapshot.treasury != nil {
            currentSequence = await treasury.refresh(
                groupID: group.id,
                ownerIdentityID: ownerIdentityID
            )?.sequenceNumber ?? snapshot.account?.sequenceNumber
        } else {
            currentSequence = snapshot.account?.sequenceNumber
        }

        let outcome = TreasuryProposalVerifier.verify(
            envelope: envelope,
            network: network,
            treasury: snapshot.treasury,
            proposerBlsPubkeyHex: payload.proposerBlsPubkeyHex,
            group: group,
            currentSequence: currentSequence
        )

        let kind: TreasuryProposalKind
        let rejection: TreasuryRejection?
        switch outcome {
        case .accepted(let accepted):
            kind = accepted
            rejection = nil
        case .rejected(let reason):
            // A refused proposal still needs a kind to be stored; the
            // UI shows the refusal, not the kind.
            kind = .payment
            rejection = reason
        }

        guard let account = snapshot.treasury?.account
            ?? (try? StellarAccountID(publicKey: envelope.transaction.sourceAccount.publicKey))
        else { return }

        await treasury.record(StoredProposal(
            proposal: TreasuryProposal(
                id: payload.proposalID,
                groupID: group.id,
                ownerIdentityID: ownerIdentityID,
                proposerBlsPubkeyHex: payload.proposerBlsPubkeyHex,
                treasuryAccount: account,
                network: network,
                kind: kind,
                envelope: envelope,
                createdAt: createdAt
            ),
            rejection: rejection
        ))
    }

    // MARK: - Signature

    /// Attach a co-signer's signature to a proposal we already hold.
    ///
    /// No sender check, and none is needed: the repository verifies the
    /// signature against the hash rebuilt from **this device's** copy
    /// of the proposal. A signature that did not come from the named
    /// account, or was made over anything else, fails that check — so
    /// forwarding one on someone's behalf is harmless and forging one
    /// is not possible.
    ///
    /// A proposal we do not hold is ignored rather than queued. The
    /// signature is re-derivable by its owner at any time, and the
    /// chain is the shared record — there is nothing here worth keeping
    /// a parking lot for.
    public func apply(
        _ payload: TreasurySignaturePayload,
        ownerIdentityID: IdentityID,
        now: Date = Date()
    ) async {
        guard let signer = try? StellarAccountID(accountID: payload.signerAccountID) else {
            return
        }
        await treasury.addSignature(
            payload.signature,
            from: signer,
            toProposal: payload.proposalID,
            ownerIdentityID: ownerIdentityID,
            now: now
        )
    }

    // MARK: - Helpers

    private func group(_ groupID: Data, _ owner: IdentityID) async -> ChatGroup? {
        let hex = groupID.hexString
        return await groups.currentGroups().first {
            $0.id == hex && $0.ownerIdentityID == owner
        }
    }
}
