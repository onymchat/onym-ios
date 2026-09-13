import Foundation
import OnymIdentity
import OnymStellar

/// What a proposal is asking the treasury to do.
///
/// Derived from the decoded operations by `TreasuryProposalVerifier`,
/// never taken from the proposer's payload — a `kind` field a sender
/// could choose would be a label on a box whose contents it does not
/// have to match. It exists so the UI can pick a title and an icon
/// without re-deriving; the detail rows always come from the operations
/// themselves.
///
/// Raw values are a persistence format: stable forever.
public enum TreasuryProposalKind: String, Codable, Equatable, Sendable {
    /// Pay someone from the treasury. Medium threshold.
    case payment
    /// Hold a new asset. Medium threshold, and it raises the account's
    /// minimum balance by one base reserve.
    case trustline
    /// Add a co-signer. High threshold — which is what makes
    /// nomination a group decision rather than a founder's.
    case addSigner
    /// Remove a co-signer, or change how many signatures are needed.
    /// High threshold.
    case changeControl

    /// Which of the account's thresholds this must reach. Read from the
    /// account's live thresholds, not hardcoded numbers — the values
    /// themselves are whatever the group chose.
    public func requiredWeight(from thresholds: HorizonThresholds) -> UInt32 {
        switch self {
        case .payment, .trustline: thresholds.medium
        case .addSigner, .changeControl: thresholds.high
        }
    }
}

/// A transaction waiting for its co-signers.
///
/// The envelope is the proposal. Everything the UI renders about it is
/// decoded from `envelope.transaction` on this device, so what a
/// co-signer approves is what they were shown.
public struct TreasuryProposal: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let groupID: String
    public let ownerIdentityID: IdentityID
    /// Lowercase BLS pubkey hex of whoever proposed it.
    public let proposerBlsPubkeyHex: String
    public let treasuryAccount: StellarAccountID
    public let network: StellarNetwork
    public let kind: TreasuryProposalKind
    /// The transaction plus whatever signatures have been collected.
    public var envelope: TransactionEnvelope
    public let createdAt: Date
    /// Hash of the applied transaction once it lands. Non-nil means the
    /// network accepted it; the UI stops asking for signatures.
    public var submittedTxHash: String?

    public init(
        id: UUID,
        groupID: String,
        ownerIdentityID: IdentityID,
        proposerBlsPubkeyHex: String,
        treasuryAccount: StellarAccountID,
        network: StellarNetwork,
        kind: TreasuryProposalKind,
        envelope: TransactionEnvelope,
        createdAt: Date,
        submittedTxHash: String? = nil
    ) {
        self.id = id
        self.groupID = groupID
        self.ownerIdentityID = ownerIdentityID
        self.proposerBlsPubkeyHex = proposerBlsPubkeyHex.lowercased()
        self.treasuryAccount = treasuryAccount
        self.network = network
        self.kind = kind
        self.envelope = envelope
        self.createdAt = createdAt
        self.submittedTxHash = submittedTxHash
    }

    /// The operations a co-signer is being asked to approve, decoded on
    /// this device.
    public var operations: [StellarOperation] { envelope.transaction.operations }

    /// The sequence number this transaction consumes. Two proposals
    /// built against the same account state share it, and only one can
    /// ever apply.
    public var sequenceNumber: Int64 { envelope.transaction.sequenceNumber }

    /// When it stops being submittable. Nil only for a transaction
    /// built without time bounds, which this app never constructs.
    public var expiresAt: Date? {
        guard let maxTime = envelope.transaction.timeBounds?.maxTime, maxTime != 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(maxTime))
    }

    /// Which of `candidates` have signed, checked against this device's
    /// own transaction hash.
    public func signers(among candidates: [StellarAccountID]) -> [StellarAccountID] {
        candidates.filter { envelope.hasSignature(from: $0, network: network) }
    }
}

/// Where a proposal stands, derived from the chain and the clock rather
/// than stored.
///
/// Same discipline as `GroupRulesStanding`: every case is worked out
/// from current inputs each time it is asked. A stored status would go
/// stale the moment somebody else's transaction consumed the sequence
/// number, and "ready to submit" is the one answer that must never be
/// wrong.
public enum TreasuryProposalStanding: Equatable, Sendable {
    /// Still short of the threshold. Carries both numbers so the UI can
    /// say "2 of 3" rather than "not yet".
    case collecting(weight: UInt32, required: UInt32)
    /// Enough weight. Anyone holding it can submit.
    case ready
    /// Applied. Carries the transaction hash for the explorer link.
    case submitted(txHash: String)
    /// The account's sequence has already moved past this transaction —
    /// something else was submitted first. It can never apply now, and
    /// the only way forward is a fresh proposal.
    case superseded
    /// Past its time bound.
    case expired
    /// This device refused it on arrival. `reason` is for the person
    /// looking at it, and the proposal is kept rather than dropped so
    /// that a refusal is visible instead of silent.
    case rejected(reason: TreasuryRejection)

    public var isActionable: Bool {
        switch self {
        case .collecting, .ready: true
        case .submitted, .superseded, .expired, .rejected: false
        }
    }
}

/// Why a device refused a proposal it received.
///
/// Each case is a rule from `TreasuryProposalVerifier`. They are
/// enumerated rather than collapsed into one "invalid" because they
/// mean genuinely different things: a mismatched network is a peer on
/// the wrong setting, while an operation this app will not decode is
/// someone asking a group to sign something it cannot read.
public enum TreasuryRejection: String, Codable, Equatable, Sendable {
    /// The transaction's source is not this group's treasury.
    case notThisTreasury
    /// Built for a different Stellar network than the one named.
    case wrongNetwork
    /// Contains an operation outside the four a treasury uses — or one
    /// this app cannot decode at all.
    case unsupportedOperation
    /// An operation whose source account is neither the treasury nor
    /// absent: a transaction that also acts on somebody else's account,
    /// signed by this group's quorum.
    case foreignOperationSource
    /// The proposer is not a member of this group.
    case proposerNotAMember
    /// The XDR did not decode.
    case malformed
    /// No treasury is anchored for this group yet.
    case noTreasury
}
