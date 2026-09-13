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
    /// Re-derived if the proposal is revived after its group's anchor
    /// arrives late — see `TreasuryPayloadReceiver`.
    public var kind: TreasuryProposalKind
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
    /// Set aside on this device.
    ///
    /// Local and reversible: it changes nothing for anyone else and
    /// signs nothing. It exists because an open proposal holds the
    /// treasury's next sequence number, so a single one nobody intends
    /// to sign blocks every other proposal until its time bound runs
    /// out — up to a week. Everything else that can freeze a treasury
    /// this way is refused at the boundary; this is the case where the
    /// proposal is perfectly valid and the group simply changed its
    /// mind, and the answer to that cannot be "wait".
    case dismissed

    public var isActionable: Bool {
        switch self {
        case .collecting, .ready: true
        case .submitted, .superseded, .expired, .rejected, .dismissed: false
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
    /// The transaction offers a fee far above the going rate — a spend
    /// that would appear in none of the operation rows.
    case excessiveFee
    /// No time bound at all. Such a proposal never expires, and because
    /// it holds the treasury's next sequence number it would block
    /// every later proposal for good.
    case noExpiry
    /// A time bound so far out that it amounts to the same thing.
    case expiresTooLate
    /// Arrived carrying more signatures than a proposal should, which
    /// would leave no room for the co-signers who still have to sign.
    case tooManySignatures
    /// Claims a sequence number far beyond the treasury's next, which
    /// would block every later proposal until it expired.
    case implausibleSequence

    /// Whether this refusal was decided against something outside the
    /// envelope — the ledger — rather than against the bytes.
    ///
    /// The distinction decides what may be re-run. Almost every reason
    /// here is a permanent fact about a transaction: an operation
    /// outside the allowlist is outside it forever, and re-checking
    /// would be a way to launder a refusal by sending an anchor
    /// afterwards. These two are not. `noTreasury` says this device had
    /// nothing to compare against; `implausibleSequence` says the
    /// account's sequence, as this device last read it, was too far
    /// from the one claimed. Both change when the device learns more,
    /// and leaving them permanent means a proposal the network would
    /// accept sits refused for good because a snapshot was stale.
    public var isAboutTheLedger: Bool {
        switch self {
        case .noTreasury, .implausibleSequence:
            true
        case .notThisTreasury, .wrongNetwork, .unsupportedOperation,
             .foreignOperationSource, .proposerNotAMember, .malformed,
             .excessiveFee, .noExpiry, .expiresTooLate, .tooManySignatures:
            false
        }
    }
}
