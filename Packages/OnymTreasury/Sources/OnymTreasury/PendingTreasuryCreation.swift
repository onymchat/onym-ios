import Foundation
import OnymIdentity
import OnymStellar

/// A treasury creation handed to the founder's wallet and not yet
/// confirmed.
///
/// Persisted, because the alternative strands real money. The stage
/// lived only in a memoised flow: cleared on identity switch, gone on
/// relaunch. A founder whose wallet had already submitted then had no
/// route back to `confirmExternalCreation()` — the ledger holds a
/// funded, locked-down account, the group is never told it exists, and
/// the setup screen offers "Create a treasury" again, which mints a
/// *new* key and asks them to fund a second account. Nothing catches
/// it, because nothing was ever anchored.
///
/// Everything needed to finish the job later is here: which account to
/// look for, which configuration to insist on before believing it, and
/// which transaction hash to announce.
public struct PendingTreasuryCreation: Equatable, Sendable {
    public let groupID: String
    public let ownerIdentityID: IdentityID
    public let treasuryAccount: StellarAccountID
    public let network: StellarNetwork
    public let creationTxHash: String
    public let coSigners: [StellarAccountID]
    public let thresholds: TreasuryThresholds
    public let startedAt: Date

    /// The treasury's own key, kept only while a split creation is
    /// half-done.
    ///
    /// Nil for the in-app path, which creates and configures in one
    /// transaction and destroys the key before returning. The external
    /// path cannot: a wallet will not submit a two-source envelope, so
    /// the account is created first and configured second, and between
    /// those two transactions this key is the *only* thing that can
    /// configure or spend the account. Lose it there and the funds are
    /// unreachable by anyone, permanently.
    ///
    /// So it is written down, encrypted at rest with everything else in
    /// this record, and deleted the moment the configuration confirms.
    /// That is a real weakening of "never persisted, never rendered,
    /// never logged" and it is stated here rather than discovered: for
    /// the length of one wallet handoff, a treasury's master key exists
    /// on one device's disk.
    public let treasurySeed: Data?

    /// The hash of the configuring transaction, once submitted.
    ///
    /// Recorded before the ledger is re-read, so a crash between
    /// submitting step two and anchoring does not lose the one fact
    /// that cannot be recovered from the account itself — which
    /// transaction made it a treasury.
    public let configurationTxHash: String?

    public init(
        groupID: String,
        ownerIdentityID: IdentityID,
        treasuryAccount: StellarAccountID,
        network: StellarNetwork,
        creationTxHash: String,
        coSigners: [StellarAccountID],
        thresholds: TreasuryThresholds,
        startedAt: Date,
        treasurySeed: Data? = nil,
        configurationTxHash: String? = nil
    ) {
        self.groupID = groupID
        self.ownerIdentityID = ownerIdentityID
        self.treasuryAccount = treasuryAccount
        self.network = network
        self.creationTxHash = creationTxHash
        self.coSigners = coSigners
        self.thresholds = thresholds
        self.startedAt = startedAt
        self.treasurySeed = treasurySeed
        self.configurationTxHash = configurationTxHash
    }

    /// A copy carrying the configuring transaction's hash.
    public func recording(configurationTxHash hash: String) -> PendingTreasuryCreation {
        PendingTreasuryCreation(
            groupID: groupID,
            ownerIdentityID: ownerIdentityID,
            treasuryAccount: treasuryAccount,
            network: network,
            creationTxHash: creationTxHash,
            coSigners: coSigners,
            thresholds: thresholds,
            startedAt: startedAt,
            treasurySeed: treasurySeed,
            configurationTxHash: hash
        )
    }
}
