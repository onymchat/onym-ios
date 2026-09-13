import Foundation
import OnymIdentity
import OnymStellar

/// Everything one group's treasury looks like to a screen.
///
/// A single snapshot rather than three streams, because the three parts
/// are only meaningful together: a proposal's standing depends on the
/// declared signers and on the live account, and a screen that received
/// them separately would render combinations that never actually
/// existed.
public struct TreasurySnapshot: Equatable, Sendable {
    public let groupID: String
    /// Nil for a group that has no treasury — the common case, and the
    /// one every surface has to draw.
    public let treasury: Treasury?
    public let declarations: [TreasurySignerDeclarationRecord]
    public let proposals: [StoredProposal]
    /// The most recent live account read, if one has succeeded. Nil
    /// until then, which is why `standing(of:)` returns nil rather than
    /// guessing.
    public let account: HorizonAccount?

    public init(
        groupID: String,
        treasury: Treasury?,
        declarations: [TreasurySignerDeclarationRecord],
        proposals: [StoredProposal],
        account: HorizonAccount?
    ) {
        self.groupID = groupID
        self.treasury = treasury
        self.declarations = declarations
        self.proposals = proposals
        self.account = account
    }

    /// Where a proposal stands, or nil when this device has not yet
    /// managed to read the account.
    ///
    /// Nil rather than a guess: the alternative is deciding "ready" or
    /// "still collecting" from a cached signer set, and both answers
    /// are capable of being confidently wrong in a way that costs
    /// money. A screen showing "checking…" is the honest rendering of
    /// not having asked the chain yet.
    public func standing(of stored: StoredProposal, now: Date) -> TreasuryProposalStanding? {
        if let rejection = stored.rejection { return .rejected(reason: rejection) }
        if let hash = stored.proposal.submittedTxHash { return .submitted(txHash: hash) }
        guard let account else { return nil }
        return TreasuryProposalVerifier.standing(
            of: stored.proposal,
            account: account,
            declaredSigners: declarations.map(\.account),
            now: now
        )
    }

    /// Where one member stands on declaring a signer. Re-derived from
    /// the stored signature each time.
    public func standing(
        ofMemberWith blsPubkeyHex: String,
        groupIDBytes: Data
    ) -> TreasurySignerStanding {
        guard let record = declarations.first(where: {
            $0.memberBlsPubkeyHex == blsPubkeyHex.lowercased()
        }) else { return .notDeclared }
        return record.standing(groupID: groupIDBytes)
    }
}

/// Owns treasury state: the store, the chain reads, and the snapshot
/// stream screens observe.
///
/// An actor, like every other repository here — it serialises mutation,
/// owns its seams, and publishes replaying `AsyncStream` snapshots. No
/// view or flow reaches past it to the store or to Horizon.
public actor TreasuryRepository {
    private let store: any TreasuryStore
    private let horizon: @Sendable (StellarNetwork) -> any HorizonClient

    private var currentIdentity: IdentityID?
    /// Latest live account read per treasury, keyed by account ID. In
    /// memory only — a cached balance that survived a relaunch would be
    /// shown as current, and this one is deliberately forgotten.
    private var accounts: [String: HorizonAccount] = [:]
    private var continuations: [UUID: (String, AsyncStream<TreasurySnapshot>.Continuation)] = [:]

    public init(
        store: any TreasuryStore,
        horizon: @escaping @Sendable (StellarNetwork) -> any HorizonClient = { network in
            URLSessionHorizonClient(network: network)
        }
    ) {
        self.store = store
        self.horizon = horizon
    }

    public func setCurrentIdentity(_ id: IdentityID?) async {
        guard currentIdentity != id else { return }
        currentIdentity = id
        accounts.removeAll()
        await publishAll()
    }

    // MARK: - Snapshots

    /// Replaying stream for one group. A new subscriber receives the
    /// current snapshot immediately, so a screen that appears late does
    /// not render blank while it waits for the next change.
    public nonisolated func snapshots(groupID: String) -> AsyncStream<TreasurySnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribe(id: id, groupID: groupID, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unsubscribe(id: id) }
            }
        }
    }

    private func subscribe(
        id: UUID,
        groupID: String,
        continuation: AsyncStream<TreasurySnapshot>.Continuation
    ) async {
        continuations[id] = (groupID, continuation)
        continuation.yield(await snapshot(groupID: groupID))
    }

    private func unsubscribe(id: UUID) {
        continuations[id] = nil
    }

    public func snapshot(groupID: String) async -> TreasurySnapshot {
        guard let owner = currentIdentity?.rawValue.uuidString else {
            return TreasurySnapshot(
                groupID: groupID,
                treasury: nil,
                declarations: [],
                proposals: [],
                account: nil
            )
        }
        let treasury = await store.treasury(groupID: groupID, ownerIDString: owner)
        return TreasurySnapshot(
            groupID: groupID,
            treasury: treasury,
            declarations: await store.declarations(groupID: groupID, ownerIDString: owner),
            proposals: await store.proposals(groupID: groupID, ownerIDString: owner),
            account: treasury.flatMap { accounts[$0.account.accountID] }
        )
    }

    private func publish(groupID: String) async {
        let snapshot = await snapshot(groupID: groupID)
        for (_, entry) in continuations where entry.0 == groupID {
            entry.1.yield(snapshot)
        }
    }

    private func publishAll() async {
        for groupID in Set(continuations.values.map(\.0)) {
            await publish(groupID: groupID)
        }
    }

    // MARK: - Commands

    public func anchor(_ treasury: Treasury) async {
        await store.upsert(treasury)
        await publish(groupID: treasury.groupID)
    }

    public func record(_ declaration: TreasurySignerDeclarationRecord) async {
        await store.upsert(declaration)
        await publish(groupID: declaration.groupID)
    }

    public func record(_ stored: StoredProposal) async {
        await store.upsert(stored)
        await publish(groupID: stored.proposal.groupID)
    }

    public func proposal(id: UUID) async -> StoredProposal? {
        guard let owner = currentIdentity?.rawValue.uuidString else { return nil }
        return await store.proposal(id: id, ownerIDString: owner)
    }

    /// Add a signature to a stored proposal, after checking it.
    ///
    /// Verification is `TransactionEnvelope.addSignature`, against the
    /// hash rebuilt from the envelope this device already holds — so a
    /// signature for a different transaction cannot be attached to this
    /// one. Returns whether it was added.
    ///
    /// A signature that verifies also settles the open question about
    /// an externally-held account: whoever declared it can evidently
    /// sign with it, so the declaration is marked proven.
    @discardableResult
    public func addSignature(
        _ signature: Data,
        from signer: StellarAccountID,
        toProposal id: UUID,
        now: Date = Date()
    ) async -> Bool {
        guard let owner = currentIdentity?.rawValue.uuidString,
              var stored = await store.proposal(id: id, ownerIDString: owner)
        else { return false }
        do {
            try stored.proposal.envelope.addSignature(
                signature,
                from: signer,
                network: stored.proposal.network
            )
        } catch {
            return false
        }
        await store.upsert(stored)
        await store.markProven(
            groupID: stored.proposal.groupID,
            ownerIDString: owner,
            account: signer,
            at: now
        )
        await publish(groupID: stored.proposal.groupID)
        return true
    }

    public func markSubmitted(proposalID: UUID, txHash: String) async {
        guard let owner = currentIdentity?.rawValue.uuidString,
              var stored = await store.proposal(id: proposalID, ownerIDString: owner)
        else { return }
        stored.proposal.submittedTxHash = txHash
        await store.upsert(stored)
        // The account's sequence has moved, so every other proposal for
        // this treasury is now superseded. Nothing to write — standing
        // is derived — but the next read must be a fresh one.
        accounts.removeValue(forKey: stored.proposal.treasuryAccount.accountID)
        await refresh(groupID: stored.proposal.groupID)
    }

    // MARK: - Chain

    /// Re-read the treasury account and republish.
    ///
    /// Called before anything that depends on the signer set being
    /// current — deciding a proposal is ready, or submitting it. The
    /// cached value exists to draw a screen, not to make a decision.
    @discardableResult
    public func refresh(groupID: String) async -> HorizonAccount? {
        guard let owner = currentIdentity?.rawValue.uuidString,
              var treasury = await store.treasury(groupID: groupID, ownerIDString: owner)
        else { return nil }
        let account = try? await horizon(treasury.network).account(treasury.account)
        if let account {
            accounts[treasury.account.accountID] = account
            treasury.lastKnownSigners = account.signers
            treasury.lastKnownThresholds = account.thresholds
            treasury.lastRefreshedAt = Date()
            await store.upsert(treasury)
        }
        await publish(groupID: groupID)
        return account
    }

    /// Applied transactions for the group's treasury, newest first.
    /// Not cached — history is a screen the user opened, and a stale
    /// list is worse than a spinner.
    public func history(groupID: String, limit: Int = 50) async -> [HorizonTransaction] {
        guard let owner = currentIdentity?.rawValue.uuidString,
              let treasury = await store.treasury(groupID: groupID, ownerIDString: owner)
        else { return [] }
        return (try? await horizon(treasury.network)
            .transactions(for: treasury.account, limit: limit)) ?? []
    }

    public func removeForOwner(_ id: IdentityID) async {
        await store.removeAll(ownerIDString: id.rawValue.uuidString)
        await publishAll()
    }
}
