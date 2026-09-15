import Foundation
import OnymIdentity
import OnymStellar
import OnymFoundation

public enum TreasuryProposalOutcome: Equatable, Sendable {
    case proposed(TreasuryProposal)
    case noTreasury
    case notAMember
    /// A proposal is already waiting on the same sequence number. Only
    /// one of them can ever apply, so a second is refused rather than
    /// created — see the type's note.
    case sequenceContended(existingID: UUID)
    case failed(String)
}

/// Builds proposals and puts them to the group.
///
/// ## One open proposal at a time
///
/// Every proposal pins the treasury's next sequence number, and a
/// sequence number can be spent once. Two open proposals are therefore
/// two transactions competing for one slot: the group signs both, one
/// applies, and the other becomes permanently dead — after people have
/// already approved it. Refusing the second is not a limitation of this
/// implementation so much as an honest rendering of what the ledger
/// allows.
///
/// The refusal names the proposal in the way, so the UI can offer to
/// open it rather than leaving someone to guess.
public struct TreasuryProposalInteractor: Sendable {
    private let treasury: TreasuryRepository
    private let identity: IdentityRepository
    private let broadcaster: TreasuryBroadcaster
    private let horizon: @Sendable (StellarNetwork) -> any HorizonClient

    /// How long a proposal stays signable. Long enough for people in
    /// different time zones to get to it, short enough that an
    /// un-actioned proposal lapses instead of lingering as something
    /// that can still spend the treasury months later.
    public static let proposalWindow: TimeInterval = 7 * 24 * 3600

    public init(
        treasury: TreasuryRepository,
        identity: IdentityRepository,
        broadcaster: TreasuryBroadcaster,
        horizon: @escaping @Sendable (StellarNetwork) -> any HorizonClient = { network in
            URLSessionHorizonClient(network: network)
        }
    ) {
        self.treasury = treasury
        self.identity = identity
        self.broadcaster = broadcaster
        self.horizon = horizon
    }

    public func proposePayment(
        groupID: String,
        destination: StellarAccountID,
        asset: StellarAsset,
        amount: StellarAmount,
        memo: StellarMemo = .none,
        now: Date = Date()
    ) async -> TreasuryProposalOutcome {
        await propose(groupID: groupID, kind: .payment, now: now) { context in
            try TreasuryTransactionFactory.payment(
                treasury: context.account,
                treasurySequence: context.sequenceNumber,
                destination: destination,
                asset: asset,
                amount: amount,
                memo: memo,
                baseFee: context.baseFee,
                timeBounds: context.bounds
            )
        }
    }

    public func proposeTrustline(
        groupID: String,
        asset: StellarAsset,
        limit: StellarAmount = .max,
        now: Date = Date()
    ) async -> TreasuryProposalOutcome {
        await propose(groupID: groupID, kind: .trustline, now: now) { context in
            try TreasuryTransactionFactory.trustline(
                treasury: context.account,
                treasurySequence: context.sequenceNumber,
                asset: asset,
                limit: limit,
                baseFee: context.baseFee,
                timeBounds: context.bounds
            )
        }
    }

    /// Nominate a chat participant as a co-signer.
    ///
    /// Note what this is: a **proposal**, at the high threshold, like
    /// any other. The founder cannot do it alone — the treasury's
    /// master key was renounced at creation, so the existing co-signers
    /// decide who joins them. The founder's privilege is proposing it.
    public func proposeAddSigner(
        groupID: String,
        newSigner: StellarAccountID,
        newThresholds: TreasuryThresholds? = nil,
        now: Date = Date()
    ) async -> TreasuryProposalOutcome {
        // Adding a signer raises the count, so the new thresholds are
        // checked against the set this proposal would produce. Same
        // "nobody holding it, permanently" failure as creation, and it
        // is worth catching here rather than trusting the caller.
        if let newThresholds,
           let existing = await liveCoSigners(groupID: groupID) {
            // The set this proposal would produce, weights included.
            //
            // The existing entry for that account is dropped first,
            // because `setOptions` *replaces* a signer's weight rather
            // than adding one: re-proposing somebody already on the
            // treasury at a lower weight makes the total go down, while
            // appending made this guard believe it went up — and an
            // unreachable `high` passed the check that exists to stop
            // exactly that.
            let resulting = existing.filter { $0.account != newSigner }
                + [TreasuryCoSigner(account: newSigner)]
            guard TreasuryQuorum(coSigners: resulting, thresholds: newThresholds).isReachable else {
                return .failed("Those thresholds can't be met once that signer is added.")
            }
        }
        return await propose(groupID: groupID, kind: .addSigner, now: now) { context in
            try TreasuryTransactionFactory.addSigner(
                treasury: context.account,
                treasurySequence: context.sequenceNumber,
                newSigner: newSigner,
                newThresholds: newThresholds,
                baseFee: context.baseFee,
                timeBounds: context.bounds
            )
        }
    }

    public func proposeRemoveSigner(
        groupID: String,
        signer: StellarAccountID,
        newThresholds: TreasuryThresholds? = nil,
        now: Date = Date()
    ) async -> TreasuryProposalOutcome {
        // Removal lowers the count, so an unchanged threshold can
        // become unreachable even without new numbers being asked for.
        if let existing = await liveCoSigners(groupID: groupID) {
            let resulting = existing.filter { $0.account != signer }
            let current = await currentThresholds(groupID: groupID)
            let effective = newThresholds ?? current
            if let effective,
               !TreasuryQuorum(coSigners: resulting, thresholds: effective).isReachable {
                return .failed("Removing that signer would leave a treasury nobody can use.")
            }
        }
        return await propose(groupID: groupID, kind: .changeControl, now: now) { context in
            try TreasuryTransactionFactory.removeSigner(
                treasury: context.account,
                treasurySequence: context.sequenceNumber,
                signer: signer,
                newThresholds: newThresholds,
                baseFee: context.baseFee,
                timeBounds: context.bounds
            )
        }
    }

    // MARK: - Shared path

    /// The live signer set, with the weights the ledger gives them.
    ///
    /// Counting heads was the same headcount-versus-weight bug this
    /// PR fixed in `misconfiguration` and in the creation clamp, left
    /// in the propose paths: with weights 3/1/1 and `high` 4, removing
    /// a signer of weight 1 leaves weight 4, which clears the bar —
    /// while "2 signers remain, the bar is 4" refuses it. Never unsafe,
    /// always wrong in the same direction, and it blocks removals on
    /// exactly the treasuries weights make possible.
    private func liveCoSigners(groupID: String) async -> [TreasuryCoSigner]? {
        await treasury.refresh(groupID: groupID).map { account in
            account.signers
                .filter { $0.weight > 0 && $0.key != account.accountID }
                .compactMap { TreasuryCoSigner(account: $0.key, weight: $0.weight) }
        }
    }

    private func currentThresholds(groupID: String) async -> TreasuryThresholds? {
        guard let account = await treasury.refresh(groupID: groupID) else { return nil }
        return TreasuryThresholds(
            low: account.thresholds.low,
            medium: account.thresholds.medium,
            high: account.thresholds.high
        )
    }

    private struct BuildContext {
        let account: StellarAccountID
        let sequenceNumber: Int64
        let baseFee: StellarAmount
        let bounds: StellarTimeBounds
    }

    private func propose(
        groupID: String,
        kind: TreasuryProposalKind,
        now: Date,
        build: (BuildContext) throws -> StellarTransaction
    ) async -> TreasuryProposalOutcome {
        guard let me = await identity.currentIdentity(),
              let owner = await identity.currentSelectedID()
        else { return .notAMember }

        let snapshot = await treasury.snapshot(groupID: groupID)
        guard let anchored = snapshot.treasury else { return .noTreasury }

        // A live read: the sequence number this pins has to be the one
        // the account is actually on, or the transaction is dead before
        // anyone signs it.
        guard let account = await treasury.refresh(groupID: groupID) else {
            return .failed("could not read the treasury account")
        }

        // Anything still open has already claimed the next sequence.
        // Except one this device set aside: a dismissal exists exactly
        // so a proposal nobody intends to sign stops holding the
        // sequence hostage until its time bound runs out.
        if let contender = snapshot.proposals.first(where: { stored in
            stored.rejection == nil
                && stored.dismissedAt == nil
                && stored.proposal.submittedTxHash == nil
                && stored.proposal.sequenceNumber > account.sequenceNumber
                && (stored.proposal.expiresAt.map { $0 > now } ?? true)
        }) {
            return .sequenceContended(existingID: contender.proposal.id)
        }

        guard let parameters = try? await horizon(anchored.network).networkParameters() else {
            return .failed("could not read the network parameters")
        }

        let context = BuildContext(
            account: anchored.account,
            sequenceNumber: account.sequenceNumber,
            baseFee: parameters.baseFee,
            bounds: StellarTimeBounds(
                minTime: 0,
                maxTime: UInt64(
                    now.addingTimeInterval(Self.proposalWindow).timeIntervalSince1970
                )
            )
        )
        guard let transaction = try? build(context) else {
            return .failed("could not build the transaction")
        }

        // The kind is re-derived from the built operations rather than
        // taken from the caller. `addSigner` with new thresholds emits
        // two `setOptions`, which every *receiver* classifies as
        // `.changeControl` — so storing the caller's `.addSigner` made
        // the proposer's card read differently from everyone else's.
        // Same required weight either way, but the summary is the thing
        // people sign against, and it should say the same thing on
        // every device.
        let derivedKind = TreasuryProposalVerifier.kind(of: transaction.operations) ?? kind
        var proposal = TreasuryProposal(
            id: UUID(),
            groupID: groupID,
            ownerIdentityID: owner,
            proposerBlsPubkeyHex: me.blsPublicKey.hexString,
            treasuryAccount: anchored.account,
            network: anchored.network,
            kind: derivedKind,
            envelope: TransactionEnvelope(transaction: transaction),
            createdAt: now
        )

        // The proposer signs their own proposal if they can — they have
        // evidently approved it, and it saves the group one round trip.
        // An external proposer signs through the ordinary wallet path
        // afterwards, like everyone else.
        if let mine = snapshot.declarations.first(where: {
            $0.memberBlsPubkeyHex == me.blsPublicKey.hexString
        }), mine.source == .onym {
            let hash = transaction.hash(network: anchored.network)
            if let signature = try? await identity.signWithTreasuryKey(hash) {
                try? proposal.envelope.addSignature(
                    signature,
                    from: mine.account,
                    network: anchored.network
                )
            }
        }

        await treasury.record(StoredProposal(proposal: proposal))
        await broadcaster.broadcast(proposal, now: now)
        return .proposed(proposal)
    }
}
