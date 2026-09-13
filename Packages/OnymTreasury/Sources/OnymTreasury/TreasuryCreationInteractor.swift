import Foundation
import OnymGroup
import OnymIdentity
import OnymStellar

/// What the founder has to fund, itemised.
///
/// Shown rather than just charged. A person being asked to put real
/// money into an account they will not solely control should be able to
/// check the arithmetic, so each component is carried separately and
/// the screen prints the sum.
public struct TreasuryFundingEstimate: Equatable, Sendable {
    /// `(2 + signers) × baseReserve` — the account's permanent floor,
    /// locked up for as long as it exists.
    public let minimumBalance: StellarAmount
    /// Anything above the floor, which is what the treasury can
    /// actually spend.
    public let spendable: StellarAmount
    public let fee: StellarAmount
    public let baseReserve: StellarAmount
    public let signerCount: Int

    public var total: StellarAmount {
        StellarAmount(stroops: minimumBalance.stroops + spendable.stroops + fee.stroops)
    }

    public init(
        minimumBalance: StellarAmount,
        spendable: StellarAmount,
        fee: StellarAmount,
        baseReserve: StellarAmount,
        signerCount: Int
    ) {
        self.minimumBalance = minimumBalance
        self.spendable = spendable
        self.fee = fee
        self.baseReserve = baseReserve
        self.signerCount = signerCount
    }
}

public enum TreasuryCreationOutcome: Equatable, Sendable {
    case created(Treasury)
    /// The group already has one. Treasuries are not replaced — see
    /// `TreasuryPayloadReceiver`'s note on re-anchoring.
    case alreadyExists
    /// The founder's funding account cannot sign here, so the creation
    /// envelope goes to their wallet. Once it applies, `adopt` records
    /// the result.
    case needsExternalWallet(SEP0007Request, treasuryAccountID: String)
    case notAdmin
    /// Nobody has declared a signer yet, so there would be no one to
    /// hand control to.
    case noDeclaredSigners
    case failed(String)
}

/// Creates a group's treasury.
///
/// The whole arrangement is one transaction — see
/// `TreasuryTransactionFactory.creation` for why it cannot be several.
/// This type's job is to gather the inputs, get the two required
/// signatures, submit, and tell the group.
public struct TreasuryCreationInteractor: Sendable {
    private let treasury: TreasuryRepository
    private let identity: IdentityRepository
    private let groups: GroupRepository
    private let broadcaster: TreasuryBroadcaster
    private let horizon: @Sendable (StellarNetwork) -> any HorizonClient

    /// How long a creation envelope stays submittable. Short: it is
    /// signed and submitted in one sitting, and a stale one should
    /// lapse rather than linger as a transaction that can still spend
    /// the founder's funds.
    public static let creationWindow: TimeInterval = 600

    public init(
        treasury: TreasuryRepository,
        identity: IdentityRepository,
        groups: GroupRepository,
        broadcaster: TreasuryBroadcaster,
        horizon: @escaping @Sendable (StellarNetwork) -> any HorizonClient = { network in
            URLSessionHorizonClient(network: network)
        }
    ) {
        self.treasury = treasury
        self.identity = identity
        self.groups = groups
        self.broadcaster = broadcaster
        self.horizon = horizon
    }

    /// What funding a treasury with `signerCount` co-signers will cost,
    /// read from the network's current parameters rather than from
    /// constants — base reserve and base fee are protocol values and
    /// have been changed by validator vote before.
    public func estimate(
        network: StellarNetwork,
        signerCount: Int,
        spendable: StellarAmount
    ) async -> TreasuryFundingEstimate? {
        guard let parameters = try? await horizon(network).networkParameters() else {
            return nil
        }
        return TreasuryFundingEstimate(
            minimumBalance: TreasuryTransactionFactory.minimumBalance(
                signerCount: signerCount,
                baseReserve: parameters.baseReserve
            ),
            spendable: spendable,
            // One operation per signer, plus the create and the
            // lockdown.
            fee: StellarAmount(
                stroops: parameters.baseFee.stroops * Int64(signerCount + 2)
            ),
            baseReserve: parameters.baseReserve,
            signerCount: signerCount
        )
    }

    /// Create the treasury for `groupIDHex`.
    ///
    /// - Parameters:
    ///   - funder: the account paying. Which key signs for it is
    ///     worked out from the account itself — see `signingKey(for:)` —
    ///     so a caller cannot assert "this one is ours" and be wrong.
    ///   - coSigners: the declared accounts that will control it.
    ///   - thresholds: how many signatures it will take.
    public func create(
        groupIDHex: String,
        funder: StellarAccountID,
        coSigners: [StellarAccountID],
        thresholds: TreasuryThresholds,
        spendable: StellarAmount,
        network: StellarNetwork,
        now: Date = Date()
    ) async -> TreasuryCreationOutcome {
        guard let me = await identity.currentIdentity(),
              let owner = await identity.currentSelectedID()
        else { return .failed("no group") }
        // Scoped to the owning identity. `currentGroups()` returns the
        // unfiltered cache across every local identity — filtering
        // happens only in `snapshots` — so with two identities in one
        // group the `isAdmin` check could consult the other identity's
        // copy while the row is written under this one.
        guard let group = await groups.currentGroups().first(where: {
            $0.id == groupIDHex && $0.ownerIdentityID == owner
        }) else { return .failed("no group") }

        guard group.isAdmin(blsPublicKey: me.blsPublicKey) else { return .notAdmin }
        guard !coSigners.isEmpty else { return .noDeclaredSigners }

        // Checked here, not only in the UI. `high > coSigners.count`
        // produces exactly the "nobody holding it, permanently" state
        // the atomic-creation design exists to rule out — and it would
        // be produced *after* real money moved in. A screen is not the
        // place this invariant can live, because a screen is not the
        // only caller.
        let deduplicated = Array(
            NSOrderedSet(array: coSigners.map(\.accountID)).compactMap { $0 as? String }
        )
        guard deduplicated.count == coSigners.count else {
            return .failed("Two co-signers named the same account.")
        }
        guard TreasurySignerSelection.isUsable(
            thresholds,
            signerCount: coSigners.count
        ) else {
            return .failed("Those thresholds can't be met by that many co-signers.")
        }
        guard await treasury.snapshot(groupID: groupIDHex).treasury == nil else {
            return .alreadyExists
        }

        let client = horizon(network)
        guard let parameters = try? await client.networkParameters(),
              let funderAccount = try? await client.account(funder)
        else { return .failed("could not read the funding account") }

        let minimum = TreasuryTransactionFactory.minimumBalance(
            signerCount: coSigners.count,
            baseReserve: parameters.baseReserve
        )
        let starting = StellarAmount(stroops: minimum.stroops + spendable.stroops)
        let bounds = StellarTimeBounds(
            minTime: 0,
            maxTime: UInt64(now.addingTimeInterval(Self.creationWindow).timeIntervalSince1970)
        )

        // Generated here and never persisted. After the last operation
        // applies this key controls nothing; see `EphemeralTreasuryKey`.
        guard let treasuryKey = try? EphemeralTreasuryKey() else {
            return .failed("could not generate a treasury key")
        }

        guard let transaction = try? TreasuryTransactionFactory.creation(
            funder: funder,
            funderSequence: funderAccount.sequenceNumber,
            treasury: treasuryKey.account,
            coSigners: coSigners,
            thresholds: thresholds,
            startingBalance: starting,
            baseFee: parameters.baseFee,
            timeBounds: bounds
        ) else { return .failed("could not build the creation transaction") }

        var envelope = TransactionEnvelope(transaction: transaction)
        // The treasury's own signature, always: operations 2..n name it
        // as their source and its master weight is still 1 until the
        // last one applies.
        guard (try? treasuryKey.sign(&envelope, network: network)) != nil else {
            return .failed("could not sign as the new account")
        }

        let funderKey = Self.signingKey(for: funder, of: me)
        guard funderKey != .external else {
            // The founder's wallet supplies the other signature. It can
            // also submit, which is why nothing is anchored here — the
            // group learns the treasury exists through `adopt`, after
            // the transaction is on the ledger.
            return .needsExternalWallet(
                SEP0007Request(
                    envelope: envelope,
                    network: network,
                    message: "Create a treasury for \(group.name)",
                    publicKey: funder
                ),
                treasuryAccountID: treasuryKey.account.accountID
            )
        }

        let hash = transaction.hash(network: network)
        let signature: Data?
        switch funderKey {
        case .treasury:
            signature = try? await identity.signWithTreasuryKey(hash)
        case .identity:
            signature = try? await identity.signWithStellarKey(hash)
        case .external:
            signature = nil
        }
        guard let signature else {
            return .failed("could not sign")
        }
        guard (try? envelope.addSignature(signature, from: funder, network: network)) != nil
        else { return .failed("the funding signature did not verify") }

        do {
            let txHash = try await client.submit(envelope)
            let created = Treasury(
                account: treasuryKey.account,
                groupID: groupIDHex,
                ownerIdentityID: owner,
                network: network,
                creationTxHash: txHash,
                createdAt: now
            )
            await treasury.anchor(created)
            await treasury.refresh(groupID: groupIDHex)
            await broadcaster.announceAnchor(created, now: now)
            return .created(created)
        } catch {
            return .failed("the network rejected the creation transaction")
        }
    }

    /// Which of this identity's keys can sign for `funder`.
    ///
    /// Worked out from the account rather than taken from the caller.
    /// The previous shape was a `funderIsOnymDerived` flag and a
    /// hardcoded `signWithTreasuryKey`, which silently assumed the
    /// funder was always the treasury-derived account: pass the
    /// identity's own `stellarAccountID` with the flag set and every
    /// creation failed with "the funding signature did not verify",
    /// because the two are different HKDF branches. A boolean a caller
    /// can get wrong is replaced by a question only the account can
    /// answer.
    static func signingKey(for funder: StellarAccountID, of identity: Identity) -> FunderKey {
        if funder.accountID == identity.treasuryAccountID { return .treasury }
        if funder.accountID == identity.stellarAccountID { return .identity }
        return .external
    }

    enum FunderKey: Equatable {
        /// The treasury-scoped key — what a member declares when they
        /// choose "the account Onym derives".
        case treasury
        /// The identity's general Stellar account.
        case identity
        /// Held outside Onym; the envelope goes to a wallet.
        case external
    }

    /// Record a treasury whose creation transaction was submitted
    /// elsewhere — by the founder's own wallet, after a
    /// `needsExternalWallet` handoff.
    ///
    /// The claim is checked against the chain before it is believed:
    /// the account must exist, its master weight must actually be zero,
    /// and its signer set must be the one that was asked for. Taking
    /// the founder's word for it would mean anchoring the group to an
    /// account that might still be under one person's control — which
    /// is the single thing this design exists to rule out.
    public func adopt(
        groupIDHex: String,
        treasuryAccountID: String,
        creationTxHash: String,
        network: StellarNetwork,
        expectedCoSigners: [StellarAccountID],
        now: Date = Date()
    ) async -> TreasuryCreationOutcome {
        guard let owner = await identity.currentSelectedID(),
              let account = try? StellarAccountID(accountID: treasuryAccountID)
        else { return .failed("bad account") }

        guard let onChain = try? await horizon(network).account(account) else {
            return .failed("the treasury account is not on the ledger yet")
        }
        // Master weight zero shows up as the account's own key being
        // absent from, or zero-weighted in, its signer list.
        let masterWeight = onChain.signers
            .first { $0.key == account }
            .map(\.weight) ?? 0
        guard masterWeight == 0 else {
            return .failed("that account can still be controlled by its own key")
        }
        let onChainSigners = Set(onChain.signers.filter { $0.weight > 0 }.map(\.key))
        guard onChainSigners == Set(expectedCoSigners) else {
            return .failed("that account's signers are not the ones this group chose")
        }

        let created = Treasury(
            account: account,
            groupID: groupIDHex,
            ownerIdentityID: owner,
            network: network,
            creationTxHash: creationTxHash,
            createdAt: now,
            lastKnownSigners: onChain.signers,
            lastKnownThresholds: onChain.thresholds,
            lastRefreshedAt: now
        )
        await treasury.anchor(created)
        await broadcaster.announceAnchor(created, now: now)
        return .created(created)
    }
}
