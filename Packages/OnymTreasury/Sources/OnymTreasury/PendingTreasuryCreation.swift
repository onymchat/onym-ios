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

    public init(
        groupID: String,
        ownerIdentityID: IdentityID,
        treasuryAccount: StellarAccountID,
        network: StellarNetwork,
        creationTxHash: String,
        coSigners: [StellarAccountID],
        thresholds: TreasuryThresholds,
        startedAt: Date
    ) {
        self.groupID = groupID
        self.ownerIdentityID = ownerIdentityID
        self.treasuryAccount = treasuryAccount
        self.network = network
        self.creationTxHash = creationTxHash
        self.coSigners = coSigners
        self.thresholds = thresholds
        self.startedAt = startedAt
    }
}
