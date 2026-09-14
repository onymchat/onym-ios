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
    /// The founder's funding account cannot sign here, so the *funding*
    /// transaction goes to their wallet — one operation from one
    /// source, which is the only shape wallets reliably submit. The
    /// signers and the lockdown are a second transaction this app runs
    /// through `completeExternalCreation`.
    ///
    /// `creationTxHash` is that funding transaction's hash, computed
    /// before it is handed over. It is a prediction: a wallet may
    /// renumber the sequence and change it, which is why what the group
    /// is finally told carries the *configuration* hash instead — that
    /// one this device submits and therefore knows.
    case needsExternalWallet(
        SEP0007Request,
        treasuryAccountID: String,
        creationTxHash: String
    )
    case notAdmin
    /// Nobody has declared a signer yet, so there would be no one to
    /// hand control to.
    case noDeclaredSigners
    /// This group's treasury is a different account, and the funding
    /// this device handed to a wallet went somewhere else. Carries the
    /// account so the founder can be told where their money is; it has
    /// been configured to the co-signer set, so the same people can
    /// move it.
    case fundedAnotherAccount(StellarAccountID)
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

    /// How long a creation envelope stays submittable.
    ///
    /// Bounded, because an unsent one should lapse rather than linger as
    /// a transaction that can still spend the founder's funds. An hour
    /// rather than the ten minutes this used to be: the external path
    /// hands the envelope to another app, and a founder reading four
    /// operations on a wallet's confirmation screen — one of which
    /// carries a "this might lock your account forever" warning — is not
    /// on a ten-minute clock. Past `maxTime` a wallet is entitled to
    /// refuse, and the ones that refuse quietly present as a Confirm
    /// button that does nothing.
    ///
    /// Still far shorter than a proposal's window, and still one
    /// sitting. What it stops being is a race against the reader.
    public static let creationWindow: TimeInterval = 3600

    /// How many times step two's fee to send along with step one.
    ///
    /// The fee is read when the funding is built and paid when the
    /// configuration is submitted, which can be minutes later and after
    /// a fee-bump vote. Ten times a few hundred stroops costs the
    /// founder nothing worth naming and is the difference between a
    /// treasury and an account nobody can finish.
    public static let configurationFeeMargin: Int64 = 10

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
            // lockdown — and, for the external path, the margin the
            // funding transaction actually sends along for the
            // configuration it cannot pay for itself.
            //
            // The screen prints this sum so a founder can check it. A
            // figure smaller than what their wallet is asked for is
            // worse than no figure: a funder holding exactly the
            // estimate fails to fund, having done what the screen said.
            fee: StellarAmount(
                stroops: parameters.baseFee.stroops * Int64(signerCount + 2)
                    + TreasuryTransactionFactory.configurationFee(
                        signerCount: signerCount,
                        baseFee: parameters.baseFee
                    ).stroops * Self.configurationFeeMargin
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
        coSigners: [TreasuryCoSigner],
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
        let deduplicated = Set(coSigners.map(\.account.accountID))
        guard deduplicated.count == coSigners.count else {
            return .failed("Two co-signers named the same account.")
        }
        // Against the weights, not the headcount. With everyone at 1
        // those were the same number; they stop being the same the
        // moment one person counts double, and the threshold that
        // matters is the one the ledger will enforce.
        let quorum = TreasuryQuorum(coSigners: coSigners, thresholds: thresholds)
        guard quorum.isReachable else {
            return .failed("Those numbers can't be met by the co-signers you chose.")
        }
        guard await treasury.snapshot(groupID: groupIDHex).treasury == nil else {
            return .alreadyExists
        }

        let client = horizon(network)
        // Two reads, two messages. One guard over both said "could not
        // read the funding account" whenever *either* failed, so a
        // network-parameters bug arrived on screen as an accusation
        // about the founder's account — and a founder looking at a
        // funded account has no way to act on that. An error that names
        // the wrong thing costs more than one that says less.
        guard let parameters = try? await client.networkParameters() else {
            return .failed("could not read the network's fee and reserve")
        }
        guard let funderAccount = try? await client.account(funder) else {
            return .failed(
                "could not read the funding account \(funder.abbreviated) on "
                + "\(network == .testnet ? "testnet" : "mainnet"). A brand-new account "
                + "does not exist on the ledger until something funds it."
            )
        }

        let minimum = TreasuryTransactionFactory.minimumBalance(
            signerCount: coSigners.count,
            baseReserve: parameters.baseReserve
        )
        let starting = StellarAmount(stroops: minimum.stroops + spendable.stroops)
        let bounds = StellarTimeBounds(
            minTime: 0,
            maxTime: UInt64(now.addingTimeInterval(Self.creationWindow).timeIntervalSince1970)
        )

        // Generated here. On the in-app path it is never persisted and
        // controls nothing after the last operation applies; on the
        // split path it outlives this call and the reasons are in
        // `PendingTreasuryCreation.treasurySeed`.
        guard let treasuryKey = try? EphemeralTreasuryKey() else {
            return .failed("could not generate a treasury key")
        }

        let funderKey = Self.signingKey(for: funder, of: me)
        if funderKey == .external {
            // Split, because a SEP-0007 wallet will not submit the
            // atomic envelope — see `TreasuryTransactionFactory
            // .creationFunding`. Step one is one operation from one
            // source, handed over unsigned, which is a shape wallets
            // do submit. Step two is this app's to run.
            //
            // The treasury pays for step two out of what step one sends
            // it, so the funding covers the minimum balance, what the
            // group wants spendable, and that fee.
            // With a margin, because this fee is read now and paid
            // later. Base fee is a protocol parameter that validators
            // vote on and that Horizon reports as of the last ledger;
            // funded to the exact figure, a treasury created with
            // `spendable == 0` and configured after any rise cannot pay
            // for its own lockdown, and stalls one transaction short of
            // existing. The margin is stroops — a few ten-thousandths
            // of an XLM — against a founder's funds being stuck.
            let configurationFee = StellarAmount(
                stroops: TreasuryTransactionFactory.configurationFee(
                    signerCount: coSigners.count,
                    baseFee: parameters.baseFee
                ).stroops * Self.configurationFeeMargin
            )
            guard let funding = try? TreasuryTransactionFactory.creationFunding(
                funder: funder,
                funderSequence: funderAccount.sequenceNumber,
                treasury: treasuryKey.account,
                startingBalance: StellarAmount(
                    stroops: starting.stroops + configurationFee.stroops
                ),
                baseFee: parameters.baseFee,
                timeBounds: bounds
            ) else { return .failed("could not build the funding transaction") }

            // Never over a handoff that is already out there.
            //
            // A second `create` used to mint a fresh key and overwrite
            // the row, which on this path destroys the only key for an
            // account a wallet may already have funded — the same loss
            // `abandonExternalCreation` refuses, reached by a different
            // button. Only UI stage ordering stood between them.
            // A row that will not read counts as one that exists: the
            // question here is "is a handoff already out there", and an
            // unreadable row is not an answer of no.
            let existingRow = try? await treasury.pendingCreation(groupID: groupIDHex)
            if existingRow == nil,
               await treasury.hasUnreadablePendingCreation(groupID: groupIDHex) {
                return .failed(
                    "a treasury handoff for this chat is on this device and cannot be read. "
                    + "Nothing has been changed."
                )
            }
            if let existing = existingRow, existing.treasurySeed != nil {
                return .failed(
                    "a treasury handoff for this chat is already waiting. Finish it, or "
                    + "start over from that screen, before creating another."
                )
            }

            let fundingEnvelope = TransactionEnvelope(transaction: funding)
            await treasury.recordPendingCreation(PendingTreasuryCreation(
                groupID: groupIDHex,
                ownerIdentityID: owner,
                treasuryAccount: treasuryKey.account,
                network: network,
                creationTxHash: funding.hash(network: network).hexString,
                coSigners: coSigners,
                thresholds: thresholds,
                startedAt: now,
                treasurySeed: treasuryKey.seedForPendingCreation()
            ))
            return .needsExternalWallet(
                SEP0007Request(
                    envelope: fundingEnvelope,
                    network: network,
                    message: "Fund a treasury for \(group.name)",
                    publicKey: funder
                ),
                treasuryAccountID: treasuryKey.account.accountID,
                creationTxHash: funding.hash(network: network).hexString
            )
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

        // Known before anyone signs: signatures live in the envelope,
        // not in the transaction, so this is already the hash the ledger
        // will record no matter who submits it.
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
    /// How far back `adopt` looks for the creating transaction. A
    /// treasury being adopted has just been created, so its history is
    /// short; the depth is here to bound the read rather than to cover
    /// an account with years behind it.
    static let creationHistoryDepth = 200

    /// Whether a half-done handoff can be thrown away.
    public enum AbandonOutcome: Equatable, Sendable {
        /// Nothing was on the ledger; the row and its key are gone.
        case discarded
        /// The account exists. Nothing was deleted, and it must not be:
        /// the key in that row is the only one that can configure or
        /// spend it.
        case accountAlreadyFunded(StellarAccountID)
        /// The ledger could not be reached, so whether anything was
        /// funded is unknown — and an unknown is not permission to
        /// delete the only key. Nothing was deleted.
        case couldNotTell
    }

    /// Throw away a handoff — unless the funding already landed.
    ///
    /// The decision belongs here rather than on a screen, because it is
    /// decided against the ledger and screens cannot read one. The
    /// footnote warning a founder that "Start over" forgets the key was
    /// a warning and not a guard: one tap after a wallet had funded the
    /// account deleted the only key that could ever reach it, and no
    /// amount of copy makes that recoverable.
    ///
    /// Refusing outright rather than asking again, because there is no
    /// good reason to destroy the key while the account it controls
    /// exists. The way out of that state is `completeExternalCreation`,
    /// which finishes the job the wallet started.
    public func abandonExternalCreation(groupIDHex: String) async -> AbandonOutcome {
        // Unreadable is not "nothing to keep". Discarding a row this
        // build cannot parse would delete a key for an account that may
        // already be funded, which is the whole reason this method asks
        // a ledger at all.
        guard let pending = try? await treasury.pendingCreation(groupID: groupIDHex) else {
            return await treasury.hasUnreadablePendingCreation(groupID: groupIDHex)
                ? .couldNotTell
                : .discarded
        }
        guard pending.treasurySeed != nil else {
            // No key to strand: an older row, or one for the in-app
            // path. Nothing on the ledger depends on it.
            await treasury.clearPendingCreation(groupID: groupIDHex)
            return .discarded
        }
        do {
            _ = try await horizon(pending.network).account(pending.treasuryAccount)
            return .accountAlreadyFunded(pending.treasuryAccount)
        } catch HorizonError.accountNotFound {
            // The one answer that means "nothing was funded". Any other
            // failure is Horizon being unreachable or unhappy, and
            // `try?` treated those as proof of absence — tap Start over
            // in a tunnel after the wallet had funded the account and
            // the key went with it. Permanently unreachable funds,
            // caused by the guard meant to prevent exactly that.
            await treasury.clearPendingCreation(groupID: groupIDHex)
            return .discarded
        } catch {
            return .couldNotTell
        }
    }

    /// Finish a split creation: configure the account the wallet
    /// funded, then anchor it.
    ///
    /// Runs entirely here, because only this device can. Step two is
    /// sourced by the treasury and signed by the treasury's own key,
    /// which exists nowhere else — a wallet has nothing to contribute
    /// and, as `creationFunding` explains, would not submit it anyway.
    ///
    /// Written to be run again. Every step reads the ledger first and
    /// does only what is not yet done, so a crash, a dead network or a
    /// founder who closed the app mid-way resumes rather than restarts:
    /// an account that exists is not re-created, a configuration that
    /// landed is not re-sent, and a treasury already anchored is left
    /// alone.
    public func completeExternalCreation(
        groupIDHex: String,
        now: Date = Date()
    ) async -> TreasuryCreationOutcome {
        guard let owner = await identity.currentSelectedID() else {
            return .failed("no identity")
        }
        let pendingRow = try? await treasury.pendingCreation(groupID: groupIDHex)
        // The anchored treasury is checked before the pending row, not
        // after. A founder who taps twice has no row left by the second
        // tap — this already worked — and "nothing is waiting for a
        // wallet here" is a confusing way to say "it is done".
        if let anchored = await treasury.snapshot(groupID: groupIDHex).treasury {
            if let pendingRow, pendingRow.treasuryAccount != anchored.account {
                // Someone else's anchor arrived while this founder's
                // funding was in flight, so their XLM is sitting in an
                // account that is not this group's treasury.
                //
                // Keeping the seed was necessary and not sufficient:
                // every later call returned `.alreadyExists` before
                // reaching the seed, so the row was preserved and
                // unreachable by any code path — the funds strandable
                // by inaction rather than by deletion. This configures
                // that account anyway. It cannot become the group's
                // treasury, but it can become an account the co-signers
                // jointly control and can empty, rather than one whose
                // only key is a secret this app promised to destroy.
                return await configureStrandedFunding(
                    pending: pendingRow,
                    groupIDHex: groupIDHex,
                    now: now
                )
            }
            if pendingRow != nil {
                await treasury.clearPendingCreation(groupID: groupIDHex)
            }
            return .alreadyExists
        }
        guard let pending = pendingRow else {
            return .failed("nothing is waiting for a wallet here")
        }
        guard let seed = pending.treasurySeed,
              let treasuryKey = try? EphemeralTreasuryKey(seed: seed),
              treasuryKey.account == pending.treasuryAccount
        else {
            // An older pending row from the atomic external path, or a
            // seed that no longer matches the account it belongs to.
            // `adopt` is the right handler for the first and the only
            // honest answer to the second.
            return await adopt(
                groupIDHex: groupIDHex,
                treasuryAccountID: pending.treasuryAccount.accountID,
                creationTxHash: pending.creationTxHash,
                network: pending.network,
                expectedCoSigners: pending.coSigners,
                expectedThresholds: pending.thresholds,
                now: now
            )
        }

        let client = horizon(pending.network)
        let onChain: HorizonAccount
        do {
            onChain = try await client.account(pending.treasuryAccount)
        } catch HorizonError.accountNotFound {
            return .failed(
                "the treasury account is not on the ledger yet. If your wallet has "
                + "not sent the funding transaction, it has not gone through."
            )
        } catch {
            // Not the same thing, and it was being reported as if it
            // were: telling a founder their wallet did not send it,
            // when what actually happened is that this device could not
            // reach Horizon, is an accusation on a network blip.
            return .failed(
                "could not reach the network to check. Nothing has been changed; try again."
            )
        }

        // Already configured — either a retry after the submission
        // landed, or a second tap. Verified below either way.
        let alreadyConfigured = Self.misconfiguration(
            onChain,
            account: pending.treasuryAccount,
            expectedCoSigners: pending.coSigners,
            expectedThresholds: pending.thresholds
        ) == nil

        var record = pending
        if !alreadyConfigured {
            guard let parameters = try? await client.networkParameters() else {
                return .failed("could not read the network's fee and reserve")
            }
            // Checked against what the account can spend above its
            // reserve, and refused with the reason when it cannot.
            //
            // An earlier version clamped the fee to whatever was
            // affordable, which sounds forgiving and is not: below the
            // base rate the network declines the submission, and the
            // founder reads that as an opaque failure rather than as
            // "send this account a little more".
            let operationCount = Int64(pending.coSigners.count + 1)
            let reserve = TreasuryTransactionFactory.minimumBalance(
                signerCount: pending.coSigners.count,
                baseReserve: parameters.baseReserve
            ).stroops
            let held = onChain.balances
                .first { $0.asset == .native }
                .map(\.balance.stroops) ?? 0
            let spendableOnFees = max(held - reserve, 0)
            let wanted = parameters.baseFee.stroops * operationCount
            guard wanted <= spendableOnFees else {
                // Refused with the reason, rather than clamped below
                // what the network charges. A fee under the base rate
                // is not an attempt — it is a submission the network
                // declines for a reason the founder would then see as
                // an opaque failure. Saying what is wrong is the only
                // useful thing left, because nothing here can add funds
                // to the account.
                return .failed(
                    "the treasury holds \(StellarAmount(stroops: held).decimalString) XLM, "
                    + "which does not cover its reserve and the fee for locking it down. "
                    + "Send it a little more and try again."
                )
            }
            let baseFee = parameters.baseFee
            guard let configuration = try? TreasuryTransactionFactory.creationConfiguration(
                treasury: pending.treasuryAccount,
                treasurySequence: onChain.sequenceNumber,
                coSigners: pending.coSigners,
                thresholds: pending.thresholds,
                baseFee: baseFee,
                timeBounds: StellarTimeBounds(
                    minTime: 0,
                    maxTime: UInt64(
                        now.addingTimeInterval(Self.creationWindow).timeIntervalSince1970
                    )
                )
            ) else { return .failed("could not build the configuration transaction") }

            var envelope = TransactionEnvelope(transaction: configuration)
            guard (try? treasuryKey.sign(&envelope, network: pending.network)) != nil else {
                return .failed("could not sign as the treasury account")
            }
            // Written down *before* the submission, not after.
            //
            // The hash is already known — it is computed from the
            // envelope, not returned by the network — and the gap
            // between submitting and recording is exactly where a
            // timeout on a transaction that actually landed, or a crash,
            // loses the one fact the account cannot be re-read for.
            // Falling back to the funding hash would announce a
            // prediction that a wallet is free to renumber.
            record = pending.recording(
                configurationTxHash: configuration.hash(network: pending.network).hexString
            )
            await treasury.recordPendingCreation(record)
            do {
                _ = try await client.submit(envelope)
            } catch {
                return .failed(
                    "the network refused the transaction that locks the treasury down. "
                    + "The account exists and holds the funds; try again."
                )
            }
        }

        // Re-read rather than believe the submission. What gets anchored
        // is the account as the ledger describes it.
        guard let configured = try? await client.account(pending.treasuryAccount),
              Self.misconfiguration(
                  configured,
                  account: pending.treasuryAccount,
                  expectedCoSigners: pending.coSigners,
                  expectedThresholds: pending.thresholds
              ) == nil
        else {
            return .failed(
                "the treasury was funded but is not locked down yet. Nothing has been "
                + "announced to the group; try again."
            )
        }

        // Announce only a hash the ledger actually holds.
        //
        // `configurationTxHash` is this device's own and therefore
        // exact — but it is nil when the configuration was already
        // on-chain before the first run got that far, and the fallback
        // was then the *predicted* funding hash, which a wallet is free
        // to renumber. The group cannot re-derive either, so a hash
        // that resolves to nothing is a provenance claim on no evidence
        // — the thing `adopt` refuses to make.
        let history = (try? await client.transactions(
            for: pending.treasuryAccount,
            limit: Self.creationHistoryDepth
        )) ?? []
        let candidates = [record.configurationTxHash, pending.creationTxHash].compactMap { $0 }
        let announcedHash = candidates.first { candidate in
            history.contains { $0.hash == candidate && $0.successful }
        } ?? history.first(where: \.successful)?.hash
        guard let announcedHash else {
            return .failed(
                "the treasury is locked down, but its history could not be read. "
                + "Nothing has been announced to the group; try again."
            )
        }

        let created = Treasury(
            account: pending.treasuryAccount,
            groupID: groupIDHex,
            ownerIdentityID: owner,
            network: pending.network,
            creationTxHash: announcedHash,
            createdAt: now,
            lastKnownSigners: configured.signers,
            lastKnownThresholds: configured.thresholds,
            lastRefreshedAt: now
        )
        await treasury.anchor(created)
        // The seed dies here, with the row that held it.
        await treasury.clearPendingCreation(groupID: groupIDHex)
        await broadcaster.announceAnchor(created, now: now)
        return .created(created)
    }

    /// Configure an account whose funding landed but which can never
    /// be this group's treasury, because another one was anchored
    /// first.
    ///
    /// The point is reachability, not ownership: after this the account
    /// is controlled by the co-signers at the thresholds the founder
    /// chose, so the money can be moved by the same people who would
    /// have controlled the treasury. Doing nothing would leave it under
    /// an ephemeral key with no route to use it.
    private func configureStrandedFunding(
        pending: PendingTreasuryCreation,
        groupIDHex: String,
        now: Date
    ) async -> TreasuryCreationOutcome {
        // Every exit below used to be `.alreadyExists`, which the screen
        // renders as "created". So an unreachable Horizon, a refused
        // submission or a seed that would not rebuild all ended with a
        // founder told their treasury was made while their XLM sat in an
        // unconfigured account under a key they were told was destroyed.
        // The account is named in every one of these, because knowing
        // where the money is is the least this can offer.
        let stuck = "your funding is in \(pending.treasuryAccount.abbreviated), which is not "
            + "this chat's treasury and is not locked down yet."
        guard let seed = pending.treasurySeed,
              let key = try? EphemeralTreasuryKey(seed: seed),
              key.account == pending.treasuryAccount
        else {
            return .failed("\(stuck) The key for it is unreadable on this device.")
        }
        let client = horizon(pending.network)
        let onChain: HorizonAccount
        do {
            onChain = try await client.account(pending.treasuryAccount)
        } catch HorizonError.accountNotFound {
            // Nothing was funded after all. The row stays: it is the
            // only copy of the key, and a wallet may still send it.
            return .alreadyExists
        } catch {
            return .failed("could not reach the network to check. Nothing has been changed.")
        }

        if Self.misconfiguration(
            onChain,
            account: pending.treasuryAccount,
            expectedCoSigners: pending.coSigners,
            expectedThresholds: pending.thresholds
        ) == nil {
            await treasury.clearPendingCreation(groupID: groupIDHex)
            return .fundedAnotherAccount(pending.treasuryAccount)
        }

        guard let parameters = try? await client.networkParameters() else {
            return .failed("\(stuck) Could not read the network's fee and reserve; try again.")
        }
        guard let configuration = try? TreasuryTransactionFactory.creationConfiguration(
            treasury: pending.treasuryAccount,
            treasurySequence: onChain.sequenceNumber,
            coSigners: pending.coSigners,
            thresholds: pending.thresholds,
            baseFee: parameters.baseFee,
            timeBounds: StellarTimeBounds(
                minTime: 0,
                maxTime: UInt64(
                    now.addingTimeInterval(Self.creationWindow).timeIntervalSince1970
                )
            )
        ) else {
            return .failed("\(stuck) Could not build the transaction that locks it down.")
        }
        var envelope = TransactionEnvelope(transaction: configuration)
        guard (try? key.sign(&envelope, network: pending.network)) != nil else {
            return .failed("\(stuck) Could not sign as that account.")
        }
        guard (try? await client.submit(envelope)) != nil else {
            return .failed("\(stuck) The network refused the transaction; try again.")
        }

        // Re-read before deleting the key, exactly as the main path
        // does. A successful POST is not the same as an applied
        // transaction, and here the difference is paid for with the only
        // copy of a secret.
        guard let configured = try? await client.account(pending.treasuryAccount),
              Self.misconfiguration(
                  configured,
                  account: pending.treasuryAccount,
                  expectedCoSigners: pending.coSigners,
                  expectedThresholds: pending.thresholds
              ) == nil
        else {
            return .failed("\(stuck) The lockdown was sent but the ledger does not show it yet.")
        }
        await treasury.clearPendingCreation(groupID: groupIDHex)
        return .fundedAnotherAccount(pending.treasuryAccount)
    }

    /// Why an account on the ledger is not the treasury this group
    /// asked for, or nil when it is.
    ///
    /// One function, used by `adopt` and by the split path's resume
    /// branch. The split shipped with its own, looser copy — no
    /// per-signer weight check, no reachability — and the resume branch
    /// is precisely where that matters: it believes whatever the ledger
    /// shows, without having observed how the account got that way.
    ///
    /// Nothing on either path saw what was actually submitted. So
    /// comparing only *which* keys are signers is not enough: an
    /// account configured by hand with the same keys but weight 3 on
    /// the founder's own, or `med`/`high` of 1, would be anchored and
    /// announced to the group as an account nobody controls alone. And
    /// thresholds above the signers' total weight make an account that
    /// can never change its own signers again — spendable until a key
    /// is lost, and then never.
    /// An account and the weight it carries, for comparing a ledger's
    /// signer set against the one a group chose.
    private struct Pair: Hashable {
        let account: StellarAccountID
        let weight: UInt32
    }

    public static func misconfiguration(
        _ onChain: HorizonAccount,
        account: StellarAccountID,
        expectedCoSigners: [TreasuryCoSigner],
        expectedThresholds: TreasuryThresholds
    ) -> String? {
        // Master weight zero shows up as the account's own key being
        // absent from, or zero-weighted in, its signer list.
        let masterWeight = onChain.signers
            .first { $0.key == account }
            .map(\.weight) ?? 0
        guard masterWeight == 0 else {
            return "that account can still be controlled by its own key"
        }
        // Keys *and* weights, as a set of pairs.
        //
        // The weight check used to be "everybody is 1", which was true
        // of every treasury this app could build and stopped being true
        // the moment weights became a thing a founder sets. What has to
        // hold is that the ledger shows the configuration this group
        // chose — so an account where the founder quietly gave
        // themselves 3 still fails, while a treasury the group
        // deliberately weighted 2/2/1/1 passes.
        let live = onChain.signers.filter { $0.weight > 0 }
        let onLedger = Set(live.map { Pair(account: $0.key, weight: $0.weight) })
        let chosen = Set(expectedCoSigners.map { Pair(account: $0.account, weight: $0.weight) })
        guard Set(live.map(\.key)) == Set(expectedCoSigners.map(\.account)) else {
            return "that account's signers are not the ones this group chose"
        }
        guard onLedger == chosen else {
            return "that account weights its signers differently from what this group chose"
        }
        guard onChain.thresholds.low == expectedThresholds.low,
              onChain.thresholds.medium == expectedThresholds.medium,
              onChain.thresholds.high == expectedThresholds.high
        else {
            return "that account needs a different number of signatures than this group chose"
        }
        let total = live.reduce(UInt64(0)) { $0 + UInt64($1.weight) }
        guard onChain.thresholds.high >= onChain.thresholds.medium,
              onChain.thresholds.medium > 0,
              UInt64(onChain.thresholds.high) <= total
        else {
            return "that account's thresholds cannot be met by its signers"
        }
        return nil
    }

    public func adopt(
        groupIDHex: String,
        treasuryAccountID: String,
        creationTxHash: String,
        network: StellarNetwork,
        expectedCoSigners: [TreasuryCoSigner],
        expectedThresholds: TreasuryThresholds,
        now: Date = Date()
    ) async -> TreasuryCreationOutcome {
        guard let owner = await identity.currentSelectedID(),
              let account = try? StellarAccountID(accountID: treasuryAccountID)
        else { return .failed("bad account") }

        // The same guard `create` keeps, and the receive path keeps.
        // Without it a second `adopt` with a different account silently
        // re-points the founder's own device, which contradicts "a
        // treasury is never re-anchored" on the one device that can
        // still announce.
        //
        // The pending row goes too, and that is the point of clearing it
        // here rather than only on success. This group has a treasury;
        // whatever the wallet was asked to do is finished business. Left
        // behind, the row outlives the handoff and `TreasuryFlow`
        // restores `awaitingWallet` from it on the next launch — "waiting
        // for your wallet" on a group whose treasury already exists,
        // again on every launch after that.
        guard await treasury.snapshot(groupID: groupIDHex).treasury == nil else {
            await treasury.clearPendingCreation(groupID: groupIDHex)
            return .alreadyExists
        }

        guard let onChain = try? await horizon(network).account(account) else {
            return .failed("the treasury account is not on the ledger yet")
        }
        if let wrong = Self.misconfiguration(
            onChain,
            account: account,
            expectedCoSigners: expectedCoSigners,
            expectedThresholds: expectedThresholds
        ) {
            return .failed(wrong)
        }

        // The hash announced to the group must be one the group can look
        // up, and it must name the transaction this app prepared. It is
        // computed locally from the envelope handed to the wallet, and
        // nothing else checks the wallet submitted *that* transaction —
        // an equivalent one built by hand passes every configuration
        // check above and anchors a hash that is on no ledger,
        // permanently, because re-anchoring is refused.
        let applied = (try? await horizon(network).transactions(
            for: account,
            limit: Self.creationHistoryDepth
        )) ?? []
        guard applied.contains(where: { $0.hash == creationTxHash && $0.successful }) else {
            return .failed(
                "that account exists, but not from the transaction this app prepared"
            )
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
        await treasury.clearPendingCreation(groupID: groupIDHex)
        await broadcaster.announceAnchor(created, now: now)
        return .created(created)
    }
}
